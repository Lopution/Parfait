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
  }) : assert(maxBytes > 0),
       _maxBytes = maxBytes,
       _sizeOf = sizeOf,
       _dispose = dispose;

  final int _maxBytes;
  final int Function(T value) _sizeOf;
  final void Function(T value) _dispose;
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
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey)!;
      _residentBytes -= oldest.bytes;
      if (!identical(oldest.value, value)) {
        _dispose(oldest.value);
      }
    }
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
