// "Ask Notely" control for the title bar (top-right).
//
// A compact pill with an accent spark icon — restrained, but the accent makes it read as the
// one AI affordance. Toggles the Ask panel; highlights while open.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';

class AskButton extends StatefulWidget {
  const AskButton({super.key});

  @override
  State<AskButton> createState() => _AskButtonState();
}

class _AskButtonState extends State<AskButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ask = AppScope.of(context).ask;
    final t = context.tokens;
    return AnimatedBuilder(
      animation: ask,
      builder: (context, _) {
        final open = ask.isOpen;
        final Color bg = open
            ? t.selection
            : (_hover ? t.hover : Colors.transparent);
        final Color border = open ? t.accent : t.border;
        return Tooltip(
          message: 'Ask Notely about your stash',
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: ask.toggle,
              child: AnimatedContainer(
                duration: NotelyMotion.fast,
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(NotelyDims.radius),
                  border: Border.all(color: border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 13, color: t.accent),
                    const SizedBox(width: 7),
                    Text(
                      'Ask Notely',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
