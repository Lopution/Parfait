import '../../../core/entity/illust_entity.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/pixiv_http_client.dart';

/// Detail data source: `GET /v1/illust/detail?illust_id=` through the shared
/// authenticated client.
class IllustDetailRepository {
  IllustDetailRepository(this._client);

  final PixivHttpClient _client;

  static const String _path = '/v1/illust/detail';

  Future<IllustEntity> fetch(int illustId) async {
    final json = await _client.getJson(
      Uri(
        scheme: 'https',
        host: 'app-api.pixiv.net',
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
}
