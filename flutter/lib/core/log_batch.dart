/// Kernel log batching shared by the service engine and the UI.
///
/// A start emits a burst of one-line events. Crossing the engine boundary once
/// per line copied the UI's log tail for every entry; a short window and a
/// bounded batch reduce that to one message per frame's worth of lines. The
/// limit mirrors the receiver's ring so a batch can never carry rows the UI
/// would immediately discard.
const logBatchWindow = Duration(milliseconds: 16);

/// The in-memory tail, matching FlClash's `maxLogsLength`: long enough to hold a
/// whole start burst plus the recent session, still bounded.
const logRingLimit = 5000;

/// One cross-engine payload stays bounded independently of the ring: the service
/// engine flushes every 512 lines. The UI's own pending buffer is capped by the
/// ring (see BoxController.maxLogLength), so a burst can still fill 5000 rows.
const maxKernelLogBatchLines = 512;

/// While the reader is scrolled away from the newest line, both the old head and
/// the arriving tail are kept (FlClash's `pausedMaxLogsLength`).
const pausedLogLimit = 10000;
