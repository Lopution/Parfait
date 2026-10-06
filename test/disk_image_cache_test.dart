import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/image/disk_image_cache.dart';

Directory _freshDir() {
  final dir = Directory.systemTemp.createTempSync('parfait-dcache-');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Uint8List _bytes(int seed, int size) =>
    Uint8List.fromList(List.generate(size, (i) => (seed + i) % 251));

void main() {
  test('miss returns null; stored file hits and round-trips bytes', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir);
    const url = 'https://i.pximg.net/img-master/img/1_p0_master1200.jpg';
    expect(await cache.lookup(url), isNull);

    final file = await cache.storeBytes(url, _bytes(7, 4096));
    expect(await file.readAsBytes(), _bytes(7, 4096));
    expect(file.parent.path, dir.path);
    expect(cache.totalBytes, 4096);
    expect(cache.entryCount, 1);

    final hit = await cache.lookup(url);
    expect(hit, isNotNull);
    expect(await hit!.readAsBytes(), _bytes(7, 4096));
  });

  test('key keeps the URL extension and stays stable', () {
    const url =
        'https://i.pximg.net/img-original/img/2020/01/01/00/00/01_p0.png';
    final key = DiskImageCache.keyFor(url);
    expect(key, matches(RegExp(r'^[0-9a-f]{40}\.png$')));
    expect(DiskImageCache.keyFor(url), key);
    expect(
      DiskImageCache.keyFor(
        'https://i.pximg.net/c/540x540_70/img-master/img/1_p0_master1200.jpg',
      ),
      isNot(key),
    );
    // Extensionless or odd paths still get a pure hash name.
    expect(
      DiskImageCache.keyFor('https://i.pximg.net/favicon.ico?x=1'),
      matches(RegExp(r'^[0-9a-f]{40}(\.ico)?$')),
    );
  });

  test('a half-written tmp file is never a hit and is swept on open', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir);
    const url = 'https://i.pximg.net/a.jpg';
    // Simulate an interrupted write: a dangling .tmp sibling of the key.
    final key = DiskImageCache.keyFor(url);
    final tmp = File('${dir.path}/$key.tmp-1');
    await tmp.writeAsBytes(_bytes(1, 100));

    expect(await cache.lookup(url), isNull);
    expect(cache.entryCount, 0);

    final reopened = DiskImageCache.open(dir);
    expect(await tmp.exists(), isFalse);
    expect(reopened.entryCount, 0);
  });

  test('a body shorter than the declared length is not committed', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir);
    const url = 'https://i.pximg.net/short.jpg';
    await expectLater(
      cache.store(
        url,
        Stream<List<int>>.fromIterable([_bytes(0, 50), _bytes(1, 50)]),
        expectedLength: 150,
      ),
      throwsA(isA<ImageCacheIncomplete>()),
    );
    expect(await cache.lookup(url), isNull);
    // No stray tmp file is left behind either.
    expect(await dir.list().isEmpty, isTrue);
  });

  test('oldest entries are evicted once the size cap is exceeded', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir, maxBytes: 1000);
    for (var i = 0; i < 4; i++) {
      await cache.storeBytes('https://i.pximg.net/$i.jpg', _bytes(i, 400));
    }
    expect(cache.entryCount, 2); // 800 <= 1000; the two oldest are gone
    expect(await cache.lookup('https://i.pximg.net/0.jpg'), isNull);
    expect(await cache.lookup('https://i.pximg.net/1.jpg'), isNull);
    expect(await cache.lookup('https://i.pximg.net/2.jpg'), isNotNull);
    expect(await cache.lookup('https://i.pximg.net/3.jpg'), isNotNull);
    expect(cache.totalBytes, 800);
  });

  test('a lookup refreshes recency — the read one survives eviction', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir, maxBytes: 1000);
    await cache.storeBytes('https://i.pximg.net/0.jpg', _bytes(0, 400));
    await cache.storeBytes('https://i.pximg.net/1.jpg', _bytes(1, 400));
    // Read 0 again: now 1 is the oldest.
    expect(await cache.lookup('https://i.pximg.net/0.jpg'), isNotNull);
    await cache.storeBytes('https://i.pximg.net/2.jpg', _bytes(2, 400));
    expect(await cache.lookup('https://i.pximg.net/0.jpg'), isNotNull);
    expect(await cache.lookup('https://i.pximg.net/1.jpg'), isNull);
  });

  test('reopen rebuilds the index and keeps mtime order', () async {
    final dir = _freshDir();
    var now = DateTime(2030, 1, 1, 12);
    var cache = DiskImageCache.open(dir, clock: () => now);
    await cache.storeBytes('https://i.pximg.net/old.jpg', _bytes(0, 300));
    await cache.storeBytes('https://i.pximg.net/new.jpg', _bytes(1, 300));
    // Touch the older file so it survives the next cap check post-restart.
    now = now.add(const Duration(hours: 1));
    expect(await cache.lookup('https://i.pximg.net/old.jpg'), isNotNull);

    cache = DiskImageCache.open(dir, maxBytes: 400);
    // Over cap already at scan: the untouched (older-mtime) entry is
    // evicted before the cache reports ready.
    expect(cache.entryCount, 1);
    expect(cache.totalBytes, 300);
    expect(await cache.lookup('https://i.pximg.net/old.jpg'), isNotNull);
    expect(await cache.lookup('https://i.pximg.net/new.jpg'), isNull);
  });

  test('remove deletes the file and frees the budget', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir, maxBytes: 500);
    await cache.storeBytes('https://i.pximg.net/a.jpg', _bytes(0, 400));
    await cache.remove('https://i.pximg.net/a.jpg');
    expect(await cache.lookup('https://i.pximg.net/a.jpg'), isNull);
    expect(cache.totalBytes, 0);
    await cache.remove('https://i.pximg.net/a.jpg'); // idempotent
  });

  test('open creates a missing directory', () async {
    final dir = Directory('${_freshDir().path}/nested/cache');
    final cache = DiskImageCache.open(dir);
    expect(dir.existsSync(), isTrue);
    await cache.storeBytes('https://i.pximg.net/a.jpg', _bytes(0, 10));
    expect(await cache.lookup('https://i.pximg.net/a.jpg'), isNotNull);
  });

  test('a file deleted behind the index misses and frees its budget', () async {
    final dir = _freshDir();
    final cache = DiskImageCache.open(dir);
    final file = await cache.storeBytes(
      'https://i.pximg.net/a.jpg',
      _bytes(0, 400),
    );
    await file.delete();
    expect(await cache.lookup('https://i.pximg.net/a.jpg'), isNull);
    expect(cache.entryCount, 0);
    expect(cache.totalBytes, 0);
  });
}
