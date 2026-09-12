// Right-hand transcript panel.
//
// Mounted for any non-idle session state (the workspace shell animates the slide-in). Shows:
//   • a header whose indicator reflects Listening / Paused / Review,
//   • a compact audio-capability strip (honest about mic vs system audio),
//   • the scrollable conversational transcript,
//   • a Review footer (Summarise / Close) once capture has stopped.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/audio/meeting_audio_service.dart';
import 'listening_state.dart';
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
      child: AnimatedBuilder(
        animation: listening,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(listening.state),
              _CapabilityStrip(caps: listening.audioCapabilities),
              Expanded(child: _transcript(listening.entries)),
              if (listening.isReviewing) const _ReviewFooter(),
            ],
          );
        },
      ),
    );
  }

  Widget _transcript(List entries) {
    if (entries.isEmpty) {
      return const Center(
        child: Text(
          'Waiting for speech…',
          style: TextStyle(fontSize: 12.5, color: NotelyColors.textFaint),
        ),
      );
    }
    _autoScroll();
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      itemCount: entries.length,
      itemBuilder: (context, i) =>
          TranscriptMessage(key: ValueKey(i), entry: entries[i]),
    );
  }

  Widget _header(ListeningState state) {
    final (Color color, String label, bool pulse) = switch (state) {
      ListeningState.listening => (NotelyColors.recording, 'Listening', true),
      ListeningState.paused => (const Color(0xFFC9A15B), 'Paused', false),
      ListeningState.reviewing => (NotelyColors.textSecondary, 'Review', false),
      ListeningState.idle => (NotelyColors.textFaint, '', false),
    };
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
          _StatusDot(color: color, pulse: pulse),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 11.5, color: color)),
        ],
      ),
    );
  }
}

/// Honest per-source availability (mic vs system/call audio).
class _CapabilityStrip extends StatelessWidget {
  const _CapabilityStrip({required this.caps});
  final AudioCapabilities caps;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: NotelyColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row('Microphone', caps.microphone),
          const SizedBox(height: 4),
          _row('System audio', caps.systemAudio, note: caps.systemAudioNote),
        ],
      ),
    );
  }

  Widget _row(String label, AudioSourceStatus status, {String? note}) {
    final (IconData icon, Color color, String text) = switch (status) {
      AudioSourceStatus.available => (
        Icons.check_circle_outline,
        Color(0xFF8FC98C),
        'Available',
      ),
      AudioSourceStatus.permissionRequired => (
        Icons.error_outline,
        Color(0xFFC9A15B),
        'Permission required',
      ),
      AudioSourceStatus.unsupported => (
        Icons.block,
        NotelyColors.textFaint,
        'Unsupported',
      ),
      AudioSourceStatus.unavailable => (
        Icons.remove_circle_outline,
        NotelyColors.textFaint,
        'Unavailable',
      ),
    };
    return Tooltip(
      message: note ?? '',
      triggerMode: note == null
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: NotelyColors.textSecondary,
              ),
            ),
          ),
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

/// Review actions shown once capture has stopped.
class _ReviewFooter extends StatelessWidget {
  const _ReviewFooter();

  Future<void> _summarise(BuildContext context) async {
    final scope = AppScope.of(context);
    // Summaries write into the open note. If none is open, create one in the stash first.
    if (!scope.editor.hasOpenNote) {
      final path = await scope.explorer.createFile('Meeting Notes');
      if (path != null) {
        await scope.editor.open(path);
      } else {
        return; // creation failed; explorer.error surfaces the reason
      }
    }
    await scope.listening.summarise(editor: scope.editor);
  }

  @override
  Widget build(BuildContext context) {
    final listening = AppScope.of(context).listening;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: NotelyColors.panel,
        border: Border(top: BorderSide(color: NotelyColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _FooterBtn(
              label: listening.isSummarising ? 'Summarising…' : 'Summarise',
              icon: Icons.auto_awesome,
              primary: true,
              onTap: listening.isSummarising ? null : () => _summarise(context),
            ),
          ),
          const SizedBox(width: 8),
          _FooterBtn(
            label: 'Close',
            icon: Icons.close,
            primary: false,
            onTap: listening.isSummarising ? null : listening.close,
          ),
        ],
      ),
    );
  }
}

class _FooterBtn extends StatelessWidget {
  const _FooterBtn({
    required this.label,
    required this.icon,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg = primary ? NotelyColors.accent : NotelyColors.raised;
    final Color fg = primary
        ? const Color(0xFF0E1114)
        : NotelyColors.textPrimary;
    final Color border = primary ? Colors.transparent : NotelyColors.border;
    return Opacity(
      opacity: onTap == null ? 0.6 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(NotelyDims.radius),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 7),
                Text(
                  label,
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
      ),
    );
  }
}

/// Status dot that optionally pulses (used for the active "Listening" state).
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, required this.pulse});
  final Color color;
  final bool pulse;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulse && _c.isAnimating) {
      _c
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulse) return dot;
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: dot,
    );
  }
}
