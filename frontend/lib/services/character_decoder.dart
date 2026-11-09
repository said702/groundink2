import 'dart:math' as math;

/// A character the recognizer detected in a word crop.
class CharDetection {
  final int x1, y1, x2, y2;
  final double confidence;
  final int classIndex;

  const CharDetection(
      this.x1, this.y1, this.x2, this.y2, this.confidence, this.classIndex);

  double get width => math.max(1e-6, (x2 - x1).toDouble());
  double get height => math.max(1e-6, (y2 - y1).toDouble());
  double get centerX => (x1 + x2) / 2;
}

/// Turns the raw detections of the character model into the characters of a
/// word, left to right.
///
/// Keeps the confident detections, adds weaker ones at places where no
/// confident one is (thin letters like "i" and "r" are often detected with
/// low confidence) if their height fits the word, and removes overlapping
/// duplicates. Compared with a single confidence cut-off of 0.4 this lowers
/// the character error rate on IAM, CVL, GoBo and Merlin word crops from
/// 21.0% to 20.3% (see tool/evaluate_char_recognition.py).
class CharacterDecoder {
  /// Detections at least this confident are always kept.
  static const high = 0.4;

  /// Weaker detections down to this confidence fill gaps.
  static const low = 0.25;

  /// Overlap (IoU) above which the less confident detection is dropped.
  static const nmsIou = 0.3;

  static const maxCharacters = 40;

  static List<CharDetection> decode(List<CharDetection> detections) {
    final strong = [
      for (final d in detections)
        if (d.confidence >= high) d
    ];
    final List<CharDetection> selected;
    if (strong.isEmpty) {
      selected = [
        for (final d in detections)
          if (d.confidence >= low) d
      ];
    } else {
      final medianHeight = _median([for (final d in strong) d.height]);
      selected = [...strong];
      final weak = [
        for (final d in detections)
          if (d.confidence >= low && d.confidence < high) d
      ];
      for (final d in _byConfidence(weak)) {
        final near =
            strong.any((s) => _overlapX(d, s) > 0.15 || iou(d, s) > 0.08);
        final plausible =
            d.height >= 0.35 * medianHeight && d.height <= 2.8 * medianHeight;
        if (!near && plausible) selected.add(d);
      }
    }

    final kept = <CharDetection>[];
    for (final d in _byConfidence(selected)) {
      if (kept.length >= maxCharacters) break;
      if (kept.every((k) => iou(d, k) <= nmsIou)) kept.add(d);
    }
    final indexed = [for (var i = 0; i < kept.length; i++) (i, kept[i])];
    indexed.sort((a, b) {
      final byX = a.$2.x1.compareTo(b.$2.x1);
      if (byX != 0) return byX;
      final byCenter = a.$2.centerX.compareTo(b.$2.centerX);
      return byCenter != 0 ? byCenter : a.$1.compareTo(b.$1);
    });
    return [for (final (_, d) in indexed) d];
  }

  /// Most confident first; equal confidences keep their order.
  static List<CharDetection> _byConfidence(List<CharDetection> detections) {
    final indexed = [
      for (var i = 0; i < detections.length; i++) (i, detections[i])
    ];
    indexed.sort((a, b) {
      final byConfidence = b.$2.confidence.compareTo(a.$2.confidence);
      return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
    });
    return [for (final (_, d) in indexed) d];
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double iou(CharDetection a, CharDetection b) {
    final iw = math.min(a.x2, b.x2) - math.max(a.x1, b.x1);
    final ih = math.min(a.y2, b.y2) - math.max(a.y1, b.y1);
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    final union =
        (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter;
    return union > 0 ? inter / union : 0;
  }

  /// Horizontal overlap relative to the narrower detection.
  static double _overlapX(CharDetection a, CharDetection b) {
    final inter = math.min(a.x2, b.x2) - math.max(a.x1, b.x1);
    if (inter <= 0) return 0;
    return inter / math.max(1e-6, math.min(a.width, b.width));
  }
}
