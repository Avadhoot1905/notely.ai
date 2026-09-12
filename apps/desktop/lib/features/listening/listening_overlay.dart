// The floating "Notely is listening" widget (Granola-style).
//
// While a session is capturing (listening or paused) a small draggable pill floats over the
// workspace, making it obvious that Notely is recording — even when attention is on the call.
// Tapping the pill reveals a compact popover: the live transcript plus quick pause/stop actions,
// like the right-hand panel but smaller. The popover closes on the ✕, on tapping the pill again,
// or on a click anywhere outside it.
//
// This is an in-app overlay. A true always-on-top window that floats over *other* apps needs
// native window management (a platform plugin / the Rust shell); the widget is built so that
// swap stays localized — it reads only [ListeningController].

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import 'listening_state.dart';

class ListeningOverlay extends StatefulWidget {
  const ListeningOverlay({super.key});

  @override
  State<ListeningOverlay> createState() => _ListeningOverlayState();
}

class _ListeningOverlayState extends State<ListeningOverlay> {
  static const double _pillW = 210;
  static const double _pillH = 40;
  static const double _popW = 320;
  static const double _margin = 12;

  bool _open = false;
  double? _left;
  double? _bottom;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Keep the elapsed readout ticking between transcript events.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _onDrag(DragUpdateDetails d, double maxLeft, double maxBottom) {
    setState(() {
      _left = ((_left ?? 0) + d.delta.dx).clamp(_margin, maxLeft);
      _bottom = ((_bottom ?? 0) - d.delta.dy).clamp(_margin, maxBottom);
    });
  }

  @override
  Widget build(BuildContext context) {
    final listening = AppScope.of(context).listening;
    return AnimatedBuilder(
      animation: listening,
      builder: (context, _) {
        final active = listening.isListening || listening.isPaused;
        if (!active) {
          _open = false;
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final contentW = math.max(_pillW, _popW);
            final maxLeft = math.max(_margin, w - contentW - _margin);
            final maxBottom = math.max(_margin, h - _pillH - _margin);
            // Default anchor: bottom-centred, just above the status bar.
            _left ??= ((w - _pillW) / 2).clamp(_margin, maxLeft);
            _bottom ??= 72.0.clamp(_margin, maxBottom);
            final left = _left!.clamp(_margin, maxLeft);
            final bottom = _bottom!.clamp(_margin, maxBottom);

            return Stack(
              children: [
                // Click-away layer: any tap outside the pill/popover dismisses the popover.
                if (_open)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _open = false),
                    ),
                  ),
                Positioned(
                  left: left,
                  bottom: bottom,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_open) ...[
                        _Popover(onClose: () => setState(() => _open = false)),
                        const SizedBox(height: 8),
                      ],
                      _Pill(
                        listening: listening,
                        expanded: _open,
                        onTap: () => setState(() => _open = !_open),
                        onDrag: (d) => _onDrag(d, maxLeft, maxBottom),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

(Color, String, bool) _statusOf(NotelyTokens t, ListeningState s) =>
    switch (s) {
      ListeningState.paused => (t.warning, 'Notely is paused', false),
      _ => (t.recording, 'Notely is listening', true),
    };

// ─────────────────────────────────────────────────────────────────────────────
// Collapsed pill
// ─────────────────────────────────────────────────────────────────────────────
class _Pill extends StatefulWidget {
  const _Pill({
    required this.listening,
    required this.expanded,
    required this.onTap,
    required this.onDrag,
  });

  final ListeningController listening;
  final bool expanded;
  final VoidCallback onTap;
  final GestureDragUpdateCallback onDrag;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (color, label, pulse) = _statusOf(t, widget.listening.state);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanUpdate: widget.onDrag,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          height: _ListeningOverlayState._pillH,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _hover ? Color.alphaBlend(t.hover, t.raised) : t.raised,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: t.borderStrong),
            boxShadow: [
              BoxShadow(
                color: t.overlayScrim.withValues(alpha: 0.3),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LiveDot(color: color, pulse: pulse),
              const SizedBox(width: 9),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: t.textPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _fmt(widget.listening.elapsed),
                style: NotelyType.statusMono.copyWith(
                  fontSize: 11.5,
                  color: t.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                widget.expanded ? Icons.expand_more : Icons.expand_less,
                size: 16,
                color: t.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Expanded popover: compact transcript + quick actions
// ─────────────────────────────────────────────────────────────────────────────
class _Popover extends StatefulWidget {
  const _Popover({required this.onClose});
  final VoidCallback onClose;

  @override
  State<_Popover> createState() => _PopoverState();
}

class _PopoverState extends State<_Popover> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final listening = AppScope.of(context).listening;
    final t = context.tokens;
    final (color, _, pulse) = _statusOf(t, listening.state);
    final entries = listening.entries;
    if (entries.isNotEmpty) _autoScroll();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: _ListeningOverlayState._popW,
        decoration: BoxDecoration(
          color: t.panel,
          borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
          border: Border.all(color: t.borderStrong),
          boxShadow: [
            BoxShadow(
              color: t.overlayScrim.withValues(alpha: 0.34),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  _LiveDot(color: color, pulse: pulse),
                  const SizedBox(width: 9),
                  Text(
                    listening.isPaused ? 'Paused' : 'Listening',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _fmt(listening.elapsed),
                    style: NotelyType.statusMono.copyWith(
                      fontSize: 11.5,
                      color: t.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  _IconBtn(
                    icon: Icons.close_rounded,
                    tip: 'Hide',
                    onTap: widget.onClose,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: t.border),
            // Transcript.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 256),
              child: entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Center(
                        child: Text(
                          'Waiting for speech…',
                          style: TextStyle(fontSize: 12, color: t.textFaint),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final e = entries[i];
                        return _CompactLine(
                          speaker: e.speaker,
                          time: e.time,
                          text: e.text,
                        );
                      },
                    ),
            ),
            Divider(height: 1, color: t.border),
            // Quick actions.
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: listening.isPaused
                        ? _ActionBtn(
                            label: 'Resume',
                            icon: Icons.play_arrow_rounded,
                            tone: _Tone.accent,
                            onTap: listening.resume,
                          )
                        : _ActionBtn(
                            label: 'Pause',
                            icon: Icons.pause_rounded,
                            tone: _Tone.neutral,
                            onTap: listening.pause,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionBtn(
                      label: 'Stop',
                      icon: Icons.stop_rounded,
                      tone: _Tone.danger,
                      onTap: listening.stop,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactLine extends StatelessWidget {
  const _CompactLine({
    required this.speaker,
    required this.time,
    required this.text,
  });
  final String speaker;
  final String time;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = t.speakerFor(speaker);
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                speaker,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                time,
                style: NotelyType.statusMono.copyWith(
                  fontSize: 10,
                  color: t.textFaint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            text,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: t.textPrimary),
          ),
        ],
      ),
    );
  }
}

enum _Tone { accent, danger, neutral }

class _ActionBtn extends StatefulWidget {
  const _ActionBtn({
    required this.label,
    required this.icon,
    required this.tone,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final _Tone tone;
  final VoidCallback onTap;

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    late final Color bg;
    late final Color fg;
    late final Color border;
    switch (widget.tone) {
      case _Tone.accent:
        bg = _hover ? Color.lerp(t.accent, Colors.white, 0.08)! : t.accent;
        fg = t.onAccent;
        border = Colors.transparent;
      case _Tone.danger:
        bg = t.recording.withValues(alpha: _hover ? 0.2 : 0.14);
        fg = t.recording;
        border = t.recording.withValues(alpha: 0.5);
      case _Tone.neutral:
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
          height: 32,
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
              const SizedBox(width: 6),
              Text(widget.label, style: NotelyType.button.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatefulWidget {
  const _IconBtn({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NotelyMotion.fast,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hover ? t.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: _hover ? t.textSecondary : t.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// A status dot that softly pulses while live (shared look with the transcript header).
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.color, required this.pulse});
  final Color color;
  final bool pulse;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
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
  void didUpdateWidget(_LiveDot old) {
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
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulse) return dot;
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_c),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.5),
              blurRadius: 6,
            ),
          ],
        ),
        child: dot,
      ),
    );
  }
}
