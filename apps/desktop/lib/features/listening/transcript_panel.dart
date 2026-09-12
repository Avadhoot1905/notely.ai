// Right-hand live transcript panel.
//
// Mounted only while listening is active (the workspace shell handles the slide-in). Shows a
// header with a pulsing "Listening" indicator and a scrollable, auto-following list of
// conversational transcript messages.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import 'transcript_message.dart';

class TranscriptPanel extends StatefulWidget {
  const TranscriptPanel({super.key});

  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final listening = AppScope.of(context).listening;
    return Container(
      decoration: const BoxDecoration(
        color: NotelyColors.panel,
        border: Border(left: BorderSide(color: NotelyColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: AnimatedBuilder(
              animation: listening,
              builder: (context, _) {
                final entries = listening.entries;
                _autoScroll();
                if (entries.isEmpty) {
                  return const Center(
                    child: Text(
                      'Waiting for speech…',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: NotelyColors.textFaint,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  itemCount: entries.length,
                  itemBuilder: (context, i) =>
                      TranscriptMessage(key: ValueKey(i), entry: entries[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      height: NotelyDims.titleBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: NotelyColors.border)),
      ),
      child: Row(
        children: [
          const Text(
            'Live transcript',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: NotelyColors.textPrimary,
            ),
          ),
          const Spacer(),
          const _PulsingDot(),
          const SizedBox(width: 6),
          const Text(
            'Listening',
            style: TextStyle(fontSize: 11.5, color: NotelyColors.recording),
          ),
        ],
      ),
    );
  }
}

/// A small pulsing red dot indicating an active session.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: NotelyColors.recording,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
