// Engine-backed "Ask Notely": source-grounded answers over the vault, produced by the Rust
// engine (full-text retrieval + local LLM). The engine reads the same Markdown notes on disk, so
// answers cite real passages the panel can open and highlight.
//
// Reliability first (see the product's "AI failure must not equal data loss" rule): if the engine
// is disconnected, times out, or errors, this falls back to the offline keyword answerer
// ([MockAskService]) so Ask always returns something useful with clickable sources.

import 'dart:async';

import '../../ipc/engine_client.dart';
import '../../ipc/protocol.dart' as ipc;
import 'ask_service.dart';

class EngineAskService implements AskService {
  EngineAskService({required this.client, AskService? fallback})
    : _fallback = fallback ?? const MockAskService();

  final EngineClient client;
  final AskService _fallback;

  @override
  Future<AskAnswer> ask({
    required String query,
    required String stashRoot,
  }) async {
    // Not connected: don't even attempt the socket — answer offline immediately.
    if (!client.isConnected) {
      return _fallback.ask(query: query, stashRoot: stashRoot);
    }
    try {
      final answer = await client.ask(query, vaultPath: stashRoot);
      return _map(answer);
    } on EngineUnavailable {
      return _fallback.ask(query: query, stashRoot: stashRoot);
    } on TimeoutException {
      return _fallback.ask(query: query, stashRoot: stashRoot);
    } on ipc.EngineError {
      return _fallback.ask(query: query, stashRoot: stashRoot);
    } on ipc.ProtocolException {
      return _fallback.ask(query: query, stashRoot: stashRoot);
    }
  }

  AskAnswer _map(ipc.EngineAnswer a) => AskAnswer(
    text: a.text,
    filesRead: a.filesRead,
    citations: [
      for (final c in a.citations)
        Citation(
          path: c.path,
          startLine: c.startLine,
          endLine: c.endLine,
          snippet: c.snippet,
        ),
    ],
  );
}
