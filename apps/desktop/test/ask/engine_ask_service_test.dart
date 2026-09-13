// Tests for EngineAskService: it maps engine answers into the app's AskAnswer model when the
// engine is reachable, and degrades to the fallback answerer whenever the engine is disconnected,
// times out, or errors — the "AI failure must not equal data loss" reliability rule for Ask.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/ipc/engine_client.dart';
import 'package:notely_desktop/ipc/protocol.dart';
import 'package:notely_desktop/services/ask/ask_service.dart';
import 'package:notely_desktop/services/ask/engine_ask_service.dart';

/// A stub engine client whose connection state and `ask` behavior are scripted.
class _StubClient extends EngineClient {
  _StubClient({required this.connected, this.answer, this.error})
    : super(host: '127.0.0.1', port: 1);

  final bool connected;
  final EngineAnswer? answer;
  final Object? error;

  @override
  bool get isConnected => connected;

  @override
  Future<EngineAnswer> ask(
    String question, {
    required String vaultPath,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (error != null) throw error!;
    return answer!;
  }
}

/// A fallback that returns a recognizable sentinel so we can assert it was used.
class _SentinelFallback implements AskService {
  const _SentinelFallback();
  @override
  Future<AskAnswer> ask({
    required String query,
    required String stashRoot,
  }) async {
    return const AskAnswer(text: 'FALLBACK', filesRead: [], citations: []);
  }
}

void main() {
  group('EngineAskService', () {
    test('maps a grounded engine answer into AskAnswer', () async {
      final client = _StubClient(
        connected: true,
        answer: const EngineAnswer(
          text: 'PostgreSQL was chosen [1].',
          filesRead: ['/vault/arch.md'],
          citations: [
            EngineCitation(
              path: '/vault/arch.md',
              startLine: 2,
              endLine: 4,
              snippet: 'We chose PostgreSQL…',
            ),
          ],
        ),
      );
      final service = EngineAskService(
        client: client,
        fallback: const _SentinelFallback(),
      );

      final ans = await service.ask(query: 'what db?', stashRoot: '/vault');

      expect(ans.text, 'PostgreSQL was chosen [1].');
      expect(ans.filesRead, ['/vault/arch.md']);
      expect(ans.citations.single.path, '/vault/arch.md');
      expect(ans.citations.single.startLine, 2);
      expect(ans.citations.single.endLine, 4);
    });

    test(
      'falls back when the engine is not connected (no socket attempt)',
      () async {
        final service = EngineAskService(
          client: _StubClient(connected: false),
          fallback: const _SentinelFallback(),
        );
        final ans = await service.ask(query: 'q', stashRoot: '/vault');
        expect(ans.text, 'FALLBACK');
      },
    );

    test('falls back on an engine-level error', () async {
      final service = EngineAskService(
        client: _StubClient(
          connected: true,
          error: const EngineError('llm exploded'),
        ),
        fallback: const _SentinelFallback(),
      );
      final ans = await service.ask(query: 'q', stashRoot: '/vault');
      expect(ans.text, 'FALLBACK');
    });

    test('falls back on a timeout', () async {
      final service = EngineAskService(
        client: _StubClient(connected: true, error: TimeoutException('slow')),
        fallback: const _SentinelFallback(),
      );
      final ans = await service.ask(query: 'q', stashRoot: '/vault');
      expect(ans.text, 'FALLBACK');
    });

    test('falls back when the transport drops', () async {
      final service = EngineAskService(
        client: _StubClient(
          connected: true,
          error: const EngineUnavailable('closed'),
        ),
        fallback: const _SentinelFallback(),
      );
      final ans = await service.ask(query: 'q', stashRoot: '/vault');
      expect(ans.text, 'FALLBACK');
    });
  });
}
