import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/services/character_decoder.dart';

const classes =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

String decodeText(List<CharDetection> detections) => [
      for (final d in CharacterDecoder.decode(detections)) classes[d.classIndex]
    ].join();

void main() {
  test('matches the evaluated decoder on real detections', () {
    // Raw detections of the character model on 100 word crops (IAM, CVL,
    // GoBo, Merlin) and the text the evaluation's decoder produced.
    final cases = jsonDecode(
            File('test/fixtures/char_decoder_golden.json').readAsStringSync())
        as List<dynamic>;
    expect(cases, hasLength(100));
    for (final c in cases) {
      final detections = [
        for (final d in c['dets'] as List<dynamic>)
          CharDetection(d[0] as int, d[1] as int, d[2] as int, d[3] as int,
              (d[4] as num).toDouble(), d[5] as int),
      ];
      expect(decodeText(detections), c['adaptive'] as String);
    }
  });

  test('keeps a weak detection in a gap but not a weak duplicate', () {
    // "h" "i"(weak, in a gap) "t"; plus a weak duplicate on top of the "t".
    final text = decodeText(const [
      CharDetection(0, 0, 10, 20, 0.9, 43), // h
      CharDetection(12, 5, 15, 20, 0.3, 44), // i
      CharDetection(18, 0, 28, 20, 0.8, 55), // t
      CharDetection(19, 1, 28, 20, 0.35, 47), // l, overlaps the t
    ]);
    expect(text, 'hit');
  });

  test('a weak detection of an implausible size is dropped', () {
    final text = decodeText(const [
      CharDetection(0, 0, 10, 20, 0.9, 36), // a
      CharDetection(12, 0, 22, 20, 0.9, 37), // b
      CharDetection(30, 8, 32, 10, 0.3, 46), // tiny speck
    ]);
    expect(text, 'ab');
  });

  test('without confident detections the weak ones are used', () {
    final text = decodeText(const [
      CharDetection(0, 0, 10, 20, 0.3, 36),
      CharDetection(12, 0, 22, 20, 0.2, 37), // below the lower bound
    ]);
    expect(text, 'a');
  });
}
