import '../models/word_box.dart';

/// Aligns a recognized word with a proposed correction.
class SpellingFeedback {
  static Set<int> changedCharacters(String recognized, String correction) {
    final source = recognized.toLowerCase();
    final target = correction.toLowerCase();
    var index = 0;
    while (index < source.length &&
        index < target.length &&
        source[index] == target[index]) {
      // An extra repeated character is the first visible error even though
      // the duplicated character itself still matches at this position.
      if (index + 1 < source.length &&
          source[index] == source[index + 1] &&
          (index + 1 >= target.length ||
              source[index + 1] != target[index + 1])) {
        return {index};
      }
      index++;
    }

    // The target may contain an inserted letter. There is no ink for that
    // letter, so mark the first existing character that is displaced by it.
    if (index < source.length) return {index};
    return <int>{};
  }

  /// For each character of [newText], the index of the character of
  /// [oldText] it corresponds to, or null if it was inserted. Uses a
  /// minimal (case-insensitive) edit alignment; on ties, characters are
  /// paired by position.
  static List<int?> align(String oldText, String newText) {
    final a = oldText.toLowerCase();
    final b = newText.toLowerCase();
    final n = a.length, m = b.length;
    final d = List.generate(n + 1, (i) => List<int>.filled(m + 1, 0));
    for (var i = 0; i <= n; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= m; j++) {
      d[0][j] = j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final pair = d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
        final delete = d[i - 1][j] + 1;
        final insert = d[i][j - 1] + 1;
        d[i][j] = pair < delete
            ? (pair < insert ? pair : insert)
            : (delete < insert ? delete : insert);
      }
    }
    final result = List<int?>.filled(m, null);
    var i = n, j = m;
    while (i > 0 && j > 0) {
      if (d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) {
        result[j - 1] = i - 1;
        i--;
        j--;
      } else if (d[i][j] == d[i - 1][j] + 1) {
        i--;
      } else {
        j--;
      }
    }
    return result;
  }

  /// [word] with its text changed to [newText], keeping the ink of every
  /// character that is still there (substituted letters keep their ink;
  /// inserted letters have none).
  static List<CharacterResult> realignCharacters(WordBox word, String newText) {
    final oldText = word.characters.map((c) => c.char).join();
    final mapping = align(oldText, newText);
    return [
      for (var j = 0; j < newText.length; j++)
        mapping[j] == null
            ? CharacterResult(
                char: newText[j],
                bbox: const [],
                contour: const [],
                confidence: 1.0)
            : word.characters[mapping[j]!].withChar(newText[j]),
    ];
  }
}
