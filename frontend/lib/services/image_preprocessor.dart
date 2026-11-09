import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Image preprocessing für das Zeichenmodell.
/// Implementiert bg_normalize, tight_crop, und white_pad.
class ImagePreprocessor {
  /// Konvertiert Bild zu Graustufen.
  static img.Image asGray(img.Image image) {
    if (image.numChannels == 1) return image;
    return img.grayscale(image);
  }

  /// Konvertiert Graustufen-Bild zu RGB.
  static img.Image asRgb(img.Image gray) {
    if (gray.numChannels >= 3) return gray;
    // Manuell Grau → RGB konvertieren
    final rgb = img.Image(width: gray.width, height: gray.height);
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final pixel = gray.getPixel(x, y);
        final g = pixel.r.toInt(); // Grauwert
        rgb.setPixelRgb(x, y, g, g, g);
      }
    }
    return rgb;
  }

  /// Perzentil-Berechnung für ein Array von Werten.
  static double percentile(List<int> values, double p) {
    if (values.isEmpty) return 0.0;
    final sorted = List<int>.from(values)..sort();
    final idx = ((p / 100.0) * (sorted.length - 1)).round();
    return sorted[idx.clamp(0, sorted.length - 1)].toDouble();
  }

  /// Contrast Stretching: dehnt Histogramm auf 0-255.
  static img.Image stretchContrast(img.Image gray) {
    // Sammle alle Grauwerte
    final values = <int>[];
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        values.add(gray.getPixel(x, y).r.toInt());
      }
    }

    final lo = percentile(values, 1.0);
    final hi = percentile(values, 99.0);
    if (hi <= lo + 1) return gray;

    final result = img.Image(width: gray.width, height: gray.height);
    final range = hi - lo;

    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final val = gray.getPixel(x, y).r.toInt();
        final stretched = ((val - lo) * 255.0 / range).clamp(0, 255).toInt();
        result.setPixelRgb(x, y, stretched, stretched, stretched);
      }
    }

    return result;
  }

  /// Background Normalization: entfernt ungleichmäßige Beleuchtung.
  static img.Image bgNormalize(img.Image gray) {
    // Berechne Sigma basierend auf Bildgröße
    final sigma = math.max(7, (math.min(gray.width, gray.height) / 3).round());

    // Gauss-Blur für Hintergrund-Schätzung
    // gaussianBlur mutates its input; keep the original ink for normalization.
    final bg = img.gaussianBlur(img.Image.from(gray), radius: sigma);

    // Division: gray / max(bg, 8) * 235
    final result = img.Image(width: gray.width, height: gray.height);
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final grayVal = gray.getPixel(x, y).r.toInt();
        final bgVal = math.max(bg.getPixel(x, y).r.toInt(), 8);
        final norm = (grayVal / bgVal * 235).clamp(0, 255).toInt();
        result.setPixelRgb(x, y, norm, norm, norm);
      }
    }

    return stretchContrast(result);
  }

  /// Same as [otsuThreshold], computed from a histogram of [total] gray
  /// values.
  static int otsuOfHistogram(Int32List hist, int total) =>
      _FastPreprocessor._otsu(hist, total);

  /// Berechnet Otsu-Threshold für ein Graustufenbild.
  static int otsuThreshold(img.Image gray) {
    // Histogramm erstellen
    final hist = List<int>.filled(256, 0);
    final total = gray.width * gray.height;

    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final val = gray.getPixel(x, y).r.toInt();
        hist[val]++;
      }
    }

    // Otsu's Methode: maximiere Between-Class Variance
    double sum = 0;
    for (int i = 0; i < 256; i++) {
      sum += i * hist[i];
    }

    double sumB = 0;
    int wB = 0;
    double maxVar = 0;
    int threshold = 0;

    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;

      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final varBetween = wB * wF * (mB - mF) * (mB - mF);

      if (varBetween > maxVar) {
        maxVar = varBetween;
        threshold = t;
      }
    }

    return threshold;
  }

  /// Foreground-Maske: erkennt Vordergrund (Text).
  static List<List<bool>> foregroundMask(img.Image gray) {
    final h = gray.height;
    final w = gray.width;

    if (h < 3 || w < 3) {
      return List.generate(h, (_) => List.filled(w, true));
    }

    // Median der Randpixel als Hintergrund-Schätzung
    final border = <int>[];
    for (int x = 0; x < w; x++) {
      border.add(gray.getPixel(x, 0).r.toInt());
      border.add(gray.getPixel(x, h - 1).r.toInt());
    }
    for (int y = 1; y < h - 1; y++) {
      border.add(gray.getPixel(0, y).r.toInt());
      border.add(gray.getPixel(w - 1, y).r.toInt());
    }
    border.sort();
    final bg = border[border.length ~/ 2].toDouble();

    // Otsu-Threshold
    final blur = img.gaussianBlur(gray, radius: 1);
    final otsu = otsuThreshold(blur);

    // Maske erstellen
    final mask = List.generate(h, (_) => List.filled(w, false));

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final val = gray.getPixel(x, y).r.toInt();
        if (bg >= 128) {
          mask[y][x] = (val < bg - 12) || (val < otsu);
        } else {
          mask[y][x] = (val > bg + 12) || (val > otsu);
        }
      }
    }

    // Morphologisches Opening (vereinfacht)
    return _morphOpen(mask, 2);
  }

  /// Vereinfachtes morphologisches Opening.
  static List<List<bool>> _morphOpen(List<List<bool>> mask, int kernelSize) {
    final h = mask.length;
    if (h == 0) return mask;
    final w = mask[0].length;
    final pad = kernelSize ~/ 2;

    // Erosion
    final eroded = List.generate(h, (_) => List.filled(w, false));
    for (int y = pad; y < h - pad; y++) {
      for (int x = pad; x < w - pad; x++) {
        bool allTrue = true;
        outer:
        for (int ky = -pad; ky <= pad; ky++) {
          for (int kx = -pad; kx <= pad; kx++) {
            if (!mask[y + ky][x + kx]) {
              allTrue = false;
              break outer;
            }
          }
        }
        eroded[y][x] = allTrue;
      }
    }

    // Dilation
    final opened = List.generate(h, (_) => List.filled(w, false));
    for (int y = pad; y < h - pad; y++) {
      for (int x = pad; x < w - pad; x++) {
        outer:
        for (int ky = -pad; ky <= pad; ky++) {
          for (int kx = -pad; kx <= pad; kx++) {
            if (eroded[y + ky][x + kx]) {
              opened[y][x] = true;
              break outer;
            }
          }
        }
      }
    }

    return opened;
  }

  /// Tight Crop: schneidet das Bild auf den Vordergrund zu.
  static img.Image tightCropGray(img.Image gray, {int pad = 2}) {
    return _tightCropWithOffset(gray, pad: pad).$1;
  }

  static (img.Image, int, int) _tightCropWithOffset(img.Image gray,
      {int pad = 2}) {
    final mask = foregroundMask(gray);
    final h = gray.height;
    final w = gray.width;

    // Finde Bounding-Box des Vordergrunds
    int minX = w, maxX = 0, minY = h, maxY = 0;
    int count = 0;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (mask[y][x]) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          count++;
        }
      }
    }

    if (count < 5) return (gray, 0, 0);

    // Padding hinzufügen
    final x1 = math.max(0, minX - pad);
    final x2 = math.min(w, maxX + 1 + pad);
    final y1 = math.max(0, minY - pad);
    final y2 = math.min(h, maxY + 1 + pad);

    return (
      img.copyCrop(gray, x: x1, y: y1, width: x2 - x1, height: y2 - y1),
      x1,
      y1
    );
  }

  /// Fügt weißen Rand hinzu.
  static img.Image addWhitePad(img.Image gray, {int padX = 2, int padY = 2}) {
    final newW = gray.width + 2 * padX;
    final newH = gray.height + 2 * padY;
    final result = img.Image(width: newW, height: newH);

    // Mit Weiß füllen
    for (int y = 0; y < newH; y++) {
      for (int x = 0; x < newW; x++) {
        result.setPixelRgb(x, y, 255, 255, 255);
      }
    }

    // Original kopieren
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final pixel = gray.getPixel(x, y);
        result.setPixel(padX + x, padY + y, pixel);
      }
    }

    return result;
  }

  /// Haupt-Preprocessing-Pipeline für das Zeichenmodell.
  /// Entspricht preprocess_bg_norm_tight_pad2 aus Python.
  static img.Image preprocessForSegmentation(img.Image image) {
    return preprocessWithOffset(image).$1;
  }

  /// Offsets map processed coordinates back onto the unmodified word crop.
  ///
  /// Uses a typed-array implementation for 8-bit RGB(A) images (camera JPEGs
  /// and PNGs). It produces bit-identical output to
  /// [preprocessWithOffsetReference] but avoids per-pixel object access,
  /// which dominated the per-word processing time on devices.
  static (img.Image, int, int) preprocessWithOffset(img.Image image) {
    if (_FastPreprocessor.supports(image)) {
      return _FastPreprocessor.preprocessWithOffset(image);
    }
    return preprocessWithOffsetReference(image);
  }

  /// Reference pipeline built on `package:image` pixel access.
  ///
  /// Used for image formats the fast path does not cover, and by tests to
  /// verify that the fast path returns the same pixels.
  static (img.Image, int, int) preprocessWithOffsetReference(img.Image image) {
    // 1. Zu Graustufen konvertieren
    final gray = asGray(image);

    // 2. Background-Normalisierung
    final norm = bgNormalize(gray);

    // 3. Tight Crop mit Padding
    final (cropped, offsetX, offsetY) = _tightCropWithOffset(norm, pad: 2);

    // 4. Weißen Rand hinzufügen
    final padded = addWhitePad(cropped, padX: 2, padY: 2);

    // 5. Zurück zu RGB konvertieren
    return (asRgb(padded), offsetX - 2, offsetY - 2);
  }
}

/// Single-channel re-implementation of [ImagePreprocessor] for 8-bit images.
///
/// Every step mirrors the reference pipeline, including the rounding rules of
/// `package:image` (truncating `toInt`, 8-bit storage between blur passes,
/// clamped edge reflection) and the in-place radius-1 blur that
/// `foregroundMask` applies to the image that is later cropped.
final class _FastPreprocessor {
  static bool supports(img.Image image) =>
      image.format == img.Format.uint8 &&
      !image.hasPalette &&
      (image.numChannels == 3 || image.numChannels == 4) &&
      image.width > 0 &&
      image.height > 0;

  static (img.Image, int, int) preprocessWithOffset(img.Image image) {
    final w = image.width;
    final h = image.height;
    final n = w * h;
    final channels = image.numChannels;
    final src = image.toUint8List();

    // 1. Grayscale (img.grayscale: luminance, clamped and truncated).
    final gray = Uint8List(n);
    for (var i = 0, s = 0; i < n; i++, s += channels) {
      final l = 0.299 * src[s] + 0.587 * src[s + 1] + 0.114 * src[s + 2];
      gray[i] = l.clamp(0, 255).toInt();
    }

    // 2. Background normalization.
    final sigma = math.max(7, (math.min(w, h) / 3).round());
    final background = _gaussianBlur(gray, w, h, sigma);
    final norm = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final bgVal = math.max(background[i], 8);
      norm[i] = (gray[i] / bgVal * 235).clamp(0, 255).toInt();
    }

    // Contrast stretching between the 1st and 99th percentile.
    final hist = _histogram(norm);
    final lo = _percentile(hist, n, 1.0);
    final hi = _percentile(hist, n, 99.0);
    var stretched = norm;
    if (hi > lo + 1) {
      final range = hi - lo;
      stretched = Uint8List(n);
      for (var i = 0; i < n; i++) {
        stretched[i] = ((norm[i] - lo) * 255.0 / range).clamp(0, 255).toInt();
      }
    }

    // 3. Foreground mask. The reference blurs the image in place here, so the
    // blurred pixels are also what gets cropped below.
    final (mask, maskedImage) = _foregroundMask(stretched, w, h);

    // Tight crop with padding 2.
    var minX = w, maxX = 0, minY = h, maxY = 0, count = 0;
    for (var y = 0, i = 0; y < h; y++) {
      for (var x = 0; x < w; x++, i++) {
        if (mask[i] != 0) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          count++;
        }
      }
    }
    var x1 = 0, y1 = 0, x2 = w, y2 = h;
    if (count >= 5) {
      x1 = math.max(0, minX - 2);
      x2 = math.min(w, maxX + 1 + 2);
      y1 = math.max(0, minY - 2);
      y2 = math.min(h, maxY + 1 + 2);
    }

    // 4. White padding of 2 pixels, expanded to RGB.
    const pad = 2;
    final cropW = x2 - x1;
    final cropH = y2 - y1;
    final outW = cropW + 2 * pad;
    final outH = cropH + 2 * pad;
    final out = Uint8List(outW * outH * 3)..fillRange(0, outW * outH * 3, 255);
    for (var y = 0; y < cropH; y++) {
      var o = ((y + pad) * outW + pad) * 3;
      var s = (y + y1) * w + x1;
      for (var x = 0; x < cropW; x++, s++) {
        final v = maskedImage[s];
        out[o++] = v;
        out[o++] = v;
        out[o++] = v;
      }
    }

    return (
      img.Image.fromBytes(
          width: outW, height: outH, bytes: out.buffer, numChannels: 3),
      x1 - pad,
      y1 - pad,
    );
  }

  /// Returns the opened foreground mask and the image the mask was computed
  /// on (blurred with radius 1 unless the image is smaller than 3x3).
  static (Uint8List, Uint8List) _foregroundMask(Uint8List gray, int w, int h) {
    final n = w * h;
    if (h < 3 || w < 3) {
      return (Uint8List(n)..fillRange(0, n, 1), gray);
    }

    // Median of the border pixels as background estimate.
    final borderHist = Int32List(256);
    for (var x = 0; x < w; x++) {
      borderHist[gray[x]]++;
      borderHist[gray[(h - 1) * w + x]]++;
    }
    for (var y = 1; y < h - 1; y++) {
      borderHist[gray[y * w]]++;
      borderHist[gray[y * w + w - 1]]++;
    }
    final borderCount = 2 * w + 2 * (h - 2);
    final bg = _valueAtSortedIndex(borderHist, borderCount ~/ 2).toDouble();

    final blurred = _gaussianBlur(gray, w, h, 1);
    final otsu = _otsu(_histogram(blurred), n);

    final raw = Uint8List(n);
    if (bg >= 128) {
      for (var i = 0; i < n; i++) {
        final val = blurred[i];
        raw[i] = (val < bg - 12) || (val < otsu) ? 1 : 0;
      }
    } else {
      for (var i = 0; i < n; i++) {
        final val = blurred[i];
        raw[i] = (val > bg + 12) || (val > otsu) ? 1 : 0;
      }
    }
    return (_morphOpen3x3(raw, w, h), blurred);
  }

  /// Matches ImagePreprocessor._morphOpen with kernelSize 2 (3x3, interior).
  static Uint8List _morphOpen3x3(Uint8List mask, int w, int h) {
    final eroded = Uint8List(w * h);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        eroded[i] = mask[i - w - 1] &
            mask[i - w] &
            mask[i - w + 1] &
            mask[i - 1] &
            mask[i] &
            mask[i + 1] &
            mask[i + w - 1] &
            mask[i + w] &
            mask[i + w + 1];
      }
    }
    final opened = Uint8List(w * h);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        opened[i] = eroded[i - w - 1] |
            eroded[i - w] |
            eroded[i - w + 1] |
            eroded[i - 1] |
            eroded[i] |
            eroded[i + 1] |
            eroded[i + w - 1] |
            eroded[i + w] |
            eroded[i + w + 1];
      }
    }
    return opened;
  }

  static final Map<int, Float64List> _kernelCache = {};

  /// Same coefficients as `img.gaussianBlur`.
  static Float64List _kernel(int radius) {
    return _kernelCache.putIfAbsent(radius, () {
      final num sigma = radius * (2.0 / 3.0);
      final num s = 2.0 * sigma * sigma;
      final coefficients = List<num>.filled(2 * radius + 1, 0);
      num sum = 0.0;
      for (var x = -radius; x <= radius; ++x) {
        final num c = math.exp(-(x * x) / s);
        sum += c;
        coefficients[x + radius] = c;
      }
      final scale = 1.0 / sum;
      return Float64List.fromList(
          [for (final c in coefficients) (c * scale).toDouble()]);
    });
  }

  /// Same as `reflectIndex` in package:image 4.12.
  static int _reflect(int max, int x) {
    if (x < 0) x = -x;
    if (x >= max) x = max - (x - max) - 1;
    return x < 0 ? 0 : (x >= max ? max - 1 : x);
  }

  /// Separable gaussian blur of a single 8-bit channel, matching
  /// `img.gaussianBlur` (horizontal pass into an 8-bit buffer, then vertical).
  static Uint8List _gaussianBlur(Uint8List src, int w, int h, int radius) {
    // package:image leaves single-row and single-column images unchanged.
    if (w < 2 || h < 2) return Uint8List.fromList(src);
    final k = _kernel(radius);
    final size = 2 * radius + 1;

    // Horizontal pass. Each row is copied into a buffer extended by the
    // reflected edge pixels, so the inner loop needs no index mapping. Every
    // output still sums k[0] * v[0] + k[1] * v[1] + ... in the same order.
    final tmp = Float64List(w * h);
    final padded = Float64List(w + 2 * radius);
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var i = 0; i < padded.length; i++) {
        padded[i] = src[row + _reflect(w, i - radius)].toDouble();
      }
      for (var x = 0; x < w; x++) {
        var acc = 0.0;
        for (var j = 0; j < size; j++) {
          acc += k[j] * padded[x + j];
        }
        // Stored as 8 bits between the passes, like the reference.
        tmp[row + x] = (acc.toInt() & 0xFF).toDouble();
      }
    }

    // Vertical pass, row by row (cache friendly). For each pixel the taps
    // are still accumulated in ascending order, so results are identical.
    final dst = Uint8List(w * h);
    final acc = Float64List(w);
    for (var y = 0; y < h; y++) {
      acc.fillRange(0, w, 0.0);
      for (var j = 0; j < size; j++) {
        final base = _reflect(h, y + j - radius) * w;
        final kj = k[j];
        for (var x = 0; x < w; x++) {
          acc[x] += kj * tmp[base + x];
        }
      }
      final row = y * w;
      for (var x = 0; x < w; x++) {
        dst[row + x] = acc[x].toInt();
      }
    }
    return dst;
  }

  static Int32List _histogram(Uint8List values) {
    final hist = Int32List(256);
    for (final v in values) {
      hist[v]++;
    }
    return hist;
  }

  /// Value at position [index] of the sorted values described by [hist].
  static int _valueAtSortedIndex(Int32List hist, int index) {
    var cumulative = 0;
    for (var v = 0; v < 256; v++) {
      cumulative += hist[v];
      if (cumulative > index) return v;
    }
    return 255;
  }

  /// Same as ImagePreprocessor.percentile, computed from a histogram.
  static double _percentile(Int32List hist, int count, double p) {
    final idx = ((p / 100.0) * (count - 1)).round().clamp(0, count - 1);
    return _valueAtSortedIndex(hist, idx).toDouble();
  }

  /// Same as ImagePreprocessor.otsuThreshold, computed from a histogram.
  static int _otsu(Int32List hist, int total) {
    double sum = 0;
    for (int i = 0; i < 256; i++) {
      sum += i * hist[i];
    }
    double sumB = 0;
    int wB = 0;
    double maxVar = 0;
    int threshold = 0;
    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final varBetween = wB * wF * (mB - mF) * (mB - mF);
      if (varBetween > maxVar) {
        maxVar = varBetween;
        threshold = t;
      }
    }
    return threshold;
  }
}
