import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:groundink/services/onnx_inference.dart';

// The spell check moved to lib/services/spelling/ (see spell_checker_test.dart).
void main() {
  test('toNchwFloat matches per-pixel channel extraction', () {
    const size = 8;
    final image = img.Image(width: size, height: size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        image.setPixelRgb(x, y, x * 30, y * 30, (x * y) % 256);
      }
    }
    final expected = <double>[];
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final p = image.getPixel(x, y);
          expected.add((c == 0 ? p.r : (c == 1 ? p.g : p.b)) / 255.0);
        }
      }
    }
    final actual = OnnxInference.toNchwFloat(image, size);
    expect(actual.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      expect(actual[i], closeTo(expected[i], 1e-6), reason: 'index $i');
    }
  });
}
