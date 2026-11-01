import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;

/// Offline-ONNX-Inferenz für Wort- und Zeichenerkennung.
/// Ersetzt den FastAPI-Backend-Aufruf durch lokale ONNX-Runtime.
class OnnxInference {
  static OrtSession? _wordSession;
  static OrtSession? _charSession;
  static List<String>? _wordDict;

  /// Lädt beide ONNX-Modelle + Wörterbuch aus den App-Assets.
  static Future<void> init(
      {Uint8List? wordModel, Uint8List? charModel, String? dictionary}) async {
    if (_wordSession != null && _charSession != null && _wordDict != null) {
      return; // bereits initialisiert
    }

    // ONNX Runtime initialisieren
    OrtEnv.instance.init();

    // Session-Optionen
    final sessionOptions = OrtSessionOptions();
    sessionOptions.setIntraOpNumThreads(
        math.max(1, math.min(4, Platform.numberOfProcessors)));
    sessionOptions.setInterOpNumThreads(1);

    // Wort-Modell laden
    final wordBytes = wordModel ??
        Uint8List.sublistView(
            await rootBundle.load('assets/models/word_detection_model.onnx'));
    _wordSession = OrtSession.fromBuffer(wordBytes, sessionOptions);

    // Zeichen-Modell laden
    final charBytes = charModel ??
        Uint8List.sublistView(
            await rootBundle.load('assets/models/char_model_nano_256.onnx'));
    _charSession = OrtSession.fromBuffer(charBytes, sessionOptions);

    // Wörterbuch laden
    final wordsJson = dictionary ??
        await rootBundle.loadString('assets/models/english_words.json');
    _wordDict = (jsonDecode(wordsJson) as List<dynamic>).cast<String>();
    sessionOptions.release();
  }

  static void dispose() {
    _wordSession?.release();
    _charSession?.release();
    _wordSession = null;
    _charSession = null;
    _wordDict = null;
    OrtEnv.instance.release();
  }

  static (img.Image, double, int, int) _letterbox(img.Image source, int size) {
    final scale = math.min(size / source.width, size / source.height);
    final width = (source.width * scale).round().clamp(1, size);
    final height = (source.height * scale).round().clamp(1, size);
    final left = (size - width) ~/ 2;
    final top = (size - height) ~/ 2;
    final canvas = img.Image(width: size, height: size);
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(
        canvas,
        img.copyResize(source,
            width: width,
            height: height,
            interpolation: img.Interpolation.linear),
        dstX: left,
        dstY: top);
    return (canvas, scale, left, top);
  }

  /// Converts a square RGB image into a normalized NCHW float tensor.
  ///
  /// Reads the raw RGB bytes once instead of calling `getPixel` per channel
  /// and pixel, which allocated a pixel object for every access.
  static Float32List toNchwFloat(img.Image image, int size) {
    final rgb = image.getBytes(order: img.ChannelOrder.rgb);
    final plane = size * size;
    final input = Float32List(3 * plane);
    for (int i = 0, src = 0; i < plane; i++, src += 3) {
      input[i] = rgb[src] / 255.0;
      input[plane + i] = rgb[src + 1] / 255.0;
      input[2 * plane + i] = rgb[src + 2] / 255.0;
    }
    return input;
  }

  /// YOLO26n Wort-Detection: Bild → Bounding-Boxes von Wörtern.
  /// Gibt Liste von (bbox [x1,y1,x2,y2], confidence) zurück.
  static List<Map<String, dynamic>> detectWords(img.Image image,
      {double confThreshold = 0.25}) {
    if (_wordSession == null) {
      throw Exception('ONNX not initialized. Call OnnxInference.init() first.');
    }

    // YOLO26n word detector expects a 640x640 RGB input.
    const inputSize = 640;
    final (resized, scale, padX, padY) = _letterbox(image, inputSize);

    // Bild → NCHW Float-Tensor (1,3,640,640), normalisiert auf 0-1
    final input = toNchwFloat(resized, inputSize);

    // Input-Shape
    final shape = [1, 3, inputSize, inputSize];
    final inputOrt = OrtValueTensor.createTensorWithDataList(input, shape);

    // Input-Name aus dem Modell holen (meistens "images" bei YOLO)
    final runOptions = OrtRunOptions();
    final inputs = {_wordSession!.inputNames.first: inputOrt};

    // Inferenz ausführen
    final outputs = _wordSession!.run(runOptions, inputs);

    // YOLO26n end-to-end output: (1, 300, 6) with xyxy, score, class.
    // outputs ist eine List<OrtValue?> — index 0 = erster Output
    final outputValue = outputs[0];
    final outputData = outputValue?.value as List<dynamic>;

    final results = <Map<String, dynamic>>[];

    // Skalierung: 640 → Originalbild
    final scaleX = 1 / scale;
    final scaleY = 1 / scale;

    final inner = outputData[0] as List<dynamic>;
    final first = inner.first as List<dynamic>;
    final isEndToEnd = first.length == 6;
    final numDetections =
        isEndToEnd ? inner.length : (inner[0] as List<dynamic>).length;

    for (int d = 0; d < numDetections; d++) {
      late final double x1, y1, x2, y2, conf;
      if (isEndToEnd) {
        final detection = inner[d] as List<dynamic>;
        if ((detection[5] as num).toInt() != 0) continue;
        x1 = (detection[0] as num).toDouble();
        y1 = (detection[1] as num).toDouble();
        x2 = (detection[2] as num).toDouble();
        y2 = (detection[3] as num).toDouble();
        conf = (detection[4] as num).toDouble();
      } else {
        x1 = (inner[0][d] as num).toDouble();
        y1 = (inner[1][d] as num).toDouble();
        x2 = (inner[2][d] as num).toDouble();
        y2 = (inner[3][d] as num).toDouble();
        conf = (inner[4][d] as num).toDouble();
      }

      if (conf < confThreshold) continue;

      // Zurückskalieren auf Originalbild
      results.add({
        'bbox': [
          (((isEndToEnd ? x1 : x1 - x2 / 2) - padX) * scaleX)
              .round()
              .clamp(0, image.width),
          (((isEndToEnd ? y1 : y1 - y2 / 2) - padY) * scaleY)
              .round()
              .clamp(0, image.height),
          (((isEndToEnd ? x2 : x1 + x2 / 2) - padX) * scaleX)
              .round()
              .clamp(0, image.width),
          (((isEndToEnd ? y2 : y1 + y2 / 2) - padY) * scaleY)
              .round()
              .clamp(0, image.height),
        ],
        'confidence': conf,
        'conf': conf,
      });
    }

    // Sortiere von links nach rechts
    for (final output in outputs) {
      output?.release();
    }
    inputOrt.release();
    runOptions.release();
    final filtered = _nms(results, maxDetections: 300);
    filtered.sort(
        (a, b) => (a['bbox'] as List)[0].compareTo((b['bbox'] as List)[0]));
    return filtered;
  }

  /// YOLO-Segmentation Zeichen-Modell: Wort-Crop → erkannte Buchstaben + Konturen.
  /// Gibt Liste von {char, bbox, contour, confidence} zurück.
  ///
  /// Parameter (entsprechend den Modell-Settings):
  /// - confThreshold: YOLO-Confidence (default 0.1)
  /// - iouThreshold: NMS IoU-Threshold (default 0.4)
  /// - finalConfThreshold: Finale Filterung nach adaptive_conf (default 0.4)
  static List<Map<String, dynamic>> recognizeCharacters(
    img.Image wordCrop,
    List<int> wordBbox, {
    double confThreshold = 0.1,
    double iouThreshold = 0.4,
    double finalConfThreshold = 0.4,
  }) {
    if (_charSession == null) {
      throw Exception('ONNX not initialized. Call OnnxInference.init() first.');
    }

    // Match the static 256x256 ONNX export used by this variant.
    const inputSize = 256;
    final (resized, scale, padX, padY) = _letterbox(wordCrop, inputSize);

    // Bild → NCHW Float-Tensor
    final input = toNchwFloat(resized, inputSize);

    final shape = [1, 3, inputSize, inputSize];
    final inputOrt = OrtValueTensor.createTensorWithDataList(input, shape);
    final runOptions = OrtRunOptions();
    final inputs = {_charSession!.inputNames.first: inputOrt};

    final outputs = _charSession!.run(runOptions, inputs);

    // Klassen-Namen (0-9, A-Z, a-z)
    const classNames = [
      '0',
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
      'I',
      'J',
      'K',
      'L',
      'M',
      'N',
      'O',
      'P',
      'Q',
      'R',
      'S',
      'T',
      'U',
      'V',
      'W',
      'X',
      'Y',
      'Z',
      'a',
      'b',
      'c',
      'd',
      'e',
      'f',
      'g',
      'h',
      'i',
      'j',
      'k',
      'l',
      'm',
      'n',
      'o',
      'p',
      'q',
      'r',
      's',
      't',
      'u',
      'v',
      'w',
      'x',
      'y',
      'z'
    ];

    // Output: [1, 98, 1344] = xywh(4), class scores(62), mask coefficients(32).
    const numClasses = 62;

    final results = <Map<String, dynamic>>[];

    // Skalierung zurück auf Wort-Crop
    final scaleX = 1 / scale;
    final scaleY = 1 / scale;

    // Ersten Output parsen - NUR mit try-catch für OOM-Schutz
    final outputValue = outputs[0];
    if (outputValue == null) {
      inputOrt.release();
      runOptions.release();
      return results;
    }

    List<dynamic> outputData;
    try {
      outputData = outputValue.value as List<dynamic>;
    } catch (e) {
      inputOrt.release();
      runOptions.release();
      outputValue.release();
      rethrow;
    }

    if (outputData.isEmpty) {
      inputOrt.release();
      runOptions.release();
      outputValue.release();
      return results;
    }

    final inner = outputData[0] as List<dynamic>;
    final numValues = inner.length;
    if (inner.isEmpty) {
      inputOrt.release();
      runOptions.release();
      outputValue.release();
      return results;
    }

    final numDetections = (inner[0] as List<dynamic>).length;

    final rawResults = <Map<String, dynamic>>[];

    for (int d = 0; d < numDetections; d++) {
      // Erste 4 Werte = bbox
      final x1 = (inner[0][d] as num).toDouble();
      final y1 = (inner[1][d] as num).toDouble();
      final x2 = (inner[2][d] as num).toDouble();
      final y2 = (inner[3][d] as num).toDouble();
      // YOLO has 62 class scores after xywh, without an objectness column.
      int bestCls = 0;
      double bestScore = 0;
      for (int c = 0; c < numClasses && (4 + c) < numValues; c++) {
        final score = (inner[4 + c][d] as num).toDouble();
        if (score > bestScore) {
          bestScore = score;
          bestCls = c;
        }
      }

      final conf = bestScore;
      if (conf < confThreshold) continue;

      final label = bestCls < classNames.length ? classNames[bestCls] : '?';

      // Zurückskalieren auf Wort-Crop-Koordinaten
      final cx1 = ((x1 - x2 / 2 - padX) * scaleX).round();
      final cy1 = ((y1 - y2 / 2 - padY) * scaleY).round();
      final cx2 = ((x1 + x2 / 2 - padX) * scaleX).round();
      final cy2 = ((y1 + y2 / 2 - padY) * scaleY).round();

      // Globale Koordinaten (relativ zum Originalbild)
      final gx1 = wordBbox[0] + cx1;
      final gy1 = wordBbox[1] + cy1;
      final gx2 = wordBbox[0] + cx2;
      final gy2 = wordBbox[1] + cy2;

      rawResults.add({
        'char': label,
        'bbox': [gx1, gy1, gx2, gy2],
        'conf': conf,
        'detIdx': d,
      });
    }

    // NMS
    final nmsFiltered =
        _nms(rawResults, iouThreshold: iouThreshold, maxDetections: 15);

    // Finale Confidence-Filterung
    final filtered = nmsFiltered
        .where((d) => (d['conf'] as double) >= finalConfThreshold)
        .toList();

    // Release the native tensors after decoding.
    outputValue.release();
    runOptions.release();
    inputOrt.release();

    // Ergebnisse zusammenstellen
    for (int i = 0; i < filtered.length; i++) {
      final det = filtered[i];
      results.add({
        'char': det['char'] as String,
        'bbox': det['bbox'] as List<int>,
        'contour': <List<int>>[],
        'mask': null,
        'maskW': null,
        'maskH': null,
        'confidence': det['conf'] as double,
      });
    }

    // Sortiere von links nach rechts
    results.sort(
        (a, b) => (a['bbox'] as List)[0].compareTo((b['bbox'] as List)[0]));
    return results;
  }

  /// Prüft ein Wort offline gegen das Wörterbuch.
  /// Gibt (isCorrect, suggestions) zurück.
  static (bool, List<String>) checkWord(String word,
      {List<String>? dictionary}) {
    final words = dictionary ?? _wordDict;
    if (words == null) {
      throw Exception(
          'Dictionary not loaded. Call OnnxInference.init() first.');
    }

    word = word.trim();
    if (word.isEmpty) return (true, []);

    final lower = word.toLowerCase();
    // Building a set from the ~200k-word list used to happen for every word.
    if (!identical(words, _cachedSetSource)) {
      _cachedSetSource = words;
      _cachedWordSet = words.toSet();
    }
    final wordSet = _cachedWordSet!;

    if (wordSet.contains(lower)) {
      return (true, []);
    }

    // Einfache Edit-Distance-basierte Vorschläge (Levenshtein)
    final suggestions = <MapEntry<String, int>>[];
    for (final dictWord in wordSet) {
      if ((dictWord.length - lower.length).abs() > 2) continue;
      final dist = _levenshtein(lower, dictWord, maxDistance: 2);
      if (dist <= 2) {
        suggestions.add(MapEntry(dictWord, dist));
      }
    }

    suggestions.sort((a, b) => a.value.compareTo(b.value));
    final top = suggestions.take(5).map((e) => e.key).toList();
    return (false, top);
  }

  static List<String>? _cachedSetSource;
  static Set<String>? _cachedWordSet;

  /// Levenshtein-Distanz zwischen zwei Strings.
  ///
  /// With [maxDistance], returns `maxDistance + 1` as soon as the distance is
  /// known to exceed it; distances up to [maxDistance] are exact.
  static int _levenshtein(String s1, String s2, {int? maxDistance}) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    final m = s2.length;
    var previous = Int32List(m + 1);
    var current = Int32List(m + 1);
    for (int j = 0; j <= m; j++) {
      previous[j] = j;
    }

    for (int i = 1; i <= s1.length; i++) {
      current[0] = i;
      var rowMin = i;
      final c1 = s1.codeUnitAt(i - 1);
      for (int j = 1; j <= m; j++) {
        final cost = c1 == s2.codeUnitAt(j - 1) ? 0 : 1;
        var best = previous[j] + 1;
        final insert = current[j - 1] + 1;
        if (insert < best) best = insert;
        final substitute = previous[j - 1] + cost;
        if (substitute < best) best = substitute;
        current[j] = best;
        if (best < rowMin) rowMin = best;
      }
      if (maxDistance != null && rowMin > maxDistance) return maxDistance + 1;
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[m];
  }

  /// Non-Maximum Suppression: entfernt überlappende Detections (IoU > threshold),
  /// behält die besten [maxDetections] nach Confidence.
  static List<Map<String, dynamic>> _nms(
    List<Map<String, dynamic>> detections, {
    double iouThreshold = 0.45,
    int maxDetections = 30,
  }) {
    // Nach Confidence absteigend sortieren
    final sorted = List<Map<String, dynamic>>.from(detections)
      ..sort((a, b) => (b['conf'] as double).compareTo(a['conf'] as double));

    final keep = <Map<String, dynamic>>[];

    for (final det in sorted) {
      if (keep.length >= maxDetections) break;

      final bbox = det['bbox'] as List;
      final ax1 = bbox[0] as int, ay1 = bbox[1] as int;
      final ax2 = bbox[2] as int, ay2 = bbox[3] as int;

      var suppressed = false;
      for (final kept in keep) {
        final kbbox = kept['bbox'] as List;
        final bx1 = kbbox[0] as int, by1 = kbbox[1] as int;
        final bx2 = kbbox[2] as int, by2 = kbbox[3] as int;

        // Intersection
        final ix1 = ax1 > bx1 ? ax1 : bx1;
        final iy1 = ay1 > by1 ? ay1 : by1;
        final ix2 = ax2 < bx2 ? ax2 : bx2;
        final iy2 = ay2 < by2 ? ay2 : by2;
        final iw = ix2 - ix1, ih = iy2 - iy1;
        if (iw <= 0 || ih <= 0) continue;
        final intersection = iw * ih;

        // Union
        final areaA = (ax2 - ax1) * (ay2 - ay1);
        final areaB = (bx2 - bx1) * (by2 - by1);
        final union = areaA + areaB - intersection;

        if (intersection / union > iouThreshold) {
          suppressed = true;
          break;
        }
      }

      if (!suppressed) keep.add(det);
    }

    return keep;
  }
}
