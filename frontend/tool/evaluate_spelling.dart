// Measures how often the spell checker ranks the intended word first on
// corpora of real misspellings, compares it with the previous plain
// edit-distance ranking, and searches the ranking weights.
//
// The corpora are not part of the repository (research use):
//   https://www.dcs.bbk.ac.uk/~ROGER/holbrook-tagged.dat  (children's
//       writing; misspellings tagged in their sentences)
//   https://www.dcs.bbk.ac.uk/~ROGER/missp.dat           (Birkbeck)
//   https://norvig.com/spell-testset1.txt, spell-testset2.txt
//
// Usage (from frontend/):
//   dart run tool/evaluate_spelling.dart --holbrook holbrook-tagged.dat \
//       [--birkbeck missp.dat] [--norvig spell-testset1.txt] [--baseline] [--grid]
import 'dart:io';
import 'dart:math' as math;

import 'package:groundink/services/spelling/error_model.dart';
import 'package:groundink/services/spelling/language_model.dart';
import 'package:groundink/services/spelling/spell_checker.dart';

class Item {
  final String observed;
  final String target;
  final String? previous;
  final String? next;
  Item(this.observed, this.target, {this.previous, this.next});
}

/// Per-candidate values that do not depend on the weights.
class Features {
  final List<String> words;
  final List<double> edit;
  final List<double> subtitles;
  final List<double?> books;
  final List<double> previous;
  final List<double> next;
  Features(this.words, this.edit, this.subtitles, this.books, this.previous,
      this.next);
}

final _word = RegExp(r"[A-Za-z']+");
final _err = RegExp(r'<ERR targ=([^>]*)>\s*(.*?)\s*</ERR>');

List<Item> readHolbrook(String path, LanguageModel model, SpellChecker sc) {
  final items = <Item>[];
  final passages = <List<(String, String?)>>[]; // (token, target if error)
  var current = <(String, String?)>[];
  for (final line in File(path).readAsLinesSync()) {
    if (RegExp(r'^\s*\d+\.\s*$').hasMatch(line)) {
      if (current.isNotEmpty) passages.add(current);
      current = [];
      continue;
    }
    var rest = line;
    while (true) {
      final match = _err.firstMatch(rest);
      final plain = match == null ? rest : rest.substring(0, match.start);
      for (final t in _word.allMatches(plain)) {
        current.add((t.group(0)!, null));
      }
      if (match == null) break;
      final target = match.group(1)!.trim();
      final written = match.group(2)!.trim();
      final parts = _word.allMatches(written).map((m) => m.group(0)!).toList();
      if (parts.length == 1) {
        current.add((parts.single, target));
      } else {
        for (final p in parts) {
          current.add((p, '?'));
        }
      }
      rest = rest.substring(match.end);
    }
  }
  if (current.isNotEmpty) passages.add(current);

  for (final tokens in passages) {
    for (var i = 0; i < tokens.length; i++) {
      final (written, target) = tokens[i];
      if (target == null || target == '?') continue;
      final t = target.toLowerCase();
      if (!RegExp(r"^[a-z']+$").hasMatch(t) || !model.contains(t)) continue;
      if (sc.isCorrect(written)) continue; // real-word errors: not flagged
      items.add(Item(written, t,
          previous: i > 0 ? tokens[i - 1].$1 : null,
          next: i + 1 < tokens.length ? tokens[i + 1].$1 : null));
    }
  }
  return items;
}

List<Item> readBirkbeck(String path, LanguageModel model, SpellChecker sc,
    {int sample = 4000}) {
  final all = <Item>[];
  String? target;
  for (final line in File(path).readAsLinesSync()) {
    final s = line.trim();
    if (s.isEmpty) continue;
    if (s.startsWith(r'$')) {
      target = s.substring(1).toLowerCase();
      continue;
    }
    if (target == null || !model.contains(target)) continue;
    if (!RegExp(r'^[A-Za-z]+$').hasMatch(s) || sc.isCorrect(s)) continue;
    all.add(Item(s, target));
  }
  all.shuffle(math.Random(1));
  return all.take(sample).toList();
}

List<Item> readNorvig(String path, LanguageModel model, SpellChecker sc) {
  final items = <Item>[];
  for (final line in File(path).readAsLinesSync()) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final target = line.substring(0, colon).trim().toLowerCase();
    if (!model.contains(target)) continue;
    for (final w in line.substring(colon + 1).trim().split(RegExp(r'\s+'))) {
      if (w.isEmpty || sc.isCorrect(w)) continue;
      items.add(Item(w, target));
    }
  }
  return items;
}

Features features(Item item, SpellChecker sc, ErrorModel em) {
  final model = sc.model;
  final lower = item.observed.toLowerCase();
  final prevId =
      item.previous == null ? null : model.idOf(item.previous!.toLowerCase());
  final nextId =
      item.next == null ? null : model.idOf(item.next!.toLowerCase());
  final words = <String>[];
  final edit = <double>[], sub = <double>[], prev = <double>[];
  final next = <double>[];
  final books = <double?>[];
  for (final id in sc.candidates(lower)) {
    if (!model.isSuggestible(id)) continue;
    final w = model.words[id];
    words.add(w);
    edit.add(em.cost(lower, w));
    sub.add(model.logPrior(id));
    books.add(model.logPriorBooks(id));
    prev.add(prevId == null ? 0 : model.association(prevId, id));
    next.add(nextId == null ? 0 : model.association(id, nextId));
  }
  return Features(words, edit, sub, books, prev, next);
}

/// Same formula as SpellChecker.suggest, on precomputed features.
double scoreOf(Features f, int i, SpellingWeights w) {
  final books = f.books[i];
  final prior = w.booksPrior == 0 || books == null
      ? f.subtitles[i]
      : (1 - w.booksPrior) * f.subtitles[i] + w.booksPrior * books;
  final ctx = f.previous[i].clamp(w.contextMin, w.contextMax) +
      f.next[i].clamp(w.contextMin, w.contextMax);
  return -w.edit * f.edit[i] + prior + w.context * ctx;
}

/// Rank of the target (0-based) under [w], or -1 if not a candidate.
int rankOf(Item item, Features f, SpellingWeights w) {
  final targetIndex = f.words.indexOf(item.target);
  if (targetIndex < 0) return -1;
  double score(int i) => scoreOf(f, i, w);

  final targetScore = score(targetIndex);
  var rank = 0;
  for (var i = 0; i < f.words.length; i++) {
    if (i == targetIndex) continue;
    final s = score(i);
    // Ties count against the target.
    if (s > targetScore || (s == targetScore && i < targetIndex)) rank++;
  }
  return rank;
}

/// The ranking the app used before: plain edit distance, ties in
/// dictionary (alphabetical) order.
int baselineRank(Item item, LanguageModel model) {
  final lower = item.observed.toLowerCase();
  final scored = <(int, int)>[];
  for (var id = 0; id < model.length; id++) {
    final w = model.words[id];
    if ((w.length - lower.length).abs() > 2) continue;
    final d = levenshtein(lower, w);
    if (d <= 2) scored.add((d, id));
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  for (var r = 0; r < scored.length; r++) {
    if (model.words[scored[r].$2] == item.target) return r;
  }
  return -1;
}

int levenshtein(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      cur[j] = math.min(math.min(prev[j] + 1, cur[j - 1] + 1),
          prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

String summarize(String label, List<int> ranks) {
  final n = ranks.length;
  String pct(int k) =>
      (100 * ranks.where((r) => r >= 0 && r < k).length / n).toStringAsFixed(1);
  final found = ranks.where((r) => r >= 0).length;
  return '${label.padRight(34)} top1 ${pct(1).padLeft(5)}%  '
      'top3 ${pct(3).padLeft(5)}%  top5 ${pct(5).padLeft(5)}%  '
      '(target among candidates: ${(100 * found / n).toStringAsFixed(1)}%, '
      'n=$n)';
}

void main(List<String> args) {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final model = LanguageModel.fromGzip(
      File(arg('--model') ?? 'assets/models/english_lm.bin.gz')
          .readAsBytesSync());
  final sc = SpellChecker(model);
  const em = ErrorModel();

  final sets = <String, List<Item>>{};
  final holbrook = arg('--holbrook');
  if (holbrook != null) sets['holbrook'] = readHolbrook(holbrook, model, sc);
  final birkbeck = arg('--birkbeck');
  if (birkbeck != null) sets['birkbeck'] = readBirkbeck(birkbeck, model, sc);
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--norvig' && i + 1 < args.length) {
      sets
          .putIfAbsent('norvig', () => [])
          .addAll(readNorvig(args[i + 1], model, sc));
    }
  }

  final clock = Stopwatch()..start();
  final feats = {
    for (final e in sets.entries)
      e.key: [for (final it in e.value) features(it, sc, em)]
  };
  stdout.writeln('features: ${clock.elapsedMilliseconds} ms for '
      '${feats.values.fold<int>(0, (s, l) => s + l.length)} items');

  final configs = <String, SpellingWeights?>{
    if (args.contains('--baseline')) 'edit distance (before)': null,
    'P(w) + error model': const SpellingWeights(context: 0),
    'P(w) + error model + context': const SpellingWeights(),
  };
  for (final e in sets.entries) {
    stdout.writeln('\n== ${e.key}');
    for (final c in configs.entries) {
      final ranks = c.value == null
          ? [for (final it in e.value) baselineRank(it, model)]
          : [
              for (var i = 0; i < e.value.length; i++)
                rankOf(e.value[i], feats[e.key]![i], c.value!)
            ];
      stdout.writeln(summarize(c.key, ranks));
    }
  }

  // How far below the best suggestion the intended word scores when it is
  // ranked 2nd-5th; guides SpellingWeights.maxGap.
  const defaults = SpellingWeights();
  for (final e in sets.entries) {
    final gaps = <double>[];
    final kept = <double, int>{6: 0, 8: 0, 10: 0, 12: 0, 15: 0};
    for (var i = 0; i < e.value.length; i++) {
      final f = feats[e.key]![i];
      if (f.words.isEmpty) continue;
      final scores = [
        for (var j = 0; j < f.words.length; j++) scoreOf(f, j, defaults)
      ]..sort((a, b) => b.compareTo(a));
      for (final g in kept.keys) {
        kept[g] = kept[g]! +
            scores.take(5).where((s) => scores.first - s <= g).length;
      }
      final r = rankOf(e.value[i], f, defaults);
      if (r >= 1 && r < 5) {
        gaps.add(scores.first -
            scoreOf(f, f.words.indexOf(e.value[i].target), defaults));
      }
    }
    gaps.sort();
    String q(double p) => gaps.isEmpty
        ? '-'
        : gaps[((gaps.length - 1) * p).round()].toStringAsFixed(1);
    stdout.writeln('\n${e.key}: gap of intended word ranked 2-5: '
        'median ${q(0.5)}, p90 ${q(0.9)}, p98 ${q(0.98)}, max ${q(1)}');
    stdout.writeln('  suggestions shown per word (max 5) by maxGap: '
        '${kept.entries.map((k) => '${k.key}: ${(k.value / e.value.length).toStringAsFixed(2)}').join(', ')}');
  }

  // The production code path must rank exactly like the features above.
  final checkItems = (sets['holbrook'] ?? sets.values.first).take(300);
  var mismatches = 0;
  for (final it in checkItems) {
    final top = sc.suggest(it.observed, previous: it.previous, next: it.next);
    final f = features(it, sc, em);
    final r = rankOf(it, f, defaults);
    final topIsTarget = top.isNotEmpty && top.first.word == it.target;
    if (topIsTarget != (r == 0)) mismatches++;
  }
  stdout.writeln('\nSpellChecker.suggest vs. evaluation: $mismatches '
      'mismatches in ${checkItems.length} items');

  if (args.contains('--grid')) {
    final tune = sets['holbrook'] ?? sets.values.first;
    final tuneFeats = feats['holbrook'] ?? feats.values.first;
    var best = (-1.0, const SpellingWeights());
    for (final edit in [4.0, 5.0, 6.0, 7.0, 8.0, 9.0]) {
      for (final books in [0.0, 0.25, 0.5]) {
        for (final context in [0.0, 0.5, 0.7, 1.0, 1.3, 1.6]) {
          for (final cmax in [3.0, 5.0, 8.0]) {
            for (final cmin in [-1.5, -3.0, -5.0]) {
              final w = SpellingWeights(
                  edit: edit,
                  booksPrior: books,
                  context: context,
                  contextMax: cmax,
                  contextMin: cmin);
              var hits = 0.0;
              for (var i = 0; i < tune.length; i++) {
                final r = rankOf(tune[i], tuneFeats[i], w);
                if (r == 0) hits += 1;
                if (r >= 0 && r < 3) hits += 0.2; // tie-break toward top3
              }
              if (hits > best.$1) {
                best = (hits, w);
                stdout.writeln('edit $edit books $books context $context '
                    'cmax $cmax cmin $cmin -> ${hits.toStringAsFixed(1)}');
              }
            }
          }
        }
      }
    }
    final w = best.$2;
    for (final e in sets.entries) {
      final ranks = [
        for (var i = 0; i < e.value.length; i++)
          rankOf(e.value[i], feats[e.key]![i], w)
      ];
      stdout.writeln(summarize('best on holbrook -> ${e.key}', ranks));
    }
  }
}
