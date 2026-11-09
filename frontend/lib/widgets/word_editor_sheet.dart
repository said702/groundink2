import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/word_box.dart';
import '../services/spelling_feedback.dart';
import '../theme/app_theme.dart';
import '../theme/highlight_colors.dart';
import 'photo_panel.dart' show CroppedPhotoPainter;

/// What the user entered in the word editor.
class WordEdit {
  /// The letters actually on the paper (fixes misread letters).
  final String written;

  /// The word that was meant; empty lets the spell checker suggest.
  final String intended;

  const WordEdit(this.written, this.intended);
}

/// Lets the user fix a word the app misread and/or enter the intended word
/// when it is not among the suggestions. [typeCorrection] focuses the field
/// for the intended word.
Future<WordEdit?> showWordEditor(
  BuildContext context, {
  required WordBox word,
  required String? correction,
  ui.Image? image,
  bool typeCorrection = false,
}) {
  return showModalBottomSheet<WordEdit>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => _WordEditor(
      word: word,
      correction: correction,
      image: image,
      typeCorrection: typeCorrection,
    ),
  );
}

class _WordEditor extends StatefulWidget {
  final WordBox word;
  final String? correction;
  final ui.Image? image;
  final bool typeCorrection;

  const _WordEditor({
    required this.word,
    required this.correction,
    required this.image,
    required this.typeCorrection,
  });

  @override
  State<_WordEditor> createState() => _WordEditorState();
}

class _WordEditorState extends State<_WordEditor> {
  late final _written = TextEditingController(text: widget.word.text);
  late final _intended = TextEditingController(
    text: widget.typeCorrection
        ? ''
        : widget.correction ?? (widget.word.isCorrect ? widget.word.text : ''),
  );

  @override
  void initState() {
    super.initState();
    _written.addListener(_changed);
    _intended.addListener(_changed);
  }

  @override
  void dispose() {
    _written.dispose();
    _intended.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  void _save() {
    final written = _written.text.trim();
    if (written.isEmpty) return;
    Navigator.of(context).pop(WordEdit(written, _intended.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final written = _written.text.trim();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.cardBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Correct this word',
                    style: TextStyle(
                        fontSize: tablet ? 26 : 20,
                        fontWeight: FontWeight.w800),
                  ),
                  if (widget.image != null && widget.word.bbox.length >= 4) ...[
                    const SizedBox(height: 12),
                    _HandwritingSnippet(
                      image: widget.image!,
                      bbox: widget.word.bbox,
                      height: tablet ? 130 : 88,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _field(
                    controller: _written,
                    label: 'Written',
                    helper: 'The letters on the paper — fix any the app '
                        'read wrong.',
                    autofocus: false,
                    tablet: tablet,
                  ),
                  const SizedBox(height: 12),
                  _field(
                    controller: _intended,
                    label: 'Correct spelling',
                    helper: 'The word that was meant. Leave empty for '
                        'suggestions.',
                    autofocus: widget.typeCorrection,
                    tablet: tablet,
                  ),
                  const SizedBox(height: 14),
                  _Preview(
                    written: written,
                    intended: _intended.text.trim(),
                    color: HighlightColors.forInk(widget.word.inkColor),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('Cancel',
                            style: TextStyle(fontSize: tablet ? 20 : 15)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: written.isEmpty ? null : _save,
                        icon: const Icon(Icons.check),
                        label: Text('Save',
                            style: TextStyle(fontSize: tablet ? 20 : 15)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String helper,
    required bool autofocus,
    required bool tablet,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      // The keyboard must not "fix" a misspelled word or curl apostrophes.
      autocorrect: false,
      enableSuggestions: false,
      smartQuotesType: SmartQuotesType.disabled,
      smartDashesType: SmartDashesType.disabled,
      textCapitalization: TextCapitalization.none,
      inputFormatters: [
        FilteringTextInputFormatter.allow(
            RegExp(r"[\p{L}\p{N}' -]", unicode: true)),
      ],
      textInputAction:
          controller == _written ? TextInputAction.next : TextInputAction.done,
      onSubmitted: controller == _intended ? (_) => _save() : null,
      style: TextStyle(fontSize: tablet ? 26 : 20, fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        // Not in the focus order: "next" on the keyboard must reach the next
        // field, and Enter must not clear this one.
        suffixIcon: controller.text.isEmpty
            ? null
            : ExcludeFocus(
                child: IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear),
                  onPressed: controller.clear,
                ),
              ),
      ),
    );
  }
}

/// The handwritten word, cut out of the photo, for reference while typing.
class _HandwritingSnippet extends StatelessWidget {
  final ui.Image image;
  final List<int> bbox;
  final double height;

  const _HandwritingSnippet(
      {required this.image, required this.bbox, required this.height});

  @override
  Widget build(BuildContext context) {
    final w = (bbox[2] - bbox[0]).toDouble();
    final h = (bbox[3] - bbox[1]).toDouble();
    final pad = math.max(4.0, h * 0.25);
    final source = Rect.fromLTRB(
      math.max(0, bbox[0] - pad),
      math.max(0, bbox[1] - pad),
      math.min(image.width.toDouble(), bbox[2] + pad),
      math.min(image.height.toDouble(), bbox[3] + pad),
    );
    if (w <= 0 || h <= 0 || source.isEmpty) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height),
        child: AspectRatio(
          aspectRatio: source.width / source.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.cardBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: CustomPaint(
                painter: CroppedPhotoPainter(image: image, sourceRect: source),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows how the feedback will look: the differing letters, or that the
/// word counts as correct.
class _Preview extends StatelessWidget {
  final String written;
  final String intended;
  final Color color;

  const _Preview(
      {required this.written, required this.intended, required this.color});

  @override
  Widget build(BuildContext context) {
    if (written.isEmpty) return const SizedBox.shrink();
    if (intended.isEmpty) {
      return const Text(
        'The app will check the written word and suggest corrections.',
        style: TextStyle(fontSize: 13, color: Colors.black54),
      );
    }
    if (written.toLowerCase() == intended.toLowerCase()) {
      return const Row(
        children: [
          Icon(Icons.check_circle, color: AppColors.success),
          SizedBox(width: 8),
          Expanded(
            child: Text('Spelled correctly — not a mistake.',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success)),
          ),
        ],
      );
    }
    final changed = SpellingFeedback.changedCharacters(written, intended);
    return Text.rich(
      TextSpan(children: [
        for (var i = 0; i < written.length; i++)
          TextSpan(
            text: written[i],
            style: changed.contains(i)
                ? TextStyle(
                    color: color,
                    decoration: TextDecoration.underline,
                    decorationColor: color,
                    decorationThickness: 2.5)
                : null,
          ),
        const WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Icon(Icons.arrow_forward, color: Colors.black38),
          ),
        ),
        TextSpan(
            text: intended, style: const TextStyle(color: AppColors.success)),
      ]),
      style: const TextStyle(
          fontSize: 20, fontWeight: FontWeight.w800, color: Colors.black87),
    );
  }
}
