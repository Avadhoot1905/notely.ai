// Companion overlay — the Flutter UI rendered inside the SEPARATE native overlay window.
//
// This is a second Flutter entrypoint. The native side (macOS NSPanel today) runs a dedicated
// FlutterEngine on [companionMain], so this UI lives in its own always-on-top, transparent,
// non-activating desktop window — NOT inside the main Notely window.
//
// It is intentionally state-light: it renders whatever snapshot the main app pushes over
// `notely/companion/incoming` and sends button presses back over `notely/companion/outgoing`.
// The single source of truth remains the MeetingSessionManager in the main engine.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Entry point invoked by the native runner for the companion window's FlutterEngine.
@pragma('vm:entry-point')
void companionMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _CompanionApp());
}

/// Channel the native side calls to push snapshots into this engine.
const _incoming = MethodChannel('notely/companion/incoming');

/// Channel this engine calls to send commands out (native relays to the main engine).
const _outgoing = MethodChannel('notely/companion/outgoing');

class _CompanionSnapshot {
  const _CompanionSnapshot({
    required this.status,
    required this.paused,
    required this.elapsedSeconds,
    required this.lines,
    this.partial,
    this.meetingTitle,
  });

  final String status; // idle | listening | paused | processing | stopped
  final bool paused;
  final int elapsedSeconds;
  final List<Map<String, String>> lines;
  final Map<String, String>? partial;
  final String? meetingTitle;

  static Map<String, String> _line(Map l) => {
    'speaker': '${l['speaker'] ?? ''}',
    'time': '${l['time'] ?? ''}',
    'text': '${l['text'] ?? ''}',
  };

  factory _CompanionSnapshot.fromMap(Map<dynamic, dynamic> m) {
    final rawLines = (m['lines'] as List?) ?? const [];
    final rawPartial = m['partial'];
    return _CompanionSnapshot(
      status:
          (m['status'] as String?) ??
          (m['paused'] == true ? 'paused' : 'listening'),
      paused: m['paused'] == true,
      elapsedSeconds: (m['elapsedSeconds'] as int?) ?? 0,
      meetingTitle: m['meetingTitle'] as String?,
      partial: rawPartial is Map ? _line(rawPartial) : null,
      lines: rawLines.whereType<Map>().map(_line).toList(),
    );
  }
}

/// Status → (headline, indicator color, whether the dot pulses).
({String label, Color color, bool pulse}) _statusStyle(String status) =>
    switch (status) {
      'paused' => (label: 'Notely paused', color: _warning, pulse: false),
      'processing' => (label: 'Processing…', color: _accent, pulse: false),
      'stopped' => (label: 'Stopped', color: _textFaint, pulse: false),
      'idle' => (label: 'Notely', color: _textFaint, pulse: false),
      _ => (label: 'Notely is listening', color: _recording, pulse: true),
    };

class _CompanionApp extends StatefulWidget {
  const _CompanionApp();

  @override
  State<_CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<_CompanionApp> {
  _CompanionSnapshot _snap = const _CompanionSnapshot(
    status: 'listening',
    paused: false,
    elapsedSeconds: 0,
    lines: [],
  );
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _incoming.setMethodCallHandler((call) async {
      if (call.method == 'update' && call.arguments is Map) {
        setState(
          () => _snap = _CompanionSnapshot.fromMap(call.arguments as Map),
        );
      } else if (call.method == 'setExpanded') {
        setState(() => _expanded = call.arguments == true);
      }
      return null;
    });
  }

  void _send(String command) => _outgoing.invokeMethod('command', command);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      home: Builder(
        builder: (context) {
          final reduceMotion = MediaQuery.of(context).disableAnimations;
          return Scaffold(
            backgroundColor: Colors.transparent,
            // Hover is the core interaction: entering the window expands, leaving collapses —
            // reusing the native window's expand/collapse resize (no focus stealing; the panel is
            // non-activating). Tap still expands as a fallback.
            body: MouseRegion(
              onEnter: (_) {
                if (!_expanded) _send('expand');
              },
              onExit: (_) {
                if (_expanded) _send('collapse');
              },
              child: Align(
                alignment: Alignment.topLeft,
                child: _expanded
                    ? _Popover(
                        snap: _snap,
                        reduceMotion: reduceMotion,
                        onPause: () => _send(_snap.paused ? 'resume' : 'pause'),
                        onStop: () => _send('stop'),
                        onOpen: () => _send('openInNotely'),
                        onCollapse: () => _send('collapse'),
                      )
                    : _Pill(
                        snap: _snap,
                        reduceMotion: reduceMotion,
                        onTap: () => _send('expand'),
                        // macOS drags the panel natively (movable-by-background); Windows/Linux
                        // need the UI to initiate the native window move via a command.
                        onDragStart:
                            defaultTargetPlatform == TargetPlatform.macOS
                            ? null
                            : () => _send('beginDrag'),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _fmt(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

const _panel = Color(0xFF1B1D22);
const _raised = Color(0xFF23262D);
const _border = Color(0xFF33373F);
const _accent = Color(0xFF6C8CFF);
const _recording = Color(0xFFFF5D5D);
const _warning = Color(0xFFF2B34B);
const _textPrimary = Color(0xFFE6E8EC);
const _textSecondary = Color(0xFFA0A6B0);
const _textFaint = Color(0xFF6C727C);

class _Pill extends StatelessWidget {
  const _Pill({
    required this.snap,
    required this.onTap,
    this.onDragStart,
    this.reduceMotion = false,
  });
  final _CompanionSnapshot snap;
  final VoidCallback onTap;
  final VoidCallback? onDragStart;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(snap.status);
    return Semantics(
      button: true,
      label:
          '${style.label}. ${_fmt(snap.elapsedSeconds)} elapsed. Hover or activate to expand the Notely companion.',
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: GestureDetector(
          onTap: onTap,
          onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _raised,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _border),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 16,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(color: style.color, pulse: style.pulse && !reduceMotion),
                const SizedBox(width: 9),
                Text(
                  style.label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _fmt(snap.elapsedSeconds),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: _textSecondary,
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

class _Popover extends StatelessWidget {
  const _Popover({
    required this.snap,
    required this.onPause,
    required this.onStop,
    required this.onOpen,
    required this.onCollapse,
    this.reduceMotion = false,
  });
  final _CompanionSnapshot snap;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onOpen;
  final VoidCallback onCollapse;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(snap.status);
    final items = <Widget>[
      for (final l in snap.lines) _lineTile(l),
      if (snap.partial != null) _lineTile(snap.partial!, partial: true),
    ];
    final emptyText = snap.status == 'paused'
        ? 'Paused'
        : 'Waiting for speech…';
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  _Dot(color: style.color, pulse: style.pulse && !reduceMotion),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      snap.meetingTitle ?? style.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _fmt(snap.elapsedSeconds),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: _textSecondary,
                    ),
                  ),
                  const Spacer(),
                  _IconBtn(
                    icon: Icons.close_rounded,
                    semanticLabel: 'Collapse companion',
                    onTap: onCollapse,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _border),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          emptyText,
                          style: const TextStyle(
                            fontSize: 12,
                            color: _textFaint,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      children: items,
                    ),
            ),
            const Divider(height: 1, color: _border),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: _ActionBtn(
                      label: snap.paused ? 'Resume' : 'Pause',
                      icon: snap.paused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                      onTap: onPause,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionBtn(
                      label: 'Stop',
                      icon: Icons.stop_rounded,
                      danger: true,
                      onTap: onStop,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: _ActionBtn(
                label: 'Open in Notely',
                icon: Icons.open_in_new_rounded,
                filled: true,
                onTap: onOpen,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.filled = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color bg = filled
        ? _accent
        : danger
        ? _recording.withValues(alpha: 0.14)
        : _raised;
    final Color fg = filled
        ? Colors.white
        : danger
        ? _recording
        : _textPrimary;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: filled ? Colors.transparent : _border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
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
    );
  }
}

/// A finalized or partial transcript tile. Partials render dimmed + italic ("visually mutable")
/// so a user sees speech settling; when a partial becomes final it replaces this cleanly (the
/// projection moves it from `partial` into `lines`, so there is no duplication).
Widget _lineTile(Map<String, String> l, {bool partial = false}) {
  final speaker = l['speaker'] ?? '';
  final time = l['time'] ?? '';
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (speaker.isNotEmpty || time.isNotEmpty)
          Row(
            children: [
              if (speaker.isNotEmpty) ...[
                Text(
                  speaker,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _accent,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                time,
                style: const TextStyle(fontSize: 10, color: _textFaint),
              ),
            ],
          ),
        const SizedBox(height: 2),
        Text(
          l['text'] ?? '',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: partial ? _textSecondary : _textPrimary,
            fontStyle: partial ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ],
    ),
  );
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap, this.semanticLabel});
  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 15, color: _textFaint),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulse});
  final Color color;
  final bool pulse;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
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
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulse && _c.isAnimating) {
      _c
        ..stop()
        ..value = 1;
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
      child: dot,
    );
  }
}
