import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';

/// Word list, word frequencies and word-pair statistics used to rank
/// spelling suggestions.
///
/// Loaded from `assets/models/english_lm.bin.gz`, which
/// `tool/build_language_model.py` builds (the file format is documented
/// there). Pure Dart, so it also runs in the worker isolate and in tools.
class LanguageModel {
  static const _magic = 0x4D4C4947; // 'GILM' read as little-endian u32.
  static const _version = 1;
  static const _flagNoSuggest = 1;

  /// All dictionary words, lowercase; a word's id is its index.
  final List<String> words;
  final Map<String, int> _ids;
  final Uint8List _flags;
  final Uint32List _counts;
  final Float32List _googleLn;
  final Uint32List _rowStart;
  final Uint32List _pairWord;
  final Float32List _pairPmi;
  final double _lnTotal;
  final double _lnGoogleTotal;
  final double _lnPairThreshold;

  LanguageModel._(
    this.words,
    this._ids,
    this._flags,
    this._counts,
    this._googleLn,
    this._rowStart,
    this._pairWord,
    this._pairPmi,
    this._lnTotal,
    this._lnGoogleTotal,
    this._lnPairThreshold,
  );

  /// Parses the gzip-compressed asset.
  factory LanguageModel.fromGzip(List<int> compressed) =>
      LanguageModel.fromBytes(Uint8List.fromList(gzip.decode(compressed)));

  /// Parses the uncompressed model.
  factory LanguageModel.fromBytes(Uint8List bytes) {
    if (Endian.host != Endian.little) {
      throw UnsupportedError('Big-endian hosts are not supported.');
    }
    // Typed views need aligned offsets; a fresh copy starts at offset 0.
    if (bytes.offsetInBytes % 8 != 0) bytes = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 48 ||
        data.getUint32(0, Endian.little) != _magic ||
        data.getUint32(4, Endian.little) != _version) {
      throw const FormatException('Unsupported spelling model file.');
    }
    final n = data.getUint32(8, Endian.little);
    final m = data.getUint32(12, Endian.little);
    final blobLength = data.getUint32(16, Endian.little);
    final total = data.getFloat64(24, Endian.little);
    final lnGoogleTotal = data.getFloat64(32, Endian.little);
    final lnPairThreshold = data.getFloat64(40, Endian.little);

    int aligned(int length) => (length + 3) & ~3;
    final expected = 48 +
        aligned(blobLength) +
        aligned(n) +
        4 * n * 2 +
        4 * (n + 1) +
        4 * m * 2;
    if (bytes.length != expected) {
      throw const FormatException('Corrupt spelling model file.');
    }
    var offset = 48;
    final words = utf8
        .decode(Uint8List.sublistView(bytes, offset, offset + blobLength))
        .split('\n');
    offset += aligned(blobLength);
    if (words.length != n) {
      throw const FormatException('Corrupt spelling model word list.');
    }
    final flags = Uint8List.sublistView(bytes, offset, offset + n);
    offset += aligned(n);
    final buffer = bytes.buffer;
    final base = bytes.offsetInBytes;
    final counts = buffer.asUint32List(base + offset, n);
    offset += 4 * n;
    final googleLn = buffer.asFloat32List(base + offset, n);
    offset += 4 * n;
    final rowStart = buffer.asUint32List(base + offset, n + 1);
    offset += 4 * (n + 1);
    final pairWord = buffer.asUint32List(base + offset, m);
    offset += 4 * m;
    final pairPmi = buffer.asFloat32List(base + offset, m);
    if (rowStart[n] != m) {
      throw const FormatException('Corrupt spelling model pair table.');
    }

    return LanguageModel._(
      words,
      {for (var i = 0; i < n; i++) words[i]: i},
      flags,
      counts,
      googleLn,
      rowStart,
      pairWord,
      pairPmi,
      math.log(total),
      lnGoogleTotal,
      lnPairThreshold,
    );
  }

  int get length => words.length;

  /// Id of a lowercase dictionary word, or null.
  int? idOf(String word) => _ids[word];

  bool contains(String word) => _ids.containsKey(word);

  /// False for words that are never offered as suggestions (profanity,
  /// slurs; see tool/data/suggestion_blocklist.txt).
  bool isSuggestible(int id) => _flags[id] & _flagNoSuggest == 0;

  /// Occurrences in the subtitle corpus.
  int count(int id) => _counts[id];

  /// ln P(word) from subtitle frequencies.
  double logPrior(int id) => math.log(_counts[id]) - _lnTotal;

  /// ln P(word) from Google Books frequencies, or null if not listed.
  double? logPriorBooks(int id) {
    final ln = _googleLn[id];
    return ln < 0 ? null : ln - _lnGoogleTotal;
  }

  /// How much more (positive) or less (negative) often word [b] directly
  /// follows word [a] than chance would predict: the pointwise mutual
  /// information ln(P(a b) / (P(a) P(b))) in Google Books.
  ///
  /// The pair list only holds pairs seen at least ~100k times. For a missing
  /// pair whose words are so frequent that chance alone predicts more than
  /// that, the pair is rarer than expected and the result is negative.
  /// Otherwise a missing pair says nothing and the result is 0.
  double association(int a, int b) {
    var lo = _rowStart[a];
    var hi = _rowStart[a + 1];
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final word = _pairWord[mid];
      if (word == b) return _pairPmi[mid];
      if (word < b) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final lnA = _googleLn[a];
    final lnB = _googleLn[b];
    if (lnA < 0 || lnB < 0) return 0;
    // ln of the largest PMI a pair below the list threshold can have.
    final bound = _lnPairThreshold + _lnGoogleTotal - lnA - lnB;
    return bound < 0 ? bound - math.ln2 : 0;
  }
}
