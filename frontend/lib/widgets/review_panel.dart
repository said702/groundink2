import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/spelling_feedback.dart';
import '../state/review_session.dart';
import '../theme/app_theme.dart';
import '../theme/highlight_colors.dart';

/// The spelling review below the photo: the recognized text, and the
/// mistakes one at a time (swipe or use the arrows to move between them).
class ReviewPanel extends StatefulWidget {
  final ReviewSession session;

  /// A word of the recognized text was tapped.
  final ValueChanged<ReviewEntry> onWordTap;

  /// Edit a word; [typeCorrection] starts in the correction field.
  final void Function(ReviewEntry entry, bool typeCorrection) onEdit;

  /// Remove a mistake from the review.
  final ValueChanged<ReviewEntry> onDismiss;

  const ReviewPanel({
    super.key,
    required this.session,
    required this.onWordTap,
    required this.onEdit,
    required this.onDismiss,
  });

  @override
  State<ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends State<ReviewPanel> {
  late PageController _pages;
  final _wordKeys = <int, GlobalKey>{};
  bool _syncing = false;

  ReviewSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _pages = PageController(initialPage: math.max(0, session.currentIndex));
    session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(ReviewPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, session)) {
      old.session.removeListener(_onSessionChanged);
      session.addListener(_onSessionChanged);
      _wordKeys.clear();
      _pages.dispose();
      _pages = PageController(initialPage: math.max(0, session.currentIndex));
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _pages.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPage();
      _revealCurrentWord();
    });
  }

  /// Moves the pager to the mistake selected elsewhere (photo, transcript,
  /// buttons).
  void _syncPage() {
    final index = session.currentIndex;
    if (index < 0 || !_pages.hasClients) return;
    final page = (_pages.page ?? index.toDouble()).round();
    if (page == index) return;
    if ((page - index).abs() == 1) {
      _syncing = true;
      _pages
          .animateToPage(index,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic)
          .whenComplete(() => _syncing = false);
    } else {
      _pages.jumpToPage(index);
    }
  }

  void _revealCurrentWord() {
    final id = session.current?.id;
    final context = id == null ? null : _wordKeys[id]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context,
        alignment: 0.5, duration: const Duration(milliseconds: 250));
  }

  void _onPageChanged(int index) {
    if (!_syncing) session.showIndex(index);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final open = session.openMistakes;
        return LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Summary(session: session),
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxHeight: constraints.maxHeight * 0.3),
                child: _Transcript(
                  session: session,
                  keyFor: (id) => _wordKeys.putIfAbsent(id, GlobalKey.new),
                  onTap: widget.onWordTap,
                ),
              ),
              const SizedBox(height: 6),
              if (open.isEmpty)
                Expanded(child: _AllDone(session: session))
              else ...[
                _Pager(session: session),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: open.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, i) {
                      final entry = open[i];
                      return _MistakeCard(
                        key: ValueKey(entry.id),
                        entry: entry,
                        onChoose: (target) =>
                            session.chooseCorrection(entry.id, target),
                        onEdit: () => widget.onEdit(entry, false),
                        onTypeCorrection: () => widget.onEdit(entry, true),
                        onDismiss: () => widget.onDismiss(entry),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

bool _isTablet(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= 600;

/// "12 words · 2 mistakes" and the restore action for removed mistakes.
class _Summary extends StatelessWidget {
  final ReviewSession session;
  const _Summary({required this.session});

  @override
  Widget build(BuildContext context) {
    final words = session.entries.length;
    final mistakes = session.openMistakes.length;
    final removed = session.dismissedCount;
    final iconSize = _isTablet(context) ? 26.0 : 18.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      // Same height with and without the restore button, so that the
      // panel does not jump when a mistake is removed.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(Icons.text_snippet_outlined,
                size: iconSize, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$words ${words == 1 ? 'word' : 'words'}'),
                  const TextSpan(text: '  ·  '),
                  TextSpan(
                    text: '$mistakes ${mistakes == 1 ? 'mistake' : 'mistakes'}',
                    style: TextStyle(
                        color:
                            mistakes > 0 ? AppColors.error : AppColors.success),
                  ),
                  if (removed > 0) TextSpan(text: '  ·  $removed removed'),
                ]),
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (removed > 0)
              TextButton.icon(
                onPressed: session.restoreAll,
                style:
                    TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: Icon(Icons.restore, size: iconSize),
                label: const Text('Restore', style: TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The recognized words in reading order. Mistakes are underlined like in a
/// word processor; the reviewed one is marked like on the photo.
class _Transcript extends StatelessWidget {
  final ReviewSession session;
  final GlobalKey Function(int id) keyFor;
  final ValueChanged<ReviewEntry> onTap;

  const _Transcript(
      {required this.session, required this.keyFor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final currentId = session.current?.id;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 2),
            child: Text(
              'Recognized text — tap a word to check or correct it',
              style: TextStyle(fontSize: 11.5, color: Colors.black54),
            ),
          ),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final entry in session.entries)
                _TranscriptWord(
                  key: keyFor(entry.id),
                  entry: entry,
                  current: entry.id == currentId,
                  onTap: () => onTap(entry),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TranscriptWord extends StatelessWidget {
  final ReviewEntry entry;
  final bool current;
  final VoidCallback onTap;

  const _TranscriptWord(
      {super.key,
      required this.entry,
      required this.current,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = HighlightColors.forInk(entry.word.inkColor);
    final style = entry.isOpen
        ? TextStyle(
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: color,
            decorationThickness: 2,
          )
        : const TextStyle(color: Colors.black87);
    final label =
        entry.isOpen ? 'Mistake: ${entry.word.text}' : entry.word.text;
    return Semantics(
      button: true,
      selected: current,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: current
              ? BoxDecoration(
                  color: HighlightColors.marker.withValues(alpha: 0.75),
                  border: Border.all(color: HighlightColors.markerEdge),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Text(entry.word.text,
              style: style.copyWith(fontSize: 16, height: 1.3)),
        ),
      ),
    );
  }
}

/// "‹  Mistake 2 of 5  ›"
class _Pager extends StatelessWidget {
  final ReviewSession session;
  const _Pager({required this.session});

  @override
  Widget build(BuildContext context) {
    final count = session.openMistakes.length;
    final index = session.currentIndex;
    final iconSize = _isTablet(context) ? 34.0 : 26.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filledTonal(
            iconSize: iconSize,
            tooltip: 'Previous mistake',
            onPressed: session.hasPrevious ? session.previous : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Mistake ${index + 1} of $count',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ),
          IconButton.filledTonal(
            iconSize: iconSize,
            tooltip: 'Next mistake',
            onPressed: session.hasNext ? session.next : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// One mistake: the handwriting next to the intended word, the suggestions,
/// and the edit and remove actions.
class _MistakeCard extends StatelessWidget {
  final ReviewEntry entry;
  final ValueChanged<String> onChoose;
  final VoidCallback onEdit;
  final VoidCallback onTypeCorrection;
  final VoidCallback onDismiss;

  const _MistakeCard({
    super.key,
    required this.entry,
    required this.onChoose,
    required this.onEdit,
    required this.onTypeCorrection,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final word = entry.word;
    final correction = entry.correction;
    final color = HighlightColors.forInk(word.inkColor);
    final tablet = _isTablet(context);
    final suggestions = [
      ...word.suggestions,
      if (correction != null && !word.suggestions.contains(correction))
        correction,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: SingleChildScrollView(
          // Room for the "New scan" button floating above the panel.
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 88),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _WrittenVsIntended(
                        written: word.text,
                        intended: correction,
                        color: color,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Correct this word',
                    iconSize: tablet ? 30 : 24,
                    color: AppColors.primary,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Remove this mistake',
                    iconSize: tablet ? 30 : 24,
                    color: Colors.black54,
                    onPressed: onDismiss,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                suggestions.isEmpty
                    ? 'No suggestion found. Type the word that was meant:'
                    : 'Did you mean:',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final s in suggestions)
                    ChoiceChip(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      selected: s == correction,
                      showCheckmark: false,
                      label: Text(s,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: s == correction
                                  ? Colors.white
                                  : AppColors.accent)),
                      selectedColor: AppColors.accent,
                      backgroundColor: AppColors.accent.withValues(alpha: 0.08),
                      side: BorderSide(
                          color: AppColors.accent.withValues(alpha: 0.35)),
                      onSelected: (_) => onChoose(s),
                    ),
                  ActionChip(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    avatar: Icon(Icons.keyboard_outlined,
                        size: tablet ? 24 : 18, color: AppColors.primary),
                    label: const Text('Other word…',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary)),
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.35)),
                    onPressed: onTypeCorrection,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The written word with the differing letters colored like on the photo,
/// an arrow, and the intended word.
class _WrittenVsIntended extends StatelessWidget {
  final String written;
  final String? intended;
  final Color color;

  const _WrittenVsIntended(
      {required this.written, required this.intended, required this.color});

  @override
  Widget build(BuildContext context) {
    final changed = intended == null
        ? const <int>{}
        : SpellingFeedback.changedCharacters(written, intended!);
    return Semantics(
      label: intended == null
          ? 'Written: $written'
          : 'Written: $written. Correct: $intended',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(children: [
          for (var i = 0; i < written.length; i++)
            TextSpan(
              text: written[i],
              style: changed.contains(i)
                  ? TextStyle(
                      color: color,
                      decoration: TextDecoration.underline,
                      decorationColor: color,
                      decorationThickness: 2.5,
                    )
                  : null,
            ),
          if (intended != null) ...[
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward, color: Colors.black38),
              ),
            ),
            TextSpan(
              text: intended,
              style: const TextStyle(color: AppColors.success),
            ),
          ],
        ]),
        style: const TextStyle(
            fontSize: 24, fontWeight: FontWeight.w800, color: Colors.black87),
      ),
    );
  }
}

/// Shown when no mistake is left to review.
class _AllDone extends StatelessWidget {
  final ReviewSession session;
  const _AllDone({required this.session});

  @override
  Widget build(BuildContext context) {
    final removed = session.dismissedCount;
    final noMistakes = removed == 0;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 88),
      child: Column(
        children: [
          Icon(noMistakes ? Icons.celebration_outlined : Icons.task_alt,
              size: _isTablet(context) ? 56 : 40, color: AppColors.success),
          const SizedBox(height: 8),
          Text(
            noMistakes
                ? 'No spelling mistakes found!'
                : 'All mistakes reviewed.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'If a word was read incorrectly, tap it above to correct it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
          if (removed > 0) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: session.restoreAll,
              icon: const Icon(Icons.restore),
              label: Text('Restore $removed removed '
                  '${removed == 1 ? 'mistake' : 'mistakes'}'),
            ),
          ],
        ],
      ),
    );
  }
}
