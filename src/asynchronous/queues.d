module asynchronous.queues;

import std.algorithm;
import std.exception;
import std.range;
import std.typecons;
import asynchronous.events : EventLoop, getEventLoop;
import asynchronous.futures : Waiter;
import asynchronous.locks : Event;
import asynchronous.tasks : waitFor;
import asynchronous.types : Coroutine;

/// Queues

/**
 * Exception thrown when $(D_PSYMBOL Queue.getNowait()) is called on a
 * $(D_PSYMBOL Queue) object which is empty.
 */
class QueueEmptyException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * Exception thrown when $(D_PSYMBOL Queue.putNowait()) is called on a
 * $(D_PSYMBOL Queue) object which is full.
 */
class QueueFullException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * A queue, useful for coordinating producer and consumer coroutines.
 *
 * If $(D_PSYMBOL maxsize) is equal to zero, the queue size is infinite.
 * Otherwise $(D_PSYMBOL put()) will block when the queue reaches maxsize, until
 * an item is removed by $(D_PSYMBOL get()).
 *
 * You can reliably know this $(D_PSYMBOL Queue)'s size with $(D_PSYMBOL
 * qsize()), since your single-threaded asynchronous application won't be
 * interrupted between calling $(D_PSYMBOL qsize()) and doing an operation on
 * the Queue.
 *
 * This class is not thread safe.
 */
class Queue(T)
{
    private EventLoop eventLoop;
    private size_t maxsize_;
    private Waiter[] getters;
    private Waiter[] putters;
    private size_t unfinishedTasks = 0;
    private Event finished;
    private T[] queue;
    private size_t start = 0;
    private size_t length = 0;

    this(EventLoop eventLoop = null, size_t maxsize = 0)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;
        
        this.maxsize_ = maxsize;

        this.finished = new Event(this.eventLoop);
        this.finished.set;
    }

    override string toString()
    {
        import std.string;

        return "%s(maxsize %s, queue %s, getters %s, putters %s, unfinisedTasks %s)"
            .format(typeid(this), maxsize, queue, getters, putters,
                unfinishedTasks);
    }

    protected T get_()
    {
        auto result = queue[start];
        queue[start] = T.init;
        ++start;
        if (start == queue.length)
            start = 0;
        --length;
        return result;
    }

    protected void put_(T item)
    {
        queue[(start + length) % $] = item;
        ++length;
    }

    private void ensureCapacity()
    {
        if (length < queue.length)
            return;

        assert(maxsize_ == 0 || length < maxsize_);
        assert(length == queue.length);

        size_t newLength = max(8, length * 2);

        if (maxsize_ > 0)
            newLength = min(newLength, maxsize_);

        bringToFront(queue[0 .. start], queue[start .. $]);
        start = 0;

        queue.length = newLength;

        if (maxsize_ == 0)
            queue.length = queue.capacity;
    }

    private void consumeDoneGetters()
    {
        // Delete waiters at the head of the get() queue who've timed out.
        getters = getters.find!(g => !g.done);
    }

    private void consumeDonePutters()
    {
        // Delete waiters at the head of the put() queue who've timed out.
        putters = putters.find!(g => !g.done);
    }

    /**
     * Return $(D_KEYWORD true) if the queue is empty, $(D_KEYWORD false)
     * otherwise.
     */
    @property bool empty()
    {
        return queue.empty;
    }

    /**
     * Return $(D_KEYWORD true) if there are maxsize items in the queue.
     *
     * Note: if the Queue was initialized with $(D_PSYMBOL maxsize) = 0 (the
     * default), then $(D_PSYMBOL full()) is never $(D_KEYWORD true).
     */
    @property bool full()
    {
        if (maxsize == 0)
            return false;
        else
            return qsize >= maxsize;
    }

    /**
     * Remove and return an item from the queue.
     *
     * If queue is empty, wait until an item is available.
     */
    @Coroutine
    T get()
    {
        consumeDonePutters;

        if (!putters.empty)
        {
            assert(full, "queue not full, why are putters waiting?");

            auto putter = putters.front;
            putter.setResult;
            putters.popFront;
        }
        else if (queue.empty)
        {
            auto waiter = new Waiter(eventLoop);

            putters ~= waiter;
            eventLoop.waitFor(waiter);
            assert(!queue.empty);
        }

        return get_;
    }

    /**
     * Remove and return an item from the queue.
     *
     * Return an item if one is immediately available, else throw $(D_PSYMBOL
     * QueueEmptyException).
     */
    @Coroutine
    T getNowait()
    {
        consumeDonePutters;

        if (!putters.empty)
        {
            assert(full, "queue not full, why are putters waiting?");

            auto putter = putters.front;
            putter.setResult;
            putters.popFront;
        }
        else
        {
            enforceEx!QueueEmptyException(!queue.empty);
        }

        return get_;
    }

    /**
     * Block until all items in the queue have been gotten and processed.
     *
     * The count of unfinished tasks goes up whenever an item is added to the
     * queue. The count goes down whenever a consumer calls $(D_PSYMBOL
     * taskDone()) to indicate that the item was retrieved and all work on it is
     * complete.
     * When the count of unfinished tasks drops to zero, $(D_PSYMBOL join())
     * unblocks.
     */
    @Coroutine
    void join()
    {
        if (unfinishedTasks > 0)
            finished.wait;
    }

    /**
     * Put an item into the queue.
     *
     * If the queue is full, wait until a free slot is available before adding
     * item.
     */
    @Coroutine
    void put(T item)
    {
        consumeDoneGetters;

        if (!getters.empty)
        {
            assert(queue.empty, "queue non-empty, why are getters waiting?");

            auto getter = getters.front;
            getter.setResult;
            getters.popFront;
        }
        else if (maxsize > 0 && maxsize <= qsize)
        {
            auto waiter = new Waiter(eventLoop);

            putters ~= waiter;
            eventLoop.waitFor(waiter);
            assert(qsize < maxsize);
        }

        ensureCapacity;
        put_(item);
        ++unfinishedTasks;
        finished.clear;
    }

    /**
     * Put an item into the queue without blocking.
     *
     * If no free slot is immediately available, throw $(D_PSYMBOL
     * QueueFullException).
     */
    void putNowait(T item)
    {
        consumeDoneGetters;

        if (!getters.empty)
        {
            assert(queue.empty, "queue non-empty, why are getters waiting?");

            auto getter = getters.front;
            getter.setResult;
            getters.popFront;
        }
        else
        {
            enforceEx!QueueFullException(maxsize == 0 || qsize < maxsize);
        }

        ensureCapacity;
        put_(item);
        ++unfinishedTasks;
        finished.clear;
    }

    /**
     * Number of items in the queue.
     */
    @property size_t qsize()
    {
        return length;
    }

    /**
     * Indicate that a formerly enqueued task is complete.
     *
     * Used by queue consumers. For each $(D_PSYMBOL get()) used to fetch a
     * task, a subsequent call to $(D_PSYMBOL taskDone()) tells the queue that
     * the processing on the task is complete.
     *
     * If a $(D_PSYMBOL join()) is currently blocking, it will resume when all
     * items have been processed (meaning that a $(D_PSYMBOL taskDone()) call
     * was received for every item that had been $(D_PSYMBOL put()) into the
     * queue).
     *
     * Throws $(D_PSYMBOL Exception) if called more times than there were items
     * placed in the queue.
     */
    void taskDone()
    {
        enforce(unfinishedTasks > 0, "taskDone() called too many times");

        --unfinishedTasks;
        if (unfinishedTasks == 0)
            finished.set;
    }

    /**
     * Number of items allowed in the queue.
     */
    @property size_t maxsize()
    {
        return maxsize_;
    }
}

unittest
{
    auto queue = new Queue!int;

    foreach (i; iota(200))
        queue.putNowait(i);

    foreach (i; iota(200))
        assert(queue.getNowait == i);
}

unittest
{
    auto queue = new Queue!int(null, 10);

    foreach (i; iota(10))
        queue.putNowait(i);

    assertThrown!QueueFullException(queue.putNowait(11));
}

/**
 * A subclass of $(D_PSYMBOL Queue); retrieves entries in priority order (lowest
 * first).
 *
 * Entries are typically tuples of the form: (priority number, data).
 */
//class PriorityQueue(T) : Queue(T)
//{

//    def _init(self, maxsize):
//        self._queue = []

//    def _put(self, item, heappush=heapq.heappush):
//        heappush(self._queue, item)

//    def _get(self, heappop=heapq.heappop):
//        return heappop(self._queue)
//}

//class LifoQueue(Queue):
//    """A subclass of Queue that retrieves most recently added entries first."""

//    def _init(self, maxsize):
//        self._queue = []

//    def _put(self, item):
//        self._queue.append(item)

//    def _get(self):
//        return self._queue.pop()
