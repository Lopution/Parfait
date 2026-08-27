import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_providers.dart';
import '../network/pixiv_http_client.dart';
import 'ugoira_repository.dart';

final ugoiraRepositoryProvider = Provider<UgoiraRepository>((ref) {
  return UgoiraRepository(
    client: ref.watch(pixivHttpClientProvider),
    transport: ref.watch(pixivMediaTransportProvider),
  );
});
