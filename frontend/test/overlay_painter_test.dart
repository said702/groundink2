import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/models/word_box.dart';
import 'package:groundink/theme/highlight_colors.dart';
import 'package:groundink/widgets/overlay_painter.dart';

/// A word "cot" (suggestion "cat") at [x], whose letters each have one
/// 3-pixel ink run at height 4.
WordBox cot(int x) => WordBox(
      text: 'cot',
      bbox: [x, 2, x + 30, 8],
      confidence: 1,
      isCorrect: false,
      suggestions: ['cat'],
      characters: [
        for (var i = 0; i < 3; i++)
          CharacterResult(
              char: 'cot'[i],
              bbox: [x + i * 10, 2, x + i * 10 + 10, 8],
              contour: [],
              confidence: 1,
              inkRuns: [
                [x + i * 10 + 2, 4, 3]
              ]),
      ],
    );

/// Paints black ink for [words] on white, then the overlay; returns RGBA.
Future<(ByteData, int)> render(
    WidgetTester tester, List<WordBox> words, List<OverlayWord> overlay,
    {int width = 70, int height = 14}) async {
  late ByteData bytes;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    for (final w in words) {
      for (final c in w.characters) {
        for (final run in c.inkRuns) {
          canvas.drawRect(
              Rect.fromLTWH(
                  run[0].toDouble(), run[1].toDouble(), run[2].toDouble(), 1),
              Paint()..color = Colors.black);
        }
      }
    }
    final size = Size(width.toDouble(), height.toDouble());
    OverlayPainter(words: overlay, imageSize: size).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
    picture.dispose();
  });
  return (bytes, width);
}

int rgb(ByteData bytes, int width, int x, int y) =>
    bytes.getUint32((y * width + x) * 4) >> 8;

int rgbOf(Color c) => c.toARGB32() & 0xFFFFFF;

/// Dark ink, possibly tinted by the translucent marker.
bool isInk(int rgb) =>
    (rgb >> 16) < 0x80 && ((rgb >> 8) & 0xFF) < 0x80 && (rgb & 0xFF) < 0x80;

void main() {
  testWidgets('only the suspect letter of the selected word changes color',
      (tester) async {
    final word = cot(0);
    final (bytes, width) = await render(tester, [
      word
    ], [
      OverlayWord(
          word: word,
          correction: 'cat',
          color: HighlightColors.blue,
          selected: true),
    ]);
    // "c" and "t" keep their ink color (under the translucent marker).
    expect(isInk(rgb(bytes, width, 2, 4)), isTrue);
    expect(isInk(rgb(bytes, width, 22, 4)), isTrue);
    // The "o" is drawn in the highlight color.
    expect(rgb(bytes, width, 12, 4), rgbOf(HighlightColors.blue));
    // Paper inside the marker is tinted yellow, paper far away stays white.
    final tinted = rgb(bytes, width, 12, 6);
    expect(tinted & 0xFF, lessThan(0xF0), reason: 'blue channel reduced');
    expect(rgb(bytes, width, 60, 1), 0xFFFFFF);
  });

  testWidgets('other mistakes get an underline instead of recolored letters',
      (tester) async {
    final word = cot(0);
    final (bytes, width) = await render(tester, [
      word
    ], [
      OverlayWord(word: word, correction: 'cat', color: HighlightColors.red),
    ]);
    // The letters are untouched.
    expect(rgb(bytes, width, 12, 4), 0x000000);
    // Something reddish is drawn just below the word box.
    var underline = false;
    for (var x = 0; x < 30; x++) {
      for (var y = 8; y < 14; y++) {
        final c = rgb(bytes, width, x, y);
        if ((c >> 16) > 0xB0 && (c & 0xFF) < 0xA0) underline = true;
      }
    }
    expect(underline, isTrue);
  });

  testWidgets('correct words are not marked', (tester) async {
    final word = cot(0).copyWith(isCorrect: true, suggestions: const []);
    final (bytes, width) = await render(tester, [
      word
    ], [
      OverlayWord(
          word: word,
          correction: null,
          color: HighlightColors.red,
          selected: true),
    ]);
    expect(isInk(rgb(bytes, width, 12, 4)), isTrue);
  });
}
