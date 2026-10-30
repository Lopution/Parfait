import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/raster_affinity.dart';

void main() {
  test('frees every core only when none is little', () {
    final all = {for (var cpu = 0; cpu < 8; cpu++) cpu};
    for (final (chip, capacities, cores) in <(String, List<int>, Set<int>?)>[
      // Snapdragon 8 Elite Gen 5, read on the device: no little cores.
      (
        '2 prime + 6 performance',
        [762, 762, 762, 762, 762, 762, 1024, 1024],
        all,
      ),
      // The engine already excludes little cores; its set is kept.
      ('with little cores', [381, 381, 980, 980, 980, 980, 980, 1024], null),
      (
        'no capacity table',
        [1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024],
        null,
      ),
      ('no readings', [], null),
    ]) {
      expect(rasterCores(capacities.asMap()), cores, reason: chip);
    }
  });

  test('sets only the raster threads, from a full capacity table', () async {
    final root = await Directory.systemTemp.createTemp('raster_affinity');
    addTearDown(() => root.delete(recursive: true));
    final cpuRoot = '${root.path}/cpu';
    final taskRoot = '${root.path}/task';
    for (var cpu = 0; cpu < 8; cpu++) {
      final dir = await Directory('$cpuRoot/cpu$cpu').create(recursive: true);
      await File(
        '${dir.path}/cpu_capacity',
      ).writeAsString(cpu < 6 ? '762\n' : '1024\n');
    }
    // Siblings the kernel lists next to the cores.
    await Directory('$cpuRoot/cpufreq').create();
    for (final (tid, name) in [
      (101, '1.raster'),
      (102, '1.io'),
      (103, 'io.github.lopu'),
      (104, '1.raster'),
    ]) {
      final dir = await Directory('$taskRoot/$tid').create(recursive: true);
      await File('${dir.path}/comm').writeAsString('$name\n');
    }

    final calls = <int, Set<int>>{};
    Future<void> free() => freeRasterThreads(
      cpuRoot: cpuRoot,
      taskRoot: taskRoot,
      setAffinity: (tid, cpus) {
        calls[tid] = cpus;
        return 0;
      },
    );
    await free();
    final all = {for (var cpu = 0; cpu < 8; cpu++) cpu};
    expect(calls, {101: all, 104: all});

    // A core without a reading leaves the engine's choice.
    calls.clear();
    await File('$cpuRoot/cpu7/cpu_capacity').delete();
    await free();
    expect(calls, isEmpty);

    // So does a table the ROM does not let the app read, without an error.
    await freeRasterThreads(
      cpuRoot: '${root.path}/denied',
      taskRoot: taskRoot,
      setAffinity: (tid, cpus) => fail('no table, no affinity'),
    );
  });
}
