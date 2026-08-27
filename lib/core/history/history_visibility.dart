import 'dart:async';

import 'package:flutter/material.dart';

import '../navigation/route_observer.dart';
import 'history_models.dart';
import 'history_repository.dart';
import 'history_tracker.dart';

typedef HistoryErrorCallback = void Function(Object error, StackTrace stack);

/// Wraps content that should count only while its route is visible and the
/// app is foregrounded.
class HistoryVisibility extends StatefulWidget {
  const HistoryVisibility({
    super.key,
    required this.accountId,
    required this.contentType,
    required this.contentId,
    required this.snapshot,
    required this.localHistoryEnabled,
    required this.pixivHistoryEnabled,
    required this.repository,
    this.remote,
    this.isAccountCurrent,
    this.clock,
    this.now,
    this.onError,
    required this.child,
  });

  final String accountId;
  final HistoryContentType contentType;
  final int contentId;
  final HistorySnapshot snapshot;
  final bool localHistoryEnabled;
  final bool pixivHistoryEnabled;
  final HistoryRepository repository;
  final PixivHistoryRemote? remote;
  final bool Function()? isAccountCurrent;
  final HistoryElapsedClock? clock;
  final DateTime Function()? now;
  final HistoryErrorCallback? onError;
  final Widget child;

  @override
  State<HistoryVisibility> createState() => _HistoryVisibilityState();
}

class _HistoryVisibilityState extends State<HistoryVisibility>
    with WidgetsBindingObserver, RouteAware {
  late HistoryTracker _tracker;
  ModalRoute<dynamic>? _route;
  bool _routeVisible = false;
  bool _foreground = true;
  bool _effectiveVisible = false;
  bool _didResolveRoute = false;

  @override
  void initState() {
    super.initState();
    _tracker = _newTracker();
    WidgetsBinding.instance.addObserver(this);
  }

  HistoryTracker _newTracker() {
    return HistoryTracker(
      repository: widget.repository,
      accountId: widget.accountId,
      contentType: widget.contentType,
      contentId: widget.contentId,
      snapshot: widget.snapshot,
      localHistoryEnabled: widget.localHistoryEnabled,
      pixivHistoryEnabled: widget.pixivHistoryEnabled,
      remote: widget.remote,
      isAccountCurrent: widget.isAccountCurrent,
      clock: widget.clock,
      now: widget.now,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      if (_route != null) replicaRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) replicaRouteObserver.subscribe(this, route);
    }
    if (!_didResolveRoute) {
      _didResolveRoute = true;
      _routeVisible = route?.isCurrent ?? true;
      _updateVisibility();
    }
  }

  @override
  void didUpdateWidget(covariant HistoryVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.contentType != widget.contentType ||
        oldWidget.contentId != widget.contentId) {
      _run(_tracker.finish());
      _tracker = _newTracker();
      if (_effectiveVisible) _run(_tracker.start());
      return;
    }
    _tracker
      ..updateSnapshot(widget.snapshot)
      ..updateSettings(
        localHistoryEnabled: widget.localHistoryEnabled,
        pixivHistoryEnabled: widget.pixivHistoryEnabled,
        remote: widget.remote,
        isAccountCurrent: widget.isAccountCurrent,
      );
  }

  @override
  void didPush() => _setRouteVisible(true);

  @override
  void didPopNext() => _setRouteVisible(true);

  @override
  void didPushNext() => _setRouteVisible(false);

  @override
  void didPop() => _setRouteVisible(false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateVisibility();
  }

  void _setRouteVisible(bool value) {
    _routeVisible = value;
    _updateVisibility();
  }

  void _updateVisibility() {
    final next = _routeVisible && _foreground;
    if (next == _effectiveVisible) return;
    _effectiveVisible = next;
    _run(next ? _tracker.start() : _tracker.pauseAndCommit());
  }

  void _run(Future<void> operation) {
    unawaited(() async {
      try {
        await operation;
      } catch (error, stack) {
        final callback = widget.onError;
        if (callback != null) {
          callback(error, stack);
        } else {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'pixiv_func.history',
              context: ErrorDescription('while persisting browsing history'),
            ),
          );
        }
      }
    }());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_route != null) replicaRouteObserver.unsubscribe(this);
    _run(_tracker.finish());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
