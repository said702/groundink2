import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';
// The raw tensor accessors need the generated FFI types of the package.
// ignore: implementation_imports
import 'package:onnxruntime/src/bindings/onnxruntime_bindings_generated.dart'
    as bg;
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

  /// Scales [source] into a [size]x[size] gray (114) canvas, keeping aspect.
  ///
  /// Copies the resized rows straight into the canvas bytes. Produces the
  /// same pixels as [letterboxReference], whose per-pixel `compositeImage`
  /// blend took most of the per-word preparation time.
  static (img.Image, double, int, int) letterbox(img.Image source, int size) {
    final scale = math.min(size / source.width, size / source.height);
    final width = (source.width * scale).round().clamp(1, size);
    final height = (source.height * scale).round().clamp(1, size);
    final left = (size - width) ~/ 2;
    final top = (size - height) ~/ 2;
    final resized = img.copyResize(source,
        width: width, height: height, interpolation: img.Interpolation.linear);
    final channels = resized.numChannels;
    if (resized.format != img.Format.uint8 ||
        resized.hasPalette ||
        (channels != 3 && channels != 4)) {
      return letterboxReference(source, size);
    }
    final src = resized.getBytes(
        order: channels == 4 ? img.ChannelOrder.rgba : img.ChannelOrder.rgb);
    final out = Uint8List(size * size * 3)..fillRange(0, size * size * 3, 114);
    for (var y = 0; y < height; y++) {
      var o = ((top + y) * size + left) * 3;
      var s = y * width * channels;
      for (var x = 0; x < width; x++, s += channels) {
        // Translucent pixels are blended by compositeImage; keep that exact.
        if (channels == 4 && src[s + 3] != 255) {
          return letterboxReference(source, size);
        }
        out[o++] = src[s];
        out[o++] = src[s + 1];
        out[o++] = src[s + 2];
      }
    }
    return (
      img.Image.fromBytes(
          width: size, height: size, bytes: out.buffer, numChannels: 3),
      scale,
      left,
      top
    );
  }

  /// Original letterbox built on `img.fill` and `img.compositeImage`.
  static (img.Image, double, int, int) letterboxReference(
      img.Image source, int size) {
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

  /// Creates a float tensor that ONNX Runtime reads straight from [data].
  ///
  /// `OrtValueTensor.createTensorWithDataList` flattens its input into a
  /// growable `List<double>` first, boxing every value (~200k per word for
  /// the character model, ~1.2M for the word model). This copies the typed
  /// list into native memory in one go and builds the same tensor.
  static OrtValueTensor createFloatTensor(Float32List data, List<int> shape) {
    final api = OrtEnv.instance.ortApiPtr.ref;
    final dataPtr = calloc<ffi.Float>(data.length);
    dataPtr.asTypedList(data.length).setAll(0, data);
    final shapePtr = calloc<ffi.Int64>(shape.length);
    shapePtr.asTypedList(shape.length).setAll(0, shape);
    final memInfoPtrPtr = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
    final valuePtrPtr = calloc<ffi.Pointer<bg.OrtValue>>();
    try {
      OrtStatus.checkOrtStatus(api.AllocatorGetInfo.asFunction<
              bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtAllocator>,
                  ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(
          OrtAllocator.instance.ptr, memInfoPtrPtr));
      OrtStatus.checkOrtStatus(api.CreateTensorWithDataAsOrtValue.asFunction<
              bg.OrtStatusPtr Function(
                  ffi.Pointer<bg.OrtMemoryInfo>,
                  ffi.Pointer<ffi.Void>,
                  int,
                  ffi.Pointer<ffi.Int64>,
                  int,
                  int,
                  ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
          memInfoPtrPtr.value,
          dataPtr.cast(),
          data.length * 4,
          shapePtr,
          shape.length,
          ONNXTensorElementDataType.float.value,
          valuePtrPtr));
      // The tensor owns dataPtr and frees it in release().
      return OrtValueTensor(valuePtrPtr.value, dataPtr.cast());
    } catch (_) {
      calloc.free(dataPtr);
      rethrow;
    } finally {
      calloc.free(shapePtr);
      calloc.free(memInfoPtrPtr);
      calloc.free(valuePtrPtr);
    }
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
    final (resized, scale, padX, padY) = letterbox(image, inputSize);

    // Bild → NCHW Float-Tensor (1,3,640,640), normalisiert auf 0-1
    final input = toNchwFloat(resized, inputSize);

    // Input-Shape
    final shape = [1, 3, inputSize, inputSize];
    final inputOrt = createFloatTensor(input, shape);

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
    final (resized, scale, padX, padY) = letterbox(wordCrop, inputSize);

    // Bild → NCHW Float-Tensor
    final input = toNchwFloat(resized, inputSize);

    final shape = [1, 3, inputSize, inputSize];
    final inputOrt = createFloatTensor(input, shape);
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

    // Ersten Output parsen. Read the float data directly from native memory;
    // `OrtValue.value` boxed all ~130k values into nested Dart lists per word.
    void releaseNative() {
      for (final output in outputs) {
        output?.release();
      }
      runOptions.release();
      inputOrt.release();
    }

    final outputValue = outputs[0];
    if (outputValue == null) {
      releaseNative();
      return results;
    }

    final _FloatTensor? tensor;
    try {
      tensor = _readChannelTensor(outputValue);
    } catch (e) {
      releaseNative();
      rethrow;
    }
    if (tensor == null || tensor.channels == 0) {
      releaseNative();
      return results;
    }

    final data = tensor.data;
    final numValues = tensor.channels;
    final numDetections = tensor.count;

    final rawResults = <Map<String, dynamic>>[];

    for (int d = 0; d < numDetections; d++) {
      // Erste 4 Werte = bbox
      final x1 = data[d];
      final y1 = data[numDetections + d];
      final x2 = data[2 * numDetections + d];
      final y2 = data[3 * numDetections + d];
      // YOLO has 62 class scores after xywh, without an objectness column.
      int bestCls = 0;
      double bestScore = 0;
      for (int c = 0; c < numClasses && (4 + c) < numValues; c++) {
        final score = data[(4 + c) * numDetections + d];
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

    // Release the native tensors after decoding (all outputs, including the
    // unused mask prototypes, which were previously leaked for every word).
    releaseNative();

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

  /// Reads a `[1, channels, count]` float tensor into a flat buffer.
  ///
  /// Copies straight from the tensor memory. Falls back to `OrtValue.value`
  /// for tensors that are not float or not rank 3. Returns null when the
  /// tensor is empty.
  static _FloatTensor? _readChannelTensor(OrtValue value) {
    final api = OrtEnv.instance.ortApiPtr.ref;
    final infoPtrPtr = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
    final typePtr = calloc<ffi.Int32>();
    final rankPtr = calloc<ffi.Size>();
    final dataPtrPtr = calloc<ffi.Pointer<ffi.Float>>();
    ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> info = ffi.nullptr;
    try {
      OrtStatus.checkOrtStatus(api.GetTensorTypeAndShape.asFunction<
              bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
                  ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(
          value.ptr, infoPtrPtr));
      info = infoPtrPtr.value;
      OrtStatus.checkOrtStatus(api.GetTensorElementType.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
              ffi.Pointer<ffi.Int32>)>()(info, typePtr));
      OrtStatus.checkOrtStatus(api.GetDimensionsCount.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
              ffi.Pointer<ffi.Size>)>()(info, rankPtr));
      final rank = rankPtr.value;
      if (typePtr.value == ONNXTensorElementDataType.float.value && rank == 3) {
        final dims = calloc<ffi.Int64>(3);
        try {
          OrtStatus.checkOrtStatus(api.GetDimensions.asFunction<
              bg.OrtStatusPtr Function(
                  ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                  ffi.Pointer<ffi.Int64>,
                  int)>()(info, dims, 3));
          final batch = dims[0], channels = dims[1], count = dims[2];
          if (batch == 0 || channels == 0) return null;
          OrtStatus.checkOrtStatus(api.GetTensorMutableData.asFunction<
                  bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
                      ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(
              value.ptr, dataPtrPtr.cast()));
          // Batch 0 only, as in the previous `outputData[0]` access.
          final data = Float32List.fromList(
              dataPtrPtr.value.asTypedList(channels * count));
          return _FloatTensor(data, channels, count);
        } finally {
          calloc.free(dims);
        }
      }
    } finally {
      if (info != ffi.nullptr) {
        api.ReleaseTensorTypeAndShapeInfo.asFunction<
            void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)>()(info);
      }
      calloc.free(infoPtrPtr);
      calloc.free(typePtr);
      calloc.free(rankPtr);
      calloc.free(dataPtrPtr);
    }

    // Generic fallback (previous behaviour).
    final outputData = value.value as List<dynamic>;
    if (outputData.isEmpty) return null;
    final inner = outputData[0] as List<dynamic>;
    if (inner.isEmpty) return null;
    final count = (inner[0] as List<dynamic>).length;
    final data = Float32List(inner.length * count);
    for (var ch = 0; ch < inner.length; ch++) {
      final row = inner[ch] as List<dynamic>;
      for (var d = 0; d < count; d++) {
        data[ch * count + d] = (row[d] as num).toDouble();
      }
    }
    return _FloatTensor(data, inner.length, count);
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
      // Same order as iterating the set, so suggestions keep their order.
      _cachedWordList = _cachedWordSet!.toList(growable: false);
      _cachedMasks = Int32List.fromList(
          [for (final w in _cachedWordList!) _letterMask(w)]);
      _checkCache.clear();
    }
    final wordSet = _cachedWordSet!;

    if (wordSet.contains(lower)) {
      return (true, []);
    }

    // Texts repeat words; the suggestion search is the expensive part.
    final cached = _checkCache[lower];
    if (cached != null) return (false, List.of(cached));

    // Einfache Edit-Distance-basierte Vorschläge (Levenshtein)
    final suggestions = <MapEntry<String, int>>[];
    final length = lower.length;
    final list = _cachedWordList!;
    final masks = _cachedMasks!;
    final mask = _letterMask(lower);
    for (var i = 0; i < list.length; i++) {
      final dictWord = list[i];
      if ((dictWord.length - length).abs() > 2) continue;
      // One edit changes at most two bits of the letter-presence mask, so
      // more than four differing bits means a distance above 2.
      if (_bitCount(masks[i] ^ mask) > 4) continue;
      final dist = _levenshteinWithin2(lower, dictWord);
      if (dist <= 2) {
        suggestions.add(MapEntry(dictWord, dist));
      }
    }

    suggestions.sort((a, b) => a.value.compareTo(b.value));
    final top = suggestions.take(5).map((e) => e.key).toList();
    _checkCache[lower] = top;
    return (false, List.of(top));
  }

  static List<String>? _cachedSetSource;
  static Set<String>? _cachedWordSet;
  static List<String>? _cachedWordList;
  static Int32List? _cachedMasks;

  /// Bit set of the characters in [s] (any char→bit mapping keeps the
  /// filter in [checkWord] exact; a-z get distinct bits). Bits 0-29 only,
  /// so values stay positive in an Int32List.
  static int _letterMask(String s) {
    var mask = 0;
    for (var i = 0; i < s.length; i++) {
      mask |= 1 << (s.codeUnitAt(i) % 30);
    }
    return mask;
  }

  static int _bitCount(int v) {
    v = v - ((v >> 1) & 0x55555555);
    v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
    return (((v + (v >> 4)) & 0x0F0F0F0F) * 0x01010101 >> 24) & 0xFF;
  }

  static final Map<String, List<String>> _checkCache = {};

  static Int32List _bandPrev = Int32List(0), _bandCur = Int32List(0);

  /// Levenshtein distance restricted to the diagonal band |i - j| <= 2.
  ///
  /// Exact for distances up to 2 (any such alignment stays in the band);
  /// returns a value > 2 otherwise. Computes 5 cells per row instead of the
  /// whole row and reuses its buffers.
  static int _levenshteinWithin2(String s1, String s2) {
    const k = 2;
    const inf = 1 << 20;
    final n = s1.length, m = s2.length;
    if ((n - m).abs() > k) return k + 1;
    if (s1 == s2) return 0;
    if (n == 0) return m;
    if (m == 0) return n;
    if (_bandPrev.length < m + 2) {
      _bandPrev = Int32List(m + 2);
      _bandCur = Int32List(m + 2);
    }
    var prev = _bandPrev, cur = _bandCur;
    for (var j = 0; j <= m + 1; j++) {
      prev[j] = j <= k ? j : inf;
    }
    for (var i = 1; i <= n; i++) {
      final lo = i - k > 1 ? i - k : 1;
      final hi = i + k < m ? i + k : m;
      cur[lo - 1] = lo == 1 ? (i <= k ? i : inf) : inf;
      var rowMin = cur[lo - 1];
      final c1 = s1.codeUnitAt(i - 1);
      for (var j = lo; j <= hi; j++) {
        final cost = c1 == s2.codeUnitAt(j - 1) ? 0 : 1;
        var best = prev[j] + 1;
        final insert = cur[j - 1] + 1;
        if (insert < best) best = insert;
        final substitute = prev[j - 1] + cost;
        if (substitute < best) best = substitute;
        cur[j] = best;
        if (best < rowMin) rowMin = best;
      }
      // Cell just right of the band must read as unreachable next row.
      if (hi + 1 <= m) cur[hi + 1] = inf;
      if (rowMin > k) return k + 1;
      final swap = prev;
      prev = cur;
      cur = swap;
    }
    return prev[m];
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

/// Flat `[channels, count]` view of a model output (batch 0).
class _FloatTensor {
  final Float32List data;
  final int channels;
  final int count;

  const _FloatTensor(this.data, this.channels, this.count);
}
