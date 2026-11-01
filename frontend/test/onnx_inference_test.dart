import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:groundink/services/onnx_inference.dart';

/// Reference implementation of the original (slow) spell check, used to make
/// sure the optimized version returns exactly the same suggestions.
(bool, List<String>) referenceCheckWord(String word, List<String> words) {
  word = word.trim();
  if (word.isEmpty) return (true, []);
  final lower = word.toLowerCase();
  final wordSet = words.toSet();
  if (wordSet.contains(lower)) return (true, []);
  final suggestions = <MapEntry<String, int>>[];
  for (final dictWord in wordSet) {
    if ((dictWord.length - lower.length).abs() > 2) continue;
    final dist = referenceLevenshtein(lower, dictWord);
    if (dist <= 2) suggestions.add(MapEntry(dictWord, dist));
  }
  suggestions.sort((a, b) => a.value.compareTo(b.value));
  return (false, suggestions.take(5).map((e) => e.key).toList());
}

int referenceLevenshtein(String s1, String s2) {
  if (s1 == s2) return 0;
  if (s1.isEmpty) return s2.length;
  if (s2.isEmpty) return s1.length;
  final matrix =
      List.generate(s1.length + 1, (i) => List.filled(s2.length + 1, 0));
  for (int i = 0; i <= s1.length; i++) {
    matrix[i][0] = i;
  }
  for (int j = 0; j <= s2.length; j++) {
    matrix[0][j] = j;
  }
  for (int i = 1; i <= s1.length; i++) {
    for (int j = 1; j <= s2.length; j++) {
      final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
      matrix[i][j] = [
        matrix[i - 1][j] + 1,
        matrix[i][j - 1] + 1,
        matrix[i - 1][j - 1] + cost,
      ].reduce((a, b) => a < b ? a : b);
    }
  }
  return matrix[s1.length][s2.length];
}

void main() {
  test('checkWord accepts dictionary words and suggests close matches', () {
    const dictionary = ['house', 'horse', 'mouse', 'hose', 'apple'];
    expect(OnnxInference.checkWord('House', dictionary: dictionary).$1, isTrue);

    final (ok, suggestions) =
        OnnxInference.checkWord('hosue', dictionary: dictionary);
    expect(ok, isFalse);
    expect(suggestions, containsAll(['house', 'hose', 'horse']));
    expect(suggestions, isNot(contains('apple')));
  });

  test('optimized checkWord matches the original implementation', () {
    final dictionary =
        (jsonDecode(File('assets/models/english_words.json').readAsStringSync())
                as List<dynamic>)
            .cast<String>();
    const samples = [
      'teh',
      'recieve',
      'speling',
      'helo',
      'wrold',
      'Thsi',
      'beutiful',
      'qwzx',
      'a',
      'handwritting',
      'definately',
      'cat',
    ];
    for (final word in samples) {
      final (ok, suggestions) =
          OnnxInference.checkWord(word, dictionary: dictionary);
      final (expectedOk, expectedSuggestions) =
          referenceCheckWord(word, dictionary);
      expect(ok, expectedOk, reason: word);
      expect(suggestions, orderedEquals(expectedSuggestions), reason: word);
    }
  });

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
