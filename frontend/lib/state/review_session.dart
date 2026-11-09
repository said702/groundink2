import 'package:flutter/foundation.dart';

import '../models/word_box.dart';

/// One recognized word and what the user decided about it.
class ReviewEntry {
  /// Stable id: the word's position in reading order.
  final int id;

  /// The recognized word; replaced when the user corrects it.
  WordBox word;

  /// The correction the user picked or typed; null means the best
  /// suggestion.
  String? _target;

  /// Whether the user removed this mistake from the review.
  bool dismissed = false;

  ReviewEntry(this.id, this.word);

  /// Whether the word is (still) a spelling mistake.
  bool get isMistake => !word.isCorrect;

  /// Whether the mistake is shown in the review.
  bool get isOpen => isMistake && !dismissed;

  /// The intended word the handwriting is compared with.
  String? get correction =>
      _target ?? (word.suggestions.isEmpty ? null : word.suggestions.first);
}

/// Review state of one scan: which mistakes are open, which one is shown,
/// the chosen corrections, and removed mistakes.
class ReviewSession extends ChangeNotifier {
  final List<ReviewEntry> entries;
  int? _selectedId;

  ReviewSession(List<WordBox> words)
      : entries = [
          for (var i = 0; i < words.length; i++) ReviewEntry(i, words[i])
        ] {
    final open = openMistakes;
    _selectedId = open.isEmpty ? null : open.first.id;
  }

  /// Mistakes still to review, in reading order.
  List<ReviewEntry> get openMistakes => [
        for (final e in entries)
          if (e.isOpen) e
      ];

  int get dismissedCount =>
      entries.where((e) => e.isMistake && e.dismissed).length;

  /// The mistake currently shown, or null when none is open.
  ReviewEntry? get current {
    final id = _selectedId;
    if (id == null) return null;
    final entry = entries[id];
    return entry.isOpen ? entry : null;
  }

  /// Position of [current] in [openMistakes], or -1.
  int get currentIndex {
    final id = current?.id;
    return id == null ? -1 : openMistakes.indexWhere((e) => e.id == id);
  }

  ReviewEntry entry(int id) => entries[id];

  /// Shows the open mistake at [index] of [openMistakes].
  void showIndex(int index) {
    final open = openMistakes;
    if (open.isEmpty) return;
    _select(open[index.clamp(0, open.length - 1)].id);
  }

  /// Shows the mistake [id] if it is open; returns whether it is.
  bool show(int id) {
    if (!entries[id].isOpen) return false;
    _select(id);
    return true;
  }

  bool get hasNext =>
      currentIndex >= 0 && currentIndex < openMistakes.length - 1;
  bool get hasPrevious => currentIndex > 0;

  void next() {
    if (hasNext) showIndex(currentIndex + 1);
  }

  void previous() {
    if (hasPrevious) showIndex(currentIndex - 1);
  }

  /// Uses [target] as the intended word of [id].
  void chooseCorrection(int id, String target) {
    entries[id]._target = target;
    notifyListeners();
  }

  /// Removes mistake [id] from the review and shows the next one (or the
  /// previous one if it was the last).
  void dismiss(int id) {
    final entry = entries[id];
    if (!entry.isMistake || entry.dismissed) return;
    final wasShown = current?.id == id;
    final index = openMistakes.indexWhere((e) => e.id == id);
    entry.dismissed = true;
    if (wasShown) {
      final open = openMistakes;
      _selectedId =
          open.isEmpty ? null : open[index.clamp(0, open.length - 1)].id;
    }
    notifyListeners();
  }

  /// Puts a removed mistake back into the review and shows it.
  void restore(int id) {
    final entry = entries[id];
    if (!entry.dismissed) return;
    entry.dismissed = false;
    _select(id, notify: false);
    notifyListeners();
  }

  /// Puts all removed mistakes back.
  void restoreAll() {
    for (final e in entries) {
      e.dismissed = false;
    }
    _selectedId ??= openMistakes.isEmpty ? null : openMistakes.first.id;
    notifyListeners();
  }

  /// Replaces word [id] after the user corrected it. [target] is the
  /// intended word (null: the best suggestion). A word that becomes a
  /// mistake is shown; one that becomes correct leaves the review.
  void update(int id, WordBox word, {String? target}) {
    final entry = entries[id];
    final wasShown = current?.id == id;
    final index = openMistakes.indexWhere((e) => e.id == id);
    entry
      ..word = word
      .._target = target
      ..dismissed = false;
    if (entry.isOpen) {
      _selectedId = id;
    } else if (wasShown) {
      final open = openMistakes;
      _selectedId =
          open.isEmpty ? null : open[index.clamp(0, open.length - 1)].id;
    }
    notifyListeners();
  }

  void _select(int id, {bool notify = true}) {
    if (_selectedId == id) return;
    _selectedId = id;
    if (notify) notifyListeners();
  }
}
