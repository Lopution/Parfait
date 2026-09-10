import 'dart:async';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform/android_intent_channel.dart';
import '../core/platform/intent_router.dart';
import '../l10n/context.dart';
import 'navigation/routes.dart';
import 'widgets/app_snack_bar.dart';

/// Owns the process-wide Android intent subscription beside the app router.
class ExternalIntentBridge extends StatefulWidget {
  const ExternalIntentBridge({
    super.key,
    required this.router,
    required this.child,
    this.intentSource,
  });

  final GoRouter router;
  final Widget child;
  final AndroidIntentSource? intentSource;

  @override
  State<ExternalIntentBridge> createState() => _ExternalIntentBridgeState();
}

class _ExternalIntentBridgeState extends State<ExternalIntentBridge> {
  late final AndroidIntentSource _intentSource;
  StreamSubscription<AndroidIntentResult>? _intentSubscription;
  bool _externalPageOpen = false;

  @override
  void initState() {
    super.initState();
    _intentSource =
        widget.intentSource ?? const MethodChannelAndroidIntentSource();
    _intentSubscription = _intentSource.onNewIntent.listen(
      _handleExternalIntent,
      onError: _handleExternalIntentStreamError,
    );
    unawaited(_readInitialIntent());
  }

  @override
  void dispose() {
    unawaited(_intentSubscription?.cancel());
    super.dispose();
  }

  Future<void> _readInitialIntent() async {
    try {
      final result = await _intentSource.readInitial();
      if (mounted) _handleExternalIntent(result);
    } on MissingPluginException {
      // Non-Android platforms have no native intent bridge.
    } on PlatformException {
      if (mounted) _showExternalIntentFailure();
    } on Object {
      if (mounted) _showExternalIntentFailure();
    }
  }

  void _handleExternalIntentStreamError(Object error, StackTrace stackTrace) {
    if (error is MissingPluginException) return;
    if (mounted) _showExternalIntentFailure();
  }

  void _handleExternalIntent(AndroidIntentResult result) {
    switch (result) {
      case SharedImageAndroidIntent():
        if (_externalPageOpen) return;
        _externalPageOpen = true;
        unawaited(
          routeExternalIntent(
            widget.router,
            result,
          ).whenComplete(() => _externalPageOpen = false),
        );
      case RejectedAndroidIntent():
        _showExternalIntentFailure();
      case RoutedAndroidIntent():
        unawaited(routeExternalIntent(widget.router, result));
      case IgnoredAndroidIntent():
        break;
    }
  }

  void _showExternalIntentFailure() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.searchReverseIntentFailed);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
