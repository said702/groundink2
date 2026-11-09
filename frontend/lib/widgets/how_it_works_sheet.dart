import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Shows the "How it works" bottom sheet explaining the 4-step pipeline:
/// Capture → Transcribe → Feedback → Grounded.
void showHowItWorksSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => const _HowItWorksSheet(),
  );
}

class _HowItWorksSheet extends StatelessWidget {
  const _HowItWorksSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
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
            const SizedBox(height: 20),
            const Text(
              'How it works',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              'Visually grounded feedback for handwritten learner input',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            const _Step(
              number: 1,
              icon: Icons.photo_camera_outlined,
              color: AppColors.primary,
              title: 'Capture',
              body: 'Take a photo of handwritten text — from a worksheet, '
                  'notebook, or tablet screenshot.',
            ),
            const _Step(
              number: 2,
              icon: Icons.text_fields,
              color: AppColors.accent,
              title: 'Transcribe',
              body: 'On-device AI detects words and reads individual '
                  'characters in your handwriting.',
            ),
            const _Step(
              number: 3,
              icon: Icons.spellcheck,
              color: AppColors.warning,
              title: 'Feedback',
              body: 'Each word is checked against an English dictionary. '
                  'Suggestions are ranked by how common a word is, by '
                  'typical mistakes, and by the neighboring words.',
            ),
            const _Step(
              number: 4,
              icon: Icons.gps_fixed,
              color: AppColors.error,
              title: 'Grounded',
              body: 'Letters that differ from the selected suggestion are '
                  'highlighted in red (in blue if the writing itself is red). '
                  'Missing letters have no existing stroke to highlight. '
                  'Swipe through the mistakes, tap a word to correct it, '
                  'or remove a mistake you do not want to look at.',
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: AppColors.success.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_outline, size: 18, color: AppColors.success),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Runs fully offline — your handwriting never leaves the device.',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.success),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  const _Step({
    required this.number,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(icon, color: color, size: 22),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$number.  $title',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        fontSize: 13, color: Colors.black54, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
