// A single conversational transcript block: timestamp + speaker + bubble.
//
// Styled like a calm chat message (Granola / WhatsApp), not a raw terminal line. Fades/slides
// in when it arrives.

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
    duration: const Duration(milliseconds: 260),
  )..forward();

  // Derive a stable accent per speaker so names are easy to track.
  static const _speakerColors = [
    Color(0xFF5B9BD5),
    Color(0xFF8FC98C),
    Color(0xFFC9A15B),
    Color(0xFFB58FD5),
  ];

  Color get _speakerColor =>
      _speakerColors[widget.entry.speaker.hashCode.abs() %
          _speakerColors.length];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut)),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
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
                      color: _speakerColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.entry.time,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: NotelyColors.textFaint,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: NotelyColors.raised,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(3),
                    topRight: Radius.circular(NotelyDims.radius),
                    bottomLeft: Radius.circular(NotelyDims.radius),
                    bottomRight: Radius.circular(NotelyDims.radius),
                  ),
                  border: Border.all(color: NotelyColors.border),
                ),
                child: Text(
                  widget.entry.text,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.42,
                    color: NotelyColors.textPrimary,
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
