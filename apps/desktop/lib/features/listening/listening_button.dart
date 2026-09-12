// The primary "Start listening" control in the sidebar.
//
// Toggles [ListeningController.startListening]. Prominent but not gigantic: a single compact
// row that flips between an accent "Start listening" and a red-tinted "Stop listening".

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';

class ListeningButton extends StatelessWidget {
  const ListeningButton({super.key});

  @override
  Widget build(BuildContext context) {
    final listening = AppScope.of(context).listening;
    return AnimatedBuilder(
      animation: listening,
      builder: (context, _) {
        final active = listening.startListening;
        final Color bg = active
            ? NotelyColors.recording.withValues(alpha: 0.14)
            : NotelyColors.accent;
        final Color fg = active
            ? NotelyColors.recording
            : const Color(0xFF0E1114);
        final Color border = active
            ? NotelyColors.recording.withValues(alpha: 0.5)
            : Colors.transparent;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: listening.toggle,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            child: Container(
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(NotelyDims.radius),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    active ? Icons.stop : Icons.fiber_manual_record,
                    size: active ? 13 : 11,
                    color: fg,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    active ? 'Stop listening' : 'Start listening',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
