import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/models/word_box.dart';
import 'package:groundink/state/review_session.dart';

WordBox word(String text, {List<String> suggestions = const []}) => WordBox(
      text: text,
      bbox: const [0, 0, 10, 10],
      confidence: 1,
      isCorrect: suggestions.isEmpty,
      suggestions: suggestions,
      characters: const [],
    );

/// "I wnet to scool with my sistr": three mistakes (ids 1, 3, 6).
ReviewSession session() => ReviewSession([
      word('I'),
      word('wnet', suggestions: ['went', 'wet']),
      word('to'),
      word('scool', suggestions: ['school']),
      word('with'),
      word('my'),
      word('sistr', suggestions: ['sister']),
    ]);

void main() {
  test('starts at the first mistake and steps through them in order', () {
    final s = session();
    expect([for (final e in s.openMistakes) e.id], [1, 3, 6]);
    expect(s.current!.id, 1);
    expect(s.hasPrevious, isFalse);
    s.next();
    expect(s.current!.id, 3);
    s.next();
    expect(s.current!.id, 6);
    expect(s.hasNext, isFalse);
    s.next();
    expect(s.current!.id, 6);
    s.previous();
    expect(s.currentIndex, 1);
  });

  test('a tapped word is shown only if it is an open mistake', () {
    final s = session();
    expect(s.show(6), isTrue);
    expect(s.current!.id, 6);
    expect(s.show(2), isFalse);
    expect(s.current!.id, 6);
  });

  test('the best suggestion is the default correction', () {
    final s = session();
    expect(s.entry(1).correction, 'went');
    s.chooseCorrection(1, 'wet');
    expect(s.entry(1).correction, 'wet');
  });

  test('removing a mistake shows the next one and can be undone', () {
    final s = session();
    var notified = 0;
    s.addListener(() => notified++);
    s.dismiss(1);
    expect(notified, 1);
    expect([for (final e in s.openMistakes) e.id], [3, 6]);
    expect(s.current!.id, 3);
    expect(s.dismissedCount, 1);
    s.restore(1);
    expect([for (final e in s.openMistakes) e.id], [1, 3, 6]);
    expect(s.current!.id, 1);
    expect(s.dismissedCount, 0);
  });

  test('removing the last mistake shows the previous one', () {
    final s = session();
    s.show(6);
    s.dismiss(6);
    expect(s.current!.id, 3);
    s.dismiss(3);
    s.dismiss(1);
    expect(s.current, isNull);
    expect(s.openMistakes, isEmpty);
    s.restoreAll();
    expect(s.openMistakes.length, 3);
    expect(s.current, isNotNull);
  });

  test('a corrected word leaves the review when it becomes correct', () {
    final s = session();
    s.update(1, word('went'));
    expect([for (final e in s.openMistakes) e.id], [3, 6]);
    expect(s.current!.id, 3);
    expect(s.entry(1).word.text, 'went');
  });

  test('a word the user marks as a mistake joins the review', () {
    final s = session();
    s.update(2, word('to', suggestions: ['too']), target: 'too');
    expect([for (final e in s.openMistakes) e.id], [1, 2, 3, 6]);
    expect(s.current!.id, 2);
    expect(s.entry(2).correction, 'too');
  });

  test('editing a removed mistake brings it back', () {
    final s = session();
    s.dismiss(3);
    s.update(3, word('scol', suggestions: ['school']));
    expect(s.entry(3).isOpen, isTrue);
    expect(s.dismissedCount, 0);
  });
}
