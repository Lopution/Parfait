import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../debug/trace_marks.dart';
import '../log.dart';
import '../logging/crash_log.dart';

/// Pins a thread to [cpus]; returns 0 or the `errno` of the failure.
typedef AffinitySetter = int Function(int tid, Set<int> cpus);

/// Frees the engine's raster threads to every core when the chip has no
/// little cores.
///
/// The engine pins each raster thread once, as it starts, to the cores it
/// does not count as efficiency cores, and it counts the cores with the
/// lowest top frequency as those (`kNotEfficiency`, `CPUSpeedTracker`). On a
/// chip without little cores that excludes full cores: the Snapdragon 8
/// Elite family (two prime and six performance Oryon cores) leaves the
/// raster thread the two prime cores. Nothing else keeps that cluster busy,
/// so every raster frame started at its lowest frequency (883 MHz on an
/// SM8850). Freed, it ran on the performance cores at about 1.3 GHz, as a
/// native RenderThread does, and the same frames took a sixth less time.
///
/// The kernel keeps the requested set when the app moves between cpusets
/// (Linux 6.2 and later; these chips ship with 6.6 or later), so one call
/// at launch holds. A raster thread started from a freed one inherits its
/// set.
Future<void> freeRasterThreads({
  String cpuRoot = '/sys/devices/system/cpu',
  String taskRoot = '/proc/self/task',
  AffinitySetter setAffinity = _libcSetAffinity,
}) async {
  final cores = rasterCores(await readCpuCapacities(cpuRoot));
  if (cores == null) {
    log('raster affinity: left to the engine');
    return;
  }
  final threads = await rasterThreads(taskRoot);
  if (threads.isEmpty) log('raster affinity: no raster thread found');
  for (final tid in threads) {
    final error = setAffinity(tid, cores);
    if (error != 0) {
      CrashLog.record(
        StateError('sched_setaffinity($tid, $cores) failed: errno $error'),
      );
      continue;
    }
    TraceMarks.mark('event raster-affinity $tid $cores');
  }
}

/// The cores the raster threads may run on, or null to keep the engine's
/// choice.
///
/// `cpu_capacity` is the kernel's own measure: each core's performance at
/// its top frequency against the fastest core's 1024. A core under half of
/// the fastest is a little one. With none, every core is free; with any,
/// the engine already excludes them, and its set is kept so this never
/// narrows it. Equal capacities say nothing: one kind of core, which the
/// engine does not pin, or a kernel without a capacity table.
Set<int>? rasterCores(Map<int, int> capacityByCpu) {
  if (capacityByCpu.isEmpty) return null;
  final fastest = capacityByCpu.values.reduce(math.max);
  final slowest = capacityByCpu.values.reduce(math.min);
  if (slowest == fastest || slowest * 2 < fastest) return null;
  return capacityByCpu.keys.toSet();
}

/// Every core's `cpu_capacity`, or none when a core has no reading.
Future<Map<int, int>> readCpuCapacities(String cpuRoot) async {
  final capacities = <int, int>{};
  await for (final entry in Directory(cpuRoot).list()) {
    final cpu = RegExp(r'/cpu(\d+)$').firstMatch(entry.path)?.group(1);
    if (cpu == null) continue;
    final file = File('${entry.path}/cpu_capacity');
    final capacity = await file.exists()
        ? int.tryParse((await file.readAsString()).trim())
        : null;
    if (capacity == null) return const {};
    capacities[int.parse(cpu)] = capacity;
  }
  return capacities;
}

/// The engine's raster threads in this process (`1.raster`, …).
Future<List<int>> rasterThreads(String taskRoot) async {
  final threads = <int>[];
  await for (final task in Directory(taskRoot).list()) {
    try {
      final name = await File('${task.path}/comm').readAsString();
      if (name.trim().endsWith('.raster')) {
        threads.add(int.parse(task.path.split('/').last));
      }
    } on FileSystemException {
      // The thread exited after the listing.
    }
  }
  return threads;
}

/// A `cpu_set_t` on Android: 1024 bits.
const _cpuSetBytes = 128;

int _libcSetAffinity(int tid, Set<int> cpus) {
  final mask = Uint8List(_cpuSetBytes);
  for (final cpu in cpus) {
    mask[cpu ~/ 8] |= 1 << (cpu % 8);
  }
  if (_schedSetAffinity(tid, mask.length, mask.address) == 0) return 0;
  return _errno().value;
}

// libc's, found in the process: no native asset provides these symbols.
@Native<Int32 Function(Int32, IntPtr, Pointer<Uint8>)>(
  symbol: 'sched_setaffinity',
  isLeaf: true,
)
external int _schedSetAffinity(int tid, int size, Pointer<Uint8> mask);

@Native<Pointer<Int32> Function()>(symbol: '__errno', isLeaf: true)
external Pointer<Int32> _errno();
