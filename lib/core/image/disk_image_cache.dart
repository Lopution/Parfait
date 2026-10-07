import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The stored body did not match the length the response declared — the
/// file is deleted rather than committed, because a truncated image would
/// decode as garbage on the next hit.
class ImageCacheIncomplete implements Exception {
  const ImageCacheIncomplete(this.path, this.expected, this.received);

  final String path;
  final int expected;
  final int received;

  @override
  String toString() =>
      'ImageCacheIncomplete: $path expected $expected bytes, got $received';
}

/// On-disk image store owned by the background image worker.
///
/// Keys are `sha1` of the *canonical* request URL (before mirror rewriting),
/// so a mirror switch never invalidates entries. Files are written to
/// `<key>.tmp` and renamed onto `<key><ext>` atomically, so a hit can never
/// observe a partially written file; leftover `.tmp` files are swept on
/// open.
///
/// The index is in-memory and rebuilt from a directory scan on open —
/// no sqlite, no platform channels, both of which the worker isolate cannot
/// (and the main isolate should not) pay for during scroll. Eviction is
/// LRU by last access; hits update the in-memory order and the file mtime
/// so a restart keeps the same recency order.
class DiskImageCache {
  DiskImageCache._(
    this._dir, {
    this.maxBytes = defaultMaxBytes,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The worker cache directory name under the system temp dir.
  static const directoryName = 'parfait_images_v2';

  /// Cache size ceiling.
  static const defaultMaxBytes = 256 * 1024 * 1024;

  static final _keyPattern = RegExp(r'^[0-9a-f]{40}(\.[a-z0-9]{1,5})?$');
  static final _extensionPattern = RegExp(r'\.([a-z0-9]{1,5})$');

  final Directory _dir;
  final int maxBytes;
  final DateTime Function() _clock;

  /// URL keys in LRU order — oldest first. Entry order and file mtime both
  /// express last access; the order is the authority while running, mtime
  /// is how the next launch rebuilds it.
  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();
  var _totalBytes = 0;

  int get totalBytes => _totalBytes;
  int get entryCount => _entries.length;

  /// Opens the store over [dir] (created when missing), sweeping
  /// interrupted writes and rebuilding the index. Throws when [dir] cannot
  /// be created or listed — a store that cannot start must not pretend to
  /// exist (the worker reports the init failure instead of silently
  /// fetching without a cache).
  ///
  /// The scan is synchronous: it runs once in the worker isolate, where a
  /// blocking stat per file is far cheaper than an IO-pool round trip each.
  static DiskImageCache open(
    Directory dir, {
    int maxBytes = defaultMaxBytes,
    DateTime Function()? clock,
  }) {
    dir.createSync(recursive: true);
    return DiskImageCache._(dir, maxBytes: maxBytes, clock: clock).._scan();
  }

  /// Content-addressed file base for [url]: sha1 hex plus the URL's own
  /// extension, so a saved/shared file keeps a sensible suffix.
  static String keyFor(String url) {
    final digest = sha1.convert(utf8.encode(url)).toString();
    final lastSegment = Uri.tryParse(url)?.pathSegments.lastOrNull ?? '';
    final match = _extensionPattern.firstMatch(lastSegment.toLowerCase());
    return match == null ? digest : '$digest${match.group(0)}';
  }

  /// The cached file for [url], or null on a miss (absent index entry or a
  /// file that vanished since the scan). A hit moves the entry to the LRU
  /// tail and updates its mtime.
  Future<File?> lookup(String url) async {
    final key = keyFor(url);
    final entry = _entries.remove(key);
    if (entry == null) return null;
    final file = File(_filePath(key));
    if (!await file.exists()) {
      _totalBytes -= entry.size;
      return null;
    }
    _entries[key] = _CacheEntry(entry.size, _clock());
    try {
      // Persisted recency: the next launch rebuilds LRU order from mtimes.
      await file.setLastModified(_clock());
    } on Object {
      // A read-only filesystem hit still counts as a hit.
    }
    return file;
  }

  /// Streams [body] into a temp file and commits it under [url]'s key.
  /// When [expectedLength] is given and the received byte count differs the
  /// partial file is deleted and [ImageCacheIncomplete] is thrown — only a
  /// complete body ever lands under a real key.
  Future<File> store(
    String url,
    Stream<List<int>> body, {
    int? expectedLength,
  }) async {
    final key = keyFor(url);
    final tmp = File(
      '${_filePath(key)}.tmp-${_clock().microsecondsSinceEpoch}',
    );
    var written = 0;
    IOSink? sink;
    try {
      sink = tmp.openWrite();
      await for (final chunk in body) {
        written += chunk.length;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expectedLength != null && expectedLength != written) {
        await tmp.delete();
        throw ImageCacheIncomplete(tmp.path, expectedLength, written);
      }
      await tmp.rename(_filePath(key));
    } on Object {
      if (sink != null) {
        try {
          await sink.close();
        } on Object {
          // Best-effort cleanup: the original error is the one that matters.
        }
      }
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } on Object {
          // Best-effort cleanup: the original error is the one that matters.
        }
      }
      rethrow;
    }
    _track(key, written);
    return File(_filePath(key));
  }

  /// Commits an in-memory [bytes] body — used by tests and the segmented
  /// writer path that already holds the full buffer.
  Future<File> storeBytes(String url, Uint8List bytes) =>
      store(url, Stream<List<int>>.value(bytes), expectedLength: bytes.length);

  Future<void> remove(String url) async {
    final key = keyFor(url);
    final entry = _entries.remove(key);
    if (entry == null) return;
    _totalBytes -= entry.size;
    try {
      await File(_filePath(key)).delete();
    } on Object {
      // Already gone — the index stays authoritative.
    }
  }

  void _scan() {
    final found = <(String key, _CacheEntry)>[];
    for (final entity in _dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.contains('.tmp')) {
        // Interrupted write — a real key only ever exists complete. Swept
        // inline like the rest of the scan, so a reopened cache never races
        // its own cleanup.
        try {
          entity.deleteSync();
        } on FileSystemException {
          // Already gone, or held by another writer; the next open retries.
        }
        continue;
      }
      if (!_keyPattern.hasMatch(name)) continue;
      final stat = entity.statSync();
      found.add((name, _CacheEntry(stat.size, stat.modified)));
    }
    found.sort((a, b) => a.$2.accessed.compareTo(b.$2.accessed));
    for (final (key, entry) in found) {
      _entries[key] = entry;
      _totalBytes += entry.size;
    }
    _evictIfNeeded();
  }

  void _track(String key, int size) {
    final existing = _entries.remove(key);
    if (existing != null) _totalBytes -= existing.size;
    _entries[key] = _CacheEntry(size, _clock());
    _totalBytes += size;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    while (_totalBytes > maxBytes && _entries.isNotEmpty) {
      final key = _entries.keys.first;
      _totalBytes -= _entries.remove(key)!.size;
      unawaited(File(_filePath(key)).delete().catchError((_) => File('')));
    }
  }

  String _filePath(String key) => '${_dir.path}/$key';
}

class _CacheEntry {
  const _CacheEntry(this.size, this.accessed);

  final int size;
  final DateTime accessed;
}
