// The primary listening controls in the sidebar.
//
// Renders from [ListeningController.state]:
//   idle      → [● Start listening]   (accent — a primary action with a subtle hover lift)
//   listening → [■ Stop listening]  [Ⅱ Pause]
//   paused    → [▶ Resume]          [■ Stop]   (warning-tinted paused affordance)
//   reviewing → a muted "Reviewing" hint (actions live in the transcript panel footer)
//
// State is communicated by icon + label + color together (never color alone).

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import 'listening_state.dart';

class ListeningButton extends StatelessWidget {
  const ListeningButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final listening = scope.listening;
    final t = context.tokens;
    return AnimatedBuilder(
      animation: listening,
      builder: (context, _) {
        switch (listening.state) {
          case ListeningState.idle:
            return _Btn(
              label: 'Start listening',
              icon: Icons.fiber_manual_record,
              iconSize: 11,
              style: _BtnStyle.accent,
              onTap: () =>
                  listening.start(activeFilePath: scope.editor.openPath),
            );
          case ListeningState.listening:
            return Row(
              children: [
                Expanded(
                  child: _Btn(
                    label: 'Stop listening',
                    icon: Icons.stop_rounded,
                    style: _BtnStyle.danger,
                    onTap: listening.stop,
                  ),
                ),
                const SizedBox(width: 8),
                _Btn(
                  label: 'Pause',
                  icon: Icons.pause_rounded,
                  style: _BtnStyle.neutral,
                  onTap: listening.pause,
                ),
              ],
            );
          case ListeningState.paused:
            return Row(
              children: [
                Expanded(
                  child: _Btn(
                    label: 'Resume',
                    icon: Icons.play_arrow_rounded,
                    style: _BtnStyle.accent,
                    onTap: listening.resume,
                  ),
                ),
                const SizedBox(width: 8),
                _Btn(
                  label: 'Stop',
                  icon: Icons.stop_rounded,
                  style: _BtnStyle.danger,
                  onTap: listening.stop,
                ),
              ],
            );
          case ListeningState.reviewing:
            return Container(
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NotelyDims.radius),
                border: Border.all(color: t.border),
              ),
              child: Text(
                'Reviewing — summarise or close →',
                style: NotelyType.meta.copyWith(color: t.textFaint),
              ),
            );
        }
      },
    );
  }
}

enum _BtnStyle { accent, danger, neutral }

class _Btn extends StatefulWidget {
  const _Btn({
    required this.label,
    required this.icon,
    required this.style,
    required this.onTap,
    this.iconSize = 13,
  });

  final String label;
  final IconData icon;
  final _BtnStyle style;
  final VoidCallback onTap;
  final double iconSize;

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    late final Color bg;
    late final Color fg;
    late final Color border;
    List<BoxShadow>? shadow;

    switch (widget.style) {
      case _BtnStyle.accent:
        bg = _hover ? Color.lerp(t.accent, Colors.white, 0.08)! : t.accent;
        fg = t.onAccent;
        border = Colors.transparent;
        if (_hover) {
          shadow = [
            BoxShadow(
              color: t.accent.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ];
        }
      case _BtnStyle.danger:
        bg = t.recording.withValues(alpha: _hover ? 0.2 : 0.14);
        fg = t.recording;
        border = t.recording.withValues(alpha: 0.5);
      case _BtnStyle.neutral:
        bg = _hover ? t.raised : t.raised.withValues(alpha: 0.6);
        fg = t.textPrimary;
        border = t.border;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(color: border),
            boxShadow: shadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: widget.iconSize, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: NotelyType.button.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
