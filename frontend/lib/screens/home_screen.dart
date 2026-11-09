import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/offline_detector.dart';
import '../services/progress_notifier.dart';
import '../services/spelling_feedback.dart';
import '../models/word_box.dart';
import '../state/review_session.dart';
import '../widgets/overlay_painter.dart';
import '../widgets/how_it_works_sheet.dart';
import '../widgets/photo_panel.dart';
import '../widgets/review_panel.dart';
import '../widgets/word_editor_sheet.dart';
import '../theme/app_theme.dart';
import '../theme/highlight_colors.dart';

/// Main screen: capture/pick a photo → offline detection → grounded feedback.
/// No server needed — ONNX models run locally on the device.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  File? _imageFile;
  bool _loading = false;
  bool _initializing = true;
  ReviewSession? _session;
  Rect _crop = Rect.zero;
  String? _error;
  Size _imagePixelSize = Size.zero;
  ui.Image? _displayImage;

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
    _session?.dispose();
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

  /// Replaces the review of the previous scan.
  void _setSession(ReviewSession? session) {
    final old = _session;
    _session = session;
    _crop = session == null
        ? Rect.zero
        : _focusedCropRect([for (final e in session.entries) e.word]);
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    // Widgets of the previous scan may still reference it this frame.
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
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
      _setSession(null);
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
      _setSession(null);
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
        _setSession(ReviewSession(results));
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
        final session = _session;
        Widget layout() => Column(
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
        // The photo follows the review (selection, corrections).
        return session == null
            ? layout()
            : ListenableBuilder(
                listenable: session, builder: (context, _) => layout());
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
    final session = _session;
    final current = session?.current;
    final crop =
        session == null || _crop.isEmpty ? Offset.zero & _imagePixelSize : _crop;
    return PhotoPanel(
      imageFile: _imageFile!,
      image: _displayImage,
      imageSize: _imagePixelSize,
      crop: crop,
      overlay: [
        if (session != null)
          for (final entry in session.entries)
            if (entry.isOpen)
              OverlayWord(
                word: entry.word,
                correction: entry.correction,
                color: HighlightColors.forInk(entry.word.inkColor),
                selected: entry.id == current?.id,
              ),
      ],
      words: [
        if (session != null)
          for (final entry in session.entries)
            (id: entry.id, bbox: entry.word.bbox),
      ],
      focus: current?.word.bbox,
      onWordTap:
          session == null ? null : (id) => _onWordTap(session.entry(id)),
    );
  }

  Rect _focusedCropRect(List<WordBox> words) {
    final imageRect = Offset.zero & _imagePixelSize;
    if (_imagePixelSize == Size.zero || words.isEmpty) {
      return imageRect;
    }

    var left = _imagePixelSize.width;
    var top = _imagePixelSize.height;
    var right = 0.0;
    var bottom = 0.0;

    for (final word in words) {
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

    final session = _session;
    if (session == null || session.entries.isEmpty) {
      return const Center(
        child: Text(
          'No words detected. Try a closer, well-lit photo.',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }

    return ReviewPanel(
      session: session,
      onWordTap: _onWordTap,
      onEdit: (entry, typeCorrection) =>
          _editWord(entry, typeCorrection: typeCorrection),
      onDismiss: _dismiss,
    );
  }

  /// A word was tapped on the photo or in the recognized text: show it if
  /// it is a mistake under review, otherwise offer to correct it.
  void _onWordTap(ReviewEntry entry) {
    final session = _session;
    if (session == null) return;
    if (!session.show(entry.id)) _editWord(entry);
  }

  void _dismiss(ReviewEntry entry) {
    final session = _session;
    if (session == null) return;
    session.dismiss(entry.id);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed “${entry.word.text}” from the review'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (identical(_session, session)) session.restore(entry.id);
          },
        ),
      ));
  }

  /// Lets the user fix misread letters and/or type the intended word.
  Future<void> _editWord(ReviewEntry entry,
      {bool typeCorrection = false}) async {
    final session = _session;
    if (session == null) return;
    final edit = await showWordEditor(
      context,
      word: entry.word,
      correction: entry.isMistake ? entry.correction : null,
      image: _displayImage,
      typeCorrection: typeCorrection,
    );
    if (edit == null || !mounted || !identical(_session, session)) return;

    var word = entry.word;
    final writtenChanged = edit.written != word.text;
    if (writtenChanged) {
      word = word.copyWith(
        text: edit.written,
        characters: SpellingFeedback.realignCharacters(word, edit.written),
      );
    }
    final intended = edit.intended;

    // The word is right as written (e.g. the app had misread a letter).
    if (intended.isNotEmpty &&
        intended.toLowerCase() == edit.written.toLowerCase()) {
      session.update(
          entry.id, word.copyWith(isCorrect: true, suggestions: const []));
      _snack('“${edit.written}” is spelled correctly.');
      return;
    }

    var isCorrect = word.isCorrect;
    var suggestions = word.suggestions;
    if (writtenChanged || intended.isEmpty) {
      final entries = session.entries;
      try {
        (isCorrect, suggestions) = await OfflineDetector.checkWord(
          edit.written,
          previous: entry.id > 0 ? entries[entry.id - 1].word.text : null,
          next: entry.id + 1 < entries.length
              ? entries[entry.id + 1].word.text
              : null,
        );
      } catch (_) {
        // Without the spell checker, keep the user's input.
        suggestions = const [];
      }
      if (!mounted || !identical(_session, session)) return;
    }

    if (intended.isEmpty) {
      session.update(entry.id,
          word.copyWith(isCorrect: isCorrect, suggestions: suggestions));
      if (isCorrect) _snack('“${edit.written}” is spelled correctly.');
      return;
    }

    // A mistake whose intended word the user entered.
    session.update(
      entry.id,
      word.copyWith(isCorrect: false, suggestions: [
        intended,
        for (final s in suggestions)
          if (s.toLowerCase() != intended.toLowerCase()) s,
      ]),
      target: intended,
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
