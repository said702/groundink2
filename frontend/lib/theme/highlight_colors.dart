import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'app_theme.dart';

/// Colors that point at spelling mistakes in the handwriting.
class HighlightColors {
  /// Default color of suspect letters.
  static const red = AppColors.error;

  /// Used instead of red when the handwriting itself is red, pink or orange,
  /// where red letters would not stand out.
  static const blue = Color(0xFF2563EB);

  /// Highlighter-pen fill and edge behind the selected word.
  static const marker = Color(0xFFFFE066);
  static const markerEdge = Color(0xFFF59E0B);

  /// Highlight color for handwriting of color [inkArgb] (see
  /// WordBox.inkColor); red unless the ink is reddish.
  static Color forInk(int? inkArgb) {
    if (inkArgb == null) return red;
    final (_, a, b) = oklab(inkArgb);
    // Black, gray (pencil) and very dull inks have almost no chroma.
    if (math.sqrt(a * a + b * b) < 0.045) return red;
    // OKLab hue: magenta ≈ -30°, red ≈ 29°, orange ≈ 60°, yellow ≈ 110°,
    // green ≈ 140°, blue ≈ -95°, violet ≈ -65°.
    final hue = math.atan2(b, a) * 180 / math.pi;
    return hue > -40 && hue < 80 ? blue : red;
  }

  /// OKLab coordinates (L, a, b) of an sRGB color (Björn Ottosson, 2020).
  static (double, double, double) oklab(int argb) {
    double linear(int channel) {
      final c = channel / 255;
      return c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4) as double;
    }

    final r = linear((argb >> 16) & 0xFF);
    final g = linear((argb >> 8) & 0xFF);
    final b = linear(argb & 0xFF);
    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    );
  }

  static double _cbrt(double x) => x <= 0 ? 0 : math.pow(x, 1 / 3) as double;
}
