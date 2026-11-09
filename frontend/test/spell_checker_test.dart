import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/models/word_box.dart';
import 'package:groundink/services/offline_detector.dart';
import 'package:groundink/services/spelling/error_model.dart';
import 'package:groundink/services/spelling/language_model.dart';
import 'package:groundink/services/spelling/spell_checker.dart';

void main() {
  late LanguageModel model;
  late SpellChecker checker;

  setUpAll(() {
    model = LanguageModel.fromGzip(
        File('assets/models/english_lm.bin.gz').readAsBytesSync());
    checker = SpellChecker(model);
  });

  List<String> words(String observed, {String? previous, String? next}) => [
        for (final s
            in checker.suggest(observed, previous: previous, next: next))
          s.word
      ];

  group('LanguageModel', () {
    test('keeps the previous word list', () {
      expect(model.length, 160572);
      for (final w in ['the', 'dog', "don't", 'mira', 'aardvark']) {
        expect(model.contains(w), isTrue, reason: w);
      }
      expect(model.contains('teh'), isFalse);
    });

    test('word frequencies order common words first', () {
      double p(String w) => model.logPrior(model.idOf(w)!);
      expect(p('the'), greaterThan(p('dog')));
      expect(p('dog'), greaterThan(p('aardvark')));
      expect(p('little'), greaterThan(p('littler')));
    });

    test('word pairs: frequent pairs positive, unusual ones negative', () {
      double a(String x, String y) =>
          model.association(model.idOf(x)!, model.idOf(y)!);
      expect(a('went', 'to'), greaterThan(1));
      expect(a('my', 'sister'), greaterThan(1));
      expect(a('the', 'of'), lessThan(-3));
      // Missing pair of rare words: no evidence either way.
      expect(a('aardvark', 'zygote'), 0);
    });

    test('profanity is never suggested but still a known word', () {
      for (final w in ['fuck', 'shit', 'bitch']) {
        final id = model.idOf(w)!;
        expect(model.isSuggestible(id), isFalse, reason: w);
        expect(checker.isCorrect(w), isTrue, reason: w);
      }
      expect(model.isSuggestible(model.idOf('duck')!), isTrue);
      expect(words('fuk'), isNot(contains('fuck')));
      expect(words('fcuk'), isNot(contains('fuck')));
      expect(words('shiit'), isNot(contains('shit')));
    });
  });

  group('ErrorModel', () {
    const em = ErrorModel();

    test('identical words cost nothing, one arbitrary edit costs 1', () {
      expect(em.cost('dog', 'dog'), 0);
      expect(em.cost('dxg', 'dog'), 1);
    });

    test('typical mistakes are cheaper than arbitrary edits', () {
      // Swapped letters (one edit) vs. two substitutions.
      expect(em.cost('teh', 'the'), lessThan(1));
      // Missing double letter, silent letters.
      expect(em.cost('litle', 'little'), lessThan(em.cost('lttle', 'little')));
      expect(em.cost('scool', 'school'), lessThan(1));
      expect(em.cost('wach', 'watch'), lessThan(1));
      // Letters the recognizer confuses.
      expect(em.cost('c0at', 'coat'), lessThan(0.5));
      expect(em.cost('rnap', 'map'), lessThan(em.cost('rnap', 'nap')));
      expect(em.cost('hcuse', 'house'), lessThan(em.cost('hzuse', 'house')));
    });

    test('uncertain letters are cheaper to replace', () {
      final sure = em.cost('hause', 'house', confidences: [1, 1, 1, 1, 1]);
      final unsure = em.cost('hause', 'house', confidences: [1, 0.45, 1, 1, 1]);
      expect(unsure, lessThan(sure));
    });
  });

  group('SpellChecker', () {
    test('a word is correct exactly when it is in the dictionary', () {
      expect(checker.isCorrect('House'), isTrue);
      expect(checker.isCorrect('HOUSE'), isTrue);
      expect(checker.isCorrect('hosue'), isFalse);
      expect(checker.isCorrect(''), isTrue);
    });

    test('ranks the intended word first for common misspellings', () {
      const cases = {
        'teh': 'the',
        'becuase': 'because',
        'littel': 'little',
        'scool': 'school',
        'freind': 'friend',
        'beutiful': 'beautiful',
        'siter': 'sister',
        'definately': 'definitely',
        'c0at': 'coat',
      };
      cases.forEach((observed, intended) {
        expect(words(observed).first, intended, reason: observed);
      });
    });

    test('neighboring words change the ranking', () {
      // Alone, "whent" is most likely "when"; in "I whent to" it is "went".
      expect(words('whent').first, 'when');
      expect(words('whent', previous: 'I', next: 'to').first, 'went');
      // Alone, "sed" is most likely "set"; in "she sed that" it is "said".
      expect(words('sed').first, 'set');
      expect(words('sed', previous: 'she', next: 'that').first, 'said');
    });

    test('misspelled neighbors are ignored as context', () {
      expect(words('whent', previous: 'xqz', next: 'qqq'), words('whent'));
    });

    test('returns at most five plausible suggestions', () {
      for (final w in ['a', 'xq', 'wen', 'brotter', 'zzzzzzzzzzzz']) {
        final s = checker.suggest(w);
        expect(s.length, lessThanOrEqualTo(5), reason: w);
        if (s.isNotEmpty) {
          expect(s.first.score - s.last.score, lessThanOrEqualTo(10));
        }
      }
    });

    test('an uncertain letter is not replaced by an unrelated one', () {
      // Seen on the emulator: the recognizer was unsure about the "r" of
      // "rabit", which must not turn the child's "rabbit" into "habit".
      for (final confidence in [0.95, 0.7, 0.5, 0.41]) {
        final ranked = checker.suggest('rabit',
            previous: 'his',
            next: 'and',
            confidences: [confidence, 0.95, 0.95, 0.95, 0.95]);
        expect(ranked.first.word, 'rabbit', reason: '$confidence');
      }
    });

    test('uses the recognizer confidence', () {
      // The recognizer was unsure about the "a" of "hause".
      final unsure =
          checker.suggest('hause', confidences: [0.99, 0.41, 0.99, 0.99, 0.99]);
      expect(unsure.first.word, 'house');
    });
  });

  test('checkWordsInContext uses the neighbors in reading order', () {
    WordBox word(String text) => WordBox(
        text: text,
        bbox: const [0, 0, 10, 10],
        confidence: 1,
        isCorrect: true,
        suggestions: const [],
        characters: [
          for (final c in text.split(''))
            CharacterResult(
                char: c, bbox: const [], contour: const [], confidence: 0.95)
        ]);
    final checked = checkWordsInContext([
      for (final t in ['I', 'whent', 'to', 'scool']) word(t)
    ], checker);
    expect([for (final w in checked) w.isCorrect], [true, false, true, false]);
    expect(checked[1].suggestions.first, 'went');
    expect(checked[3].suggestions.first, 'school');
    expect(checked[0].suggestions, isEmpty);
  });
}
