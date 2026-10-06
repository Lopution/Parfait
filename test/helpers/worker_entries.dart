import 'dart:isolate';

import 'package:parfait/core/image/image_worker_protocol.dart';

/// A worker isolate that exits before it ever reports ready.
@pragma('vm:entry-point')
void exitAtOnceWorkerEntry(Map<String, Object?> args) {}

/// A worker isolate that reports ready, then exits on its first message —
/// a worker that crashed mid-session.
@pragma('vm:entry-point')
void readyThenExitWorkerEntry(Map<String, Object?> args) {
  final inbox = ReceivePort();
  (args['sendPort'] as SendPort).send(
    encodeWorkerEvent(ReadyEvent(inbox.sendPort)),
  );
  inbox.listen((_) => Isolate.exit());
}
