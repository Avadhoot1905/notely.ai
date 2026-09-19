// Right-hand transcript panel.
//
// Mounted for any non-idle session state (the workspace shell animates the slide-in). Shows:
//   • a header with a "LIVE TRANSCRIPT" identity label and a state indicator,
//   • a compact audio-capability strip (honest about mic vs system audio),
//   • the scrollable conversation timeline,
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
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(left: BorderSide(color: t.border)),
      ),
      child: AnimatedBuilder(
        animation: listening,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(t, listening.state),
              _CapabilityStrip(caps: listening.audioCapabilities),
              Expanded(child: _transcript(t, listening.entries)),
              if (listening.isReviewing) const _ReviewFooter(),
            ],
          );
        },
      ),
    );
  }

  Widget _transcript(NotelyTokens t, List entries) {
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'Waiting for speech…',
          style: TextStyle(fontSize: 12.5, color: t.textFaint),
        ),
      );
    }
    _autoScroll();
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      itemCount: entries.length,
      itemBuilder: (context, i) =>
          TranscriptMessage(key: ValueKey(i), entry: entries[i]),
    );
  }

  Widget _header(NotelyTokens t, ListeningState state) {
    final (Color color, String label, bool pulse) = switch (state) {
      ListeningState.listening => (t.recording, 'Listening', true),
      ListeningState.paused => (t.warning, 'Paused', false),
      ListeningState.reviewing => (t.textSecondary, 'Review', false),
      ListeningState.idle => (t.textFaint, '', false),
    };
    final icon = switch (state) {
      ListeningState.paused => Icons.pause_rounded,
      ListeningState.reviewing => Icons.check_rounded,
      _ => null,
    };
    return Container(
      height: NotelyDims.titleBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Text(
            'LIVE TRANSCRIPT',
            style: NotelyType.sectionLabel.copyWith(color: t.textSecondary),
          ),
          const Spacer(),
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: Icon(icon, size: 13, color: color),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _StatusDot(color: color, pulse: pulse),
            ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
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
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(t, 'Microphone', caps.microphone, note: caps.microphoneNote),
          const SizedBox(height: 4),
          _row(t, 'System audio', caps.systemAudio, note: caps.systemAudioNote),
        ],
      ),
    );
  }

  Widget _row(
    NotelyTokens t,
    String label,
    AudioSourceStatus status, {
    String? note,
  }) {
    final (IconData icon, Color color, String text) = switch (status) {
      AudioSourceStatus.capturing => (
        Icons.check_circle,
        t.success,
        'Capturing',
      ),
      AudioSourceStatus.available => (
        Icons.check_circle_outline,
        t.success,
        'Available',
      ),
      AudioSourceStatus.permissionRequired => (
        Icons.error_outline,
        t.warning,
        'Permission required',
      ),
      AudioSourceStatus.unsupported => (
        Icons.block,
        t.textFaint,
        'Unsupported',
      ),
      AudioSourceStatus.unavailable => (
        Icons.remove_circle_outline,
        t.textFaint,
        'Unavailable',
      ),
      AudioSourceStatus.error => (
        Icons.error_outline,
        t.danger,
        'Capture error',
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
              style: TextStyle(fontSize: 11, color: t.textSecondary),
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
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _FooterBtn(
              label: listening.isSummarising ? 'Summarising…' : 'Summarise',
              icon: Icons.auto_awesome_outlined,
              primary: true,
              onTap: listening.isSummarising ? null : () => _summarise(context),
            ),
          ),
          const SizedBox(width: 8),
          _FooterBtn(
            label: 'Close',
            icon: Icons.close_rounded,
            primary: false,
            onTap: listening.isSummarising ? null : listening.close,
          ),
        ],
      ),
    );
  }
}

class _FooterBtn extends StatefulWidget {
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
  State<_FooterBtn> createState() => _FooterBtnState();
}

class _FooterBtnState extends State<_FooterBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final Color bg = widget.primary
        ? (_hover ? Color.lerp(t.accent, Colors.white, 0.08)! : t.accent)
        : (_hover ? t.raised : t.raised.withValues(alpha: 0.6));
    final Color fg = widget.primary ? t.onAccent : t.textPrimary;
    final Color border = widget.primary ? Colors.transparent : t.border;
    return Opacity(
      opacity: widget.onTap == null ? 0.6 : 1.0,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NotelyMotion.fast,
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
                Icon(widget.icon, size: 14, color: fg),
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: NotelyType.button.copyWith(color: fg),
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
    // A soft glow ring communicates "live" without looking like an AI effect.
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_c),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.5),
              blurRadius: 5,
            ),
          ],
        ),
        child: dot,
      ),
    );
  }
}
