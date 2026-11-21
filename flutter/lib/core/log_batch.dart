/// Kernel log batching shared by the service engine and the UI.
///
/// A start emits a burst of one-line events. Crossing the engine boundary once
/// per line copied the UI's log tail for every entry; a short window and a
/// bounded batch reduce that to one message per frame's worth of lines. The
/// limit mirrors the receiver's ring so a batch can never carry rows the UI
/// would immediately discard.
const logBatchWindow = Duration(milliseconds: 16);
const logRingLimit = 512;
const maxKernelLogBatchLines = logRingLimit;
