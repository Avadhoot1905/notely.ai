// Integrations dialog: a small, honest connection UX for external knowledge sources.
//
// Deliberately simple (no admin console): see what's connected and imported, connect a source by
// pasting a token, pick specific channels, and import a bounded range. Every step reinforces the
// model — Slack/Teams are knowledge sources folded into your searchable, citable vault, not
// embedded clients — and makes clear what scope was imported and how to remove it.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../ipc/protocol.dart' as ipc;
import 'integrations_state.dart';

class IntegrationsDialog extends StatelessWidget {
  const IntegrationsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: context.tokens.overlayScrim,
      builder: (_) => const IntegrationsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Dialog(
      backgroundColor: t.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
        side: BorderSide(color: t.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: const _IntegrationsBody(),
      ),
    );
  }
}

enum _Step { overview, connect, pick, done }

class _IntegrationsBody extends StatefulWidget {
  const _IntegrationsBody();

  @override
  State<_IntegrationsBody> createState() => _IntegrationsBodyState();
}

class _IntegrationsBodyState extends State<_IntegrationsBody> {
  _Step _step = _Step.overview;
  SourceKind _kind = SourceKind.slack;

  final TextEditingController _token = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  bool _busy = false;
  String? _error;

  String _workspace = '';
  List<ipc.SourceChannel> _channels = const [];
  final Set<String> _selected = {};
  int _maxMessages = 500;
  ipc.ImportSummary? _summary;

  IntegrationsController get _c => AppScope.of(context).integrations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.refresh());
  }

  @override
  void dispose() {
    _token.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  void _startConnect(SourceKind kind) {
    setState(() {
      _kind = kind;
      _error = null;
      _channels = const [];
      _selected.clear();
      _summary = null;
      _token.text = _c.tokenFor(kind) ?? '';
      _step = _Step.connect;
    });
  }

  Future<void> _continueToPick() async {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Paste a token to continue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await _c.listChannels(
        _kind,
        token,
        baseUrl: _baseUrl.text.trim(),
      );
      setState(() {
        _workspace = res.workspace;
        _channels = res.channels;
        _step = _Step.pick;
      });
    } catch (e) {
      setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_selected.isEmpty) {
      setState(() => _error = 'Select at least one channel.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final summary = await _c.import(
        _kind,
        _token.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        scope: ipc.ImportScope(
          channelIds: _selected.toList(),
          maxMessages: _maxMessages,
        ),
      );
      setState(() {
        _summary = summary;
        _step = _Step.done;
      });
    } catch (e) {
      setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('authentication') || s.contains('Auth')) {
      return 'Authentication failed — check the token and try again.';
    }
    if (s.contains('rate limited')) {
      return 'The service is rate-limiting us. Try again shortly.';
    }
    return s.replaceFirst('EngineError: ', '').replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(t),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: switch (_step) {
              _Step.overview => _overview(t),
              _Step.connect => _connect(t),
              _Step.pick => _pick(t),
              _Step.done => _done(t),
            },
          ),
        ),
      ],
    );
  }

  Widget _header(NotelyTokens t) {
    final title = switch (_step) {
      _Step.overview => 'INTEGRATIONS',
      _Step.connect => 'CONNECT ${_kind.label.toUpperCase()}',
      _Step.pick => 'IMPORT FROM ${_kind.label.toUpperCase()}',
      _Step.done => 'IMPORT COMPLETE',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 10, 10),
      child: Row(
        children: [
          if (_step != _Step.overview)
            InkWell(
              onTap: () => setState(() {
                _error = null;
                _step = _step == _Step.done
                    ? _Step.overview
                    : _Step.values[_step.index - 1];
              }),
              borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.arrow_back, size: 16, color: t.textFaint),
              ),
            ),
          Icon(Icons.hub_outlined, size: 15, color: t.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: NotelyType.sectionLabel.copyWith(color: t.textPrimary),
            ),
          ),
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded, size: 16, color: t.textFaint),
            ),
          ),
        ],
      ),
    );
  }

  // ── Overview: connected sources + connect buttons ──────────────────────────
  Widget _overview(NotelyTokens t) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Bring knowledge from your work tools into Notely. Imported content becomes '
              'ordinary notes in your vault — searchable, answerable, and citable alongside '
              'everything else.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: t.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            if (_c.error != null)
              _note(t, _c.error!, danger: true)
            else if (_c.sources.isEmpty)
              _note(t, 'No sources connected yet.')
            else
              for (final s in _c.sources) _connectedRow(t, s),
            const SizedBox(height: 18),
            Text(
              'CONNECT A SOURCE',
              style: NotelyType.sectionLabel.copyWith(
                fontSize: 10,
                color: t.textFaint,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _connectCard(t, SourceKind.slack, Icons.tag)),
                const SizedBox(width: 10),
                Expanded(
                  child: _connectCard(
                    t,
                    SourceKind.teams,
                    Icons.groups_outlined,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _connectedRow(NotelyTokens t, ipc.ConnectedSource s) {
    final kind = SourceKind.fromWire(s.kind);
    final icon = kind == SourceKind.slack ? Icons.tag : Icons.groups_outlined;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: t.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${kind.label} · ${s.workspace}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${s.documentCount} ${s.documentCount == 1 ? 'channel' : 'channels'} imported'
            '${s.importedChannels.isEmpty ? '' : ' · ${s.importedChannels.join(', ')}'}',
            style: TextStyle(fontSize: 11.5, color: t.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            'in ${s.folder}/'
            '${s.lastImportedAt != null ? ' · last import ${_shortDate(s.lastImportedAt!)}' : ''}',
            style: TextStyle(fontSize: 11, color: t.textFaint),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _smallBtn(t, 'Import more', () => _startConnect(kind)),
              const SizedBox(width: 8),
              _smallBtn(
                t,
                'Disconnect',
                () => _confirmDisconnect(kind),
                danger: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connectCard(NotelyTokens t, SourceKind kind, IconData icon) {
    return InkWell(
      onTap: () => _startConnect(kind),
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: t.background,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          border: Border.all(color: t.border),
        ),
        child: Column(
          children: [
            Icon(icon, size: 22, color: t.textSecondary),
            const SizedBox(height: 8),
            Text(
              kind.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: t.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDisconnect(SourceKind kind) async {
    final t = context.tokens;
    var removeFiles = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: t.raised,
          title: Text(
            'Disconnect ${kind.label}?',
            style: NotelyType.dialogTitle,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Notely will forget this connection.',
                style: TextStyle(fontSize: 12.5, color: t.textSecondary),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: removeFiles,
                onChanged: (v) => setSt(() => removeFiles = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(
                  'Also delete imported notes from the vault',
                  style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Disconnect', style: TextStyle(color: t.danger)),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _c.disconnect(kind, removeImported: removeFiles);
    }
  }

  // ── Connect: token entry ───────────────────────────────────────────────────
  Widget _connect(NotelyTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Paste an access token for ${_kind.label}. It is used only to read the channels you '
          'choose and is kept in memory for this session — never written to disk.',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: t.textSecondary),
        ),
        const SizedBox(height: 16),
        _field(t, _token, _kind.tokenHint, obscure: true),
        const SizedBox(height: 10),
        _field(t, _baseUrl, 'API base URL (optional — advanced)'),
        if (_error != null) ...[
          const SizedBox(height: 10),
          _note(t, _error!, danger: true),
        ],
        const SizedBox(height: 18),
        _primaryBtn(
          t,
          _busy ? 'Connecting…' : 'Continue',
          _busy ? null : _continueToPick,
        ),
      ],
    );
  }

  // ── Pick: channel selection + scope ────────────────────────────────────────
  Widget _pick(NotelyTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Connected to $_workspace. Choose the channels to import — only these are read.',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: t.textSecondary),
        ),
        const SizedBox(height: 12),
        if (_channels.isEmpty)
          _note(t, 'No channels available for this token.')
        else
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              border: Border.all(color: t.border),
              borderRadius: BorderRadius.circular(NotelyDims.radius),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _channels.length,
              itemBuilder: (context, i) {
                final ch = _channels[i];
                final on = _selected.contains(ch.id);
                return InkWell(
                  onTap: () => setState(() {
                    on ? _selected.remove(ch.id) : _selected.add(ch.id);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          on ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 17,
                          color: on ? t.accent : t.textFaint,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ch.name,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: t.textPrimary,
                                ),
                              ),
                              if (ch.purpose != null && ch.purpose!.isNotEmpty)
                                Text(
                                  ch.purpose!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: t.textFaint,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              'Up to',
              style: TextStyle(fontSize: 12, color: t.textSecondary),
            ),
            Expanded(
              child: Slider(
                value: _maxMessages.toDouble(),
                min: 100,
                max: 2000,
                divisions: 19,
                activeColor: t.accent,
                label: '$_maxMessages',
                onChanged: (v) => setState(() => _maxMessages = v.round()),
              ),
            ),
            Text(
              '$_maxMessages msgs/channel',
              style: TextStyle(fontSize: 11.5, color: t.textFaint),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          _note(t, _error!, danger: true),
        ],
        const SizedBox(height: 14),
        _primaryBtn(
          t,
          _busy ? 'Importing…' : 'Import ${_selected.length} selected',
          _busy || _selected.isEmpty ? null : _import,
        ),
      ],
    );
  }

  // ── Done: summary ──────────────────────────────────────────────────────────
  Widget _done(NotelyTokens t) {
    final s = _summary!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline, size: 20, color: t.success),
            const SizedBox(width: 10),
            Text(
              'Imported into your vault',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _summaryRow(t, 'Channels', '${s.channelsImported}'),
        _summaryRow(t, 'New messages', '${s.messagesImported}'),
        _summaryRow(t, 'Already present (skipped)', '${s.messagesSkipped}'),
        _summaryRow(t, 'Notes written', '${s.documentsWritten}'),
        if (s.warnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final w in s.warnings) _note(t, w, danger: true),
        ],
        const SizedBox(height: 8),
        Text(
          'This knowledge is now searchable, answerable in Ask, and appears in your '
          'Knowledge Space — with citations back to the original.',
          style: TextStyle(fontSize: 12, height: 1.5, color: t.textFaint),
        ),
        const SizedBox(height: 16),
        _primaryBtn(t, 'Done', () => setState(() => _step = _Step.overview)),
      ],
    );
  }

  // ── Bits ───────────────────────────────────────────────────────────────────
  Widget _field(
    NotelyTokens t,
    TextEditingController c,
    String hint, {
    bool obscure = false,
  }) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: TextStyle(fontSize: 12.5, color: t.textPrimary),
      cursorColor: t.accent,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: t.textFaint, fontSize: 12.5),
        filled: true,
        fillColor: t.background,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
      ),
    );
  }

  Widget _note(NotelyTokens t, String text, {bool danger = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        border: Border.all(
          color: danger ? t.danger.withValues(alpha: 0.5) : t.border,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: danger ? t.danger : t.textSecondary,
        ),
      ),
    );
  }

  Widget _summaryRow(NotelyTokens t, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: t.textSecondary),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
        ),
      ],
    ),
  );

  Widget _primaryBtn(NotelyTokens t, String label, VoidCallback? onTap) {
    return Opacity(
      opacity: onTap == null ? 0.6 : 1,
      child: Material(
        color: t.accent,
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            child: Text(
              label,
              style: NotelyType.button.copyWith(color: t.onAccent),
            ),
          ),
        ),
      ),
    );
  }

  Widget _smallBtn(
    NotelyTokens t,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
          border: Border.all(
            color: danger ? t.danger.withValues(alpha: 0.5) : t.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: danger ? t.danger : t.textSecondary,
          ),
        ),
      ),
    );
  }

  String _shortDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
