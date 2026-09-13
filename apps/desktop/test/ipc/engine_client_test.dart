// IPC boundary tests for [EngineClient].
//
// These exercise the real transport (newline-delimited JSON over a loopback TCP socket) against
// an in-process fake engine, with no dependency on the Rust binary. They cover the connection
// lifecycle, request/response correlation, timeouts, backend errors, malformed payloads, events,
// unavailability, disconnect/reconnect recovery, and protocol-version incompatibility.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/ipc/engine_client.dart';
import 'package:notely_desktop/ipc/protocol.dart';

void main() {
  // Fast backoff so reconnect tests don't dawdle.
  EngineClient makeClient(int port) => EngineClient(
    host: '127.0.0.1',
    port: port,
    handshakeTimeout: const Duration(seconds: 2),
    minBackoff: const Duration(milliseconds: 20),
    maxBackoff: const Duration(milliseconds: 80),
  );

  test(
    'connects, reaches connected state, and captures health via handshake',
    () async {
      final engine = FakeEngine();
      await engine.start();
      addTearDown(engine.close);
      final client = makeClient(engine.port);
      addTearDown(client.dispose);

      client.start();
      await _waitState(client, EngineConnectionState.connected);
      expect(client.isConnected, isTrue);

      // The handshake sends Health; the fake replies, populating health.
      await _until(() => client.health.value != null);
      expect(client.health.value!.model, 'test-model');
      expect(client.health.value!.llmOk, isTrue);
    },
  );

  test('correlates a request with its response', () async {
    final engine = FakeEngine();
    engine.onRequest = (req, socket) {
      if (req['type'] == 'GetMom') {
        _writeResponse(socket, req['request_id'] as String, 'Mom', {
          'markdown': '# Minutes',
        });
      }
    };
    await engine.start();
    addTearDown(engine.close);
    final client = makeClient(engine.port);
    addTearDown(client.dispose);
    client.start();
    await _waitState(client, EngineConnectionState.connected);

    expect(await client.getMom('m1'), '# Minutes');
  });

  test('a backend error response surfaces as EngineError', () async {
    final engine = FakeEngine();
    engine.onRequest = (req, socket) => _writeResponse(
      socket,
      req['request_id'] as String,
      'Error',
      {'message': 'no such meeting'},
    );
    await engine.start();
    addTearDown(engine.close);
    final client = makeClient(engine.port);
    addTearDown(client.dispose);
    client.start();
    await _waitState(client, EngineConnectionState.connected);

    await expectLater(
      client.getMom('missing'),
      throwsA(
        isA<EngineError>().having(
          (e) => e.message,
          'message',
          'no such meeting',
        ),
      ),
    );
  });

  test('a request times out when the engine never responds', () async {
    final engine = FakeEngine(); // no onRequest → GetMom is ignored
    await engine.start();
    addTearDown(engine.close);
    final client = makeClient(engine.port);
    addTearDown(client.dispose);
    client.start();
    await _waitState(client, EngineConnectionState.connected);

    await expectLater(
      client.send(
        const GetMom('m1'),
        timeout: const Duration(milliseconds: 150),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'a malformed line does not crash the client; later responses still work',
    () async {
      final engine = FakeEngine();
      engine.onRequest = (req, socket) {
        if (req['type'] == 'GetMom') {
          _writeRaw(socket, '{ this is not json');
          _writeResponse(socket, req['request_id'] as String, 'Mom', {
            'markdown': 'ok',
          });
        }
      };
      await engine.start();
      addTearDown(engine.close);
      final client = makeClient(engine.port);
      addTearDown(client.dispose);
      client.start();
      await _waitState(client, EngineConnectionState.connected);

      expect(await client.getMom('m1'), 'ok');
    },
  );

  test(
    'engine events are decoded and delivered; unknown events do not crash',
    () async {
      final engine = FakeEngine();
      await engine.start();
      addTearDown(engine.close);
      final client = makeClient(engine.port);
      addTearDown(client.dispose);
      client.start();
      final socket = await engine.firstClient;
      await _waitState(client, EngineConnectionState.connected);

      final received = <EngineEvent>[];
      final sub = client.events().listen(received.add);
      addTearDown(sub.cancel);

      _writeEvent(socket, 'ExtractionProgress', {
        'job_id': 'j1',
        'completed': 2,
        'total': 5,
      });
      _writeEvent(socket, 'SomeFutureEvent', {'job_id': 'j1'});

      await _until(() => received.length >= 2);
      expect(received[0].type, EngineEventType.extractionProgress);
      expect(received[0].completed, 2);
      expect(received[1].type, EngineEventType.unknown);
      expect(received[1].rawType, 'SomeFutureEvent');
    },
  );

  test(
    'an unavailable backend leaves send() throwing EngineUnavailable',
    () async {
      // Bind then immediately release a port so nothing is listening on it.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final client = makeClient(deadPort);
      addTearDown(client.dispose);
      client.start();
      // Give the failed connect a moment to settle.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(client.isConnected, isFalse);
      await expectLater(
        client.send(const Health()),
        throwsA(isA<EngineUnavailable>()),
      );
    },
  );

  test(
    'pending requests fail on disconnect, then the client reconnects and resyncs',
    () async {
      final engine = FakeEngine();
      engine.onRequest = (req, socket) {
        if (req['type'] == 'GetMom') {
          _writeResponse(socket, req['request_id'] as String, 'Mom', {
            'markdown': 'after-reconnect',
          });
        }
      };
      await engine.start();
      addTearDown(engine.close);
      final client = makeClient(engine.port);
      addTearDown(client.dispose);
      client.start();
      final socket = await engine.firstClient;
      await _waitState(client, EngineConnectionState.connected);

      // Kill the connection server-side; the client should reconnect (server keeps listening).
      socket.destroy();
      await _waitState(client, EngineConnectionState.disconnected);
      await _waitState(client, EngineConnectionState.connected);

      // A fresh request over the reconnected socket succeeds.
      expect(await client.getMom('m1'), 'after-reconnect');
    },
  );

  test(
    'an incompatible protocol version marks the client incompatible',
    () async {
      final engine = FakeEngine(healthVersion: 999);
      await engine.start();
      addTearDown(engine.close);
      final client = makeClient(engine.port);
      addTearDown(client.dispose);
      client.start();

      await _waitState(client, EngineConnectionState.incompatible);
      expect(client.lastError.value, contains('protocol version'));
      await expectLater(
        client.send(const Health()),
        throwsA(isA<EngineUnavailable>()),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// In-process fake engine
// ---------------------------------------------------------------------------

/// A minimal newline-JSON TCP server standing in for the Rust engine. Auto-answers the Health
/// handshake (with [healthVersion]); all other requests go to [onRequest].
class FakeEngine {
  FakeEngine({this.healthVersion = 1});

  final int healthVersion;
  ServerSocket? _server;
  final Completer<Socket> _firstClient = Completer<Socket>();

  /// Handler for non-Health requests. Receives the decoded request envelope and its socket.
  void Function(Map<String, dynamic> req, Socket socket)? onRequest;

  int get port => _server!.port;

  /// Completes with the first client socket that connects.
  Future<Socket> get firstClient => _firstClient.future;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleConn);
  }

  void _handleConn(Socket socket) {
    if (!_firstClient.isCompleted) _firstClient.complete(socket);
    var buffer = '';
    socket.listen(
      (chunk) {
        buffer += utf8.decode(chunk);
        while (true) {
          final nl = buffer.indexOf('\n');
          if (nl < 0) break;
          final line = buffer.substring(0, nl).trim();
          buffer = buffer.substring(nl + 1);
          if (line.isEmpty) continue;
          final req = jsonDecode(line) as Map<String, dynamic>;
          _dispatch(req, socket);
        }
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  void _dispatch(Map<String, dynamic> req, Socket socket) {
    if (req['type'] == 'Health') {
      _writeResponse(socket, req['request_id'] as String, 'Health', {
        'protocol_version': healthVersion,
        'engine_ok': true,
        'llm_ok': true,
        'model': 'test-model',
        'asr_provider': 'fixture',
      });
      return;
    }
    onRequest?.call(req, socket);
  }

  Future<void> close() async {
    await _server?.close();
  }
}

void _writeResponse(
  Socket s,
  String requestId,
  String type,
  Map<String, dynamic> data,
) {
  s.write(
    '${jsonEncode({'protocol_version': 1, 'request_id': requestId, 'type': type, 'data': data})}\n',
  );
}

void _writeEvent(Socket s, String type, Map<String, dynamic> data) {
  s.write(
    '${jsonEncode({
      'protocol_version': 1,
      'event': {'type': type, 'data': data},
    })}\n',
  );
}

void _writeRaw(Socket s, String line) => s.write('$line\n');

// ---------------------------------------------------------------------------
// Async test helpers
// ---------------------------------------------------------------------------

Future<void> _waitState(
  EngineClient client,
  EngineConnectionState want, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (client.state.value == want) return;
  final done = Completer<void>();
  void listener() {
    if (client.state.value == want && !done.isCompleted) done.complete();
  }

  client.state.addListener(listener);
  try {
    await done.future.timeout(
      timeout,
      onTimeout: () => throw StateError(
        'timed out waiting for $want (last: ${client.state.value})',
      ),
    );
  } finally {
    client.state.removeListener(listener);
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) throw StateError('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
