// The primary listening controls in the sidebar.
//
// Renders from [ListeningController.state]:
//   idle      → [● Start listening]
//   listening → [■ Stop listening]  [Ⅱ Pause]
//   paused    → [▶ Resume]          [■ Stop]
//   reviewing → a muted "Reviewing" hint (actions live in the transcript panel footer)
//
// Visual language matches the original single accent control — compact rows, same radius/size.

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
                    icon: Icons.stop,
                    style: _BtnStyle.danger,
                    onTap: listening.stop,
                  ),
                ),
                const SizedBox(width: 8),
                _Btn(
                  label: 'Pause',
                  icon: Icons.pause,
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
                    icon: Icons.play_arrow,
                    style: _BtnStyle.accent,
                    onTap: listening.resume,
                  ),
                ),
                const SizedBox(width: 8),
                _Btn(
                  label: 'Stop',
                  icon: Icons.stop,
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
                border: Border.all(color: NotelyColors.border),
              ),
              child: const Text(
                'Reviewing — summarise or close →',
                style: TextStyle(fontSize: 11.5, color: NotelyColors.textFaint),
              ),
            );
        }
      },
    );
  }
}

enum _BtnStyle { accent, danger, neutral }

class _Btn extends StatelessWidget {
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
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Color border;
    switch (style) {
      case _BtnStyle.accent:
        bg = NotelyColors.accent;
        fg = const Color(0xFF0E1114);
        border = Colors.transparent;
      case _BtnStyle.danger:
        bg = NotelyColors.recording.withValues(alpha: 0.14);
        fg = NotelyColors.recording;
        border = NotelyColors.recording.withValues(alpha: 0.5);
      case _BtnStyle.neutral:
        bg = NotelyColors.raised;
        fg = NotelyColors.textPrimary;
        border = NotelyColors.border;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: iconSize, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
