// Persists "Ask Notely" conversations so previous chats survive restarts (like the Claude
// VS Code extension / Antigravity history). Stored as JSON via shared_preferences; each
// conversation is tagged with the stash it belongs to so history is shown per stash.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../features/ask/ask_state.dart';

class AskStore {
  static const _key = 'notely.ask.conversations';

  Future<List<AskConversation>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(AskConversation.fromJson)
          .whereType<AskConversation>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<AskConversation> conversations) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final c in conversations) c.toJson()]),
    );
  }
}
