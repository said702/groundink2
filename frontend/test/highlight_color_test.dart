import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:groundink/services/character_ink.dart';
import 'package:groundink/services/ink_color.dart';
import 'package:groundink/theme/highlight_colors.dart';

/// A "photo" of two strokes in [ink] on [paper], with anti-aliased edges
/// (stroke edges blend ink and paper like in a real photo).
(img.Image, List<List<int>>, List<int>) photo(
    img.ColorRgb8 ink, img.ColorRgb8 paper) {
  final image = img.Image(width: 60, height: 30);
  img.fill(image, color: paper);
  img.ColorRgb8 mix(double t) => img.ColorRgb8(
        (ink.r * t + paper.r * (1 - t)).round(),
        (ink.g * t + paper.g * (1 - t)).round(),
        (ink.b * t + paper.b * (1 - t)).round(),
      );
  for (final x in [12, 36]) {
    img.fillRect(image, x1: x - 1, y1: 6, x2: x - 1, y2: 24, color: mix(0.4));
    img.fillRect(image, x1: x, y1: 6, x2: x + 3, y2: 24, color: ink);
    img.fillRect(image, x1: x + 4, y1: 6, x2: x + 4, y2: 24, color: mix(0.4));
  }
  final bbox = [4, 2, 56, 28];
  return (image, CharacterInk.extractAll(image, [bbox]).single, bbox);
}

void main() {
  final white = img.ColorRgb8(245, 245, 240);

  test('red ink is measured as red and highlighted in blue', () {
    final (image, runs, bbox) = photo(img.ColorRgb8(200, 35, 40), white);
    final ink = InkColor.measure(image, runs, bbox)!;
    expect((ink >> 16) & 0xFF, greaterThan(150));
    expect((ink >> 8) & 0xFF, lessThan(90));
    expect(HighlightColors.forInk(ink), HighlightColors.blue);
  });

  test('pink and orange pens are highlighted in blue', () {
    for (final pen in [
      img.ColorRgb8(230, 80, 150), // pink
      img.ColorRgb8(240, 120, 20), // orange
      img.ColorRgb8(150, 40, 40), // dark red
    ]) {
      final (image, runs, bbox) = photo(pen, white);
      expect(HighlightColors.forInk(InkColor.measure(image, runs, bbox)),
          HighlightColors.blue,
          reason: '$pen');
    }
  });

  test('black, blue, green pens and pencil keep the red highlight', () {
    for (final pen in [
      img.ColorRgb8(25, 25, 30), // black
      img.ColorRgb8(30, 55, 160), // blue ballpoint
      img.ColorRgb8(20, 120, 50), // green
      img.ColorRgb8(105, 105, 110), // pencil
      img.ColorRgb8(90, 50, 160), // violet
    ]) {
      final (image, runs, bbox) = photo(pen, white);
      expect(HighlightColors.forInk(InkColor.measure(image, runs, bbox)),
          HighlightColors.red,
          reason: '$pen');
    }
  });

  test('warm light does not make black ink look red', () {
    // Black ink photographed under yellowish light on yellowish paper.
    final (image, runs, bbox) =
        photo(img.ColorRgb8(70, 50, 30), img.ColorRgb8(235, 210, 160));
    expect(HighlightColors.forInk(InkColor.measure(image, runs, bbox)),
        HighlightColors.red);
  });

  test('without ink or a measurement the default red is used', () {
    final image = img.Image(width: 10, height: 10);
    expect(InkColor.measure(image, const [], const [0, 0, 10, 10]), isNull);
    expect(HighlightColors.forInk(null), HighlightColors.red);
  });
}
