// Client for the Notely Rust engine.
//
// This is the ONLY place the app is allowed to communicate with the backend. The transport
// (a local socket / stdio pipe to the engine process) is an implementation detail hidden
// behind this class, so the rest of the app never depends on how bytes reach the engine.
//
// The app depends on the engine's *protocol* (see `protocol.dart`), never on its internal
// implementation. It knows nothing about FFmpeg, ASR, Qwen, Ollama, models, or the database.

import 'protocol.dart';

/// Talks to the local engine over IPC. Requests return quickly; long-running work reports
/// progress via a stream of engine events.
class EngineClient {
  EngineClient();

  /// Send a request and await the engine's immediate response.
  ///
  /// TODO(v0): establish the transport, encode a versioned envelope
  /// ({protocolVersion, requestId, payload}), write it, and decode the response.
  Future<Map<String, dynamic>> send(Request request) async {
    throw UnimplementedError('EngineClient.send not implemented (scaffold)');
  }

  /// Stream of asynchronous engine events (job progress/lifecycle).
  ///
  /// TODO(v0): surface decoded events so the UI can show live progress.
  Stream<Map<String, dynamic>> events() {
    throw UnimplementedError('EngineClient.events not implemented (scaffold)');
  }
}
