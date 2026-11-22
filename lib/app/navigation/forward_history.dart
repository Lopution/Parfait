import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

const _maxForwardHistoryPerBucket = 50;

const _branchBuckets = <String>[
  'recommended',
  'ranking',
  'new',
  'search',
  'settings',
];

bool _isPreHomePath(String path) =>
    path == '/' ||
    path == '/splash' ||
    path == '/user-agreement' ||
    path == '/welcome' ||
    path.startsWith('/welcome/') ||
    path == '/login' ||
    path.startsWith('/login/');

String _bucketForPath(String path) {
  for (final bucket in _branchBuckets) {
    final prefix = '/$bucket';
    if (path == prefix || path.startsWith('$prefix/')) return bucket;
  }
  return 'root';
}

bool _isViewerRoute(String location) =>
    Uri.parse(location).path.contains('/viewer/');

/// Returns the active top-most URI of [router], including routes pushed via
/// `router.push(...)` ([ImperativeRouteMatch]), which [RouteMatchList.uri]
/// omits.
Uri liveRouterUri(GoRouter router) {
  final config = router.routerDelegate.currentConfiguration;
  if (config.isNotEmpty) {
    RouteMatchBase walker = config.matches.last;
    while (walker is ShellRouteMatch && walker.matches.isNotEmpty) {
      walker = walker.matches.last;
    }
    if (walker is ImperativeRouteMatch) {
      return walker.matches.uri;
    }
    return config.uri;
  }
  return router.routeInformationProvider.value.uri;
}

Object? _liveRouterExtra(RouteMatchList config) {
  if (config.isEmpty) return null;
  RouteMatchBase walker = config.matches.last;
  while (walker is ShellRouteMatch && walker.matches.isNotEmpty) {
    walker = walker.matches.last;
  }
  if (walker is ImperativeRouteMatch) {
    return walker.matches.extra;
  }
  return config.extra;
}

int _matchTreeDepth(RouteMatchList config) {
  var count = 0;
  void walk(List<RouteMatchBase> matches) {
    for (final m in matches) {
      count++;
      if (m is ShellRouteMatch) {
        walk(m.matches);
      }
    }
  }

  walk(config.matches);
  return count;
}

/// A single replayable navigation entry kept for forward navigation.
@immutable
class ForwardHistoryEntry {
  const ForwardHistoryEntry({
    required this.bucket,
    required this.location,
    this.extra,
  });

  final String bucket;
  final String location;
  final Object? extra;
}

/// Snapshot exposed to navigation chrome for enabled/disabled button states.
@immutable
class ForwardHistoryState {
  const ForwardHistoryState({
    required this.canGoBack,
    required this.canGoForward,
  });

  final bool canGoBack;
  final bool canGoForward;

  @override
  bool operator ==(Object other) =>
      other is ForwardHistoryState &&
      other.canGoBack == canGoBack &&
      other.canGoForward == canGoForward;

  @override
  int get hashCode => Object.hash(canGoBack, canGoForward);
}

@immutable
class _FallbackStackEntry {
  const _FallbackStackEntry({required this.uri, required this.extra});

  final String uri;
  final Object? extra;
}

/// Tracks per-branch replayable forward history for a [GoRouter].
///
/// Works in two modes:
/// 1. Production routers built by `createPixivRouter`, which construct a
///    [ForwardHistoryStack.detached], wire [rootObserver] and
///    [observerForBranch] into GoRouter, and call [attachRouter].
/// 2. Standalone test [GoRouter] instances via [ForwardHistoryStack.ofRouter],
///    which fall back to `routerDelegate` stack-depth diffs so shortcuts and
///    method-channel navigation tests work without custom router wiring.
class ForwardHistoryStack {
  ForwardHistoryStack.detached() {
    _liveStacks.add(WeakReference(this));
  }

  ForwardHistoryStack._attached(GoRouter router) {
    _liveStacks.add(WeakReference(this));
    attachRouter(router);
  }

  static final Expando<ForwardHistoryStack> _byRouter =
      Expando<ForwardHistoryStack>('forward_history_by_router');
  static final Expando<ForwardHistoryEntry> _pageEntries =
      Expando<ForwardHistoryEntry>('forward_history_page_entry');
  static final List<WeakReference<ForwardHistoryStack>> _liveStacks = [];

  GoRouter? _router;
  final _StateListenable _stateListenable = _StateListenable();

  final Map<String, List<ForwardHistoryEntry>> _forwardStacks = {};
  final Map<Route<dynamic>, ForwardHistoryEntry> _activeEntries = {};
  final Map<Route<dynamic>, String> _openModals = {};
  final List<String> _pendingReplays = [];
  final List<_FallbackStackEntry> _fallbackStack = [];

  bool _usesObservers = false;
  bool _pendingCleanupScheduled = false;
  bool _postFramePublishScheduled = false;
  int _pushGeneration = 0;
  String _lastActiveShellBucket = 'recommended';

  late final NavigatorObserver rootObserver = _ForwardNavigatorObserver(
    this,
    'root',
  );

  NavigatorObserver observerForBranch(String bucket) =>
      _ForwardNavigatorObserver(this, bucket);

  /// Binds [router] to this stack after `GoRouter` construction.
  void attachRouter(GoRouter router) {
    assert(_router == null, 'ForwardHistoryStack already attached');
    _router = router;
    _byRouter[router] = this;
    final initialBucket = _bucketForPath(_currentPath());
    if (initialBucket != 'root') {
      _lastActiveShellBucket = initialBucket;
    }
    _syncFallbackSnapshot(initial: true);
    router.routerDelegate.addListener(_onRouterDelegateChanged);
    _publishState();
  }

  /// Returns the existing [ForwardHistoryStack] for [router], or creates a
  /// delegate-tracking instance for standalone test routers.
  static ForwardHistoryStack ofRouter(GoRouter router) =>
      _byRouter[router] ?? ForwardHistoryStack._attached(router);

  /// Attaches replay metadata onto a [Page] created by `_page(...)`.
  static void attachPage(
    Page<dynamic> page, {
    required String bucket,
    required String location,
    Object? extra,
  }) {
    _pageEntries[page] = ForwardHistoryEntry(
      bucket: bucket,
      location: location,
      extra: extra,
    );
  }

  /// Updates metadata for an already-mounted [page] (for example when
  /// swiping horizontally inside `IllustDetailPagerPage`).
  static void updatePageEntry(
    Page<dynamic> page,
    ForwardHistoryEntry Function(ForwardHistoryEntry current) transform,
  ) {
    final current = _pageEntries[page];
    if (current == null) return;
    final updated = transform(current);
    _pageEntries[page] = updated;
    _pruneAndNotifyPageUpdate(page, updated);
  }

  static void _pruneAndNotifyPageUpdate(
    Page<dynamic> page,
    ForwardHistoryEntry updated,
  ) {
    _liveStacks.removeWhere((ref) {
      final target = ref.target;
      if (target == null) return true;
      target._updateActiveEntryForPage(page, updated);
      return false;
    });
  }

  void _updateActiveEntryForPage(
    Page<dynamic> page,
    ForwardHistoryEntry updated,
  ) {
    for (final entry in _activeEntries.entries.toList()) {
      if (identical(entry.key.settings, page)) {
        _activeEntries[entry.key] = ForwardHistoryEntry(
          bucket: entry.value.bucket,
          location: updated.location,
          extra: updated.extra,
        );
      }
    }
  }

  ValueListenable<ForwardHistoryState> get stateListenable => _stateListenable;

  /// Incremented on non-pop navigations (`push`, `pushReplacement`, `goForward`)
  /// so cross-source hardware side-button debounce resets between distinct
  /// navigation steps.
  int get pushGeneration => _pushGeneration;

  bool get hasOpenModal {
    if (_openModals.isEmpty) return false;
    final active = _activeBucket();
    for (final bucket in _openModals.values) {
      if (bucket == 'root' || bucket == active) return true;
    }
    return false;
  }

  bool get canGoBack {
    final path = _currentPath();
    if (_isPreHomePath(path)) return false;
    if (hasOpenModal) return true;
    return _safeCanPop();
  }

  bool get canGoForward {
    final path = _currentPath();
    if (_isPreHomePath(path)) return false;
    if (hasOpenModal) return false;
    final stack = _forwardStacks[_activeBucket()];
    return stack != null && stack.isNotEmpty;
  }

  /// Navigates back if any active navigator or modal can pop.
  Future<bool> goBack() async {
    final router = _router;
    if (router == null || !canGoBack) return false;
    return router.routerDelegate.popRoute();
  }

  /// Replays the top entry of the current branch's forward stack, if any.
  Future<bool> goForward() async {
    final router = _router;
    if (router == null || !canGoForward) return false;
    final stack = _forwardStacks[_activeBucket()];
    if (stack == null || stack.isEmpty) return false;
    final entry = stack.removeLast();
    _pendingReplays.add(entry.location);
    _scheduleReplayCleanup();
    _pushGeneration++;
    _publishState();
    unawaited(router.push<void>(entry.location, extra: entry.extra));
    return true;
  }

  void _scheduleReplayCleanup() {
    if (_pendingCleanupScheduled) return;
    _pendingCleanupScheduled = true;
    // Defer cleanup across the build frame so `didPush` on the next frame
    // consumes the replay token before stale entries are swept.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pendingCleanupScheduled = false;
      _pendingReplays.clear();
    });
  }

  bool _consumePendingReplay(String location) {
    final index = _pendingReplays.indexOf(location);
    if (index >= 0) {
      _pendingReplays.removeAt(index);
      return true;
    }
    final parsedTarget = Uri.tryParse(location);
    if (parsedTarget != null) {
      final matchIndex = _pendingReplays.indexWhere((pending) {
        final parsedPending = Uri.tryParse(pending);
        return parsedPending != null && parsedPending.path == parsedTarget.path;
      });
      if (matchIndex >= 0) {
        _pendingReplays.removeAt(matchIndex);
        return true;
      }
    }
    return false;
  }

  void _onObserverPush(
    String observerBucket,
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _usesObservers = true;
    if (route.settings is! Page) {
      // go_router forwards branch navigator events to GoRouter.observers as
      // well (`notifyRootObserver: true`), so a branch-local modal triggers
      // both its branch observer and `rootObserver`. Keep the more specific
      // branch bucket regardless of callback order.
      final existing = _openModals[route];
      if (existing == null || existing == 'root') {
        _openModals[route] = observerBucket;
      }
      _publishState();
      return;
    }
    var entry = _pageEntries[route.settings];
    if (entry != null) {
      final resolvedBucket = entry.bucket == 'root'
          ? _lastActiveShellBucket
          : entry.bucket;
      if (resolvedBucket != entry.bucket) {
        entry = ForwardHistoryEntry(
          bucket: resolvedBucket,
          location: entry.location,
          extra: entry.extra,
        );
        _pageEntries[route.settings] = entry;
      }
      _activeEntries[route] = entry;
    }

    if (previousRoute != null && entry != null) {
      final replaying = _consumePendingReplay(entry.location);
      if (!replaying) {
        _forwardStacks.remove(entry.bucket);
        _pushGeneration++;
      }
    } else if (previousRoute != null &&
        entry == null &&
        observerBucket != 'root') {
      _forwardStacks.remove(observerBucket);
      _pushGeneration++;
    }
    _publishState();
  }

  void _onObserverPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _usesObservers = true;
    if (route.settings is! Page) {
      _openModals.remove(route);
      _publishState();
      return;
    }
    final popped = _activeEntries.remove(route);
    if (popped != null && previousRoute != null) {
      _pushForwardEntry(popped);
    }
    _publishState();
  }

  void _onObserverRemove(Route<dynamic> route) {
    _usesObservers = true;
    _openModals.remove(route);
    _activeEntries.remove(route);
    _publishState();
  }

  void _onObserverReplace(
    String observerBucket, {
    Route<dynamic>? newRoute,
    Route<dynamic>? oldRoute,
  }) {
    _usesObservers = true;
    if (oldRoute != null) {
      _openModals.remove(oldRoute);
    }
    if (newRoute != null && newRoute.settings is! Page) {
      final existing = _openModals[newRoute];
      if (existing == null || existing == 'root') {
        _openModals[newRoute] = observerBucket;
      }
      _publishState();
      return;
    }
    final oldEntry = oldRoute == null ? null : _activeEntries.remove(oldRoute);
    final newSettings = newRoute?.settings;
    var newEntry = newSettings is Page ? _pageEntries[newSettings] : null;
    if (newEntry != null && newRoute != null && newSettings != null) {
      final resolvedBucket = newEntry.bucket == 'root'
          ? (oldEntry?.bucket ?? _lastActiveShellBucket)
          : newEntry.bucket;
      if (resolvedBucket != newEntry.bucket) {
        newEntry = ForwardHistoryEntry(
          bucket: resolvedBucket,
          location: newEntry.location,
          extra: newEntry.extra,
        );
        _pageEntries[newSettings] = newEntry;
      }
      _activeEntries[newRoute] = newEntry;
      final keepForward =
          oldEntry != null &&
          _isViewerRoute(oldEntry.location) &&
          _isViewerRoute(newEntry.location);
      if (!keepForward && !_consumePendingReplay(newEntry.location)) {
        _forwardStacks.remove(newEntry.bucket);
        _pushGeneration++;
      }
    }
    _publishState();
  }

  void _pushForwardEntry(ForwardHistoryEntry entry) {
    final stack = _forwardStacks.putIfAbsent(
      entry.bucket,
      () => <ForwardHistoryEntry>[],
    );
    if (stack.length >= _maxForwardHistoryPerBucket) {
      stack.removeAt(0);
    }
    stack.add(entry);
  }

  void _onRouterDelegateChanged() {
    final bucket = _bucketForPath(_currentPath());
    if (bucket != 'root') {
      _lastActiveShellBucket = bucket;
    }
    if (!_usesObservers) {
      _syncFallbackSnapshot(initial: false);
      _schedulePostFramePublish();
    }
    _publishState();
  }

  void _schedulePostFramePublish() {
    if (_postFramePublishScheduled) return;
    _postFramePublishScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _postFramePublishScheduled = false;
      if (_router != null) _publishState();
    });
  }

  void _syncFallbackSnapshot({required bool initial}) {
    final router = _router;
    if (router == null) return;
    final config = router.routerDelegate.currentConfiguration;
    if (config.isEmpty) return;
    final depth = _matchTreeDepth(config);
    final activeUri = liveRouterUri(router);
    final uri = activeUri.toString();
    final extra = _liveRouterExtra(config);
    final bucket = _bucketForPath(activeUri.path);

    if (initial || _fallbackStack.isEmpty) {
      _fallbackStack
        ..clear()
        ..add(_FallbackStackEntry(uri: uri, extra: extra));
      return;
    }

    if (depth > _fallbackStack.length) {
      final replaying = _consumePendingReplay(uri);
      if (!replaying) {
        _forwardStacks.remove(bucket);
        _pushGeneration++;
      }
      _fallbackStack.add(_FallbackStackEntry(uri: uri, extra: extra));
    } else if (depth < _fallbackStack.length) {
      final isPopToPrevious =
          depth >= 1 &&
          _fallbackStack[depth - 1].uri == uri &&
          _bucketForPath(_fallbackStack.last.uri) == bucket;
      if (isPopToPrevious) {
        while (_fallbackStack.length > depth) {
          final popped = _fallbackStack.removeLast();
          _pushForwardEntry(
            ForwardHistoryEntry(
              bucket: _bucketForPath(popped.uri),
              location: popped.uri,
              extra: popped.extra,
            ),
          );
        }
      } else {
        // Declarative stack replacement (e.g. `router.go`) rather than a pop.
        if (_fallbackStack.length > depth) {
          _fallbackStack.removeRange(depth, _fallbackStack.length);
        }
        while (_fallbackStack.length < depth) {
          _fallbackStack.add(_FallbackStackEntry(uri: uri, extra: extra));
        }
        _fallbackStack[depth - 1] = _FallbackStackEntry(uri: uri, extra: extra);
      }
    } else if (_fallbackStack.last.uri != uri) {
      if (!_consumePendingReplay(uri)) {
        _forwardStacks.remove(bucket);
        _pushGeneration++;
      }
      _fallbackStack[_fallbackStack.length - 1] = _FallbackStackEntry(
        uri: uri,
        extra: extra,
      );
    }
  }

  String _activeBucket() {
    final bucket = _bucketForPath(_currentPath());
    return bucket == 'root' ? _lastActiveShellBucket : bucket;
  }

  String _currentPath() {
    final router = _router;
    if (router == null) return '/';
    return liveRouterUri(router).path;
  }

  bool _safeCanPop() {
    final router = _router;
    if (router == null) return false;
    final nav = router.routerDelegate.navigatorKey.currentState;
    if (nav == null) return false;
    try {
      return router.canPop();
    } on Object {
      return false;
    }
  }

  void _publishState() {
    final next = ForwardHistoryState(
      canGoBack: canGoBack,
      canGoForward: canGoForward,
    );
    _stateListenable.update(next);
  }
}

class _StateListenable implements ValueListenable<ForwardHistoryState> {
  ForwardHistoryState _value = const ForwardHistoryState(
    canGoBack: false,
    canGoForward: false,
  );
  final List<VoidCallback> _listeners = [];
  bool _notifyScheduled = false;

  @override
  ForwardHistoryState get value => _value;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void update(ForwardHistoryState next) {
    if (_value == next) return;
    _value = next;
    // NavigatorObserver callbacks run inside NavigatorState.didUpdateWidget
    // during build; deferring listener notifications until post-frame avoids
    // triggering setState() on ValueListenableBuilder while building.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        _notify();
      });
      return;
    }
    _notify();
  }

  void _notify() {
    for (final listener in _listeners.toList()) {
      if (_listeners.contains(listener)) listener();
    }
  }
}

class _ForwardNavigatorObserver extends NavigatorObserver {
  _ForwardNavigatorObserver(this._stack, this._bucket);

  final ForwardHistoryStack _stack;
  final String _bucket;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack._onObserverPush(_bucket, route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack._onObserverPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack._onObserverRemove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _stack._onObserverReplace(_bucket, newRoute: newRoute, oldRoute: oldRoute);
  }
}
