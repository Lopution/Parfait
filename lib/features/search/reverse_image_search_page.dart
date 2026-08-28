import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/replica_page_route.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/reverse_image/reverse_image_controller.dart';
import '../../core/reverse_image/reverse_image_external.dart';
import '../../core/reverse_image/reverse_image_platform.dart';
import '../../core/reverse_image/reverse_image_provider.dart';
import '../illust/detail/illust_detail_page.dart';
import 'search_text.dart';

class ReverseImageSearchPage extends StatefulWidget {
  const ReverseImageSearchPage({
    super.key,
    this.initialReference,
    this.platform,
    this.provider,
    this.externalLauncher,
  });

  final ReverseImageInputReference? initialReference;
  final ReverseImageInputPlatform? platform;
  final ReverseImageProvider? provider;
  final ReverseImageExternalLauncher? externalLauncher;

  @override
  State<ReverseImageSearchPage> createState() => _ReverseImageSearchPageState();
}

class _ReverseImageSearchPageState extends State<ReverseImageSearchPage> {
  late final ReverseImageSearchController _controller;
  late final ReverseImageExternalLauncher _externalLauncher;

  @override
  void initState() {
    super.initState();
    _controller = ReverseImageSearchController(
      platform: widget.platform ?? MethodChannelReverseImageInputPlatform(),
      provider:
          widget.provider ??
          UnavailableReverseImageProvider(
            reason:
                'No approved structured reverse-image provider is configured',
          ),
    )..addListener(_onControllerChanged);
    _externalLauncher =
        widget.externalLauncher ?? MethodChannelReverseImageExternalLauncher();
    final reference = widget.initialReference;
    if (reference != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_controller.prepare(reference));
      });
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _cancelAndPop() async {
    await _controller.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _search() => _controller.search();

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      appBar: AppBar(
        title: Text(searchText(context, 'searchReverseImage')),
        leading: IconButton(
          tooltip: searchText(context, 'searchReverseCancel'),
          onPressed: _cancelAndPop,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(child: _body(context, state)),
    );
  }

  Widget _body(BuildContext context, ReverseImageFlowState state) {
    return switch (state.status) {
      ReverseImageFlowStatus.idle ||
      ReverseImageFlowStatus.canceled => _idle(context),
      ReverseImageFlowStatus.picking => _progress(
        context,
        searchText(context, 'searchReversePreparing'),
      ),
      ReverseImageFlowStatus.preparing => _progress(
        context,
        searchText(context, 'searchReversePreparing'),
      ),
      ReverseImageFlowStatus.searching => _progress(
        context,
        searchText(context, 'searchReverseSearching'),
      ),
      ReverseImageFlowStatus.ready => _ready(context, state),
      ReverseImageFlowStatus.failure => _failure(context, state),
      ReverseImageFlowStatus.success => _results(context, state),
    };
  }

  Widget _idle(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          const Icon(Icons.image_search_outlined, size: 72),
          const SizedBox(height: 18),
          Text(
            searchText(context, 'searchReverseUnavailable'),
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            searchText(context, 'searchReverseUnavailableDetail'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _privacyCard(context),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _controller.pick,
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(searchText(context, 'searchReversePick')),
          ),
        ],
      ),
    );
  }

  Widget _privacyCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.privacy_tip_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    searchText(context, 'searchReversePrivacy'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(searchText(context, 'searchReversePrivacyDetail')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progress(BuildContext context, String label) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(label),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: _cancelAndPop,
              child: Text(searchText(context, 'searchReverseCancel')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ready(BuildContext context, ReverseImageFlowState state) {
    final input = state.input!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _privacyCard(context),
          const SizedBox(height: 16),
          Text(
            searchText(context, 'searchReverseReady'),
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: input.width / input.height,
              child: Image.file(
                File(input.path),
                fit: BoxFit.contain,
                cacheWidth: 1024,
                cacheHeight: 1024,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(Icons.broken_image_outlined, size: 56),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${input.width} × ${input.height} · ${_formatBytes(input.sizeBytes)}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _search,
            icon: const Icon(Icons.search),
            label: Text(searchText(context, 'searchReverseUse')),
          ),
        ],
      ),
    );
  }

  Widget _failure(BuildContext context, ReverseImageFlowState state) {
    final failure = state.failure!;
    final message =
        failure.code == ReverseImageProviderFailureCode.providerUnavailable
        ? searchText(context, 'searchReverseUnavailableDetail')
        : failure.message;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _controller.pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(searchText(context, 'searchReverseRetry')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, ReverseImageFlowState state) {
    if (state.results.isEmpty) {
      return Center(child: Text(searchText(context, 'searchReverseNoResults')));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: state.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final hit = state.results[index];
        final title =
            hit.title ??
            (hit.pixivId == null
                ? hit.externalUrl!.host
                : 'Pixiv #${hit.pixivId}');
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Text(hit.similarity.toStringAsFixed(0)),
            ),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${hit.similarity.toStringAsFixed(1)}%'),
            trailing: hit.pixivId != null
                ? const Icon(Icons.chevron_right)
                : OutlinedButton(
                    onPressed: () => _openExternal(hit.externalUrl!),
                    child: Text(
                      searchText(context, 'searchReverseOpenExternal'),
                    ),
                  ),
            onTap: hit.pixivId == null
                ? () => _openExternal(hit.externalUrl!)
                : () => Navigator.of(context).push<void>(
                    ReplicaPageRoute<void>(
                      builder: (_) => IllustDetailPage(illustId: hit.pixivId!),
                    ),
                  ),
          ),
        );
      },
    );
  }

  Future<void> _openExternal(Uri uri) async {
    try {
      await _externalLauncher.open(uri);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(searchText(context, 'searchReverseOpenFailed'))),
      );
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

void showReverseImageSearch(
  BuildContext context, {
  ReverseImageInputReference? initialReference,
}) {
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) =>
          ReverseImageSearchPage(initialReference: initialReference),
    ),
  );
}
