import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

/// Fails a test file whose cases leave a disposable undisposed (TEST-15).
///
/// Only not-disposed objects are tracked: creation stacks for every
/// tracked object (what `createdByTestHelpers` needs) did not fit the
/// suite's memory cap. Call it from each `testExecutable`.
void enableLeakTracking() {
  LeakTesting.enable();
  LeakTesting.settings = LeakTesting.settings.withIgnored(
    notDisposed: {
      // visibility_detector builds a ContainerLayer for every visibility
      // check and never disposes it; the app builds none of its own.
      'ContainerLayer': null,
      // Static singletons that live as long as the app: still_work's
      // pointer tracker and hero_lifted_bars' two route maps.
      '_Pointers': null,
      'ValueNotifier<Map<Route<dynamic>, int>>': null,
      'ValueNotifier<Map<Route<dynamic>, List<Rect>>>': null,
      // Handed from its grid to the detail routes it opens, so it outlives
      // whichever goes first; it holds no resource, only listeners each of
      // them removes.
      'IllustPagerSource': null,
    },
  );
  // Image loads in tests mostly never answer (a fetch the fakes leave
  // pending, an asset read fake time never reaches), and a pending load
  // keeps its cache entries, and a precache its listener, alive: each case
  // starts with an empty cache. A file of plain `test`s starts no binding
  // and has no cache; starting one would turn every HTTP request into a
  // 400.
  tearDown(() {
    if (BindingBase.debugBindingType() == null) return;
    imageCache
      ..clear()
      ..clearLiveImages();
  });
  // The cache lets go of an entry's stream a frame later, which the next
  // case's first pump brings. The file's last case gets that frame here,
  // before the leak check that runs after every other tearDownAll.
  tearDownAll(() {
    if (BindingBase.debugBindingType() == null) return;
    SchedulerBinding.instance
      ..handleBeginFrame(null)
      ..handleDrawFrame();
  });
}

/// For a file whose images finish loading: octo_image's FadeWidget makes a
/// CurvedAnimation for every fade-in and never disposes it. Call it first
/// in `main`; the file runs alone, so the rest of the suite keeps the
/// class tracked.
void ignoreOctoImageFades() {
  LeakTesting.settings = LeakTesting.settings.withIgnored(
    notDisposed: {'CurvedAnimation': null},
  );
}
