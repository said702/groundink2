import 'dart:math' as math;
import 'dart:typed_data';

import 'error_model.dart';
import 'language_model.dart';

/// Tuning of [SpellChecker]'s ranking. The defaults were chosen on the
/// Holbrook corpus of children's writing (see tool/evaluate_spelling.dart).
class SpellingWeights {
  /// Log-probability lost per unit of [ErrorModel] cost.
  final double edit;

  /// Share of the Google Books word frequency in the word prior; the rest
  /// comes from subtitle frequencies.
  final double booksPrior;

  /// Weight of the neighboring words.
  final double context;

  /// Each neighbor's association is clamped to this range.
  final double contextMin;
  final double contextMax;

  /// Suggestions scoring this much below the best one are dropped.
  final double maxGap;

  const SpellingWeights({
    this.edit = 7.0,
    this.booksPrior = 0.25,
    this.context = 1.0,
    this.contextMin = -3.0,
    this.contextMax = 5.0,
    this.maxGap = 10.0,
  });
}

/// A ranked spelling suggestion.
class Suggestion {
  final String word;

  /// ln of the (unnormalized) probability of [word] being meant.
  final double score;

  const Suggestion(this.word, this.score);

  @override
  String toString() => '$word (${score.toStringAsFixed(2)})';
}

/// Offline spell checker for handwritten words.
///
/// Ranks dictionary words w for a recognized spelling o with a noisy-channel
/// model: P(w | o, context) ∝ P(o | w) · P(w) · context(w), where
/// * P(o | w) comes from [ErrorModel] (children's mistakes and recognition
///   errors, using the recognizer's per-letter confidence),
/// * P(w) is the word frequency,
/// * context(w) rewards words that often follow the previous word and
///   precede the next one (and penalizes unusual word pairs).
class SpellChecker {
  final LanguageModel model;
  final ErrorModel errorModel;
  final SpellingWeights weights;

  final Uint8List _lengths;
  final Int32List _masks;
  final Map<String, List<int>> _candidateCache = {};

  SpellChecker(
    this.model, {
    this.errorModel = const ErrorModel(),
    this.weights = const SpellingWeights(),
  })  : _lengths = Uint8List(model.length),
        _masks = Int32List(model.length) {
    for (var i = 0; i < model.length; i++) {
      final word = model.words[i];
      _lengths[i] = math.min(word.length, 255);
      _masks[i] = _letterMask(word);
    }
  }

  /// Whether [word] is a dictionary word (in any letter case).
  bool isCorrect(String word) {
    final lower = word.trim().toLowerCase();
    return lower.isEmpty || model.contains(lower);
  }

  /// Ranked corrections for the recognized spelling [observed].
  ///
  /// [confidences] are the recognizer's per-character confidences of
  /// [observed]. [previous] and [next] are the neighboring words in reading
  /// order (ignored unless they are dictionary words).
  List<Suggestion> suggest(
    String observed, {
    List<double>? confidences,
    String? previous,
    String? next,
    int limit = 5,
  }) {
    final lower = observed.trim().toLowerCase();
    if (lower.isEmpty) return const [];
    if (confidences != null && confidences.length != lower.length) {
      confidences = null;
    }
    final previousId =
        previous == null ? null : model.idOf(previous.toLowerCase());
    final nextId = next == null ? null : model.idOf(next.toLowerCase());
    final w = weights;

    final scored = <Suggestion>[];
    for (final id in candidates(lower)) {
      if (!model.isSuggestible(id)) continue;
      final word = model.words[id];
      final editCost = errorModel.cost(lower, word, confidences: confidences);
      var score = -w.edit * editCost + _logPrior(id);
      if (w.context != 0) {
        var context = 0.0;
        if (previousId != null) {
          context += model
              .association(previousId, id)
              .clamp(w.contextMin, w.contextMax);
        }
        if (nextId != null) {
          context +=
              model.association(id, nextId).clamp(w.contextMin, w.contextMax);
        }
        score += w.context * context;
      }
      scored.add(Suggestion(word, score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.isEmpty) return const [];
    final best = scored.first.score;
    return [
      for (final s in scored.take(limit))
        if (best - s.score <= w.maxGap) s,
    ];
  }

  double _logPrior(int id) {
    final subtitles = model.logPrior(id);
    final share = weights.booksPrior;
    if (share == 0) return subtitles;
    final books = model.logPriorBooks(id);
    if (books == null) return subtitles;
    return (1 - share) * subtitles + share * books;
  }

  /// Dictionary ids within plain edit distance 2 (3 for words of 8+
  /// letters) of [lower]. Cached per spelling.
  List<int> candidates(String lower) {
    final cached = _candidateCache[lower];
    if (cached != null) return cached;
    final maxDistance = lower.length >= 8 ? 3 : 2;
    final length = lower.length;
    final mask = _letterMask(lower);
    final found = <int>[];
    final words = model.words;
    for (var i = 0; i < words.length; i++) {
      if ((_lengths[i] - length).abs() > maxDistance) continue;
      // One edit changes at most two bits of the letter-presence mask.
      if (_bitCount(_masks[i] ^ mask) > 2 * maxDistance) continue;
      if (_withinDistance(lower, words[i], maxDistance)) found.add(i);
    }
    if (_candidateCache.length > 2000) _candidateCache.clear();
    return _candidateCache[lower] = found;
  }

  /// Bit set of the characters in [s] (bits 0-29, so values stay positive in
  /// an Int32List; collisions only make the filter weaker, never wrong).
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

  Int32List _bandPrev = Int32List(0), _bandCur = Int32List(0);

  /// Whether the Levenshtein distance of [s1] and [s2] is at most [k].
  /// Only computes the diagonal band |i - j| <= k.
  bool _withinDistance(String s1, String s2, int k) {
    const inf = 1 << 20;
    final n = s1.length, m = s2.length;
    if ((n - m).abs() > k) return false;
    if (n == 0 || m == 0) return math.max(n, m) <= k;
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
      if (hi + 1 <= m) cur[hi + 1] = inf;
      if (rowMin > k) return false;
      final swap = prev;
      prev = cur;
      cur = swap;
    }
    return prev[m] <= k;
  }
}
