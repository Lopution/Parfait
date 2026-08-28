import 'shared_image.dart';

/// Typed commands produced by parsing Android VIEW data.
sealed class DeepLinkRoute {
  const DeepLinkRoute();
}

/// Open a user page: `pixiv://users/<id>`, `pixivfunc://users/<id>`,
/// `https://www.pixiv.net/u/<id>`, `/users/<id>`, or `?id=<id>` on a user
/// page.
class UserRoute extends DeepLinkRoute {
  const UserRoute(this.userId);

  final int userId;
}

/// Open an illust page: `pixiv://illusts/<id>`, `pixivfunc://illusts/<id>`,
/// `https://www.pixiv.net/i/<id>`, `/artworks/<id>`, or `?illust_id=<id>`.
class IllustRoute extends DeepLinkRoute {
  const IllustRoute(this.illustId);

  final int illustId;
}

/// OAuth account callback: `pixiv://account?code=...` Routed to the login
/// flow, where the optional state is checked against the live PKCE session.
class AccountCallbackRoute extends DeepLinkRoute {
  const AccountCallbackRoute(this.code, {this.state});

  final String code;
  final String? state;
}

/// A URI that parsed but does not map to a known destination. The app shows
/// the original beta56 behaviour: an "invalid id" toast, never a crash.
class UnknownRoute extends DeepLinkRoute {
  const UnknownRoute(this.reason);

  final String reason;
}

/// A URI from a foreign scheme/host. The app must ignore it entirely.
class ForeignUri extends DeepLinkRoute {
  const ForeignUri(this.uri);

  final Uri uri;
}

/// The small platform input model shared by the Android channel and tests.
/// Android-specific extras are represented by their stable key names so the
/// Dart boundary can reject unexpected payloads before feature code sees them.
class AndroidIntentInput {
  const AndroidIntentInput({
    required this.action,
    this.uri,
    this.mimeType,
    this.hasReadUriPermission = false,
    this.sizeBytes,
    this.extraKeys = const <String>{},
  });

  static const viewAction = 'android.intent.action.VIEW';
  static const sendAction = 'android.intent.action.SEND';
  static const mainAction = 'android.intent.action.MAIN';
  static const streamExtra = 'android.intent.extra.STREAM';

  final String action;
  final Uri? uri;
  final String? mimeType;
  final bool hasReadUriPermission;
  final int? sizeBytes;
  final Set<String> extraKeys;
}

/// Result of validating an Android intent at the Dart platform boundary.
sealed class AndroidIntentResult {
  const AndroidIntentResult();
}

class RoutedAndroidIntent extends AndroidIntentResult {
  const RoutedAndroidIntent(this.route);

  final DeepLinkRoute route;
}

class SharedImageAndroidIntent extends AndroidIntentResult {
  const SharedImageAndroidIntent({
    required this.contentUri,
    required this.mimeType,
    required this.sizeBytes,
  });

  final Uri contentUri;
  final String mimeType;
  final int sizeBytes;
}

class IgnoredAndroidIntent extends AndroidIntentResult {
  const IgnoredAndroidIntent(this.reason);

  final String reason;
}

enum AndroidIntentRejectionCode {
  malformedPlatformPayload,
  unsupportedAction,
  missingUri,
  unexpectedExtras,
  invalidViewUri,
  missingStreamExtra,
  contentUriRequired,
  missingReadUriPermission,
  missingMimeType,
  unsupportedMimeType,
  missingSize,
  invalidSize,
  oversizedImage,
}

class RejectedAndroidIntent extends AndroidIntentResult {
  const RejectedAndroidIntent(this.code, this.reason);

  final AndroidIntentRejectionCode code;
  final String reason;
}

/// Validates and maps incoming Android URIs/intents to typed commands.
///
/// This is deliberately independent from navigation widgets and Android
/// channels. The native side supplies opaque intent metadata; this boundary
/// owns the exact action/scheme/host/path/MIME/permission/size rules.
abstract final class IntentRouter {
  static const Set<String> _webHosts = {'pixiv.net', 'www.pixiv.net'};
  static const Set<String> _pixivHosts = {'users', 'illusts', 'account'};
  static const Set<String> _pixivfuncHosts = {'users', 'illusts'};

  static DeepLinkRoute route(Uri uri) {
    switch (uri.scheme) {
      case 'pixiv':
        if (!_pixivHosts.contains(uri.host)) {
          return const UnknownRoute('unknown pixiv host');
        }
        if (uri.host == 'account') return _accountCallback(uri);
        return _typedIdFromExactPath(uri, uri.host);
      case 'pixivfunc':
        if (!_pixivfuncHosts.contains(uri.host)) {
          return const UnknownRoute('unknown pixivfunc host');
        }
        return _typedIdFromExactPath(uri, uri.host);
      case 'http':
      case 'https':
        if (!_webHosts.contains(uri.host)) return ForeignUri(uri);
        return _routeWebPath(uri);
      default:
        return ForeignUri(uri);
    }
  }

  /// Validates a native Android intent before the app routes or consumes it.
  static AndroidIntentResult routeIntent(AndroidIntentInput input) {
    switch (input.action) {
      case AndroidIntentInput.mainAction:
        return const IgnoredAndroidIntent('launcher intent');
      case AndroidIntentInput.viewAction:
        return _routeViewIntent(input);
      case AndroidIntentInput.sendAction:
        return _routeSendIntent(input);
      default:
        return RejectedAndroidIntent(
          AndroidIntentRejectionCode.unsupportedAction,
          'unsupported Android intent action',
        );
    }
  }

  /// Decodes the small, non-secret map emitted by [AndroidIntentChannel].
  /// Malformed platform data becomes an explicit rejection instead of an
  /// unchecked cast or a navigation side effect.
  static AndroidIntentResult routePlatformMessage(Object? message) {
    if (message == null) {
      return const IgnoredAndroidIntent('no external intent');
    }
    if (message is! Map) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.malformedPlatformPayload,
        'platform intent payload is not a map',
      );
    }

    final action = message['action'];
    if (action is! String) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.malformedPlatformPayload,
        'platform intent action is missing',
      );
    }
    final rawUri = message['uri'];
    Uri? uri;
    if (rawUri != null) {
      if (rawUri is! String || rawUri.isEmpty) {
        return const RejectedAndroidIntent(
          AndroidIntentRejectionCode.malformedPlatformPayload,
          'platform intent URI is malformed',
        );
      }
      try {
        uri = Uri.parse(rawUri);
      } on FormatException {
        return const RejectedAndroidIntent(
          AndroidIntentRejectionCode.malformedPlatformPayload,
          'platform intent URI is malformed',
        );
      }
    }

    final rawExtras = message['extraKeys'];
    final extras = <String>{};
    if (rawExtras != null) {
      if (rawExtras is! Iterable ||
          rawExtras.any((value) => value is! String)) {
        return const RejectedAndroidIntent(
          AndroidIntentRejectionCode.malformedPlatformPayload,
          'platform intent extras are malformed',
        );
      }
      extras.addAll(rawExtras.cast<String>());
    }

    final mimeType = message['mimeType'];
    if (mimeType != null && mimeType is! String) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.malformedPlatformPayload,
        'platform intent MIME type is malformed',
      );
    }
    final sizeBytes = message['sizeBytes'];
    if (sizeBytes != null && sizeBytes is! int) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.malformedPlatformPayload,
        'platform intent size is malformed',
      );
    }
    final permission = message['hasReadUriPermission'];
    if (permission != null && permission is! bool) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.malformedPlatformPayload,
        'platform intent permission flag is malformed',
      );
    }

    return routeIntent(
      AndroidIntentInput(
        action: action,
        uri: uri,
        mimeType: mimeType as String?,
        hasReadUriPermission: permission as bool? ?? false,
        sizeBytes: sizeBytes as int?,
        extraKeys: extras,
      ),
    );
  }

  static DeepLinkRoute _accountCallback(Uri uri) {
    if (_hasUnsafeUriMetadata(uri) || uri.path.isNotEmpty) {
      return const UnknownRoute('account callback has an invalid URI shape');
    }
    final keys = uri.queryParametersAll.keys.toSet();
    if (!keys.every((key) => key == 'code' || key == 'state')) {
      return const UnknownRoute('account callback has unexpected parameters');
    }
    final codes = uri.queryParametersAll['code'];
    if (codes == null || codes.length != 1 || codes.single.isEmpty) {
      return const UnknownRoute('account callback without code');
    }
    final states = uri.queryParametersAll['state'];
    if (states != null && (states.length != 1 || states.single.isEmpty)) {
      return const UnknownRoute('account callback with invalid state');
    }
    return AccountCallbackRoute(codes.single, state: states?.single);
  }

  static DeepLinkRoute _typedIdFromExactPath(Uri uri, String host) {
    if (_hasUnsafeUriMetadata(uri) || uri.query.isNotEmpty) {
      return UnknownRoute('invalid $host link shape');
    }
    final segments = uri.pathSegments;
    if (segments.length != 1 || segments.single.isEmpty) {
      return UnknownRoute('missing or extra id in $host link');
    }
    final id = int.tryParse(segments.single);
    if (id == null || id <= 0) {
      return UnknownRoute('invalid id: ${segments.single}');
    }
    return host == 'users' ? UserRoute(id) : IllustRoute(id);
  }

  static DeepLinkRoute _routeWebPath(Uri uri) {
    if (_hasUnsafeUriMetadata(uri)) {
      return const UnknownRoute('web link has an invalid URI shape');
    }
    final segments = uri.pathSegments;
    if (segments.length == 2 && uri.query.isEmpty) {
      final id = int.tryParse(segments[1]);
      if (id != null && id > 0) {
        switch (segments[0]) {
          case 'u':
          case 'users':
            return UserRoute(id);
          case 'i':
          case 'artworks':
            return IllustRoute(id);
        }
      }
    }

    if (segments.length == 1) {
      if (segments.single == 'jump.php') {
        return _queryIdRoute(uri, 'illust_id', IllustRoute.new);
      }
      if (segments.single == 'user.php') {
        return _queryIdRoute(uri, 'id', UserRoute.new);
      }
    }
    return UnknownRoute('unmapped web path: ${uri.path}');
  }

  static DeepLinkRoute _queryIdRoute(
    Uri uri,
    String key,
    DeepLinkRoute Function(int) build,
  ) {
    final keys = uri.queryParametersAll.keys.toSet();
    if (keys.length != 1 || !keys.contains(key)) {
      return const UnknownRoute('ambiguous or unexpected query parameters');
    }
    final values = uri.queryParametersAll[key];
    if (values == null || values.length != 1 || values.single.isEmpty) {
      return UnknownRoute('invalid $key: ${values?.join(',') ?? ''}');
    }
    final id = int.tryParse(values.single);
    if (id == null || id <= 0) {
      return UnknownRoute('invalid $key: ${values.single}');
    }
    return build(id);
  }

  static AndroidIntentResult _routeViewIntent(AndroidIntentInput input) {
    if (input.uri == null) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.missingUri,
        'VIEW intent has no URI',
      );
    }
    if (input.extraKeys.isNotEmpty) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.unexpectedExtras,
        'VIEW intent contains unexpected extras',
      );
    }
    final route = IntentRouter.route(input.uri!);
    if (route is ForeignUri) {
      return IgnoredAndroidIntent('foreign VIEW URI: ${route.uri.scheme}');
    }
    if (route is UnknownRoute) {
      return RejectedAndroidIntent(
        AndroidIntentRejectionCode.invalidViewUri,
        route.reason,
      );
    }
    return RoutedAndroidIntent(route);
  }

  static AndroidIntentResult _routeSendIntent(AndroidIntentInput input) {
    if (input.uri == null) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.missingUri,
        'SEND intent has no stream URI',
      );
    }
    if (!input.extraKeys.contains(AndroidIntentInput.streamExtra)) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.missingStreamExtra,
        'SEND intent has no stream extra',
      );
    }
    if (input.extraKeys.length != 1) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.unexpectedExtras,
        'SEND intent contains unexpected extras',
      );
    }
    final uri = input.uri!;
    if (uri.scheme != 'content' ||
        uri.host.isEmpty ||
        _hasUnsafeUriMetadata(uri)) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.contentUriRequired,
        'SEND intent requires a clean content URI',
      );
    }
    if (!input.hasReadUriPermission) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.missingReadUriPermission,
        'content URI read permission is missing',
      );
    }
    final mimeType = input.mimeType;
    if (mimeType == null || mimeType.isEmpty) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.missingMimeType,
        'SEND intent MIME type is missing',
      );
    }
    if (!SharedImageValidator.isImageMimeType(mimeType)) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.unsupportedMimeType,
        'unsupported image MIME type',
      );
    }
    final sizeBytes = input.sizeBytes;
    if (sizeBytes == null) {
      return const RejectedAndroidIntent(
        AndroidIntentRejectionCode.missingSize,
        'content URI size is unavailable',
      );
    }
    try {
      SharedImageValidator.validateMetadata(
        mimeType: mimeType,
        sizeBytes: sizeBytes,
      );
    } on SharedImageRejected catch (error) {
      final code = sizeBytes <= 0
          ? AndroidIntentRejectionCode.invalidSize
          : AndroidIntentRejectionCode.oversizedImage;
      return RejectedAndroidIntent(code, error.reason);
    }
    return SharedImageAndroidIntent(
      contentUri: uri,
      mimeType: mimeType.toLowerCase(),
      sizeBytes: sizeBytes,
    );
  }

  static bool _hasUnsafeUriMetadata(Uri uri) {
    return uri.userInfo.isNotEmpty || uri.hasFragment || uri.hasPort;
  }
}
