import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/account_store.dart';
import '../auth/credential.dart';
import '../auth/credential_store.dart';
import '../entity/illust_entity.dart';
import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';
import '../network/compat/network_providers.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../../features/home/recommended/recommended_repository.dart';
import 'widget_snapshot.dart';
import 'widget_snapshot_store.dart';

/// Item count per snapshot. Each recommend widget instance renders
/// item[slotIndex % items.length]; beta56 kept a shared pool and consumed it
/// across widget instances.
const int widgetSnapshotMaxItems = 8;

/// Cover byte ceiling applied before the file lands in the snapshot store.
/// The native renderer additionally bounds decoded pixels per widget size.
const int widgetCoverMaxBytes = widgetImageMaxBytes;

/// Keep the complete generation bounded before it is published. This is a
/// download/storage budget, separate from the native decoded bitmap budget.
const int widgetSnapshotMaxTotalImageBytes =
    widgetCoverMaxBytes * widgetSnapshotMaxItems;

/// Outcome of one widget feed generation pass.
enum WidgetFeedOutcome {
  /// Fresh snapshot written and activated.
  written,

  /// No signed-in account; render state cleared.
  noAccount,

  /// Authentication failed after the shared refresh chain; render state
  /// cleared so the old account's artwork cannot outlive its credential.
  authRequired,

  /// Transient network/HTTP/parse failure; same-account last-good kept and
  /// a bounded retry is scheduled by the caller.
  transientFailure,

  /// The account or credential boundary changed while this pass was in
  /// flight. The result must not clear, publish or notify native state; a
  /// newer foreground pass owns the new account boundary.
  superseded,
}

class WidgetFeedResult {
  const WidgetFeedResult(this.outcome, {this.snapshot});

  final WidgetFeedOutcome outcome;
  final WidgetSnapshot? snapshot;

  bool get written => outcome == WidgetFeedOutcome.written;
}

DateTime _defaultNow() => DateTime.now();

/// Generates the widget snapshot from the real Recommended feed.
///
/// Network always flows through the shared [PixivHttpClient] (app API) and
/// the image-purpose policy client (exact i.pximg.net allowlist); this class
/// owns no endpoints of its own. Every failure is classified into
/// [WidgetFeedOutcome] instead of being swallowed.
class WidgetFeedLoader {
  WidgetFeedLoader({
    required PixivHttpClient apiClient,
    required http.Client imageClient,
    required AccountStore accountStore,
    required CredentialStore credentialStore,
    required FutureOr<WidgetSnapshotStore> Function() storeFactory,
    DateTime Function() now = _defaultNow,
  }) : _apiClient = apiClient,
       _imageClient = imageClient,
       _accountStore = accountStore,
       _credentialStore = credentialStore,
       _storeFactory = storeFactory,
       _now = now;

  final PixivHttpClient _apiClient;
  final http.Client _imageClient;
  final AccountStore _accountStore;
  final CredentialStore _credentialStore;
  final FutureOr<WidgetSnapshotStore> Function() _storeFactory;
  final DateTime Function() _now;

  Future<WidgetFeedResult> load() async {
    final AccountState state;
    try {
      state = await _accountStore.resolveState();
    } on Object catch (error) {
      // An unreadable account store is not proof of logout. Keep the
      // same-account last-good snapshot and let the bounded retry recover.
      debugPrint(
        'WidgetFeedLoader account state unavailable: ${error.runtimeType}',
      );
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    }
    if (state.status != AccountStatus.ready) {
      debugPrint('WidgetFeedLoader account state is not ready');
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    }
    final account = state.usableCurrent;
    if (account == null) {
      await _clearQuietly();
      return const WidgetFeedResult(WidgetFeedOutcome.noAccount);
    }
    final Credential? credential;
    try {
      credential = await _credentialStore.read(account.id);
    } on Object catch (error) {
      debugPrint(
        'WidgetFeedLoader credential unavailable: ${error.runtimeType}',
      );
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    }
    if (credential == null) {
      await _clearQuietly();
      return const WidgetFeedResult(WidgetFeedOutcome.noAccount);
    }

    final accountKey = _accountKey(account.id);
    try {
      final page = await RecommendedIllustRepository(
        _apiClient,
      ).fetchPage(null);
      final candidates = page.illusts
          .where((illust) => !illust.isR18)
          .take(widgetSnapshotMaxItems)
          .toList(growable: false);
      if (candidates.isEmpty) {
        return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
      }

      final images = <String, List<int>>{};
      final items = <WidgetSnapshotItem>[];
      final generation = _generationToken();
      var totalImageBytes = 0;
      for (final illust in candidates) {
        final bytes = await _downloadCover(illust);
        if (bytes == null) {
          // One failed cover aborts this pass; the last-good snapshot stays
          // active for the same account and the caller schedules a retry.
          debugPrint('WidgetFeedLoader cover failed: ${illust.id}');
          return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
        }
        totalImageBytes += bytes.length;
        if (totalImageBytes > widgetSnapshotMaxTotalImageBytes) {
          debugPrint('WidgetFeedLoader total cover budget exceeded');
          return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
        }
        // A generation-specific name means an in-flight writer never
        // overwrites an image still referenced by the active pointer.
        final imageFile = 'cover_${illust.id}_$generation.img';
        images[imageFile] = bytes;
        items.add(
          WidgetSnapshotItem(
            illustId: illust.id,
            title: illust.title,
            userId: illust.user.id,
            userName: illust.user.name,
            imageFile: imageFile,
          ),
        );
      }

      final snapshot = WidgetSnapshot.create(
        accountKey: accountKey,
        accountRevision: state.credentialRevision,
        generatedAt: _now(),
        items: items,
      );
      if (!await _stillOwns(account.id, state.credentialRevision)) {
        return const WidgetFeedResult(WidgetFeedOutcome.superseded);
      }
      final store = await _storeFactory();
      // Store.write stages new files and flips the pointer last. It must not
      // clear the active generation first: a storage failure is transient
      // and must preserve same-account last-good state.
      await store.write(snapshot, images);
      return WidgetFeedResult(WidgetFeedOutcome.written, snapshot: snapshot);
    } on ApiUnauthorized {
      // Only the account identity is compared here. Handling the 401 is what
      // marks the account as needing re-auth, which advances the credential
      // revision, so comparing revisions would classify every real auth
      // failure as superseded and leave stale artwork on the home screen.
      if (!await _isSameCurrentAccount(account.id)) {
        return const WidgetFeedResult(WidgetFeedOutcome.superseded);
      }
      await _clearQuietly();
      return const WidgetFeedResult(WidgetFeedOutcome.authRequired);
    } on ApiRateLimited {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on ApiHttpError {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on ApiNetworkError {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on ApiTimeout {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on ApiParseError {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on SocketException {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on http.ClientException {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on WidgetSnapshotOversizeError {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on FileSystemException {
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    } on Object catch (error) {
      // Any other failure (storage backend, unexpected platform error) is
      // still surfaced as a classified outcome and a bounded retry — never
      // silently dropped.
      debugPrint('WidgetFeedLoader unexpected: ${error.runtimeType}: $error');
      return const WidgetFeedResult(WidgetFeedOutcome.transientFailure);
    }
  }

  /// Clearing is best-effort: if the store itself is unreadable the visible
  /// state is still "no snapshot". The reason stays visible in debug logs.
  Future<void> _clearQuietly() async {
    try {
      final store = await _storeFactory();
      await store.clear();
    } on Object catch (error) {
      debugPrint('WidgetFeedLoader.clear unavailable: ${error.runtimeType}');
    }
  }

  /// Downloads one cover through the image policy client with a byte cap.
  /// The exact-host registry inside the policy client rejects any non-pximg
  /// URL before a socket is opened.
  Future<List<int>?> _downloadCover(IllustEntity illust) async {
    try {
      final response = await _imageClient
          .get(
            Uri.parse(illust.imageUrls.squareMedium),
            // i.pximg.net answers image requests without the standard
            // Pixiv origin with 403; this is the same visible identity the
            // download layer already sends, not a policy bypass.
            headers: <String, String>{
              'Referer': PixivClientIdentity.downloadReferer.toString(),
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        debugPrint('WidgetFeedLoader cover http ${response.statusCode}');
        return null;
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty || bytes.length > widgetCoverMaxBytes) {
        debugPrint('WidgetFeedLoader cover size rejected: ${bytes.length}');
        return null;
      }
      return bytes;
    } on Exception catch (error) {
      debugPrint('WidgetFeedLoader cover error ${error.runtimeType}: $error');
      return null;
    }
  }

  /// Non-secret, non-reversible account binding: truncated SHA-256 of the
  /// account id. Native compares only this key, never the id itself.
  static String _accountKey(String accountId) {
    return sha256.convert(accountId.codeUnits).toString().substring(0, 16);
  }

  String _generationToken() {
    final now = _now().microsecondsSinceEpoch;
    return '${now.abs()}_${Object().hashCode.abs()}';
  }

  Future<bool> _stillOwns(String accountId, int revision) async {
    try {
      final current = await _accountStore.resolveState();
      return current.status == AccountStatus.ready &&
          current.usableCurrent?.id == accountId &&
          current.credentialRevision == revision;
    } on Object catch (error) {
      debugPrint(
        'WidgetFeedLoader ownership check unavailable: ${error.runtimeType}',
      );
      return false;
    }
  }

  /// Whether [accountId] is still the account the home screen represents.
  /// A reauth-required account still counts: it is the same account, and the
  /// caller's job is to clear its now-unauthorised snapshot.
  Future<bool> _isSameCurrentAccount(String accountId) async {
    try {
      final current = await _accountStore.resolveState();
      return current.status == AccountStatus.ready &&
          current.current?.id == accountId;
    } on Object catch (error) {
      debugPrint(
        'WidgetFeedLoader account check unavailable: ${error.runtimeType}',
      );
      return false;
    }
  }
}

final widgetFeedLoaderProvider = Provider<WidgetFeedLoader>((ref) {
  final network = ref.watch(pixivNetworkFactoryProvider);
  return WidgetFeedLoader(
    apiClient: ref.watch(pixivHttpClientProvider),
    imageClient: network.client(PixivDestinationPurpose.image),
    accountStore: ref.watch(accountStoreProvider.notifier),
    credentialStore: ref.watch(credentialStoreProvider),
    storeFactory: WidgetSnapshotStore.standard,
  );
});
