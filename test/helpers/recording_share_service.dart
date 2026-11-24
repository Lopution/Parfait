import 'dart:ui';

import 'package:share_plus/share_plus.dart' show XFile;

import 'package:parfait/core/share/share_service.dart';

/// Records what a page hands to the platform share boundary — the system sheet
/// is an external boundary, so a recording stand-in is legitimate here (the
/// page itself always runs).
class RecordingShareService implements ShareService {
  final List<SharePayload> payloads = [];
  final List<Rect?> origins = [];
  final List<({List<XFile> files, String? subject, String? text, Rect? origin})>
  fileShares = [];
  ShareOutcome outcome = ShareOutcome.openedSheet;
  Object? fileShareError;

  SharePayload? get lastPayload => payloads.lastOrNull;
  Rect? get lastOrigin => origins.lastOrNull;

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    payloads.add(payload);
    origins.add(sharePositionOrigin);
    return outcome;
  }

  @override
  Future<void> shareFiles(
    List<XFile> files, {
    String? subject,
    String? text,
    Rect? sharePositionOrigin,
  }) async {
    fileShares.add((
      files: files,
      subject: subject,
      text: text,
      origin: sharePositionOrigin,
    ));
    if (fileShareError case final error?) throw error;
  }
}
