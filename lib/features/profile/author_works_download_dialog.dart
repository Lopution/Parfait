import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/download/author_works_enumerator.dart';
import '../../core/download/illust_download_coordinator.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';

/// Enumerating → confirming flow behind the author page's "download all"
/// action (implement.md step 4). Pops with the submitted group size on
/// confirm, null on cancel/failure.
class AuthorWorksDownloadDialog extends ConsumerStatefulWidget {
  const AuthorWorksDownloadDialog({
    super.key,
    required this.userId,
    required this.enumerator,
  });

  final int userId;
  final AuthorWorksEnumerator enumerator;

  @override
  ConsumerState<AuthorWorksDownloadDialog> createState() =>
      _AuthorWorksDownloadDialogState();
}

enum _Phase { enumerating, confirming, failed }

class _AuthorWorksDownloadDialogState
    extends ConsumerState<AuthorWorksDownloadDialog> {
  final _cancelToken = CancelToken();
  _Phase _phase = _Phase.enumerating;
  int _scanned = 0;
  AuthorWorksResult? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_enumerate());
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _enumerate() async {
    try {
      final result = await widget.enumerator.enumerate(
        widget.userId,
        cancelToken: _cancelToken,
        onProgress: (works) {
          if (mounted) setState(() => _scanned = works);
        },
      );
      if (!mounted) return;
      if (result.works.isEmpty) {
        setState(() => _phase = _Phase.failed);
      } else {
        setState(() {
          _result = result;
          _phase = _Phase.confirming;
        });
      }
    } catch (error) {
      if (!mounted || _phase != _Phase.enumerating) return;
      setState(() {
        _error = error;
        _phase = _Phase.failed;
      });
    }
  }

  void _cancel() {
    _cancelToken.cancel();
    Navigator.of(context).pop();
  }

  void _confirm() {
    final works = _result!.works;
    // Submission failure (ownership, validation, channel) must stay visible —
    // it surfaces as the dialog's failure state instead of a silent pop.
    try {
      final group = ref
          .read(illustDownloadCoordinatorProvider)
          .downloadAuthorWorks(
            works: works,
            namingRule: ref.read(namingRuleProvider),
          );
      Navigator.of(context).pop(group.childCount);
    } catch (error) {
      setState(() {
        _error = error;
        _phase = _Phase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return switch (_phase) {
      _Phase.enumerating => AlertDialog(
        title: Text(l10n.downloadAuthorWorksTitle),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Flexible(child: Text(l10n.downloadAuthorEnumerating(_scanned))),
          ],
        ),
        actions: [TextButton(onPressed: _cancel, child: Text(l10n.cancel))],
      ),
      _Phase.confirming => AlertDialog(
        title: Text(l10n.downloadAuthorWorksTitle),
        content: Builder(
          builder: (context) {
            final result = _result!;
            final pages = ref
                .read(illustDownloadCoordinatorProvider)
                .authorWorksRequests(result.works)
                .length;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.downloadAuthorConfirmBody(result.works.length, pages),
                ),
                if (result.truncated) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.downloadAuthorTruncated(
                      AuthorWorksEnumerator.maxWorks,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          TextButton(onPressed: _cancel, child: Text(l10n.cancel)),
          FilledButton(onPressed: _confirm, child: Text(l10n.confirm)),
        ],
      ),
      _Phase.failed => AlertDialog(
        title: Text(l10n.downloadAuthorWorksTitle),
        content: Text(
          _error == null
              ? l10n.downloadAuthorEmpty
              : l10n.downloadAuthorFailed('$_error'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.dismiss),
          ),
        ],
      ),
    };
  }
}
