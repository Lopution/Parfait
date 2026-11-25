/// A byte-budgeted LRU cache used for decoded Ugoira frames.
///
/// The cache owns its values. Eviction and [clear] always call [dispose], so
/// callers cannot accidentally retain native image resources after a frame
/// leaves the bounded window.
class UgoiraFrameCache<T> {
  UgoiraFrameCache({
    required int maxBytes,
    required int Function(T value) sizeOf,
    required void Function(T value) dispose,
    this.loopAware = false,
  }) : assert(maxBytes > 0),
       _maxBytes = maxBytes,
       _sizeOf = sizeOf,
       _dispose = dispose;

  final int _maxBytes;
  final int Function(T value) _sizeOf;
  final void Function(T value) _dispose;

  /// When true, evicts the most-recently-played prior frame (furthest in the
  /// next loop) rather than the oldest prefix frame, avoiding 0% hit-rate LRU
  /// thrash on looping playback whose total frames exceed [_maxBytes].
  final bool loopAware;
  final Map<int, _CacheEntry<T>> _entries = {};
  int _residentBytes = 0;

  int get length => _entries.length;

  int get residentBytes => _residentBytes;

  T? get(int index) {
    final entry = _entries.remove(index);
    if (entry == null) return null;
    // Dart's insertion-ordered map makes remove/reinsert the LRU touch.
    _entries[index] = entry;
    return entry.value;
  }

  void put(int index, T value) {
    final bytes = _sizeOf(value);
    if (bytes <= 0 || bytes > _maxBytes) {
      _dispose(value);
      throw ArgumentError.value(
        bytes,
        'value bytes',
        'must be between 1 and the cache byte budget',
      );
    }

    final old = _entries.remove(index);
    if (old != null) {
      _residentBytes -= old.bytes;
      if (!identical(old.value, value)) {
        _dispose(old.value);
      }
    }
    _entries[index] = _CacheEntry(value: value, bytes: bytes);
    _residentBytes += bytes;

    while (_residentBytes > _maxBytes && _entries.isNotEmpty) {
      final victimKey = _pickEvictionKey(index);
      final victim = _entries.remove(victimKey)!;
      _residentBytes -= victim.bytes;
      if (!identical(victim.value, value)) {
        _dispose(victim.value);
      }
    }
  }

  int _pickEvictionKey(int justInserted) {
    if (!loopAware || _entries.length <= 1) {
      return _entries.keys.first;
    }
    // Evict the most recently used entry other than [justInserted] (which was
    // just played and is furthest away in the next loop).
    int? victim;
    for (final key in _entries.keys) {
      if (key != justInserted) victim = key;
    }
    return victim ?? _entries.keys.first;
  }

  void remove(int index) {
    final entry = _entries.remove(index);
    if (entry == null) return;
    _residentBytes -= entry.bytes;
    _dispose(entry.value);
  }

  void clear() {
    for (final entry in _entries.values) {
      _dispose(entry.value);
    }
    _entries.clear();
    _residentBytes = 0;
  }
}

class _CacheEntry<T> {
  const _CacheEntry({required this.value, required this.bytes});

  final T value;
  final int bytes;
}
