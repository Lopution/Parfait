import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/account_store.dart';
import '../../core/platform/intent_router.dart';
import '../../core/reverse_image/image_input.dart';

/// Dispatches an inbound OS intent (shared image, Pixiv deep link, or OAuth
/// callback) onto [router].
Future<void> routeExternalIntent(
  GoRouter router,
  AndroidIntentResult result,
) async {
  switch (result) {
    case SharedImageAndroidIntent(
      :final contentUri,
      :final mimeType,
      :final sizeBytes,
    ):
      await router.push<void>(
        '/reverse-image',
        extra: ReverseImageInputReference(
          contentUri: contentUri.toString(),
          mimeType: mimeType,
          sizeBytes: sizeBytes,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.androidSend,
        ),
      );
    case RoutedAndroidIntent(:final route):
      switch (route) {
        case IllustRoute(:final illustId):
          router.go('/recommended/illust/$illustId');
        case UserRoute(:final userId):
          router.go('/recommended/user/$userId');
        case AccountCallbackRoute():
          final top = router
              .routerDelegate
              .currentConfiguration
              .lastOrNull
              ?.matchedLocation;
          if (top == '/login/web' && router.canPop()) {
            final rootContext =
                router.routerDelegate.navigatorKey.currentContext;
            if (rootContext != null) {
              ProviderScope.containerOf(
                rootContext,
                listen: false,
              ).read(oauthServiceProvider).markCallbackHandoff();
            }
            router.pop();
          }
          final config = router.routerDelegate.currentConfiguration;
          final nextTop = config.lastOrNull?.matchedLocation;
          final query = <String, String>{
            if (config.uri.queryParameters['first'] == 'true') 'first': 'true',
            if (config.uri.queryParameters['return'] == 'true')
              'return': 'true',
          };
          final callbackLocation = Uri(
            path: '/login/callback',
            queryParameters: query.isEmpty ? null : query,
          ).toString();
          if (nextTop == '/login' || nextTop == '/login/callback') {
            await router.pushReplacement<void>(callbackLocation, extra: route);
          } else {
            await router.push<void>(callbackLocation, extra: route);
          }
        case UnknownRoute():
        case ForeignUri():
          break;
      }
    case RejectedAndroidIntent():
    case IgnoredAndroidIntent():
      break;
  }
}
