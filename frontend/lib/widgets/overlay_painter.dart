import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../models/word_box.dart';
import '../services/spelling_feedback.dart';
import '../theme/highlight_colors.dart';

/// A word drawn by [OverlayPainter].
class OverlayWord {
  final WordBox word;

  /// The intended word; the handwriting's differing letters are colored.
  final String? correction;

  /// Color of the suspect letters and of the underline.
  final Color color;

  /// The mistake currently reviewed: marked like with a highlighter pen,
  /// with its suspect letters recolored. Other words get a wavy underline.
  final bool selected;

  const OverlayWord({
    required this.word,
    required this.correction,
    required this.color,
    this.selected = false,
  });
}

/// Marks spelling mistakes on the photo.
///
/// The selected mistake gets a highlighter-pen background and its suspect
/// letters are drawn in [OverlayWord.color] (only the ink, so the letter
/// shapes stay visible); the other mistakes get a wavy underline.
class OverlayPainter extends CustomPainter {
  final List<OverlayWord> words;
  final Size imageSize;
  final Rect? sourceRect;

  OverlayPainter({
    required this.words,
    required this.imageSize,
    this.sourceRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;
    final crop = sourceRect ?? Offset.zero & imageSize;
    canvas.save();
    canvas.scale(size.width / crop.width, size.height / crop.height);
    canvas.translate(-crop.left, -crop.top);
    for (final w in words) {
      if (!w.selected) _underline(canvas, w);
    }
    for (final w in words) {
      if (w.selected) {
        _marker(canvas, w.word);
        _suspectInk(canvas, w);
      }
    }
    canvas.restore();
  }

  static Rect? _box(WordBox word) {
    final b = word.bbox;
    if (b.length < 4 || b[2] <= b[0] || b[3] <= b[1]) return null;
    return Rect.fromLTRB(
        b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble());
  }

  void _marker(Canvas canvas, WordBox word) {
    final box = _box(word);
    if (box == null) return;
    final h = box.height;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTRB(box.left - h * 0.14, box.top - h * 0.08,
          box.right + h * 0.14, box.bottom + h * 0.08),
      Radius.circular(h * 0.2),
    );
    canvas.drawRRect(
        rect,
        Paint()
          ..color = HighlightColors.marker.withValues(alpha: 0.45)
          ..isAntiAlias = true);
    canvas.drawRRect(
        rect,
        Paint()
          ..color = HighlightColors.markerEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.0, h * 0.045)
          ..isAntiAlias = true);
  }

  void _suspectInk(Canvas canvas, OverlayWord w) {
    final word = w.word;
    final correction = w.correction;
    if (word.isCorrect || correction == null) return;
    final changed = SpellingFeedback.changedCharacters(word.text, correction);
    final paint = Paint()
      ..color = w.color
      ..isAntiAlias = false;
    var offset = 0;
    for (final character in word.characters) {
      final suspect = List.generate(character.char.length, (i) => offset + i)
          .any(changed.contains);
      offset += character.char.length;
      if (!suspect) continue;
      for (final run in character.inkRuns) {
        canvas.drawRect(
            Rect.fromLTWH(
                run[0].toDouble(), run[1].toDouble(), run[2].toDouble(), 1),
            paint);
      }
    }
  }

  void _underline(Canvas canvas, OverlayWord w) {
    final box = _box(w.word);
    if (box == null) return;
    final h = box.height;
    final amplitude = math.max(1.5, h * 0.045);
    final wavelength = math.max(6.0, h * 0.22);
    final y = box.bottom + amplitude + h * 0.03;
    final path = Path()..moveTo(box.left, y);
    for (var x = box.left; x < box.right; x += wavelength / 2) {
      final up = ((x - box.left) / (wavelength / 2)).round().isEven;
      path.quadraticBezierTo(x + wavelength / 4, y + (up ? -2 : 2) * amplitude,
          math.min(x + wavelength / 2, box.right), y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = w.color.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, h * 0.04)
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(covariant OverlayPainter old) =>
      old.words != words ||
      old.imageSize != imageSize ||
      old.sourceRect != sourceRect;
}
