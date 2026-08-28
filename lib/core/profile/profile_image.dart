import '../reverse_image/image_input.dart';
import '../reverse_image/reverse_image_platform.dart';

import 'profile_edit_models.dart';

/// Reuses the bounded image header validator and app-private file ownership
/// contract from reverse-image input. Profile editing never receives the
/// source content URI after this boundary.
abstract final class ProfileImagePreprocessor {
  static Future<ProfileImageSelection> prepare({
    required ReverseImageInputPlatform platform,
    required ReverseImageInputReference reference,
  }) async {
    _validateReference(reference);
    String? path;
    var ownershipAttempted = false;
    try {
      path = await platform.copyToOwnedFile(reference);
      ownershipAttempted = true;
      final owned = await OwnedReverseImageInput.open(
        path: path,
        source: reference.source,
        mimeType: reference.mimeType,
        delete: platform.deleteOwnedFile,
      );
      final info = owned.info;
      return ProfileImageSelection(
        path: info.path,
        mimeType: info.mimeType,
        sizeBytes: info.sizeBytes,
        width: info.width,
        height: info.height,
        cleanup: owned.dispose,
      );
    } on Object {
      // OwnedReverseImageInput attempts cleanup after ownership is established.
      // Before that point only the platform adapter may know how to remove the
      // copied file, so delete it exactly once here.
      if (path != null && !ownershipAttempted) {
        await platform.deleteOwnedFile(path);
      }
      rethrow;
    }
  }

  static void _validateReference(ReverseImageInputReference reference) {
    final uri = Uri.tryParse(reference.contentUri);
    if (uri == null ||
        uri.scheme != 'content' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.invalidReference,
        'selected image reference is invalid',
      );
    }
    if (!reference.hasReadUriPermission) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.missingReadPermission,
        'selected image permission is no longer available',
      );
    }
    final mime = reference.mimeType.trim().toLowerCase();
    if (!ReverseImageInputValidator.isSupportedMime(mime)) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.invalidMimeType,
        'image MIME type is not supported',
      );
    }
    if (reference.sizeBytes <= 0) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.empty,
        'selected image is empty',
      );
    }
    if (reference.sizeBytes > ReverseImageInputLimits.maxEncodedBytes) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.oversized,
        'selected image exceeds the size limit',
      );
    }
  }
}
