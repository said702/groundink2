import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/models/word_box.dart';
import 'package:groundink/services/spelling_feedback.dart';

void main() {
  test('only a substituted character is marked', () {
    expect(SpellingFeedback.changedCharacters('asbing', 'asking'), {2});
    expect(SpellingFeedback.changedCharacters('retura', 'return'), {5});
  });
  test('correct letters and case differences are not marked', () {
    expect(SpellingFeedback.changedCharacters('World', 'world'), isEmpty);
  });
  test('missing letters mark their nearest existing character', () {
    expect(SpellingFeedback.changedCharacters('kssed', 'kissed'), {1});
    expect(SpellingFeedback.changedCharacters('speling', 'spelling'), {4});
    expect(SpellingFeedback.changedCharacters('broter', 'brother'), {4});
    expect(SpellingFeedback.changedCharacters('scool', 'school'), {2});
  });
  test('the first visible mismatch is localized', () {
    expect(SpellingFeedback.changedCharacters('helllo', 'hello'), {3});
    expect(SpellingFeedback.changedCharacters('teh', 'the'), {1});
    expect(SpellingFeedback.changedCharacters('rabit', 'rabbit'), {3});
  });
  test('empty strings are handled', () {
    expect(SpellingFeedback.changedCharacters('', 'a'), isEmpty);
    expect(SpellingFeedback.changedCharacters('a', ''), {0});
  });

  group('correcting the recognized text keeps the ink', () {
    WordBox word(String text) => WordBox(
          text: text,
          bbox: const [0, 0, 100, 20],
          confidence: 1,
          isCorrect: false,
          suggestions: const [],
          characters: [
            for (var i = 0; i < text.length; i++)
              CharacterResult(
                char: text[i],
                bbox: [i * 10, 0, i * 10 + 10, 20],
                contour: const [],
                confidence: 0.9,
                inkRuns: [
                  [i * 10 + 2, 5, 4]
                ],
              ),
          ],
        );

    test('alignment pairs characters by minimal edits', () {
      expect(SpellingFeedback.align('cqt', 'cat'), [0, 1, 2]);
      expect(SpellingFeedback.align('ct', 'cat'), [0, null, 1]);
      expect(SpellingFeedback.align('caat', 'cat'), [0, 2, 3]);
      expect(SpellingFeedback.align('Dog', 'dog'), [0, 1, 2]);
      expect(SpellingFeedback.align('', 'ab'), [null, null]);
      expect(SpellingFeedback.align('ab', ''), isEmpty);
    });

    test('a misread letter keeps its ink under the new letter', () {
      final fixed = SpellingFeedback.realignCharacters(word('cqt'), 'cat');
      expect([for (final c in fixed) c.char], ['c', 'a', 't']);
      expect(fixed[1].inkRuns, [
        [12, 5, 4]
      ]);
    });

    test('a letter the recognizer missed has no ink', () {
      final fixed = SpellingFeedback.realignCharacters(word('ct'), 'cat');
      expect([for (final c in fixed) c.char], ['c', 'a', 't']);
      expect(fixed[1].inkRuns, isEmpty);
      expect(fixed[2].inkRuns, [
        [12, 5, 4]
      ]);
    });

    test('a spurious letter is dropped with its ink', () {
      final fixed = SpellingFeedback.realignCharacters(word('caat'), 'cat');
      expect([for (final c in fixed) c.char], ['c', 'a', 't']);
      expect(fixed.expand((c) => c.inkRuns).length, 3);
    });
  });
}
