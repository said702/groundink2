import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:groundink/services/image_preprocessor.dart';
import 'package:groundink/services/onnx_inference.dart';

void expectSameLetterbox(img.Image source, int size) {
  final (fast, fs, fl, ft) = OnnxInference.letterbox(source, size);
  final (ref, rs, rl, rt) = OnnxInference.letterboxReference(source, size);
  expect((fs, fl, ft), (rs, rl, rt));
  expect(fast.width, ref.width);
  expect(fast.height, ref.height);
  expect(OnnxInference.toNchwFloat(fast, size),
      OnnxInference.toNchwFloat(ref, size));
}

img.Image randomImage(int w, int h, int channels, math.Random rng,
    {bool opaque = true}) {
  final image = img.Image(width: w, height: h, numChannels: channels);
  for (final p in image) {
    p
      ..r = rng.nextInt(256)
      ..g = rng.nextInt(256)
      ..b = rng.nextInt(256);
    if (channels == 4) p.a = opaque ? 255 : rng.nextInt(256);
  }
  return image;
}

void main() {
  test('letterbox matches the reference on the handwriting fixture', () {
    final photo = img.decodeImage(
        File('test/fixtures/handwriting_sample.jpg').readAsBytesSync())!;
    expectSameLetterbox(photo, 640);
    final crop = img.copyCrop(photo,
        x: photo.width ~/ 4, y: photo.height ~/ 4, width: 300, height: 90);
    expectSameLetterbox(crop, 256);
    expectSameLetterbox(ImagePreprocessor.preprocessWithOffset(crop).$1, 256);
  });

  test('letterbox matches the reference for RGB and RGBA images', () {
    final rng = math.Random(7);
    for (final (w, h) in [(300, 90), (90, 300), (256, 256), (17, 5), (1, 1)]) {
      expectSameLetterbox(randomImage(w, h, 3, rng), 256);
      expectSameLetterbox(randomImage(w, h, 4, rng), 256);
      expectSameLetterbox(randomImage(w, h, 4, rng, opaque: false), 256);
    }
    expectSameLetterbox(randomImage(1448, 1086, 4, rng), 640);
  });
}
