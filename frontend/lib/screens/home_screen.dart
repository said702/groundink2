import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/offline_detector.dart';
import '../services/progress_notifier.dart';
import '../services/spelling_feedback.dart';
import '../models/word_box.dart';
import '../widgets/overlay_painter.dart';
import '../widgets/how_it_works_sheet.dart';
import '../theme/app_theme.dart';

/// Main screen: capture/pick a photo → offline detection → grounded feedback.
/// No server needed — ONNX models run locally on the device.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _ResultFilter { all, correct, errors }

class _HomeScreenState extends State<HomeScreen> {
  File? _imageFile;
  bool _loading = false;
  bool _initializing = true;
  List<WordBox> _results = [];
  Map<WordBox, String> _corrections = {};
  String? _error;
  Size _imagePixelSize = Size.zero;
  ui.Image? _displayImage;
  _ResultFilter _resultFilter = _ResultFilter.all;

  // Progress Notifier für detaillierte Fortschrittsanzeige
  final ProgressNotifier _progressNotifier = ProgressNotifier();

  @override
  void initState() {
    super.initState();
    // Progress-Notifier mit OfflineDetector verbinden
    OfflineDetector.progressNotifier = _progressNotifier;
    _progressNotifier.addListener(_onProgressUpdate);
    _initOnnx();
  }

  @override
  void dispose() {
    _progressNotifier.removeListener(_onProgressUpdate);
    _progressNotifier.dispose();
    _displayImage?.dispose();
    super.dispose();
  }

  void _onProgressUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _initOnnx() async {
    try {
      await OfflineDetector.initOnnx();
      if (mounted) setState(() => _initializing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Model initialization failed: $e';
          _initializing = false;
        });
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    // Real device cameras (e.g. iPad: 12 MP) deliver far more pixels than the
    // models need (640 px word detector, 256 px character model). Decoding and
    // preprocessing full-resolution photos in Dart is what made analysis slow
    // on hardware while the emulator's small camera frames stayed fast.
    final picked = await picker.pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (picked == null) return;
    final file = File(picked.path);

    // Decode real pixel size for correct overlay scaling.
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final pixelSize = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );

    if (!mounted) {
      frame.image.dispose();
      return;
    }
    final oldImage = _displayImage;
    setState(() {
      _imageFile = file;
      _displayImage = frame.image;
      _imagePixelSize = pixelSize;
      _results = [];
      _corrections = {};
      _resultFilter = _ResultFilter.all;
      _error = null;
    });
    oldImage?.dispose();

    await _detect();
  }

  void _resetScan() {
    final oldImage = _displayImage;
    setState(() {
      _imageFile = null;
      _displayImage = null;
      _imagePixelSize = Size.zero;
      _results = [];
      _corrections = {};
      _resultFilter = _ResultFilter.all;
      _error = null;
    });
    oldImage?.dispose();
  }

  Future<void> _detect() async {
    if (_imageFile == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await OfflineDetector.detect(_imageFile!);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: tablet ? 82 : 60,
        titleTextStyle: TextStyle(fontSize: tablet ? 26 : 20, fontWeight: FontWeight.w700, color: Colors.white),
        actionsIconTheme: IconThemeData(size: tablet ? 30 : 24),
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'ground',
                  style: TextStyle(
                    fontSize: tablet ? 50 : 34,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: Padding(
                    padding: EdgeInsets.only(left: tablet ? 3 : 2),
                    child: Transform.translate(
                      offset: Offset(0, tablet ? -1 : -1),
                      child: Text.rich(
                        const TextSpan(
                          children: [
                            TextSpan(text: 'in'),
                            TextSpan(
                              text: 'k',
                              style: TextStyle(color: Color(0xFFFF6B61)),
                            ),
                          ],
                        ),
                        style: TextStyle(
                          fontSize: tablet ? 62 : 43,
                          fontFamily: 'cursive',
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => showHowItWorksSheet(context),
            tooltip: 'How it works',
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: _initializing || _loading
                ? null
                : () => _pickImage(ImageSource.camera),
            tooltip: 'Take photo',
          ),
          IconButton(
            icon: const Icon(Icons.photo_library),
            onPressed: _initializing || _loading
                ? null
                : () => _pickImage(ImageSource.gallery),
            tooltip: 'Choose from gallery',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _imageFile != null && !_loading && !_initializing
          ? FloatingActionButton.extended(
              onPressed: _resetScan,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.refresh),
              label: Text('New scan', style: TextStyle(fontSize: tablet ? 22 : 16)),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_initializing) {
      return _readablePanel(const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 20),
            Text(
              'Getting ready...',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 6),
            Text(
              'This may take a few seconds on first launch',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
      ));
    }

    if (_loading) {
      return _readablePanel(_buildProgressIndicator());
    }

    if (_imageFile == null) {
      return _buildEmptyState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        final isWideTablet = isLandscape && constraints.maxWidth >= 1200;
        return Column(
          children: [
            Expanded(
              flex: isWideTablet ? 4 : (isLandscape ? 3 : 2),
              child: _buildPhotoPanel(),
            ),
            Expanded(
              flex: isWideTablet ? 5 : (isLandscape ? 4 : 3),
              child: _readablePanel(_buildResults()),
            ),
          ],
        );
      },
    );
  }

  Widget _readablePanel(Widget child) {
    final media = MediaQuery.of(context);
    final tablet = media.size.shortestSide >= 600;
    return MediaQuery(
      data: media.copyWith(
        textScaler: tablet
            ? _PanelTextScaler(media.textScaler)
            : media.textScaler,
      ),
      child: child,
    );
  }

  Widget _buildPhotoPanel() {
    final crop = _focusedCropRect();
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspect = crop.width > 0 && crop.height > 0
            ? crop.width / crop.height
            : 4 / 3;
        final maxWidth = math.max(0.0, constraints.maxWidth - 24);
        final maxHeight = math.max(0.0, constraints.maxHeight - 18);
        final panelWidth = math.min(maxWidth, maxHeight * aspect);

        return Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: SizedBox(
              width: panelWidth,
              child: AspectRatio(
                aspectRatio: aspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: AppColors.cardBorder),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InteractiveViewer(
                      maxScale: 6,
                      child: _imagePixelSize == Size.zero ||
                              _displayImage == null
                          ? Image.file(_imageFile!, fit: BoxFit.cover)
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                CustomPaint(
                                  painter: _CroppedPhotoPainter(
                                    image: _displayImage!,
                                    sourceRect: crop,
                                  ),
                                ),
                                CustomPaint(
                                  painter: OverlayPainter(
                                    results: _visibleResults,
                                    imageSize: _imagePixelSize,
                                    corrections: _corrections,
                                    sourceRect: crop,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Rect _focusedCropRect() {
    final imageRect = Offset.zero & _imagePixelSize;
    if (_imagePixelSize == Size.zero || _results.isEmpty) {
      return imageRect;
    }

    var left = _imagePixelSize.width;
    var top = _imagePixelSize.height;
    var right = 0.0;
    var bottom = 0.0;

    for (final word in _results) {
      if (word.bbox.length < 4) continue;
      final x1 = word.bbox[0].toDouble();
      final y1 = word.bbox[1].toDouble();
      final x2 = word.bbox[2].toDouble();
      final y2 = word.bbox[3].toDouble();
      if (x2 <= x1 || y2 <= y1) continue;
      left = math.min(left, x1);
      top = math.min(top, y1);
      right = math.max(right, x2);
      bottom = math.max(bottom, y2);
    }

    if (right <= left || bottom <= top) return imageRect;

    final content = Rect.fromLTRB(left, top, right, bottom);
    final padX = math.max(content.width * 0.14, _imagePixelSize.width * 0.035);
    final padY =
        math.max(content.height * 0.28, _imagePixelSize.height * 0.02);
    var crop = Rect.fromLTRB(
      content.left - padX,
      content.top - padY,
      content.right + padX,
      content.bottom + padY,
    );

    final minHeight = _imagePixelSize.height * 0.14;
    if (crop.height < minHeight) {
      final extra = (minHeight - crop.height) / 2;
      crop = Rect.fromLTRB(
          crop.left, crop.top - extra, crop.right, crop.bottom + extra);
    }

    return Rect.fromLTRB(
      crop.left.clamp(0.0, _imagePixelSize.width).toDouble(),
      crop.top.clamp(0.0, _imagePixelSize.height).toDouble(),
      crop.right.clamp(0.0, _imagePixelSize.width).toDouble(),
      crop.bottom.clamp(0.0, _imagePixelSize.height).toDouble(),
    );
  }

  /// Detaillierte Fortschrittsanzeige während der Erkennung.
  Widget _buildProgressIndicator() {
    final progress = _progressNotifier.progress;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Fortschritts-Ring mit Prozent
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: MediaQuery.sizeOf(context).shortestSide >= 600 ? 148 : 100,
                  height: MediaQuery.sizeOf(context).shortestSide >= 600 ? 148 : 100,
                  child: CircularProgressIndicator(
                    value: progress.progress,
                    strokeWidth: 6,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                    valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                  ),
                ),
                Text(
                  '${(progress.progress * 100).toInt()}%',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            // Haupt-Statusmeldung
            Text(
              progress.message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),

            // Detail-Text
            if (progress.detail != null) ...[
              const SizedBox(height: 8),
              Text(
                progress.detail!,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.black54,
                ),
              ),
            ],

            if (progress.currentWord != null &&
                progress.totalWords != null) ...[
              const SizedBox(height: 20),
              Text(
                'Word ${progress.currentWord} of ${progress.totalWords}',
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = MediaQuery.sizeOf(context).shortestSide >= 600;
        final iconBox = isWide ? 132.0 : 96.0;
        final iconSize = isWide ? 68.0 : 48.0;
        final titleSize = isWide ? 36.0 : 24.0;
        final bodySize = isWide ? 19.0 : 14.0;
        final buttonHeight = isWide ? 64.0 : 40.0;
        final buttonTextSize = isWide ? 18.0 : 14.0;

        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(isWide ? 40 : 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: iconBox,
                  height: iconBox,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.draw_outlined,
                      size: iconSize, color: AppColors.primary),
                ),
                SizedBox(height: isWide ? 32 : 24),
                Text(
                  'Check your handwriting',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: titleSize, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: isWide ? 16 : 10),
                Text(
                  'Take a photo or pick one from your gallery.\n'
                  'Spelling feedback is highlighted directly on your\n'
                  'writing — character by character.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: bodySize, color: Colors.black54, height: 1.5),
                ),
                SizedBox(height: isWide ? 36 : 28),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: isWide ? 20 : 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: Icon(Icons.photo_camera, size: isWide ? 28 : 18),
                      label: Text('Take Photo',
                          style: TextStyle(fontSize: buttonTextSize)),
                      style: FilledButton.styleFrom(
                        minimumSize: Size(isWide ? 260 : 0, buttonHeight),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: Icon(Icons.photo_library_outlined,
                          size: isWide ? 28 : 18),
                      label: Text('Choose Image',
                          style: TextStyle(fontSize: buttonTextSize)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(isWide ? 290 : 0, buttonHeight),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: isWide ? 32 : 24),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: isWide ? 20 : 14, vertical: isWide ? 12 : 8),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off,
                          size: isWide ? 22 : 16, color: AppColors.success),
                      SizedBox(width: isWide ? 10 : 8),
                      Flexible(child: Text(
                        'Works offline — no data leaves the device',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: isWide ? 16 : 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.success),
                      )),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildResults() {
    if (_error != null) {
      return SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: AppColors.error),
                const SizedBox(height: 8),
                Text(
                  'Error: $_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.error, fontSize: 13),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _detect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'No words detected. Try a closer, well-lit photo.',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }

    final correctCount = _results.where((w) => w.isCorrect).length;
    final errorCount = _results.length - correctCount;
    final visibleResults = _visibleResults;

    return Column(
      children: [
        // Summary chips
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SummaryChip(
                icon: Icons.text_snippet_outlined,
                label: '${_results.length} words',
                color: AppColors.primary,
                selected: _resultFilter == _ResultFilter.all,
                onPressed: () => _toggleFilter(_ResultFilter.all),
              ),
              _SummaryChip(
                icon: Icons.check_circle_outline,
                label: '$correctCount correct',
                color: AppColors.success,
                selected: _resultFilter == _ResultFilter.correct,
                onPressed: () => _toggleFilter(_ResultFilter.correct),
              ),
              _SummaryChip(
                icon: Icons.cancel_outlined,
                label: '$errorCount errors',
                color: errorCount > 0 ? AppColors.error : Colors.black38,
                selected: _resultFilter == _ResultFilter.errors,
                onPressed: () => _toggleFilter(_ResultFilter.errors),
              ),
            ],
          ),
        ),
        // Word cards
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
             itemCount: visibleResults.length,
             itemBuilder: (context, index) {
               final word = visibleResults[index];
              return _WordCard(
                word: word,
                correction: _corrections[word] ??
                    (word.suggestions.isEmpty ? null : word.suggestions.first),
                onCorrectionSelected: (value) => setState(() {
                  _corrections = {..._corrections, word: value};
                }),
              );
            },
          ),
        ),
      ],
    );
  }

  List<WordBox> get _visibleResults {
    switch (_resultFilter) {
      case _ResultFilter.all:
        return _results;
      case _ResultFilter.correct:
        return _results.where((word) => word.isCorrect).toList(growable: false);
      case _ResultFilter.errors:
        return _results.where((word) => !word.isCorrect).toList(growable: false);
    }
  }

  void _toggleFilter(_ResultFilter filter) {
    setState(() {
      _resultFilter = _resultFilter == filter ? _ResultFilter.all : filter;
    });
  }
}

// Preserve the user's accessibility scaling on top of the tablet reading size.
class _PanelTextScaler extends TextScaler {
  const _PanelTextScaler(this.base);
  final TextScaler base;

  @override
  double scale(double fontSize) => base.scale(fontSize * 1.5);

  @override
  double get textScaleFactor => base.scale(14) / 14 * 1.5;
}

class _CroppedPhotoPainter extends CustomPainter {
  final ui.Image image;
  final Rect sourceRect;

  const _CroppedPhotoPainter({
    required this.image,
    required this.sourceRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      sourceRect,
      Offset.zero & size,
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant _CroppedPhotoPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.sourceRect != sourceRect;
}

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  const _SummaryChip(
      {required this.icon,
      required this.label,
      required this.color,
      required this.selected,
      required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onPressed(),
      avatar: Icon(icon,
          size: MediaQuery.sizeOf(context).shortestSide >= 600 ? 26 : 18,
          color: selected ? Colors.white : color),
      label: Text(label),
      labelStyle: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: selected ? Colors.white : color,
      ),
      selectedColor: color,
      backgroundColor: color.withValues(alpha: 0.08),
      side: BorderSide(color: color.withValues(alpha: 0.25)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}

class _WordCard extends StatelessWidget {
  final WordBox word;
  final String? correction;
  final ValueChanged<String> onCorrectionSelected;

  const _WordCard(
      {required this.word,
      required this.correction,
      required this.onCorrectionSelected});

  @override
  Widget build(BuildContext context) {
    final isCorrect = word.isCorrect;
    final color = isCorrect ? AppColors.success : AppColors.error;
    final changed = isCorrect || correction == null
        ? <int>{}
        : SpellingFeedback.changedCharacters(word.text, correction!);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Colored left border
            Container(width: 1, color: AppColors.cardBorder),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isCorrect ? Icons.check_circle : Icons.error,
                          color: color,
                          size: MediaQuery.sizeOf(context).shortestSide >= 600 ? 30 : 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              for (var i = 0; i < word.text.length; i++)
                                TextSpan(
                                  text: word.text[i],
                                  style: TextStyle(
                                      color: changed.contains(i)
                                          ? AppColors.error
                                          : Colors.black87),
                                ),
                            ]),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (isCorrect)
                      const Text(
                        'Correctly spelled',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      )
                    else if (word.suggestions.isEmpty)
                      const Text(
                        'Possible spelling issue - no suggestion found',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      )
                    else
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          const Text(
                            'Did you mean:',
                            style:
                                TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                          ...word.suggestions.map(
                            (s) => ChoiceChip(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              materialTapTargetSize: MaterialTapTargetSize.padded,
                              selected: s == correction,
                              label: Text(s,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.accent)),
                              backgroundColor:
                                  AppColors.accent.withValues(alpha: 0.08),
                              side: BorderSide(
                                  color:
                                      AppColors.accent.withValues(alpha: 0.35)),
                              onSelected: (_) => onCorrectionSelected(s),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
