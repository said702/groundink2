import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'image_preprocessor.dart';

/// Finds the ink of each recognized letter, so that a wrong letter can be
/// colored.
class CharacterInk {
  /// Brightest gray value that still counts as ink.
  static const maxThreshold = 200;

  /// A letter without ink of its own starts from its ink at most this far
  /// from its box centre (as a share of the half box size).
  static const coreDistance = 0.6;

  /// The ink of each letter of a word, one list per box of [boxes], as
  /// horizontal runs `[x, y, length]` in image coordinates.
  ///
  /// Inside its box, a letter's ink is what is at most as bright as the
  /// box's Otsu threshold (at most [maxThreshold]). Boxes of neighboring
  /// letters often overlap, for example a wide "f" reaches over its
  /// neighbors; coloring all ink inside the box would then also color parts
  /// of them. So every ink pixel goes to one letter only:
  ///
  /// 1. Ink inside exactly one box belongs to that letter. A letter without
  ///    such ink starts from its ink near its box centre.
  /// 2. From there each letter grows along its strokes, darkest pixels
  ///    first. Where the strokes of two letters touch, the border falls on
  ///    the lightest point of the connection.
  /// 3. Ink no letter grows into (an i dot, a broken stroke) goes as a whole
  ///    to the box most of it lies most central in.
  ///
  /// On 28844 letters with known outlines (CharLoc words the character model
  /// was not trained on) this colors 88.0% instead of 71.1% of the letters
  /// right: at most 5% of the colored ink belongs to another letter, and at
  /// least 90% of the letter is colored.
  static List<List<List<int>>> extractAll(
      img.Image image, List<List<int>> boxes) {
    final n = boxes.length;
    final runs = List.generate(n, (_) => <List<int>>[]);

    // Boxes clipped to the image, and the region they cover.
    final bx1 = Int32List(n), by1 = Int32List(n);
    final bx2 = Int32List(n), by2 = Int32List(n);
    var rx1 = image.width, ry1 = image.height, rx2 = 0, ry2 = 0;
    for (var i = 0; i < n; i++) {
      final b = boxes[i];
      bx1[i] = b[0].clamp(0, image.width);
      by1[i] = b[1].clamp(0, image.height);
      bx2[i] = b[2].clamp(0, image.width);
      by2[i] = b[3].clamp(0, image.height);
      if (bx2[i] <= bx1[i] || by2[i] <= by1[i]) continue;
      rx1 = math.min(rx1, bx1[i]);
      ry1 = math.min(ry1, by1[i]);
      rx2 = math.max(rx2, bx2[i]);
      ry2 = math.max(ry2, by2[i]);
    }
    if (rx2 <= rx1 || ry2 <= ry1) return runs;
    // One pixel more on each side, so that smoothing sees the real
    // neighbors at the box edges.
    rx1 = math.max(0, rx1 - 1);
    ry1 = math.max(0, ry1 - 1);
    rx2 = math.min(image.width, rx2 + 1);
    ry2 = math.min(image.height, ry2 + 1);
    final w = rx2 - rx1, h = ry2 - ry1, size = w * h;
    for (var i = 0; i < n; i++) {
      bx1[i] -= rx1;
      bx2[i] -= rx1;
      by1[i] -= ry1;
      by2[i] -= ry1;
    }

    final gray = Uint8List(size);
    final region = img.grayscale(
        img.copyCrop(image, x: rx1, y: ry1, width: w, height: h));
    for (final p in region) {
      gray[p.y * w + p.x] = p.r.toInt().clamp(0, 255);
    }

    // Ink of each box, how many boxes cover each pixel, and the box each
    // pixel lies most central in.
    final ink = Uint8List(size);
    final covered = Uint8List(size);
    final central = Int32List(size)..fillRange(0, size, -1);
    final centrality = Float64List(size)..fillRange(0, size, double.infinity);
    final hist = Int32List(256);
    for (var i = 0; i < n; i++) {
      final x1 = bx1[i], y1 = by1[i], x2 = bx2[i], y2 = by2[i];
      if (x2 <= x1 || y2 <= y1) continue;
      hist.fillRange(0, 256, 0);
      for (var y = y1; y < y2; y++) {
        for (var x = x1; x < x2; x++) {
          hist[gray[y * w + x]]++;
        }
      }
      final threshold = math.min(
          ImagePreprocessor.otsuOfHistogram(hist, (x2 - x1) * (y2 - y1)),
          maxThreshold);
      final cx = (x1 + x2) / 2, cy = (y1 + y2) / 2;
      final hw = math.max(0.5, (x2 - x1) / 2), hh = math.max(0.5, (y2 - y1) / 2);
      for (var y = y1; y < y2; y++) {
        final dy = (y + 0.5 - cy) / hh;
        for (var x = x1; x < x2; x++) {
          final k = y * w + x;
          final dx = (x + 0.5 - cx) / hw;
          final c = dx * dx + dy * dy;
          if (gray[k] <= threshold) ink[k] = 1;
          if (covered[k] < 255) covered[k]++;
          if (c < centrality[k]) {
            centrality[k] = c;
            central[k] = i;
          }
        }
      }
    }

    // 1. Seeds.
    final label = Int32List(size)..fillRange(0, size, -1);
    final seeded = List<bool>.filled(n, false);
    for (var k = 0; k < size; k++) {
      if (ink[k] == 1 && covered[k] == 1) {
        label[k] = central[k];
        seeded[central[k]] = true;
      }
    }
    const core = coreDistance * coreDistance;
    for (var k = 0; k < size; k++) {
      if (ink[k] == 1 && label[k] < 0 && !seeded[central[k]] &&
          centrality[k] <= core) {
        label[k] = central[k];
      }
    }

    // 2. Grow along the ink, darkest first; a queue per brightness level of
    // the gray values smoothed with 1 2 1, first come first served.
    final level = _blur121(gray, w, h);
    final next = Int32List(size);
    final head = Int32List(256)..fillRange(0, 256, -1);
    final tail = Int32List(256)..fillRange(0, 256, -1);
    void push(int k, int l) {
      next[k] = -1;
      if (tail[l] < 0) {
        head[l] = k;
      } else {
        next[tail[l]] = k;
      }
      tail[l] = k;
    }

    for (var k = 0; k < size; k++) {
      if (label[k] >= 0) push(k, level[k]);
    }
    for (var l = 0; l < 256; l++) {
      while (head[l] >= 0) {
        final k = head[l];
        head[l] = next[k];
        if (head[l] < 0) tail[l] = -1;
        final x = k % w, y = k ~/ w, owner = label[k];
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if ((dx == 0 && dy == 0) || nx < 0 || nx >= w) continue;
            final q = ny * w + nx;
            if (ink[q] == 1 && label[q] < 0) {
              label[q] = owner;
              push(q, math.max(l, level[q]));
            }
          }
        }
      }
    }

    // 3. Loose ink: each 8-connected piece to the box most of it is most
    // central in.
    final piece = Int32List(size);
    final votes = Int32List(n);
    for (var start = 0; start < size; start++) {
      if (ink[start] != 1 || label[start] != -1) continue;
      var count = 0;
      piece[count++] = start;
      label[start] = -2;
      for (var j = 0; j < count; j++) {
        final k = piece[j];
        final x = k % w, y = k ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if ((dx == 0 && dy == 0) || nx < 0 || nx >= w) continue;
            final q = ny * w + nx;
            if (ink[q] == 1 && label[q] == -1) {
              label[q] = -2;
              piece[count++] = q;
            }
          }
        }
      }
      votes.fillRange(0, n, 0);
      for (var j = 0; j < count; j++) {
        votes[central[piece[j]]]++;
      }
      var owner = 0;
      for (var i = 1; i < n; i++) {
        if (votes[i] > votes[owner]) owner = i;
      }
      for (var j = 0; j < count; j++) {
        label[piece[j]] = owner;
      }
    }

    // Each letter's ink inside its box, as runs.
    for (var i = 0; i < n; i++) {
      final x1 = bx1[i], y1 = by1[i], x2 = bx2[i], y2 = by2[i];
      if (x2 <= x1 || y2 <= y1) continue;
      for (var y = y1; y < y2; y++) {
        var start = -1;
        for (var x = x1; x <= x2; x++) {
          final mine = x < x2 && ink[y * w + x] == 1 && label[y * w + x] == i;
          if (mine && start < 0) start = x;
          if (!mine && start >= 0) {
            runs[i].add([rx1 + start, ry1 + y, x - start]);
            start = -1;
          }
        }
      }
    }
    return runs;
  }

  /// Gray values smoothed with the 3x3 kernel 1 2 1 (edges repeated),
  /// rounded.
  static Uint8List _blur121(Uint8List gray, int w, int h) {
    final rows = Int32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final left = gray[y * w + math.max(0, x - 1)];
        final right = gray[y * w + math.min(w - 1, x + 1)];
        rows[y * w + x] = left + 2 * gray[y * w + x] + right;
      }
    }
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final up = math.max(0, y - 1) * w, down = math.min(h - 1, y + 1) * w;
      for (var x = 0; x < w; x++) {
        out[y * w + x] =
            (rows[up + x] + 2 * rows[y * w + x] + rows[down + x] + 8) >> 4;
      }
    }
    return out;
  }
}
