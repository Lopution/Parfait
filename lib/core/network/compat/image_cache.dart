import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

class PixivImageCache {
  PixivImageCache({required this.httpClient});

  final http.Client httpClient;
  CacheManager? _manager;

  CacheManager get manager {
    return _manager ??= CacheManager(
      Config(
        'pixiv_func_images',
        fileService: HttpFileService(httpClient: httpClient),
      ),
    );
  }

  Future<void> dispose() async {
    final cache = _manager;
    _manager = null;
    if (cache != null) {
      // flutter_cache_manager 3.4.x cannot close an as-yet-unopened JSON
      // repository. Opening it explicitly also makes provider-container
      // teardown deterministic in widget tests and during app shutdown.
      await cache.store.retrieveCacheData('pixiv_func_lifecycle_probe');
      await cache.dispose();
    }
  }
}
