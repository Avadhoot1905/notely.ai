// "Ask Notely" chat state.
//
// Holds multiple conversations (like VS Code / Antigravity chat history), the active one, and
// drives the [AskService]. Conversations are persisted per stash via [AskStore] so previous
// chats reappear after a restart. Kept UI-agnostic: the panel renders [messages]/[history] and
// calls [send], [newChat], [openChat], [toggleHistory].

import 'package:flutter/foundation.dart';

import '../../services/ask/ask_service.dart';
import '../../services/ask/ask_store.dart';

enum AskRole { user, assistant }

class AskMessage {
  AskMessage.user(String this.text)
    : role = AskRole.user,
      answer = null,
      loading = false;
  AskMessage.loading()
    : role = AskRole.assistant,
      text = null,
      answer = null,
      loading = true;
  AskMessage.assistant(AskAnswer this.answer)
    : role = AskRole.assistant,
      text = null,
      loading = false;

  final AskRole role;
  final String? text;
  final AskAnswer? answer;
  final bool loading;

  Map<String, dynamic> toJson() => role == AskRole.user
      ? {'role': 'user', 'text': text}
      : {'role': 'assistant', 'answer': answer!.toJson()};

  static AskMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['role'] == 'user' && json['text'] is String) {
      return AskMessage.user(json['text'] as String);
    }
    if (json['role'] == 'assistant') {
      final answer = AskAnswer.fromJson(json['answer']);
      if (answer != null) return AskMessage.assistant(answer);
    }
    return null;
  }
}

/// A single chat thread, scoped to a stash.
class AskConversation {
  AskConversation({
    required this.id,
    required this.stashRoot,
    required this.title,
    required this.updatedAt,
    List<AskMessage>? messages,
  }) : messages = messages ?? [];

  final String id;
  final String stashRoot;
  String title;
  int updatedAt; // epoch ms
  final List<AskMessage> messages;

  Map<String, dynamic> toJson() => {
    'id': id,
    'stashRoot': stashRoot,
    'title': title,
    'updatedAt': updatedAt,
    // Never persist transient "loading" placeholders.
    'messages': [
      for (final m in messages)
        if (!m.loading) m.toJson(),
    ],
  };

  static AskConversation? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    return AskConversation(
      id: json['id'] as String,
      stashRoot: json['stashRoot'] as String? ?? '',
      title: json['title'] as String? ?? '',
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      messages:
          (json['messages'] as List?)
              ?.map(AskMessage.fromJson)
              .whereType<AskMessage>()
              .toList() ??
          [],
    );
  }
}

class AskController extends ChangeNotifier {
  AskController({AskService? service, AskStore? store})
    : _service = service ?? const MockAskService(),
      _store = store ?? AskStore();

  final AskService _service;
  final AskStore _store;

  final List<AskConversation> _all = [];
  String? _stashRoot;
  String? _activeId;
  bool _open = false;
  bool _busy = false;
  bool _showHistory = false;
  int _seq = 0;

  bool get isOpen => _open;
  bool get isBusy => _busy;
  bool get showHistory => _showHistory;
  String? get activeId => _activeId;

  /// Conversations for the current stash, most-recent first. Ties (same millisecond) break by
  /// id, which is created monotonically, so ordering is deterministic.
  List<AskConversation> get history {
    final list = _all.where((c) => c.stashRoot == _stashRoot).toList()
      ..sort((a, b) {
        final byTime = b.updatedAt.compareTo(a.updatedAt);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });
    return List.unmodifiable(list);
  }

  AskConversation? get _active {
    for (final c in _all) {
      if (c.id == _activeId) return c;
    }
    return null;
  }

  List<AskMessage> get messages =>
      List.unmodifiable(_active?.messages ?? const <AskMessage>[]);

  // ── Panel visibility ────────────────────────────────────────────────────
  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    notifyListeners();
  }

  void toggle() => _open ? close() : open();

  void toggleHistory() {
    _showHistory = !_showHistory;
    notifyListeners();
  }

  // ── Conversations ─────────────────────────────────────────────────────────
  void newChat() {
    _activeId = null; // a fresh thread is created on first send
    _showHistory = false;
    notifyListeners();
  }

  void openChat(String id) {
    _activeId = id;
    _showHistory = false;
    notifyListeners();
  }

  Future<void> deleteChat(String id) async {
    _all.removeWhere((c) => c.id == id);
    if (_activeId == id) _activeId = null;
    notifyListeners();
    await _persist();
  }

  /// Load all persisted conversations (call once at startup).
  Future<void> restore() async {
    try {
      final loaded = await _store.load();
      _all
        ..clear()
        ..addAll(loaded);
      // If a stash is already selected, surface its most recent chat.
      if (_stashRoot != null && _activeId == null) {
        final h = history;
        if (h.isNotEmpty) _activeId = h.first.id;
      }
    } catch (_) {
      // Ignore corrupt prefs; start fresh.
    }
    notifyListeners();
  }

  /// Point Ask at the open stash. Restores that stash's most recent chat as active.
  void setStash(String? root) {
    if (_stashRoot == root) return;
    _stashRoot = root;
    final h = history;
    _activeId = h.isNotEmpty ? h.first.id : null;
    _showHistory = false;
    notifyListeners();
  }

  /// Ask a question against the stash rooted at [stashRoot].
  Future<void> send(String query, {required String stashRoot}) async {
    final q = query.trim();
    if (q.isEmpty || _busy) return;

    var conv = _active;
    if (conv == null || conv.stashRoot != stashRoot) {
      conv = AskConversation(
        id: _newId(),
        stashRoot: stashRoot,
        title: _titleFrom(q),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _all.add(conv);
      _activeId = conv.id;
    }

    conv.messages
      ..add(AskMessage.user(q))
      ..add(AskMessage.loading());
    _busy = true;
    _showHistory = false;
    notifyListeners();

    AskAnswer answer;
    try {
      answer = await _service.ask(query: q, stashRoot: stashRoot);
    } catch (_) {
      answer = const AskAnswer(
        text: 'Something went wrong while searching your notes.',
        filesRead: [],
        citations: [],
      );
    }
    if (conv.messages.isNotEmpty && conv.messages.last.loading) {
      conv.messages.removeLast();
    }
    conv.messages.add(AskMessage.assistant(answer));
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (conv.title.isEmpty) conv.title = _titleFrom(q);
    _busy = false;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _store.save(_all);
    } catch (_) {
      // Non-fatal: chats remain usable this session.
    }
  }

  String _newId() {
    _seq++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_seq';
  }

  String _titleFrom(String query) {
    final t = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 44 ? '${t.substring(0, 44).trimRight()}…' : t;
  }
}
