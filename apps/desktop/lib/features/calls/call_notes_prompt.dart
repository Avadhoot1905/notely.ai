// The "take notes for this call?" prompt.
//
// A calm banner that slides down from the top when a call is detected (see
// [CallDetectionController]). It offers to start a listening session for the call or to ignore
// it. Only the card absorbs pointers; the rest of the screen stays interactive. Starting notes
// hands off to [ListeningController], after which the floating listening widget takes over.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';

class CallNotesPrompt extends StatelessWidget {
  const CallNotesPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
      animation: scope.callDetection,
      builder: (context, _) {
        final call = scope.callDetection.pending;
        return AnimatedSwitcher(
          duration: NotelyMotion.base,
          switchInCurve: NotelyMotion.curve,
          switchOutCurve: NotelyMotion.curve,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, -0.25),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: call == null
              ? const SizedBox.shrink(key: ValueKey('none'))
              : Align(
                  key: const ValueKey('prompt'),
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _Card(source: call.source, title: call.title),
                  ),
                ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.source, this.title});
  final String source;
  final String? title;

  void _startNotes(BuildContext context) {
    final scope = AppScope.of(context);
    scope.callDetection.dismiss();
    scope.listening.start(activeFilePath: scope.editor.openPath);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final subtitle = title == null ? source : '$source · $title';
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: t.raised,
          borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
          border: Border.all(color: t.border),
          boxShadow: [
            BoxShadow(
              color: t.overlayScrim.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: t.accentMuted,
                borderRadius: BorderRadius.circular(NotelyDims.radius),
              ),
              child: Icon(Icons.videocam_outlined, size: 18, color: t.accent),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Call detected',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Take notes for this call?  $subtitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            _PromptBtn(
              label: 'Ignore',
              primary: false,
              onTap: () => AppScope.of(context).callDetection.dismiss(),
            ),
            const SizedBox(width: 8),
            _PromptBtn(
              label: 'Take notes',
              icon: Icons.fiber_manual_record,
              primary: true,
              onTap: () => _startNotes(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _PromptBtn extends StatefulWidget {
  const _PromptBtn({
    required this.label,
    required this.primary,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool primary;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_PromptBtn> createState() => _PromptBtnState();
}

class _PromptBtnState extends State<_PromptBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final Color bg = widget.primary
        ? (_hover ? Color.lerp(t.accent, Colors.white, 0.08)! : t.accent)
        : (_hover ? t.hover : Colors.transparent);
    final Color fg = widget.primary ? t.onAccent : t.textSecondary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(
              color: widget.primary ? Colors.transparent : t.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 10, color: fg),
                const SizedBox(width: 7),
              ],
              Text(widget.label, style: NotelyType.button.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
