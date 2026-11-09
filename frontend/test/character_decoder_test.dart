import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('bestClass', () {
    /// Class scores of one detection.
    Float32List scores(Map<String, double> byCharacter) {
      final s = Float32List(62);
      byCharacter.forEach((ch, v) => s[classes.indexOf(ch)] = v);
      return s;
    }

    String pick(Map<String, double> byCharacter) {
      final (c, score) = CharacterDecoder.bestClass(scores(byCharacter));
      return '${classes[c]} ${score.toStringAsFixed(2)}';
    }

    test('adds up both cases of a letter that looks the same in both', () {
      // 0.2 and 0.15 are both below the lower bound, the sum is not.
      expect(pick({'s': 0.2, 'S': 0.15, 'e': 0.3}), 's 0.35');
    });

    test('gives the sum to the more likely case, lower case on a tie', () {
      expect(pick({'s': 0.1, 'S': 0.3}), 'S 0.40');
      expect(pick({'o': 0.2, 'O': 0.2, '0': 0.35}), 'o 0.40');
    });

    test('keeps the cases of other letters apart', () {
      expect(pick({'a': 0.2, 'A': 0.15}), 'a 0.20');
      expect(pick({'y': 0.2, 'Y': 0.15, 'x': 0.1, 'X': 0.08}), 'y 0.20');
    });

    test('reads one detection of the channel-first model output', () {
      // [66 channels, 3 detections]: x, y, w, h, then the class scores.
      const count = 3;
      final output = Float32List(66 * count);
      void score(int detection, String ch, double v) =>
          output[(4 + classes.indexOf(ch)) * count + detection] = v;
      score(0, 'a', 0.9);
      score(1, 'x', 0.2);
      score(1, 'X', 0.1);
      score(1, 'y', 0.25);
      score(2, 'k', 0.5);
      final (c, s) = CharacterDecoder.bestClass(output,
          offset: 4 * count + 1, stride: count);
      expect(classes[c], 'x');
      expect(s, closeTo(0.3, 1e-6));
    });
  });
}
