import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Measures the color of handwriting, so that highlights can use a color
/// that stands out from it (red highlights vanish on red ink).
class InkColor {
  /// Typical color of the ink in [runs] (horizontal ink runs `[x, y, length]`
  /// in image coordinates) as 0xFFRRGGBB, or null if there is no ink.
  ///
  /// Uses the darker half of the ink pixels (the core of the strokes; the
  /// edges are blended with the paper) and white-balances the result against
  /// the paper, estimated from the brightest quarter of [bbox].
  static int? measure(img.Image image, List<List<int>> runs, List<int> bbox) {
    final pixels = _Pixels(image);
    final ink = <int>[];
    for (final run in runs) {
      final y = run[1];
      if (y < 0 || y >= image.height) continue;
      final end = (run[0] + run[2]).clamp(0, image.width);
      for (var x = run[0].clamp(0, image.width); x < end; x++) {
        ink.add(pixels.rgb(x, y));
      }
    }
    if (ink.isEmpty) return null;
    final core = _meanOfLuminanceRange(ink, 0.0, 0.5);

    final paper = <int>[];
    if (bbox.length >= 4) {
      final x1 = bbox[0].clamp(0, image.width);
      final x2 = bbox[2].clamp(0, image.width);
      final y1 = bbox[1].clamp(0, image.height);
      final y2 = bbox[3].clamp(0, image.height);
      // Sample about 4000 pixels, enough for a stable estimate.
      final area = (x2 - x1) * (y2 - y1);
      final step = area > 4000 ? (area / 4000).ceil() : 1;
      var i = 0;
      for (var y = y1; y < y2; y++) {
        for (var x = x1; x < x2; x++) {
          if (i++ % step == 0) paper.add(pixels.rgb(x, y));
        }
      }
    }
    var r = (core >> 16) & 0xFF, g = (core >> 8) & 0xFF, b = core & 0xFF;
    if (paper.isNotEmpty) {
      final white = _meanOfLuminanceRange(paper, 0.75, 1.0);
      int balance(int value, int paperValue) => paperValue < 64
          ? value
          : (value * 255 / paperValue).round().clamp(0, 255);
      r = balance(r, (white >> 16) & 0xFF);
      g = balance(g, (white >> 8) & 0xFF);
      b = balance(b, white & 0xFF);
    }
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  static int _luminance(int rgb) =>
      (((rgb >> 16) & 0xFF) * 299 +
          ((rgb >> 8) & 0xFF) * 587 +
          (rgb & 0xFF) * 114) ~/
      1000;

  /// Mean color of the pixels whose luminance rank lies in [from, to).
  static int _meanOfLuminanceRange(List<int> colors, double from, double to) {
    final histogram = Int32List(256);
    for (final c in colors) {
      histogram[_luminance(c)]++;
    }
    final lo = (colors.length * from).floor();
    final hi = (colors.length * to).ceil().clamp(lo + 1, colors.length);
    // Luminance bounds of the requested rank range.
    var seen = 0, minLum = 0, maxLum = 255;
    var foundMin = false;
    for (var l = 0; l < 256; l++) {
      seen += histogram[l];
      if (!foundMin && seen > lo) {
        minLum = l;
        foundMin = true;
      }
      if (seen >= hi) {
        maxLum = l;
        break;
      }
    }
    var r = 0, g = 0, b = 0, n = 0;
    for (final c in colors) {
      final l = _luminance(c);
      if (l < minLum || l > maxLum) continue;
      r += (c >> 16) & 0xFF;
      g += (c >> 8) & 0xFF;
      b += c & 0xFF;
      n++;
    }
    if (n == 0) return colors.first;
    return ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n);
  }
}

/// Fast RGB access for 8-bit images; falls back to getPixel otherwise.
class _Pixels {
  final img.Image image;
  final Uint8List? _bytes;
  final int _channels;

  _Pixels(this.image)
      : _bytes = image.format == img.Format.uint8 &&
                !image.hasPalette &&
                image.numChannels >= 3
            ? image.toUint8List()
            : null,
        _channels = image.numChannels;

  int rgb(int x, int y) {
    final bytes = _bytes;
    if (bytes != null) {
      final i = (y * image.width + x) * _channels;
      return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    }
    final p = image.getPixel(x, y);
    final scale = p.maxChannelValue == 255 ? 1.0 : 255 / p.maxChannelValue;
    int c(num v) => (v * scale).round().clamp(0, 255);
    return image.numChannels >= 3
        ? (c(p.r) << 16) | (c(p.g) << 8) | c(p.b)
        : (c(p.r) << 16) | (c(p.r) << 8) | c(p.r);
  }
}
