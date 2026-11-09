#!/usr/bin/env python3
"""Builds assets/models/english_lm.bin.gz, the spelling language model.

The model combines
  * the word list and word frequencies of pyspellchecker 0.9.0 (MIT; counts
    from the OpenSubtitles2018 corpus). The app used the same word list
    before (english_words.json), without the counts;
  * word-pair statistics from the SymSpell English unigram and bigram lists
    (Google Books Ngram data, CC BY 3.0), stored as pointwise mutual
    information;
  * a "never suggest" flag for the words in data/suggestion_blocklist.txt.

Inputs (not part of the repository):
  en.json.gz  pyspellchecker/resources/en.json.gz from
              `pip download pyspellchecker==0.9.0`
  frequency_dictionary_en_82_765.txt and
  frequency_bigramdictionary_en_243_342.txt from
              https://github.com/mammothb/symspellpy (symspellpy/ folder)

Usage:
  python tool/build_language_model.py \
      --pyspellchecker en.json.gz \
      --symspell-unigrams frequency_dictionary_en_82_765.txt \
      --symspell-bigrams frequency_bigramdictionary_en_243_342.txt

Binary layout (little endian, version 1), gzip-compressed:
  0   'GILM'
  4   u32 version
  8   u32 N   number of words (word id = position, words sorted)
  12  u32 M   number of word pairs
  16  u32 byte length of the word blob
  20  u32 reserved (0)
  24  f64 sum of the subtitle counts
  32  f64 ln(sum of the Google unigram counts)
  40  f64 ln(smallest Google pair count kept in the pair list)
  48  word blob: UTF-8 words joined by '\\n', zero-padded to 4 bytes
      u8  x N flags (bit 0: never suggest), zero-padded to 4 bytes
      u32 x N subtitle counts
      f32 x N ln(Google unigram count), -1 when the word has no count
      u32 x (N + 1) start of each word's pair row (CSR)
      u32 x M second word id of each pair, ascending within a row
      f32 x M pointwise mutual information ln(P(a, b) / (P(a) P(b)))
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import os
import struct
import sys
from array import array

FLAG_NO_SUGGEST = 1

# SymSpell stores every pair count multiplied by 64 (all counts are
# multiples of 64; divided by 64 they match the unigram counts, e.g.
# P(the | of) = 0.21, P(to | want) = 0.50).
BIGRAM_COUNT_SCALE = 64


def read_blocklist(path: str) -> set[str]:
    words = set()
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip().lower()
            if line and not line.startswith('#'):
                words.add(line)
    return words


def read_counts(path: str, columns: int) -> list[tuple[list[str], int]]:
    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            parts = line.split()
            if len(parts) == columns:
                rows.append((parts[:-1], int(parts[-1])))
    return rows


def pad4(data: bytes) -> bytes:
    return data + b'\0' * (-len(data) % 4)


def little_endian(values: array) -> bytes:
    if sys.byteorder != 'little':
        values = array(values.typecode, values)
        values.byteswap()
    return values.tobytes()


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--pyspellchecker', required=True,
                        help='pyspellchecker resources/en.json.gz')
    parser.add_argument('--symspell-unigrams', required=True)
    parser.add_argument('--symspell-bigrams', required=True)
    parser.add_argument('--blocklist',
                        default=os.path.join(here, 'data',
                                             'suggestion_blocklist.txt'))
    parser.add_argument('--out', default=os.path.join(
        here, '..', 'assets', 'models', 'english_lm.bin.gz'))
    args = parser.parse_args()

    with gzip.open(args.pyspellchecker, 'rt', encoding='utf-8') as f:
        counts: dict[str, int] = json.load(f)
    google = {w[0]: c for w, c in read_counts(args.symspell_unigrams, 2)}
    pairs = [(w[0], w[1], c // BIGRAM_COUNT_SCALE)
             for w, c in read_counts(args.symspell_bigrams, 3)]
    blocked = read_blocklist(args.blocklist)

    words = sorted(counts)
    index = {w: i for i, w in enumerate(words)}
    n = len(words)

    flags = bytearray(n)
    for word in blocked:
        if word in index:
            flags[index[word]] |= FLAG_NO_SUGGEST

    ln_google_total = math.log(sum(google.values()))
    threshold = min(c for _, _, c in pairs)
    google_ln = array('f', [math.log(google[w]) if w in google else -1.0
                            for w in words])

    rows: list[list[tuple[int, float]]] = [[] for _ in range(n)]
    kept = 0
    for a, b, c in pairs:
        if a not in index or b not in index or a not in google \
                or b not in google:
            continue
        pmi = math.log(c) + ln_google_total - math.log(google[a]) \
            - math.log(google[b])
        rows[index[a]].append((index[b], pmi))
        kept += 1
    row_start = array('I', [0] * (n + 1))
    cols = array('I')
    pmis = array('f')
    for i, row in enumerate(rows):
        row.sort()
        row_start[i] = len(cols)
        for j, pmi in row:
            cols.append(j)
            pmis.append(pmi)
    row_start[n] = len(cols)

    blob = '\n'.join(words).encode('utf-8')
    header = struct.pack('<4sIIIII3d', b'GILM', 1, n, kept, len(blob), 0,
                         float(sum(counts.values())), ln_google_total,
                         math.log(threshold))
    assert len(header) == 48
    body = b''.join([
        header,
        pad4(blob),
        pad4(bytes(flags)),
        little_endian(array('I', [counts[w] for w in words])),
        little_endian(google_ln),
        little_endian(row_start),
        little_endian(cols),
        little_endian(pmis),
    ])
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'wb') as f:
        f.write(gzip.compress(body, compresslevel=9, mtime=0))

    print(f'words: {n}, pairs: {kept}, '
          f'never suggested: {sum(1 for x in flags if x & 1)}')
    print(f'raw {len(body) / 1e6:.2f} MB -> '
          f'{os.path.getsize(args.out) / 1e6:.2f} MB {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
