// A single conversational transcript block: speaker + timestamp + message.
//
// Reads as a calm conversation timeline (Granola-like), not a chat app: a thin speaker-colored
// spine on the left, a strong speaker label, a muted timestamp, and restrained message body.
// Fades/slides in as it arrives.

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../mock/mock_transcript.dart';

class TranscriptMessage extends StatefulWidget {
  const TranscriptMessage({super.key, required this.entry});

  final TranscriptEntry entry;

  @override
  State<TranscriptMessage> createState() => _TranscriptMessageState();
}

class _TranscriptMessageState extends State<TranscriptMessage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: NotelyMotion.emphasized,
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final speaker = t.speakerFor(widget.entry.speaker);
    return FadeTransition(
      opacity: _c,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _c, curve: NotelyMotion.curve)),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Speaker spine.
                Container(
                  width: 2,
                  margin: const EdgeInsets.only(top: 2, bottom: 2),
                  decoration: BoxDecoration(
                    color: speaker.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            widget.entry.speaker,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: speaker,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.entry.time,
                            style: NotelyType.statusMono.copyWith(
                              fontSize: 10.5,
                              color: t.textFaint,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.entry.text,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: t.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
