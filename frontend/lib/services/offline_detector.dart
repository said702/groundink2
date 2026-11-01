import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import '../models/word_box.dart';
import 'onnx_inference.dart';
import 'image_preprocessor.dart';
import 'progress_notifier.dart';
import 'character_ink.dart';

/// Orders detected words in the same top-to-bottom, left-to-right order in
/// which a reader sees them.
List<WordBox> sortWordsInReadingOrder(List<WordBox> words) {
  final withBoxes = words.where((word) => word.bbox.length >= 4).toList();
  final withoutBoxes = words.where((word) => word.bbox.length < 4).toList();
  withBoxes.sort((a, b) => a.bbox[1].compareTo(b.bbox[1]));

  final rows = <List<WordBox>>[];
  final rowCenters = <double>[];
  final rowHeights = <double>[];
  for (final word in withBoxes) {
    final top = word.bbox[1].toDouble();
    final bottom = word.bbox[3].toDouble();
    final center = (top + bottom) / 2;
    final height = (bottom - top).abs();
    var row = -1;
    for (var i = 0; i < rows.length; i++) {
      final tolerance = math.max(12.0, math.max(height, rowHeights[i]) * 0.6);
      if ((center - rowCenters[i]).abs() <= tolerance) {
        row = i;
        break;
      }
    }
    if (row < 0) {
      rows.add([word]);
      rowCenters.add(center);
      rowHeights.add(height);
    } else {
      rows[row].add(word);
      rowCenters[row] = (rowCenters[row] * (rows[row].length - 1) + center) /
          rows[row].length;
      rowHeights[row] = (rowHeights[row] * (rows[row].length - 1) + height) /
          rows[row].length;
    }
  }

  final rowOrder = List.generate(rows.length, (index) => index)
    ..sort((a, b) => rowCenters[a].compareTo(rowCenters[b]));
  return [
    for (final row in rowOrder)
      ...(rows[row]..sort((a, b) => a.bbox[0].compareTo(b.bbox[0]))),
    ...withoutBoxes,
  ];
}

/// Offline-Erkennungspipeline.
/// Führt Wort-Detection, Character-Recognition und Spellcheck
/// komplett lokal auf dem Gerät durch (kein Server nötig).
///
/// Die schwere ONNX-Inferenz läuft in einem separaten Isolate,
/// damit der Main-Thread (UI) nicht blockiert wird.
class OfflineDetector {
  /// Optionaler Progress-Notifier für UI-Updates.
  static ProgressNotifier? progressNotifier;
  static Uint8List? _wordModel;
  static Uint8List? _charModel;
  static String? _dictionary;

  /// Long-lived worker isolate holding the ONNX sessions and dictionary.
  static Future<(Isolate, SendPort)>? _worker;
  static const _workerExited = 'worker-exited';

  /// Loads asset data once and starts the worker isolate in the background,
  /// so the first photo does not pay for creating the sessions.
  static Future<void> initOnnx() async {
    _wordModel ??= Uint8List.sublistView(
        await rootBundle.load('assets/models/word_detection_model.onnx'));
    _charModel ??= Uint8List.sublistView(
        await rootBundle.load('assets/models/char_model_nano_256.onnx'));
    _dictionary ??=
        await rootBundle.loadString('assets/models/english_words.json');
    _ensureWorker().ignore();
  }

  static Future<(Isolate, SendPort)> _ensureWorker() {
    final existing = _worker;
    if (existing != null) return existing;
    final spawning = _spawnWorker();
    _worker = spawning;
    // A failed start must not be cached; the next photo retries.
    spawning.then((_) {}, onError: (Object _) {
      if (identical(_worker, spawning)) _worker = null;
    });
    return spawning;
  }

  static Future<(Isolate, SendPort)> _spawnWorker() async {
    final ready = ReceivePort();
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      (ready.sendPort, _wordModel!, _charModel!, _dictionary!),
      onExit: exit.sendPort,
      debugName: 'OfflineDetector',
    );
    final current = _worker;
    exit.first.then((_) {
      exit.close();
      if (identical(_worker, current)) _worker = null;
    });
    final first = await ready.first;
    ready.close();
    if (first is _WorkerFailure) first.rethrowIt();
    return (isolate, first as SendPort);
  }

  /// Entry point of the worker isolate: creates the sessions once, then
  /// processes one photo per request, in order.
  static Future<void> _workerMain(
      (SendPort, Uint8List, Uint8List, String) args) async {
    final (ready, wordModel, charModel, dictionary) = args;
    final requests = ReceivePort();
    try {
      await OnnxInference.init(
          wordModel: wordModel, charModel: charModel, dictionary: dictionary);
      // Builds the dictionary set and index now instead of on the first word.
      OnnxInference.checkWord('a');
    } catch (e, st) {
      requests.close();
      OnnxInference.dispose();
      ready.send(_WorkerFailure(e, st.toString()));
      return;
    }
    ready.send(requests.sendPort);
    await for (final message in requests) {
      final (bytes, reply, progress) =
          message as (Uint8List, SendPort, SendPort);
      try {
        reply.send(await _detectInIsolate(bytes, progress));
      } catch (e, st) {
        try {
          reply.send(_WorkerFailure(e, st.toString()));
        } catch (_) {
          // The error object itself cannot cross isolates; keep its text.
          reply.send(_WorkerFailure(Exception(e.toString()), st.toString()));
        }
      }
    }
  }

  /// Haupt-Pipeline: Foto → erkannte Wörter mit Spellcheck.
  /// Mit optionalem Progress-Callback für interaktive UI.
  ///
  /// Die komplette schwere Berechnung läuft im Worker-Isolate.
  static Future<List<WordBox>> detect(File imageFile) async {
    final progressPort = ReceivePort();
    final subscription = progressPort.listen((message) {
      if (message is DetectionProgress) _updateProgress(message);
    });
    try {
      // Asset access must stay on the main isolate.
      await initOnnx();

      // 2. Bild laden (im Main-Isolate, für Progress-UI)
      _updateProgress(DetectionProgress.loadingImage);
      final bytes = await imageFile.readAsBytes();

      // 3. Komplette Pipeline im Worker-Isolate ausführen
      final (isolate, port) = await _ensureWorker();
      final reply = ReceivePort();
      isolate.addOnExitListener(reply.sendPort, response: _workerExited);
      port.send((bytes, reply.sendPort, progressPort.sendPort));
      final response = await reply.first;
      isolate.removeOnExitListener(reply.sendPort);
      reply.close();
      if (response == _workerExited) {
        throw Exception('The recognition worker stopped unexpectedly.');
      }
      if (response is _WorkerFailure) response.rethrowIt();
      final results = response as List<WordBox>;

      _updateProgress(DetectionProgress.done);
      return results;
    } catch (e) {
      _updateProgress(DetectionProgress.error(e.toString()));
      rethrow;
    } finally {
      await subscription.cancel();
      progressPort.close();
    }
  }

  /// Interne Pipeline-Funktion, die im Isolate läuft.
  /// Kein Zugriff auf ProgressNotifier (nicht über Isolate-Grenzen teilbar).
  static Future<List<WordBox>> _detectInIsolate(
      Uint8List bytes, SendPort progress) async {
    // Bild dekodieren
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw Exception('The image could not be decoded.');
    }

    // Wort-Detection (YOLO26n ONNX)
    progress.send(DetectionProgress.detectingWords);
    final wordResults = OnnxInference.detectWords(image, confThreshold: 0.25);
    if (wordResults.isEmpty) {
      return [];
    }

    // Pro Wort: Character-Recognition + Spellcheck
    final results = <WordBox>[];

    for (int i = 0; i < wordResults.length; i++) {
      progress.send(DetectionProgress.recognizingCharacter(
          current: i + 1, total: wordResults.length));
      final w = wordResults[i];
      final bbox = (w['bbox'] as List).cast<int>();
      final conf = w['confidence'] as double;

      // Wort-Crop aus dem Originalbild
      final x1 = bbox[0].clamp(0, image.width).toInt();
      final y1 = bbox[1].clamp(0, image.height).toInt();
      final x2 = bbox[2].clamp(0, image.width).toInt();
      final y2 = bbox[3].clamp(0, image.height).toInt();
      if (x2 <= x1 || y2 <= y1) continue;
      final cropW = (x2 - x1).clamp(1, image.width - x1);
      final cropH = (y2 - y1).clamp(1, image.height - y1);
      final crop =
          img.copyCrop(image, x: x1, y: y1, width: cropW, height: cropH);
      if (crop.width == 0 || crop.height == 0) continue;

      // Preprocessing für das Segmentierungsmodell
      final (preprocessed, offsetX, offsetY) =
          ImagePreprocessor.preprocessWithOffset(crop);

      // Zeichen erkennen (mit Preprocessing)
      final charResults = OnnxInference.recognizeCharacters(
        preprocessed,
        [x1 + offsetX, y1 + offsetY, x2, y2],
        confThreshold: 0.1,
        iouThreshold: 0.4,
        finalConfThreshold: 0.4,
      );

      // Wort-Text aus Buchstaben (links nach rechts sortiert)
      final sortedChars = List<Map<String, dynamic>>.from(charResults);
      sortedChars.sort((a, b) {
        final ax = (a['bbox'] as List)[0] as int;
        final bx = (b['bbox'] as List)[0] as int;
        return ax.compareTo(bx);
      });

      final text = sortedChars.map((c) => c['char'] as String).join().trim();
      if (text.isEmpty) continue;

      // Spellcheck (offline)
      final (isCorrect, suggestions) = OnnxInference.checkWord(text);

      results.add(WordBox(
        text: text,
        bbox: [x1, y1, x2, y2],
        confidence: conf,
        isCorrect: isCorrect,
        suggestions: suggestions,
        characters: sortedChars
            .map((c) => CharacterResult(
                  char: c['char'] as String,
                  bbox: (c['bbox'] as List).cast<int>(),
                  contour: (c['contour'] as List).cast<List<int>>(),
                  confidence: c['confidence'] as double,
                  inkRuns: CharacterInk.extract(
                      image, (c['bbox'] as List).cast<int>()),
                  mask: c['mask'] != null
                      ? (c['mask'] as List)
                          .map((row) => (row as List)
                              .map((e) => (e as num).toDouble())
                              .toList())
                          .toList()
                      : null,
                  maskW: c['maskW'] as int?,
                  maskH: c['maskH'] as int?,
                ))
            .toList(),
      ));
    }

    return sortWordsInReadingOrder(results);
  }

  /// Interne Methode für Progress-Updates.
  static void _updateProgress(DetectionProgress progress) {
    progressNotifier?.update(progress);
  }
}

/// An error raised in the worker isolate, rethrown on the caller's side.
class _WorkerFailure {
  final Object error;
  final String stackTrace;

  const _WorkerFailure(this.error, this.stackTrace);

  Never rethrowIt() =>
      Error.throwWithStackTrace(error, StackTrace.fromString(stackTrace));
}
