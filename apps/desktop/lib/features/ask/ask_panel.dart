// The "Ask Notely" chat panel (right-docked).
//
// Styled after Claude's editor extension: a conversation where each answer shows exactly which
// notes were read (file pills) and cites the passages it drew from (numbered sources + inline
// [n] chips). Clicking a file pill opens the note; clicking a citation opens the note AND
// highlights the exact lines it quoted.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/ask/ask_service.dart';
import 'ask_state.dart';

class AskPanel extends StatefulWidget {
  const AskPanel({super.key});

  @override
  State<AskPanel> createState() => _AskPanelState();
}

class _AskPanelState extends State<AskPanel> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
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

  Future<void> _send([String? value]) async {
    final scope = AppScope.of(context);
    final root = scope.stash.path;
    final q = (value ?? _input.text).trim();
    if (q.isEmpty || root == null || scope.ask.isBusy) return;
    _input.clear();
    _inputFocus.requestFocus();
    await scope.ask.send(q, stashRoot: root);
  }

  Future<void> _openCitation(Citation c) async {
    final scope = AppScope.of(context);
    scope.explorer.selectFile(c.path);
    await scope.editor.open(c.path);
    if (!mounted) return;
    scope.editor.selectLines(c.startLine, c.endLine);
  }

  Future<void> _openFile(String path) async {
    final scope = AppScope.of(context);
    scope.explorer.selectFile(path);
    await scope.editor.open(path);
  }

  @override
  Widget build(BuildContext context) {
    final ask = AppScope.of(context).ask;
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(left: BorderSide(color: t.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(t, ask),
          Expanded(
            child: AnimatedBuilder(
              animation: ask,
              builder: (context, _) {
                if (ask.showHistory) return _historyView(t, ask);
                final messages = ask.messages;
                if (messages.isEmpty) return _empty(t);
                _autoScroll();
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _message(t, messages[i]),
                );
              },
            ),
          ),
          _inputBar(t, ask),
        ],
      ),
    );
  }

  Widget _header(NotelyTokens t, AskController ask) {
    return Container(
      height: NotelyDims.titleBarHeight,
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 14, color: t.accent),
          const SizedBox(width: 8),
          Text(
            'ASK NOTELY',
            style: NotelyType.sectionLabel.copyWith(color: t.textSecondary),
          ),
          const Spacer(),
          _iconBtn(t, Icons.add, 'New chat', ask.newChat),
          AnimatedBuilder(
            animation: ask,
            builder: (context, _) => _iconBtn(
              t,
              Icons.history,
              'Chat history',
              ask.toggleHistory,
              active: ask.showHistory,
            ),
          ),
          _iconBtn(t, Icons.close_rounded, 'Close', ask.close),
        ],
      ),
    );
  }

  Widget _empty(NotelyTokens t) {
    const examples = [
      'What did we decide about the release?',
      'Summarise my meeting notes',
      'Where did I write about the architecture?',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.auto_awesome, size: 26, color: t.accent),
          const SizedBox(height: 12),
          Text(
            'Ask anything about your stash',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Answers are grounded in your notes, with citations you can open.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.4, color: t.textFaint),
          ),
          const SizedBox(height: 18),
          for (final e in examples)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ExampleChip(text: e, onTap: () => _send(e)),
            ),
        ],
      ),
    );
  }

  Widget _message(NotelyTokens t, AskMessage m) {
    if (m.role == AskRole.user) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: t.selection,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          border: Border.all(color: t.accent.withValues(alpha: 0.35)),
        ),
        child: Text(
          m.text!,
          style: TextStyle(fontSize: 13, height: 1.45, color: t.textPrimary),
        ),
      );
    }
    if (m.loading) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            ),
            const SizedBox(width: 10),
            Text(
              'Searching your notes…',
              style: TextStyle(fontSize: 12.5, color: t.textSecondary),
            ),
          ],
        ),
      );
    }
    return _AssistantAnswer(
      answer: m.answer!,
      onCitation: _openCitation,
      onOpenFile: _openFile,
    );
  }

  Widget _inputBar(NotelyTokens t, AskController ask) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: AnimatedBuilder(
        animation: ask,
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                style: TextStyle(fontSize: 13, color: t.textPrimary),
                cursorColor: t.accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Ask about your notes…',
                  hintStyle: TextStyle(color: t.textFaint, fontSize: 13),
                  filled: true,
                  fillColor: t.background,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
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
              ),
            ),
            const SizedBox(width: 8),
            _SendButton(enabled: !ask.isBusy, onTap: _send),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(
    NotelyTokens t,
    IconData icon,
    String tip,
    VoidCallback onTap, {
    bool active = false,
  }) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 15, color: active ? t.accent : t.textFaint),
        ),
      ),
    );
  }

  // ── History view ──────────────────────────────────────────────────────────
  Widget _historyView(NotelyTokens t, AskController ask) {
    final chats = ask.history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Text(
                'PREVIOUS CHATS',
                style: NotelyType.sectionLabel.copyWith(color: t.textFaint),
              ),
              const Spacer(),
              _NewChatButton(onTap: ask.newChat),
            ],
          ),
        ),
        Expanded(
          child: chats.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No previous chats yet.\nAsk a question to start one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: t.textFaint,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  itemCount: chats.length,
                  itemBuilder: (context, i) {
                    final c = chats[i];
                    return _HistoryRow(
                      title: c.title.isEmpty ? 'Untitled chat' : c.title,
                      subtitle:
                          '${_relativeTime(c.updatedAt)} · '
                          '${_turns(c)} ${_turns(c) == 1 ? 'reply' : 'replies'}',
                      active: c.id == ask.activeId,
                      onTap: () => ask.openChat(c.id),
                      onDelete: () => ask.deleteChat(c.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  int _turns(AskConversation c) =>
      c.messages.where((m) => m.role == AskRole.assistant && !m.loading).length;

  String _relativeTime(int ms) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - ms;
    if (diff < 60 * 1000) return 'just now';
    if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)}m ago';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)}h ago';
    final days = diff ~/ (24 * 60 * 60 * 1000);
    if (days == 1) return 'yesterday';
    if (days < 7) return '${days}d ago';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
  }
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
    required this.onDelete,
  });
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
          decoration: BoxDecoration(
            color: widget.active
                ? t.selection
                : (_hover ? t.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border(
              left: BorderSide(
                color: widget.active ? t.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline, size: 13, color: t.textFaint),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: t.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: TextStyle(fontSize: 10.5, color: t.textFaint),
                    ),
                  ],
                ),
              ),
              if (_hover)
                InkWell(
                  onTap: widget.onDelete,
                  borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.delete_outline,
                      size: 14,
                      color: t.textFaint,
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

class _NewChatButton extends StatefulWidget {
  const _NewChatButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_NewChatButton> createState() => _NewChatButtonState();
}

class _NewChatButtonState extends State<_NewChatButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? t.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            border: Border.all(color: t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 13, color: t.accent),
              const SizedBox(width: 5),
              Text(
                'New chat',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: t.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Assistant answer (body + files read + sources)
// ─────────────────────────────────────────────────────────────────────────────
class _AssistantAnswer extends StatelessWidget {
  const _AssistantAnswer({
    required this.answer,
    required this.onCitation,
    required this.onOpenFile,
  });

  final AskAnswer answer;
  final void Function(Citation) onCitation;
  final void Function(String path) onOpenFile;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AnswerBody(answer: answer, onCitation: onCitation),
          if (answer.filesRead.isNotEmpty) ...[
            const SizedBox(height: 14),
            _label(
              t,
              'Read ${answer.filesRead.length} '
              '${answer.filesRead.length == 1 ? 'note' : 'notes'}',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final path in answer.filesRead)
                  _FilePill(path: path, onTap: () => onOpenFile(path)),
              ],
            ),
          ],
          if (answer.citations.isNotEmpty) ...[
            const SizedBox(height: 14),
            _label(t, 'Sources'),
            const SizedBox(height: 6),
            for (var i = 0; i < answer.citations.length; i++)
              _SourceRow(
                index: i + 1,
                citation: answer.citations[i],
                onTap: () => onCitation(answer.citations[i]),
              ),
          ],
        ],
      ),
    );
  }

  Widget _label(NotelyTokens t, String text) => Text(
    text.toUpperCase(),
    style: NotelyType.sectionLabel.copyWith(fontSize: 10, color: t.textFaint),
  );
}

class _AnswerBody extends StatelessWidget {
  const _AnswerBody({required this.answer, required this.onCitation});
  final AskAnswer answer;
  final void Function(Citation) onCitation;

  static final _inline = RegExp(r'(\*\*[^*]+\*\*)|(`[^`]+`)|(\[(\d+)\])');

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = TextStyle(fontSize: 13, height: 1.5, color: t.textPrimary);
    final children = <Widget>[];
    for (final raw in answer.text.split('\n')) {
      if (raw.trim().isEmpty) {
        children.add(const SizedBox(height: 8));
        continue;
      }
      final isBullet = raw.trimLeft().startsWith('- ');
      final content = isBullet ? raw.trimLeft().substring(2) : raw;
      final rich = Text.rich(
        TextSpan(style: base, children: _spans(content, t, base)),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: isBullet
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, right: 8),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: t.textFaint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(child: rich),
                  ],
                )
              : rich,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  List<InlineSpan> _spans(String content, NotelyTokens t, TextStyle base) {
    final spans = <InlineSpan>[];
    var idx = 0;
    for (final m in _inline.allMatches(content)) {
      if (m.start > idx) {
        spans.add(TextSpan(text: content.substring(idx, m.start)));
      }
      final tok = m.group(0)!;
      if (tok.startsWith('**')) {
        spans.add(
          TextSpan(
            text: tok.substring(2, tok.length - 2),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else if (tok.startsWith('`')) {
        spans.add(
          TextSpan(
            text: tok.substring(1, tok.length - 1),
            style: base.copyWith(
              fontFamily: kEditorFont,
              fontFamilyFallback: kEditorFontFallback,
              backgroundColor: t.raised,
            ),
          ),
        );
      } else {
        final n = int.tryParse(m.group(4) ?? '');
        if (n != null && n >= 1 && n <= answer.citations.length) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _CiteChip(
                n: n,
                onTap: () => onCitation(answer.citations[n - 1]),
              ),
            ),
          );
        } else {
          spans.add(TextSpan(text: tok));
        }
      }
      idx = m.end;
    }
    if (idx < content.length) {
      spans.add(TextSpan(text: content.substring(idx)));
    }
    return spans;
  }
}

class _CiteChip extends StatelessWidget {
  const _CiteChip({required this.n, required this.onTap});
  final int n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: t.accentMuted,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$n',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: t.accent,
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilePill extends StatefulWidget {
  const _FilePill({required this.path, required this.onTap});
  final String path;
  final VoidCallback onTap;

  @override
  State<_FilePill> createState() => _FilePillState();
}

class _FilePillState extends State<_FilePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = widget.path.split(RegExp(r'[/\\]')).last;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? t.raised : t.background,
            borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            border: Border.all(color: t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.article_outlined, size: 12, color: t.textFaint),
              const SizedBox(width: 6),
              Text(
                name,
                style: TextStyle(
                  fontSize: 11.5,
                  color: t.textSecondary,
                  fontFamily: kEditorFont,
                  fontFamilyFallback: kEditorFontFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatefulWidget {
  const _SourceRow({
    required this.index,
    required this.citation,
    required this.onTap,
  });
  final int index;
  final Citation citation;
  final VoidCallback onTap;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = widget.citation;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: _hover ? t.hover : t.background,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(color: _hover ? t.borderStrong : t.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: t.accentMuted,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${widget.index}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: t.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      c.fileName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'lines ${c.lineLabel}',
                    style: NotelyType.statusMono.copyWith(color: t.textFaint),
                  ),
                  const Spacer(),
                  Icon(Icons.north_east, size: 12, color: t.textFaint),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                c.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: t.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExampleChip extends StatefulWidget {
  const _ExampleChip({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  State<_ExampleChip> createState() => _ExampleChipState();
}

class _ExampleChipState extends State<_ExampleChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: _hover ? t.hover : t.background,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(color: t.border),
          ),
          child: Row(
            children: [
              Icon(
                Icons.subdirectory_arrow_right,
                size: 13,
                color: t.textFaint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.text,
                  style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.accent,
              borderRadius: BorderRadius.circular(NotelyDims.radius),
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 18,
              color: t.onAccent,
            ),
          ),
        ),
      ),
    );
  }
}
