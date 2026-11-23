package io.flrone.bridge

/**
 * The one queue every host event leaves the process through.
 *
 * Three lanes, as in FlClash's `core/message.go`: a **state** lane for snapshots whose loss
 * would leave a screen permanently wrong (it is only bounded so a leak still ends), a 256-entry
 * **priority** lane for the ordinary pushes, and a 256-entry **bulk** lane for the feeds whose
 * size follows the payload (log tails, the connection list). A full priority or bulk lane
 * evicts its own oldest message, never another lane's.
 *
 * Delivery is batched: the queue is drained when 32 messages are waiting or after 16 ms,
 * whichever comes first, and the drained messages go out in one platform-thread turn. Priority
 * is preferred, but one bulk message is guaranteed after eight consecutive priority messages so
 * a rates tick cannot starve the log screen.
 *
 * [enqueue] may be called from any thread; the injected [Scheduler] posts the drain onto the
 * platform thread, and [deliver] runs there only. The class deliberately knows nothing about
 * Android: a unit test drives a fake scheduler, and the bridge supplies a `Handler` adapter.
 */
internal class EventPump(
    private val scheduler: Scheduler,
    private val deliver: (Map<String, Any?>) -> Unit,
) {

    /** Runs [task] on the platform thread after [delayMillis]; returns a cancel handle. */
    fun interface Scheduler {
        fun post(delayMillis: Long, task: Runnable): () -> Unit
    }

    /**
     * One outbound queue. The order of the enum values is the drain preference: state first,
     * then priority with the bulk starvation guard, then bulk alone.
     */
    enum class Lane(val bound: Int) {
        STATE(1024),
        PRIORITY(256),
        BULK(256),
    }

    companion object {
        /** FlClash's `messageBatchSize` / `messageQueueSize` / `messagePriorityBurst`. */
        const val BATCH_SIZE = 32
        const val BATCH_MILLIS = 16L
        const val PRIORITY_BURST = 8
    }

    private class Item(val lane: Lane, val type: String, val payload: Any?) {
        fun event(): Map<String, Any?> = mapOf("type" to type, "value" to payload)
    }

    private val lock = Any()
    private val queues = Array(Lane.entries.size) { ArrayDeque<Item>() }
    private val enqueued = IntArray(queues.size)
    private val flushed = IntArray(queues.size)
    private val dropped = IntArray(queues.size)

    /** Consecutive priority messages drained since the last bulk turn. */
    private var burst = 0

    private var maxDepth = 0
    private var bulkBytes = 0L

    /** Cancel handle of the armed drain, and its delay; the earliest armed delay wins. */
    private var tick: (() -> Unit)? = null
    private var tickDelay = Long.MAX_VALUE

    /**
     * Whether a listener is attached. Read without the lock on [enqueue]'s fast path, written
     * under it by [attach]/[detach]; the locked re-check is what decides.
     */
    @Volatile
    private var attached = false

    /**
     * Queues one event.
     *
     * [encode] is the bulk path: it runs on the **calling** thread and only while a listener is
     * attached, so an unwatched log feed costs nothing at all — not even the encode — and a
     * watched one pays for it on the producing thread instead of the platform thread. A
     * `null` or empty encoding means the payload cannot be sent; it is dropped here, where the
     * cause is still known, rather than failing later as a generic codec error.
     */
    fun enqueue(
        type: String,
        value: Any?,
        lane: Lane = Lane.PRIORITY,
        encode: ((Any?) -> ByteArray)? = null,
    ) {
        if (encode != null && !attached) {
            drop(lane)
            return
        }
        // Outside the lock: an encode is proportional to the payload (a log batch is up to
        // 1500 rows), and holding the queue lock across it would serialise every producer.
        val payload = if (encode == null) value else runCatching { encode(value) }.getOrNull()
        if (encode != null && (payload !is ByteArray || payload.isEmpty())) {
            drop(lane)
            return
        }
        synchronized(lock) {
            // A detach can land between the fast-path check and here; the item then has no
            // reader, so it is dropped rather than left in a queue nobody will drain.
            if (!attached) {
                dropped[lane.ordinal]++
                return
            }
            if (encode != null) bulkBytes += (payload as ByteArray).size
            val queue = queues[lane.ordinal]
            if (queue.size >= lane.bound) {
                queue.removeFirst()
                dropped[lane.ordinal]++
            }
            queue.addLast(Item(lane, type, payload))
            enqueued[lane.ordinal]++
            val depth = depth()
            if (depth > maxDepth) maxDepth = depth
            arm(if (depth >= BATCH_SIZE) 0L else BATCH_MILLIS)
        }
    }

    private fun drop(lane: Lane) {
        synchronized(lock) { dropped[lane.ordinal]++ }
    }

    /**
     * Starts accepting events. The queues and counters start clean: a new listener has seen
     * nothing this pump queued for the previous one.
     */
    fun attach() {
        synchronized(lock) {
            cancelTick()
            queues.forEach { it.clear() }
            enqueued.fill(0)
            flushed.fill(0)
            dropped.fill(0)
            burst = 0
            maxDepth = 0
            bulkBytes = 0L
            attached = true
        }
    }

    /**
     * Stops accepting events and **discards** what was queued: the listener is gone, so a
     * queued event has no reader left. The counters survive the detach so the snapshot taken
     * afterwards still explains what happened; [attach] resets them.
     */
    fun detach() {
        synchronized(lock) {
            attached = false
            cancelTick()
            queues.forEachIndexed { index, queue ->
                dropped[index] += queue.size
                queue.clear()
            }
            burst = 0
        }
    }

    /**
     * Delivers everything queued right now, ignoring the batch size: the stop/dispose path,
     * where waiting out a 16 ms window means the events die with the pump. Must be called on
     * the platform thread — the one [deliver] is promised.
     */
    fun flushNow() {
        synchronized(lock) {
            cancelTick()
        }
        drain(all = true)
    }

    /**
     * Counters and depths, for diagnostics. `flushed` counts what left the queue — a delivery
     * the sink refused is counted there, because the message is gone either way — and
     * `bulk.bytes` is the encoded volume since the last [attach].
     */
    fun snapshot(): Map<String, Any> = synchronized(lock) {
        val out = LinkedHashMap<String, Any>()
        out["attached"] = attached
        out["depth"] = depth()
        out["maxDepth"] = maxDepth
        for (lane in Lane.entries) {
            val key = lane.name.lowercase()
            out["$key.enqueued"] = enqueued[lane.ordinal]
            out["$key.flushed"] = flushed[lane.ordinal]
            out["$key.dropped"] = dropped[lane.ordinal]
            out["$key.depth"] = queues[lane.ordinal].size
        }
        out["bulk.bytes"] = bulkBytes
        out
    }

    /** Arms a drain no later than [delayMillis]; an earlier armed drain already covers this one. */
    private fun arm(delayMillis: Long) {
        val armed = tick
        if (armed != null && tickDelay <= delayMillis) return
        armed?.invoke()
        tickDelay = delayMillis
        tick = scheduler.post(delayMillis) { onTick() }
    }

    private fun cancelTick() {
        tick?.invoke()
        tick = null
        tickDelay = Long.MAX_VALUE
    }

    private fun onTick() {
        synchronized(lock) {
            tick = null
            tickDelay = Long.MAX_VALUE
        }
        drain(all = false)
    }

    private fun depth(): Int = queues.sumOf { it.size }

    /**
     * Takes up to [BATCH_SIZE] messages (everything, for [flushNow]) in delivery order.
     *
     * State first — a snapshot that is dropped is a screen that stays wrong, and the lane is
     * rare enough that draining it ahead of everything cannot starve the others. One bulk
     * message after [PRIORITY_BURST] priority messages is FlClash's starvation guard: under a
     * steady priority load the bulk lane still gets a turn every eight messages.
     */
    private fun take(all: Boolean): List<Item> {
        val limit = if (all) Int.MAX_VALUE else BATCH_SIZE
        val batch = ArrayList<Item>(minOf(limit, BATCH_SIZE))
        while (batch.size < limit) {
            val next = when {
                queues[Lane.STATE.ordinal].isNotEmpty() -> queues[Lane.STATE.ordinal].removeFirst()
                burst >= PRIORITY_BURST && queues[Lane.BULK.ordinal].isNotEmpty() -> {
                    burst = 0
                    queues[Lane.BULK.ordinal].removeFirst()
                }
                queues[Lane.PRIORITY.ordinal].isNotEmpty() -> {
                    burst++
                    queues[Lane.PRIORITY.ordinal].removeFirst()
                }
                queues[Lane.BULK.ordinal].isNotEmpty() -> {
                    burst = 0
                    queues[Lane.BULK.ordinal].removeFirst()
                }
                else -> break
            }
            batch.add(next)
        }
        return batch
    }

    private fun drain(all: Boolean) {
        while (true) {
            val batch = synchronized(lock) {
                if (!attached) return
                take(all)
            }
            if (batch.isEmpty()) return
            // A sink that throws (the channel torn down under a delivery) must not lose the
            // rest of the batch or the next one.
            for (item in batch) runCatching { deliver(item.event()) }
            synchronized(lock) {
                for (item in batch) flushed[item.lane.ordinal]++
            }
            // More than one batch waiting: drain it in this same turn instead of queueing a
            // runnable per 32 messages behind a log flood.
            if (!all) synchronized(lock) { if (depth() == 0) return }
        }
    }
}
