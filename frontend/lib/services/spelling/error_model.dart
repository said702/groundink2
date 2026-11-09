import 'dart:math' as math;
import 'dart:typed_data';

/// How likely a recognized spelling is, given the word that was meant.
///
/// A weighted edit distance that knows two error sources:
/// * children's spelling mistakes: missing double letters ("litle"), silent
///   letters ("wach" for "watch", "scool"), vowel confusions ("frend"),
///   swapped letters ("teh"), sound-alike consonants (c/k, f/v, w/v);
/// * handwriting recognition: letters that look alike ("a"/"o", "n"/"h",
///   "0"/"o"), one letter read as two ("m" as "rn") and vice versa.
///
/// The recognizer's confidence matters for recognition errors only: a letter
/// it was unsure about was probably confused with a letter that looks alike,
/// or is a spurious detection; it says little about arbitrary replacements.
///
/// [cost] is 0 for identical words; 1.0 is one arbitrary edit. Typical
/// mistakes cost less, so they rank higher.
class ErrorModel {
  const ErrorModel();

  /// Cost of a transposition of two neighboring letters ("teh" → "the").
  static const transposition = 0.6;

  /// Cost of producing [observed] when [intended] was written or meant.
  ///
  /// Both are lowercase. [confidences] holds the recognizer's confidence
  /// (0..1) for each character of [observed].
  double cost(String observed, String intended, {List<double>? confidences}) {
    final n = observed.length;
    final m = intended.length;
    final width = m + 1;
    final d = Float64List((n + 1) * width);
    double confidence(int i) => confidences == null || i >= confidences.length
        ? 1.0
        : confidences[i].clamp(0.0, 1.0).toDouble();
    // Discount for recognition errors on uncertain letters.
    double misread(int i) => 0.3 + 0.7 * confidence(i);

    for (var j = 1; j <= m; j++) {
      d[j] = d[j - 1] + _insertion(intended, j - 1);
    }
    for (var i = 1; i <= n; i++) {
      final row = i * width;
      final o = observed[i - 1];
      final deletion = _deletion(observed, i - 1) * misread(i - 1);
      d[row] = d[row - width] + deletion;
      for (var j = 1; j <= m; j++) {
        final c = intended[j - 1];
        var best = d[row - width + j - 1] +
            (o == c ? 0.0 : _substitution(c, o, confidence(i - 1)));
        final delete = d[row - width + j] + deletion;
        if (delete < best) best = delete;
        final insert = d[row + j - 1] + _insertion(intended, j - 1);
        if (insert < best) best = insert;
        if (i >= 2 &&
            j >= 2 &&
            o != c &&
            o == intended[j - 2] &&
            observed[i - 2] == c) {
          final swap = d[row - 2 * width + j - 2] + transposition;
          if (swap < best) best = swap;
        }
        if (i >= 2) {
          // One intended letter written or recognized as two ("m" → "rn").
          final pair = observed.substring(i - 2, i);
          final read = _readAsTwo[c]?[pair];
          final written = _writtenAsTwo[c]?[pair];
          final split = math.min(
              read == null
                  ? double.infinity
                  : read * (misread(i - 2) + misread(i - 1)) / 2,
              written ?? double.infinity);
          final value = d[row - 2 * width + j - 1] + split;
          if (value < best) best = value;
        }
        if (j >= 2) {
          // Two intended letters written or recognized as one ("ph" → "f").
          final pair = intended.substring(j - 2, j);
          final read = _readAsOne[pair]?[o];
          final written = _writtenAsOne[pair]?[o];
          final merge = math.min(
              read == null ? double.infinity : read * misread(i - 1),
              written ?? double.infinity);
          final value = d[row - width + j - 2] + merge;
          if (value < best) best = value;
        }
        d[row + j] = best;
      }
    }
    return d[n * width + m];
  }

  static bool _isVowel(String c) => 'aeiou'.contains(c);

  /// Cost of a letter of [intended] at [k] that is missing in the writing.
  static double _insertion(String intended, int k) {
    final c = intended[k];
    final m = intended.length;
    final prev = k > 0 ? intended[k - 1] : '';
    final next = k + 1 < m ? intended[k + 1] : '';
    // The character model has no apostrophe class, so it never sees one.
    if (c == "'") return 0.15;
    if (c == prev || c == next) return 0.45; // litle → little
    if (c == 'h' && prev.isNotEmpty && 'cstwgpr'.contains(prev)) {
      return 0.55; // scool → school, wen → when
    }
    if (c == 'u' && prev == 'q') return 0.4;
    if (c == 'e' && k == m - 1 && m > 2) return 0.5; // hav → have
    if (c == 't' && next == 'c' && k + 2 < m && intended[k + 2] == 'h') {
      return 0.5; // wach → watch
    }
    if (c == 'c' && next == 'k') return 0.45; // bak → back
    if (k == 0 && ((c == 'k' && next == 'n') || (c == 'w' && next == 'r'))) {
      return 0.5; // nife → knife, rite → write
    }
    if (c == 'b' && prev == 'm' && k == m - 1) return 0.5; // clim → climb
    if (c == 'g' && next == 'h') return 0.6; // nite → night
    if (c == 'l' && prev == 'a' && next.isNotEmpty && 'kfm'.contains(next)) {
      return 0.6; // wak → walk, haf → half
    }
    if (_isVowel(c)) return 0.75; // frend → friend
    return 1.0;
  }

  /// Cost of a letter in the writing at [i] that the intended word lacks.
  static double _deletion(String observed, int i) {
    final o = observed[i];
    final n = observed.length;
    final prev = i > 0 ? observed[i - 1] : '';
    final next = i + 1 < n ? observed[i + 1] : '';
    if (o == prev || o == next) return 0.45; // helllo → hello
    // German "sch" for English "sh".
    if (o == 'c' && prev == 's' && next == 'h') return 0.5;
    if (o == 'e' && i == n - 1 && n > 2) return 0.6; // hade → had
    if (_isVowel(o)) return 0.8;
    return 1.0;
  }

  /// Cost of [observed] written or recognized for [intended], where the
  /// recognizer read [observed] with [confidence].
  static double _substitution(
      String intended, String observed, double confidence) {
    final key = _pairKey(intended, observed);
    // Arbitrary replacements barely depend on the confidence.
    var cost = 0.8 + 0.2 * confidence;
    final looks = _lookAlike[key];
    if (looks != null) cost = math.min(cost, looks * (0.3 + 0.7 * confidence));
    final sounds = _soundAlike[key];
    if (sounds != null) cost = math.min(cost, sounds);
    return cost;
  }

  static String _pairKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a$b' : '$b$a';

  static Map<String, double> _symmetric(Map<String, double> pairs) => {
        for (final e in pairs.entries) _pairKey(e.key[0], e.key[1]): e.value,
      };

  /// Letters that look alike in handwriting or to the character model.
  static final Map<String, double> _lookAlike = _symmetric(const {
    'ao': 0.5, 'ad': 0.6, 'au': 0.6, 'aq': 0.7, 'ae': 0.6, 'bh': 0.6,
    'bd': 0.55, 'bk': 0.7, 'bp': 0.6, 'ce': 0.5, 'co': 0.55, 'cr': 0.7,
    'el': 0.65, 'eo': 0.6, 'ei': 0.6, 'ft': 0.55, 'fl': 0.7, 'gq': 0.5,
    'gy': 0.55, 'gj': 0.6, 'hn': 0.5, 'hk': 0.55, 'il': 0.45, 'ij': 0.5,
    'it': 0.7, 'ir': 0.7, 'kx': 0.7, 'lt': 0.6, 'mn': 0.5, 'mw': 0.65,
    'nr': 0.55, 'nu': 0.55, 'ou': 0.6, 'oq': 0.7, 'pq': 0.55, 'rv': 0.55,
    'uv': 0.45, 'uy': 0.7, 'uw': 0.7, 'vy': 0.6, 'vw': 0.6, 'xy': 0.7,
    'yj': 0.6,
    // Digits read for letters.
    '0o': 0.3, '1l': 0.35, '1i': 0.35, '17': 0.6, '2z': 0.35, '4a': 0.6,
    '5s': 0.35, '6b': 0.4, '6g': 0.5, '7t': 0.5, '8b': 0.5, '8s': 0.7,
    '9g': 0.4, '9q': 0.45,
  });

  /// Letters that sound alike, a common source of children's mistakes.
  static final Map<String, double> _soundAlike = _symmetric({
    'ck': 0.5,
    'cs': 0.6,
    'kq': 0.6,
    'cq': 0.7,
    'sz': 0.6,
    'fv': 0.6,
    'dt': 0.6,
    'bp': 0.6,
    'gj': 0.6,
    'gk': 0.75,
    'mn': 0.5,
    'vw': 0.6,
    'iy': 0.6,
    'ey': 0.7,
    for (final a in 'aeiou'.split(''))
      for (final b in 'aeiou'.split(''))
        if (a.compareTo(b) < 0) '$a$b': 0.65,
  });

  /// intended letter → {two letters the recognizer read for it: cost}.
  static const Map<String, Map<String, double>> _readAsTwo = {
    'm': {'rn': 0.45, 'nn': 0.6, 'iu': 0.7, 'ni': 0.7},
    'w': {'vv': 0.4, 'uu': 0.6},
    'd': {'cl': 0.45},
    'u': {'ii': 0.6},
    'h': {'li': 0.6},
    'k': {'lc': 0.7},
  };

  /// intended letter → {two letters written for it: cost}.
  static const Map<String, Map<String, double>> _writtenAsTwo = {
    'x': {'ks': 0.5, 'cs': 0.6},
  };

  /// two intended letters → {one letter the recognizer read for them}.
  static const Map<String, Map<String, double>> _readAsOne = {
    'rn': {'m': 0.6},
    'cl': {'d': 0.6},
  };

  /// two intended letters → {one letter written for them: cost}.
  static const Map<String, Map<String, double>> _writtenAsOne = {
    'ph': {'f': 0.45},
    'ck': {'k': 0.4, 'c': 0.45},
    'ks': {'x': 0.6},
  };
}
