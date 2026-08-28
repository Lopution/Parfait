import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';
import 'image_input.dart';

enum ReverseImageProviderKind { structuredApi, interactiveWebView, unavailable }

@immutable
class ReverseImageProviderCapability {
  const ReverseImageProviderCapability({
    required this.name,
    required this.kind,
    required this.enabled,
    required this.observedAt,
    required this.reason,
  });

  final String name;
  final ReverseImageProviderKind kind;
  final bool enabled;
  final String observedAt;
  final String reason;
}

enum ReverseImageProviderFailureCode {
  providerUnavailable,
  cancelled,
  network,
  rateLimited,
  malformedResponse,
  unsafeResultUrl,
}

class ReverseImageProviderException implements Exception {
  const ReverseImageProviderException(this.code, this.message);

  final ReverseImageProviderFailureCode code;
  final String message;

  @override
  String toString() => 'ReverseImageProviderException($code, $message)';
}

sealed class ReverseImageSearchOutcome {
  const ReverseImageSearchOutcome();
}

class ReverseImageSearchSuccess extends ReverseImageSearchOutcome {
  const ReverseImageSearchSuccess(this.hits);

  final List<ReverseImageHit> hits;
}

class ReverseImageSearchFailure extends ReverseImageSearchOutcome {
  const ReverseImageSearchFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.retryAfter,
  });

  final ReverseImageProviderFailureCode code;
  final String message;
  final bool retryable;
  final Duration? retryAfter;
}

@immutable
class ReverseImageHit {
  const ReverseImageHit({
    required this.similarity,
    this.pixivId,
    this.title,
    this.thumbnailUrl,
    this.externalUrl,
  });

  final double similarity;
  final int? pixivId;
  final String? title;
  final Uri? thumbnailUrl;
  final Uri? externalUrl;
}

abstract interface class ReverseImageProvider {
  ReverseImageProviderCapability get capability;

  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  });
}

/// Explicitly represents the current research decision. It is not a fake
/// result provider: callers receive a terminal, visible failure and must not
/// render an empty success state.
class UnavailableReverseImageProvider implements ReverseImageProvider {
  UnavailableReverseImageProvider({
    required this.reason,
    this.name = 'reverse-image-provider',
    this.observedAt = '2026-08-28',
  });

  final String name;
  final String reason;
  final String observedAt;

  @override
  ReverseImageProviderCapability get capability =>
      ReverseImageProviderCapability(
        name: name,
        kind: ReverseImageProviderKind.unavailable,
        enabled: false,
        observedAt: observedAt,
        reason: reason,
      );

  @override
  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.cancelled,
        message: 'reverse image search was cancelled',
      );
    }
    return ReverseImageSearchFailure(
      code: ReverseImageProviderFailureCode.providerUnavailable,
      message: reason,
    );
  }
}

/// Maps the documented SauceNAO-shaped JSON contract for future approved
/// structured providers. The mapper is kept separate from transport, so no
/// HTML or challenge page can be mistaken for a successful response.
abstract final class ReverseImageResultMapper {
  static ReverseImageSearchSuccess fromSauceNaoJson(Map<String, dynamic> json) {
    final rawResults = json['results'];
    if (rawResults is! List) {
      throw const ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        'reverse image results are malformed',
      );
    }

    final indexed = <({int index, ReverseImageHit hit})>[];
    for (var index = 0; index < rawResults.length; index++) {
      final result = _map(rawResults[index]);
      final header = _map(result['header']);
      final data = _map(result['data']);
      final similarity = _similarity(header['similarity']);
      final pixivId = _positiveId(data['pixiv_id']);
      final externalUrls = _urls(data['ext_urls'], field: 'result URL');
      final externalUrl = externalUrls.isEmpty ? null : externalUrls.first;
      final thumbnailUrl = _optionalUrl(
        data['thumbnail'],
        field: 'thumbnail URL',
      );
      if (pixivId == null && externalUrl == null) {
        throw const ReverseImageProviderException(
          ReverseImageProviderFailureCode.malformedResponse,
          'reverse image result has no usable destination',
        );
      }
      indexed.add((
        index: index,
        hit: ReverseImageHit(
          similarity: similarity,
          pixivId: pixivId,
          title: _optionalText(data['title']),
          thumbnailUrl: thumbnailUrl,
          externalUrl: externalUrl,
        ),
      ));
    }

    final deduplicated = <String, ({int index, ReverseImageHit hit})>{};
    for (final entry in indexed) {
      final key = entry.hit.pixivId == null
          ? 'url:${entry.hit.externalUrl}'
          : 'pixiv:${entry.hit.pixivId}';
      final previous = deduplicated[key];
      if (previous == null || entry.hit.similarity > previous.hit.similarity) {
        deduplicated[key] = entry;
      }
    }
    final sorted = deduplicated.values.toList()
      ..sort((left, right) {
        final bySimilarity = right.hit.similarity.compareTo(
          left.hit.similarity,
        );
        return bySimilarity == 0
            ? left.index.compareTo(right.index)
            : bySimilarity;
      });
    return ReverseImageSearchSuccess([for (final entry in sorted) entry.hit]);
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map) {
      throw const ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        'reverse image result object is malformed',
      );
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const ReverseImageProviderException(
          ReverseImageProviderFailureCode.malformedResponse,
          'reverse image result keys are malformed',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static double _similarity(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 100) {
      throw const ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        'reverse image similarity is invalid',
      );
    }
    return parsed;
  }

  static int? _positiveId(Object? value) {
    final parsed = value is int
        ? value
        : value is String
        ? int.tryParse(value.trim())
        : null;
    if (parsed == null) return null;
    if (parsed <= 0) {
      throw const ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        'reverse image identifier is invalid',
      );
    }
    return parsed;
  }

  static List<Uri> _urls(Object? value, {required String field}) {
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! String)) {
      throw ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        '$field list is malformed',
      );
    }
    return [
      for (final item in value.cast<String>())
        parseSafeExternalUrl(item, field: field),
    ];
  }

  static Uri? _optionalUrl(Object? value, {required String field}) {
    if (value == null) return null;
    if (value is! String) {
      throw ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        '$field is malformed',
      );
    }
    return parseSafeExternalUrl(value, field: field);
  }

  static Uri parseSafeExternalUrl(String value, {required String field}) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty) {
      throw ReverseImageProviderException(
        ReverseImageProviderFailureCode.unsafeResultUrl,
        '$field is not an allowed HTTPS URL',
      );
    }
    return uri;
  }

  static String? _optionalText(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const ReverseImageProviderException(
        ReverseImageProviderFailureCode.malformedResponse,
        'reverse image title is malformed',
      );
    }
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }
}
