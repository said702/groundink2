import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/models/word_box.dart';
import 'package:groundink/widgets/word_editor_sheet.dart';

final ittle = WordBox(
  text: 'ittle',
  bbox: const [0, 0, 50, 10],
  confidence: 1,
  isCorrect: false,
  suggestions: const ['little', 'title'],
  characters: const [],
);

void main() {
  Future<Future<WordEdit?>> open(WidgetTester tester,
      {bool typeCorrection = false}) async {
    late Future<WordEdit?> result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showWordEditor(context,
                word: ittle,
                correction: 'little',
                typeCorrection: typeCorrection),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  Finder field(String label) =>
      find.widgetWithText(TextField, label).hitTestable();

  testWidgets('fixing a misread letter with the keyboard', (tester) async {
    final result = await open(tester);
    expect(find.text('Correct this word'), findsOneWidget);
    // The editor starts with the recognized word and the correction.
    expect(find.widgetWithText(TextField, 'ittle'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'little'), findsOneWidget);

    await tester.enterText(field('Written'), 'little');
    // "Next" moves on to the correction field (not to a clear button).
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
        focused == null
            ? null
            : find
                .ancestor(
                    of: find.byWidget(focused.widget),
                    matching:
                        find.widgetWithText(TextField, 'Correct spelling'))
                .evaluate()
                .isNotEmpty,
        isTrue,
        reason: 'focus is in the correction field');
    expect(find.widgetWithText(TextField, 'little'), findsNWidgets(2));
    expect(find.text('Spelled correctly — not a mistake.'), findsOneWidget);

    // "Done" saves.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Correct this word'), findsNothing);
    final edit = await result;
    expect(edit!.written, 'little');
    expect(edit.intended, 'little');
  });

  testWidgets('"Other word" starts with an empty correction field',
      (tester) async {
    final result = await open(tester, typeCorrection: true);
    await tester.enterText(field('Correct spelling'), 'tittle');
    await tester.pump();
    // The preview shows the intended word.
    expect(find.textContaining('tittle', findRichText: true), findsWidgets);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final edit = await result;
    expect(edit!.written, 'ittle');
    expect(edit.intended, 'tittle');
  });

  testWidgets('cancel returns nothing; an empty written word cannot be saved',
      (tester) async {
    var result = await open(tester);
    await tester.enterText(field('Written'), '');
    await tester.pump();
    final save = tester.widget<ButtonStyleButton>(find.ancestor(
        of: find.text('Save'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(save.onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
