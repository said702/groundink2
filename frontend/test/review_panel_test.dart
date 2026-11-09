import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groundink/models/word_box.dart';
import 'package:groundink/state/review_session.dart';
import 'package:groundink/widgets/photo_panel.dart';
import 'package:groundink/widgets/review_panel.dart';

WordBox word(String text, {List<String> suggestions = const []}) => WordBox(
      text: text,
      bbox: const [0, 0, 10, 10],
      confidence: 1,
      isCorrect: suggestions.isEmpty,
      suggestions: suggestions,
      characters: const [],
    );

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
  late List<int> tapped, dismissed;
  late List<(int, bool)> edited;

  Future<void> pumpPanel(WidgetTester tester, ReviewSession s,
      {Size size = const Size(390, 460)}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tapped = [];
    dismissed = [];
    edited = [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReviewPanel(
          session: s,
          onWordTap: (e) => tapped.add(e.id),
          onEdit: (e, typeCorrection) => edited.add((e.id, typeCorrection)),
          onDismiss: (e) {
            dismissed.add(e.id);
            s.dismiss(e.id);
          },
        ),
      ),
    ));
  }

  testWidgets('shows one mistake at a time; arrows and swipes move',
      (tester) async {
    final s = session();
    await pumpPanel(tester, s);
    expect(find.text('Mistake 1 of 3'), findsOneWidget);
    expect(find.text('went'), findsOneWidget);

    await tester.tap(find.byTooltip('Next mistake'));
    await tester.pumpAndSettle();
    expect(s.current!.id, 3);
    expect(find.text('Mistake 2 of 3'), findsOneWidget);
    expect(find.text('school'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(s.current!.id, 6);
    expect(find.text('Mistake 3 of 3'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(300, 0), 1500);
    await tester.pumpAndSettle();
    expect(s.current!.id, 3);

    // Selecting on the photo moves the pager along.
    s.show(1);
    await tester.pumpAndSettle();
    expect(find.text('Mistake 1 of 3'), findsOneWidget);
    expect(find.text('went'), findsOneWidget);
  });

  testWidgets('choosing another suggestion changes the correction',
      (tester) async {
    final s = session();
    await pumpPanel(tester, s);
    await tester.tap(find.text('wet'));
    await tester.pump();
    expect(s.entry(1).correction, 'wet');
  });

  testWidgets('trash removes the mistake; edit and other word open the editor',
      (tester) async {
    final s = session();
    await pumpPanel(tester, s);
    await tester.tap(find.byTooltip('Correct this word'));
    await tester.tap(find.text('Other word…'));
    expect(edited, [(1, false), (1, true)]);

    await tester.tap(find.byTooltip('Remove this mistake'));
    await tester.pumpAndSettle();
    expect(dismissed, [1]);
    expect(find.text('Mistake 1 of 2'), findsOneWidget);
    expect(find.text('school'), findsOneWidget);
    expect(find.textContaining('1 removed'), findsOneWidget);

    // Restoring keeps the mistake that is being looked at.
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('Mistake 2 of 3'), findsOneWidget);
    expect(find.text('school'), findsOneWidget);
  });

  testWidgets('tapping a word of the recognized text reports it',
      (tester) async {
    final s = session();
    await pumpPanel(tester, s);
    await tester.tap(find.text('scool'));
    await tester.tap(find.text('with'));
    expect(tapped, [3, 4]);
  });

  testWidgets('without mistakes the panel says so', (tester) async {
    await pumpPanel(tester, ReviewSession([word('I'), word('went')]));
    expect(find.text('No spelling mistakes found!'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('fits a tablet and a small phone without overflow',
      (tester) async {
    for (final size in [const Size(1024, 560), const Size(320, 300)]) {
      await pumpPanel(tester, session(), size: size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
    }
  });

  group('photo', () {
    late ui.Image image;

    setUpAll(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      image = await picture.toImage(400, 200);
      picture.dispose();
    });

    Future<TransformationController> pumpPhoto(
        WidgetTester tester, List<int>? focus, List<int> taps) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 224,
              child: PhotoPanel(
                imageFile: File('unused.jpg'),
                image: image,
                imageSize: const Size(400, 200),
                crop: const Rect.fromLTWH(0, 0, 400, 200),
                overlay: const [],
                words: const [
                  (id: 0, bbox: [20, 20, 120, 60]),
                  (id: 1, bbox: [200, 120, 260, 140]),
                ],
                focus: focus,
                onWordTap: taps.add,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
    }

    testWidgets('tapping a word on the photo selects it', (tester) async {
      final taps = <int>[];
      await pumpPhoto(tester, null, taps);
      final origin = tester.getTopLeft(find.byType(InteractiveViewer));
      // Panel is 376 px wide for a 400 px wide crop.
      const s = 376 / 400;
      await tester.tapAt(origin + const Offset(70 * s, 40 * s));
      await tester.tapAt(origin + const Offset(230 * s, 130 * s));
      await tester.tapAt(origin + const Offset(330 * s, 30 * s)); // paper
      expect(taps, [0, 1]);
    });

    testWidgets('zooms to a small selected word and back to the page',
        (tester) async {
      // A big word is readable as it is: no zoom.
      var transform = await pumpPhoto(tester, [20, 20, 120, 60], []);
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, 1e-6));

      // The small word is brought into view, zoomed in and centered.
      transform = await pumpPhoto(tester, [200, 120, 260, 140], []);
      final scale = transform.value.getMaxScaleOnAxis();
      expect(scale, greaterThan(2.5));
      const s = 376 / 400;
      final t = transform.value.getTranslation();
      final center = Offset(230 * s * scale + t.x, 130 * s * scale + t.y);
      expect(center.dx, closeTo(376 / 2, 2));
      expect(center.dy, closeTo(188 / 2, 2));

      await tester.tap(find.byTooltip('Show whole page'));
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, 1e-6));
      expect(find.byTooltip('Show whole page'), findsNothing);
    });
  });
}
