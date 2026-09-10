import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/download/download_manager.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart';
import '../../../l10n/context.dart';

class DownloadTasksPage extends ConsumerStatefulWidget {
  const DownloadTasksPage({super.key});

  @override
  ConsumerState<DownloadTasksPage> createState() => _DownloadTasksPageState();
}

class _DownloadTasksPageState extends ConsumerState<DownloadTasksPage> {
  late final DownloadManager _manager;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(downloadManagerProvider);
    _changes = _manager.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(
      _manager.recover().whenComplete(() {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _manager.tasks;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.downloaderSettings)),
      body: tasks.isEmpty
          ? Center(child: Text(context.l10n.downloadTasksEmpty))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(context.l10n.downloaderSettingsHint),
                ),
                for (final task in tasks)
                  _DownloadTaskTile(task: task, manager: _manager),
              ],
            ),
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({required this.task, required this.manager});

  final DownloadTaskSnapshot task;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    final canCancel =
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.running ||
        task.status == DownloadStatus.canceling;
    final canRetry =
        task.status == DownloadStatus.failed ||
        task.status == DownloadStatus.canceled ||
        task.status == DownloadStatus.retryable;
    return Card(
      child: ListTile(
        title: Text(task.displayName, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_downloadStatusText(context, task.status)),
            LinearProgressIndicator(value: progress),
            if (task.error != null) Text(task.error!),
          ],
        ),
        trailing: canCancel
            ? IconButton(
                tooltip: context.l10n.cancelDownload,
                icon: const Icon(Icons.close),
                onPressed: () => manager.cancel(task.id),
              )
            : canRetry
            ? IconButton(
                tooltip: context.l10n.retryDownload,
                icon: const Icon(Icons.refresh),
                onPressed: () => manager.retry(task.id),
              )
            : Icon(
                task.status == DownloadStatus.succeeded
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
              ),
      ),
    );
  }

  String _downloadStatusText(BuildContext context, DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => context.l10n.downloadQueued,
      DownloadStatus.running => context.l10n.downloadRunning,
      DownloadStatus.finalizing => context.l10n.downloadRunning,
      DownloadStatus.canceling => context.l10n.downloadCanceling,
      DownloadStatus.succeeded => context.l10n.downloadSucceeded,
      DownloadStatus.failed => context.l10n.downloadFailed,
      DownloadStatus.canceled => context.l10n.downloadCanceled,
      DownloadStatus.retryable => context.l10n.downloadFailed,
      DownloadStatus.orphaned => context.l10n.downloadFailed,
    };
  }
}
