import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:groundink/services/character_ink.dart';
import 'package:groundink/services/image_preprocessor.dart';

/// White paper with black rectangles (inclusive corners).
img.Image page(int width, int height, List<List<int>> strokes,
    {int ink = 0}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (final s in strokes) {
    img.fillRect(image,
        x1: s[0], y1: s[1], x2: s[2], y2: s[3],
        color: img.ColorRgb8(ink, ink, ink));
  }
  return image;
}

/// The pixels of runs, as "x,y".
Set<String> pixels(List<List<int>> runs) => {
      for (final r in runs)
        for (var x = r[0]; x < r[0] + r[2]; x++) '$x,${r[1]}',
    };

/// The pixels of a rectangle (inclusive corners).
Set<String> rect(int x1, int y1, int x2, int y2) => {
      for (var y = y1; y <= y2; y++)
        for (var x = x1; x <= x2; x++) '$x,$y',
    };

void main() {
  test('ink extraction excludes paper and glyphs outside the box', () {
    final image = page(30, 20, [
      [5, 5, 7, 14],
      [20, 5, 22, 14],
    ]);
    final runs = CharacterInk.extractAll(image, [
      [2, 2, 12, 18],
      [12, 0, 18, 20],
      [40, 0, 50, 20],
    ]);
    expect(runs[0], hasLength(10));
    for (final run in runs[0]) {
      expect(run[0], 5);
      expect(run[2], 3);
      expect(run[1], inInclusiveRange(5, 14));
    }
    expect(runs[1], isEmpty);
    expect(runs[2], isEmpty);
  });

  test("a neighbor's stroke inside an overlapping box stays the neighbor's",
      () {
    // Two letters; the first box reaches over the left part of the second
    // letter, like the box of a wide "f" over the "o" next to it.
    final image = page(40, 24, [
      [4, 4, 8, 19],
      [16, 4, 20, 19],
      [20, 17, 27, 19],
    ]);
    final runs = CharacterInk.extractAll(image, [
      [2, 2, 19, 22],
      [14, 2, 30, 22],
    ]);
    expect(pixels(runs[0]), rect(4, 4, 8, 19));
    expect(pixels(runs[1]), rect(16, 4, 20, 19).union(rect(20, 17, 27, 19)));
  });

  test('touching letters part at the lightest point of the connection', () {
    // Two strokes joined by a lighter bridge; both boxes cover the bridge.
    final image = page(40, 20, [
      [4, 4, 9, 15],
      [26, 4, 31, 15],
    ]);
    img.fillRect(image,
        x1: 10, y1: 9, x2: 25, y2: 10, color: img.ColorRgb8(60, 60, 60));
    img.fillRect(image,
        x1: 21, y1: 9, x2: 22, y2: 10, color: img.ColorRgb8(110, 110, 110));
    final runs = CharacterInk.extractAll(image, [
      [2, 2, 24, 18],
      [12, 2, 34, 18],
    ]);
    // Each letter keeps its side of the bridge up to the lighter part at
    // x 21..22 (the middle of the overlap would be at x 17..18).
    final a = pixels(runs[0]), b = pixels(runs[1]);
    expect(a.intersection(b), isEmpty);
    expect(a, containsAll(rect(4, 4, 9, 15).union(rect(10, 9, 20, 10))));
    expect(b, containsAll(rect(26, 4, 31, 15).union(rect(23, 9, 25, 10))));
    expect(
        a.union(b),
        rect(4, 4, 9, 15)
            .union(rect(26, 4, 31, 15))
            .union(rect(10, 9, 25, 10)));
  });

  test('a letter whose box lies inside a bigger box keeps its own ink', () {
    final image = page(40, 24, [
      [4, 4, 6, 19],
      [28, 10, 31, 13],
    ]);
    final runs = CharacterInk.extractAll(image, [
      [2, 2, 38, 22],
      [24, 6, 36, 18],
    ]);
    expect(pixels(runs[0]), rect(4, 4, 6, 19));
    expect(pixels(runs[1]), rect(28, 10, 31, 13));
  });

  test('a loose dot goes to the box it lies most central in', () {
    // An "i" next to a wide letter; the dot lies in both boxes.
    final image = page(40, 30, [
      [4, 10, 20, 26],
      [24, 12, 26, 26],
      [24, 5, 26, 7],
    ], ink: 30);
    final runs = CharacterInk.extractAll(image, [
      [2, 2, 28, 28],
      [22, 3, 29, 28],
    ]);
    expect(pixels(runs[1]), rect(24, 12, 26, 26).union(rect(24, 5, 26, 7)));
    expect(pixels(runs[0]), rect(4, 10, 20, 26));
  });

  test('preprocessing offsets preserve original glyph coordinates', () {
    final source = img.Image(width: 80, height: 40);
    img.fill(source, color: img.ColorRgb8(240, 240, 240));
    img.fillRect(source,
        x1: 25, y1: 10, x2: 30, y2: 30, color: img.ColorRgb8(10, 10, 10));
    final (processed, offsetX, offsetY) =
        ImagePreprocessor.preprocessWithOffset(source);
    var count = 0;
    for (final pixel in processed) {
      if (pixel.r < 50) {
        count++;
        expect(pixel.x + offsetX, inInclusiveRange(25, 30));
        expect(pixel.y + offsetY, inInclusiveRange(10, 30));
      }
    }
    expect(count, greaterThan(0));
  });
}
