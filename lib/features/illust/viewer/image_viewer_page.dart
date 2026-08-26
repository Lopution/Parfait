import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/pixiv_image.dart';

/// Fullscreen horizontal viewer replicating beta56 ImageScalePage
/// (R3): `n / total` title, horizontal paging, per-page zoom clamped to
/// 0.9–6.0, initial page restored, swiping suspended while zoomed.
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.urls,
    this.initialPage = 0,
  }) : assert(initialPage >= 0);

  final List<String> urls;
  final int initialPage;

  /// Zoom bounds (PRD R3: strictly 0.9–6.0).
  static const double minScale = 0.9;
  static const double maxScale = 6.0;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pageController;
  final _transformations = <int, TransformationController>{};
  int _activePage = 0;

  int get _pageCount => widget.urls.length;

  @override
  void initState() {
    super.initState();
    // Empty URL list has no pages to clamp against; keep the title at
    // "1 / 0" and let the placeholder body render (R6: no crash).
    _activePage =
        _pageCount == 0 ? 0 : widget.initialPage.clamp(0, _pageCount - 1);
    _pageController = PageController(initialPage: _activePage);
    _pageController.addListener(_onPageChanged);
    _transformationFor(_activePage).addListener(_onTransformed);
  }

  @override
  void dispose() {
    for (final controller in _transformations.values) {
      controller.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged() {
    final page = _pageController.page?.round() ?? _activePage;
    if (page != _activePage) {
      setState(() {
        _transformationFor(_activePage).removeListener(_onTransformed);
        _activePage = page;
        _transformationFor(_activePage).addListener(_onTransformed);
      });
    }
  }

  void _onTransformed() => setState(() {});

  TransformationController _transformationFor(int page) {
    return _transformations.putIfAbsent(page, TransformationController.new);
  }

  bool get _activeZoomed =>
      (_transformationFor(_activePage).value.getMaxScaleOnAxis()) >
      1.0 + precisionErrorTolerance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_activePage + 1} / $_pageCount'),
      ),
      body: _pageCount == 0
          ? const Center(
              child:
                  Text('没有可显示的图片', style: TextStyle(color: Colors.white)),
            )
          : PageView.builder(
              controller: _pageController,
              physics: _activeZoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _pageCount,
              itemBuilder: (context, page) {
                return InteractiveViewer(
                  key: ValueKey('viewer-page-$page'),
                  transformationController: _transformationFor(page),
                  minScale: ImageViewerPage.minScale,
                  maxScale: ImageViewerPage.maxScale,
                  panEnabled: true,
                  child: Center(
                    child: PixivImage(
                      url: widget.urls[page],
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
