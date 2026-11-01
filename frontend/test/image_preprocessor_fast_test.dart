import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:groundink/services/image_preprocessor.dart';

/// Asserts that the fast preprocessing path is bit-identical to the
/// reference implementation (the reference mutates its input, so each path
/// gets its own copy).
void expectSameAsReference(img.Image crop, String label) {
  final (fast, fastX, fastY) =
      ImagePreprocessor.preprocessWithOffset(img.Image.from(crop));
  final (ref, refX, refY) =
      ImagePreprocessor.preprocessWithOffsetReference(img.Image.from(crop));
  expect((fastX, fastY), (refX, refY), reason: '$label offset');
  expect((fast.width, fast.height), (ref.width, ref.height),
      reason: '$label size');
  expect(fast.numChannels, ref.numChannels, reason: '$label channels');
  final a = fast.getBytes(order: img.ChannelOrder.rgb);
  final b = ref.getBytes(order: img.ChannelOrder.rgb);
  var mismatches = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) mismatches++;
  }
  expect(mismatches, 0, reason: '$label pixels');
}

void main() {
  final sample = img.decodeJpg(
      File('test/fixtures/handwriting_sample.jpg').readAsBytesSync())!;

  test('fast preprocessing matches reference on handwriting crops', () {
    final rnd = math.Random(42);
    for (final scale in [0.5, 1.0, 2.0]) {
      final page = scale == 1.0
          ? sample
          : img.copyResize(sample,
              width: (sample.width * scale).round(),
              interpolation: img.Interpolation.linear);
      for (var i = 0; i < 12; i++) {
        final w = 8 + rnd.nextInt(math.min(page.width - 8, 450));
        final h = 6 + rnd.nextInt(math.min(page.height - 6, 160));
        final x = rnd.nextInt(page.width - w + 1);
        final y = rnd.nextInt(page.height - h + 1);
        expectSameAsReference(
            img.copyCrop(page, x: x, y: y, width: w, height: h),
            'scale $scale crop $x,$y ${w}x$h');
      }
    }
  });

  test('fast preprocessing matches reference on edge cases', () {
    final white = img.Image(width: 60, height: 20);
    img.fill(white, color: img.ColorRgb8(250, 250, 250));
    expectSameAsReference(white, 'uniform');

    final noise = img.Image(width: 37, height: 23);
    final rnd = math.Random(7);
    for (final p in noise) {
      p.setRgb(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256));
    }
    expectSameAsReference(noise, 'noise');

    for (final (w, h) in [(1, 1), (2, 2), (2, 9), (9, 2), (3, 3), (4, 30)]) {
      expectSameAsReference(
          img.copyCrop(sample, x: 40, y: 50, width: w, height: h), '${w}x$h');
    }

    final rgba = sample.convert(numChannels: 4);
    expectSameAsReference(
        img.copyCrop(rgba, x: 20, y: 30, width: 220, height: 90), 'rgba');
  });
}
