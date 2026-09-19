import 'dart:convert';

import 'package:http/http.dart' as http;

import '../entity/illust_entity.dart';
import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';
import '../network/compat/network_policy.dart';
import '../network/compat/pixiv_network_factory.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../profile/web_profile_session.dart';

/// Detail data source: `GET /v1/illust/detail?illust_id=` through the shared
/// authenticated client.
class IllustDetailRepository {
  IllustDetailRepository(
    this._client, {
    WebProfileSession? session,
    NetworkAccessPolicy? policy,
    http.Client? webClient,
  }) : _session = session ?? const MethodChannelWebProfileSession(),
       _policy = policy,
       _webClient = webClient;

  final PixivHttpClient _client;
  final WebProfileSession _session;
  final NetworkAccessPolicy? _policy;
  final http.Client? _webClient;

  static const String _path = '/v1/illust/detail';

  Future<IllustEntity> fetch(int illustId) async {
    final json = await _client.getJson(
      Uri(
        scheme: PixivClientIdentity.appApiBase.scheme,
        host: PixivClientIdentity.appApiBase.host,
        path: _path,
        queryParameters: {'illust_id': '$illustId'},
      ),
    );
    final illustJson = json['illust'];
    if (illustJson is! Map<String, dynamic>) {
      throw const ApiParseError('illust detail envelope is malformed');
    }
    return IllustEntity.fromJson(illustJson);
  }

  /// `/ajax/illust/{id}/pages` returns every page's true original width and
  /// height — the app API's `meta_pages` ships `image_urls` alone, which is
  /// why multi-page slots used to sit on the first page's ratio until the
  /// decode landed. The response feeds [IllustEntity.withPageDimensions].
  ///
  /// The shared WebView session cookie is sent when present (R18/restricted
  /// works need it); absent cookie or any transport/parse failure degrades
  /// to `null`, never an error — the caller keeps the first-page-ratio
  /// estimate exactly like before.
  Future<List<({int width, int height})>?> fetchPageDimensions(
    int illustId,
  ) async {
    try {
      // A session-channel failure must not skip the request: SFW pages
      // respond without a cookie too (same degradation Shaft relies on).
      String? cookie;
      try {
        cookie = await _session.readSessionCookie();
      } on Object {
        cookie = null;
      }
      final uri = Uri.https(
        PixivClientIdentity.webHost,
        '/ajax/illust/$illustId/pages',
        const {'lang': 'zh'},
      );
      final request = http.Request('GET', uri)
        ..headers.addAll({
          if (cookie != null && cookie.isNotEmpty) 'cookie': cookie,
          'user-agent': PixivClientIdentity.webUserAgent,
          'accept-language': 'zh-CN,zh;q=0.9,ja;q=0.8',
          'referer': 'https://www.pixiv.net/artworks/$illustId',
          'x-requested-with': 'XMLHttpRequest',
          'accept': 'application/json',
        });
      final client = _webClient ?? _newWebClient();
      final streamed = await client.send(request);
      final body = await streamed.stream.transform(utf8.decoder).join();
      if (streamed.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['error'] == true) return null;
      final pages = decoded['body'];
      if (pages is! List || pages.isEmpty) return null;
      return [
        for (final page in pages)
          if (page is Map)
            (width: _readInt(page['width']), height: _readInt(page['height'])),
      ];
    } on Object {
      return null;
    }
  }

  http.Client _newWebClient() => PixivPolicyHttpClient(
    policy: _policy ?? NetworkAccessPolicy(),
    purpose: PixivDestinationPurpose.pixivWeb,
  );

  static int _readInt(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
