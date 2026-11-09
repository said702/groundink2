import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'overlay_painter.dart';

/// A word that can be tapped on the photo.
typedef PhotoWord = ({int id, List<int> bbox});

/// The scanned photo with the spelling feedback drawn on it.
///
/// Brings the [focus] word into view (zooming in when it is too small to
/// read) whenever it changes, and reports taps on words via [onWordTap].
class PhotoPanel extends StatefulWidget {
  final File imageFile;
  final ui.Image? image;
  final Size imageSize;

  /// Part of the image that is shown (the area around the writing).
  final Rect crop;
  final List<OverlayWord> overlay;
  final List<PhotoWord> words;

  /// Bounding box `[x1, y1, x2, y2]` of the word to bring into view.
  final List<int>? focus;
  final ValueChanged<int>? onWordTap;

  const PhotoPanel({
    super.key,
    required this.imageFile,
    required this.image,
    required this.imageSize,
    required this.crop,
    required this.overlay,
    required this.words,
    this.focus,
    this.onWordTap,
  });

  @override
  State<PhotoPanel> createState() => _PhotoPanelState();
}

class _PhotoPanelState extends State<PhotoPanel>
    with SingleTickerProviderStateMixin {
  static const _maxScale = 6.0;

  final _transform = TransformationController();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  )..addListener(_onAnimate);
  Matrix4Tween? _tween;
  Size _viewport = Size.zero;
  bool _focusScheduled = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    _scheduleFocus();
  }

  @override
  void didUpdateWidget(PhotoPanel old) {
    super.didUpdateWidget(old);
    if (old.imageFile.path != widget.imageFile.path ||
        old.crop != widget.crop) {
      _animation.stop();
      _transform.value = Matrix4.identity();
      _scheduleFocus();
    } else if (!_sameBox(old.focus, widget.focus)) {
      _scheduleFocus();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform.dispose();
    super.dispose();
  }

  static bool _sameBox(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _zoomed = false;

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onAnimate() {
    final tween = _tween;
    if (tween == null) return;
    _transform.value =
        tween.transform(Curves.easeInOutCubic.transform(_animation.value));
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _transform.value.clone(), end: target);
    _animation.forward(from: 0);
  }

  void _scheduleFocus() {
    if (_focusScheduled) return;
    _focusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusScheduled = false;
      if (mounted) _focusOnWord();
    });
  }

  /// Scale factor from image pixels to panel coordinates.
  double get _imageScale =>
      widget.crop.width > 0 ? _viewport.width / widget.crop.width : 1;

  Rect _toPanel(List<int> bbox) {
    final s = _imageScale;
    final c = widget.crop;
    return Rect.fromLTRB((bbox[0] - c.left) * s, (bbox[1] - c.top) * s,
        (bbox[2] - c.left) * s, (bbox[3] - c.top) * s);
  }

  /// Pans (and if needed zooms) so that the focus word is clearly visible.
  /// Leaves the view alone when the word is already well visible.
  void _focusOnWord() {
    final box = widget.focus;
    if (box == null || box.length < 4 || _viewport.isEmpty) return;
    final word = _toPanel(box);
    if (word.width <= 0 || word.height <= 0) return;
    final w = _viewport.width, h = _viewport.height;
    final current = _transform.value;
    final k = current.getMaxScaleOnAxis();
    final t = current.getTranslation();
    final onScreen = Rect.fromLTWH(word.left * k + t.x, word.top * k + t.y,
        word.width * k, word.height * k);

    // Comfortable size: about a third of the panel height, while the word
    // (with some context) still fits the width.
    final desired =
        math.min(w * 0.7 / word.width, h * 0.32 / word.height).clamp(1.0, 4.0);
    final fits = math.min(w * 0.92 / word.width, h * 0.9 / word.height);
    final visible =
        (Offset.zero & _viewport).deflate(4).contains(onScreen.topLeft) &&
            (Offset.zero & _viewport).deflate(4).contains(onScreen.bottomRight);
    final tooSmall = k < desired * 0.6;
    if (visible && !tooSmall) return;

    final scale = (tooSmall ? desired : math.min(k, fits))
        .clamp(1.0, _maxScale)
        .toDouble();
    var dx = w / 2 - word.center.dx * scale;
    var dy = h / 2 - word.center.dy * scale;
    dx = dx.clamp(w - w * scale, 0.0).toDouble();
    dy = dy.clamp(h - h * scale, 0.0).toDouble();
    _animateTo(Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1));
  }

  void _showWholePage() => _animateTo(Matrix4.identity());

  void _onTapUp(TapUpDetails details) {
    final onWordTap = widget.onWordTap;
    if (onWordTap == null || _imageScale <= 0) return;
    final s = _imageScale;
    final point = Offset(widget.crop.left + details.localPosition.dx / s,
        widget.crop.top + details.localPosition.dy / s);
    int? best;
    var bestDistance = double.infinity;
    for (final word in widget.words) {
      final b = word.bbox;
      if (b.length < 4) continue;
      final box = Rect.fromLTRB(
          b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble());
      // A little slack makes small words easier to hit.
      final slack = math.max(8.0 / s, box.height * 0.15);
      if (!box.inflate(slack).contains(point)) continue;
      final distance = (box.center - point).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = word.id;
      }
    }
    if (best != null) onWordTap(best);
  }

  @override
  Widget build(BuildContext context) {
    final crop = widget.crop;
    final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspect = crop.width > 0 && crop.height > 0
            ? crop.width / crop.height
            : 4 / 3;
        final maxWidth = math.max(0.0, constraints.maxWidth - 24);
        final maxHeight = math.max(0.0, constraints.maxHeight - 18);
        final panelWidth = math.min(maxWidth, maxHeight * aspect);
        final viewport = Size(panelWidth, aspect > 0 ? panelWidth / aspect : 0);
        if (viewport != _viewport) {
          _viewport = viewport;
          _scheduleFocus();
        }

        return Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: SizedBox(
              width: panelWidth,
              child: AspectRatio(
                aspectRatio: aspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: AppColors.cardBorder),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        InteractiveViewer(
                          transformationController: _transform,
                          maxScale: _maxScale,
                          onInteractionStart: (_) => _animation.stop(),
                          child: widget.imageSize == Size.zero ||
                                  widget.image == null
                              ? Image.file(widget.imageFile, fit: BoxFit.cover)
                              : GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: _onTapUp,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      CustomPaint(
                                        painter: CroppedPhotoPainter(
                                          image: widget.image!,
                                          sourceRect: crop,
                                        ),
                                      ),
                                      CustomPaint(
                                        painter: OverlayPainter(
                                          words: widget.overlay,
                                          imageSize: widget.imageSize,
                                          sourceRect: crop,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                        if (_zoomed)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Material(
                              color: Colors.white.withValues(alpha: 0.92),
                              shape: const CircleBorder(),
                              elevation: 2,
                              child: IconButton(
                                icon: Icon(Icons.zoom_out_map,
                                    size: tablet ? 30 : 22),
                                color: AppColors.primary,
                                tooltip: 'Show whole page',
                                onPressed: _showWholePage,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Draws [sourceRect] of [image] scaled to the canvas.
class CroppedPhotoPainter extends CustomPainter {
  final ui.Image image;
  final Rect sourceRect;

  const CroppedPhotoPainter({
    required this.image,
    required this.sourceRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      sourceRect,
      Offset.zero & size,
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant CroppedPhotoPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.sourceRect != sourceRect;
}
