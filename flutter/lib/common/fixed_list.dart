/// A bounded list with append-in-place semantics for a high-frequency feed.
///
/// FlClash's `FixedList`: the producer appends into one shared buffer, a
/// generation counter tells a listener whether anything moved, and the UI reads
/// an immutable snapshot — instead of the producer allocating a fresh list per
/// batch and the UI slicing it back down to the window.
///
/// Two contracts matter, and both are about avoiding repeated copies of a tail
/// that is up to [capacity] rows long:
///
///  * Writes never copy the retained prefix. [appendAll] grows the internal
///    buffer and drops the oldest rows off the front, so a log burst costs the
///    new lines plus the trim's shift rather than a new list holding the whole
///    window. [replaceAll] exists for the feeds the host sends whole (the
///    connections page), which have nothing to append to.
///  * Reads are a snapshot with stable identity. [list] builds one unmodifiable
///    view and keeps returning the *same object* until the next mutation, so a
///    page can cache rows derived from it behind an `identical(previous, list)`
///    check (`pages/logs.dart`) and a provider watching the previous snapshot
///    does not rebuild when an event turns out to be a no-op.
///
/// There is deliberately no internal `ChangeNotifier`: the controller that owns
/// the list dispatches the notification after its own batching window
/// (`BoxController._dispatch`). A notifier here would fire per event, before
/// that window, which is exactly the once-per-row rebuild the batching avoids.
class FixedList<T> {
  FixedList({required this.capacity}) : assert(capacity > 0, 'a zero window is not a feed');

  /// The largest [length] the list keeps; older rows fall off the front.
  final int capacity;

  final _buffer = <T>[];
  List<T>? _snapshot;
  int _revision = 0;

  /// Generation counter: one step per mutation that changed the contents.
  ///
  /// A no-op (`appendAll` with nothing, `clear` on an empty list) does not bump
  /// it, so a consumer may treat "same revision" as "same rows".
  int get revision => _revision;

  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;
  bool get isNotEmpty => _buffer.isNotEmpty;

  /// Immutable snapshot of the current contents, stable until the next mutation.
  List<T> get list => _snapshot ??= List<T>.unmodifiable(_buffer);

  /// Appends [entries], trimming the oldest rows when the window overflows.
  void appendAll(Iterable<T> entries) {
    final added = entries is List<T> ? entries : entries.toList(growable: false);
    if (added.isEmpty) return;
    if (added.length >= capacity) {
      // The batch alone fills the window: the retained tail would be trimmed
      // away entirely, so skip growing the buffer with it first.
      _buffer
        ..clear()
        ..addAll(added.skip(added.length - capacity));
    } else {
      _buffer.addAll(added);
      final excess = _buffer.length - capacity;
      if (excess > 0) _buffer.removeRange(0, excess);
    }
    _changed();
  }

  /// Replaces the contents with [entries] (also trimming to [capacity]).
  void replaceAll(Iterable<T> entries) {
    final next = entries is List<T> ? entries : entries.toList(growable: false);
    _buffer
      ..clear()
      ..addAll(next.length > capacity ? next.skip(next.length - capacity) : next);
    _changed();
  }

  /// Drops every row; a clear of an already empty window is not a mutation.
  void clear() {
    if (_buffer.isEmpty) return;
    _buffer.clear();
    _changed();
  }

  void _changed() {
    _snapshot = null;
    _revision++;
  }
}
