// Client for the Notely Rust engine.
//
// This is the ONLY place the app is allowed to communicate with the backend. The transport
// (newline-delimited JSON over a loopback TCP socket to the engine process) is an implementation
// detail hidden behind this class, so the rest of the app never depends on how bytes reach the
// engine.
//
// The app depends on the engine's *protocol* (see `protocol.dart`), never on its internal
// implementation. It knows nothing about FFmpeg, ASR, Qwen, Ollama, models, or the database.
//
// Lifecycle model: for v0 the engine runs as a **separate process** (see `scripts/dev.sh`,
// `scripts/start-engine.sh`) and the app *connects* to it. The engine is not assumed to always be
// running: [start] begins a connect loop that reconnects with capped backoff, and [status]
// reports the current connection state so the UI can degrade gracefully.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'protocol.dart';

/// Default loopback address the engine's IPC server binds to (see `engine/src/config.rs` and
/// `NOTELY_IPC_ADDR`). Kept in sync with the engine's default.
const String kDefaultEngineHost = '127.0.0.1';
const int kDefaultEnginePort = 8765;

/// Connection state of the IPC link, surfaced to the UI.
enum EngineConnectionState {
  /// Not connected and not currently trying.
  disconnected,

  /// A connection attempt (or reconnect) is in flight.
  connecting,

  /// The transport is up and requests can be sent.
  connected,

  /// The engine speaks an incompatible protocol version; we will not talk to it.
  incompatible,
}

/// Thrown when a request is attempted but the engine is not reachable.
class EngineUnavailable implements Exception {
  final String message;
  const EngineUnavailable([this.message = 'engine not connected']);
  @override
  String toString() => 'EngineUnavailable: $message';
}

/// Talks to the local engine over IPC. Requests return quickly; long-running work reports
/// progress via a stream of engine events ([events]).
///
/// Everything is funneled through a single socket: outbound requests are line-framed JSON
/// envelopes correlated by `request_id`; inbound lines are either responses (carry `request_id`)
/// or events (carry `event`).
class EngineClient {
  EngineClient({
    String? host,
    int? port,
    this.requestTimeout = const Duration(seconds: 30),
    this.handshakeTimeout = const Duration(seconds: 5),
    this.minBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 10),
  }) : host = host ?? _hostFromEnv() ?? kDefaultEngineHost,
       port = port ?? _portFromEnv() ?? kDefaultEnginePort;

  final String host;
  final int port;
  final Duration requestTimeout;
  final Duration handshakeTimeout;
  final Duration minBackoff;
  final Duration maxBackoff;

  Socket? _socket;
  StreamSubscription<List<int>>? _socketSub;
  String _readBuffer = '';

  bool _running = false;
  int _nextRequestId = 0;
  Duration _backoff = const Duration(milliseconds: 500);
  Timer? _reconnectTimer;

  final Map<String, Completer<Response>> _pending = {};

  final ValueNotifier<EngineConnectionState> _state = ValueNotifier(
    EngineConnectionState.disconnected,
  );

  /// Last error observed on the transport, for display. Null when healthy.
  final ValueNotifier<String?> _lastError = ValueNotifier(null);

  /// Last successful health snapshot, if any.
  final ValueNotifier<HealthInfo?> _health = ValueNotifier(null);

  final StreamController<EngineEvent> _events =
      StreamController<EngineEvent>.broadcast();

  /// Current connection state (listenable).
  ValueListenable<EngineConnectionState> get state => _state;

  /// Last transport error message, or null (listenable).
  ValueListenable<String?> get lastError => _lastError;

  /// Last health snapshot from the engine, or null (listenable).
  ValueListenable<HealthInfo?> get health => _health;

  /// True once the transport is up and requests may be sent.
  bool get isConnected => _state.value == EngineConnectionState.connected;

  /// Stream of asynchronous engine events (job progress/lifecycle). Broadcast, so multiple
  /// features can subscribe; unknown event types are surfaced as [EngineEventType.unknown]
  /// rather than dropped or crashing.
  Stream<EngineEvent> events() => _events.stream;

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  /// Begin connecting to the engine, reconnecting with capped backoff until [dispose] is called.
  /// Idempotent: calling it again while already running is a no-op.
  void start() {
    if (_running) return;
    _running = true;
    _backoff = minBackoff;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (!_running || _socket != null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(EngineConnectionState.connecting);
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      _socket = socket;
      _readBuffer = '';
      _socketSub = socket.listen(
        _onData,
        onError: (Object e) => _onDisconnected(e.toString()),
        onDone: () => _onDisconnected('connection closed'),
        cancelOnError: true,
      );
      // A reset/broken pipe surfaces on `done` (e.g. failed writes when the engine crashes).
      // Swallow it here so it never escapes as an unhandled zone error; `onError`/`onDone`
      // above already drive the disconnect/reconnect path.
      unawaited(socket.done.then((_) {}, onError: (_) {}));
      _lastError.value = null;
      _backoff = minBackoff;
      _setState(EngineConnectionState.connected);
      // Handshake: verify protocol compatibility and capture health. Best-effort — a slow LLM
      // probe must not fail the connection, but a version mismatch must.
      unawaited(_handshake());
    } catch (e) {
      _onDisconnected('connect failed: $e');
    }
  }

  Future<void> _handshake() async {
    try {
      final resp = await send(const Health(), timeout: handshakeTimeout);
      if (resp is HealthResponse) {
        _health.value = resp.info;
        if (resp.info.protocolVersion != protocolVersion) {
          _lastError.value =
              'protocol version mismatch: app v$protocolVersion, engine v${resp.info.protocolVersion}';
          _setState(EngineConnectionState.incompatible);
          _running = false; // do not hammer an incompatible engine
          await _teardownSocket();
        }
      } else if (resp is ErrorResponse) {
        // A version-mismatch error from the engine also means incompatible.
        _lastError.value = resp.message;
        if (resp.message.contains('protocol version')) {
          _setState(EngineConnectionState.incompatible);
          _running = false;
          await _teardownSocket();
        }
      }
    } on EngineUnavailable {
      // Socket dropped during handshake; the disconnect path handles reconnect.
    } catch (e) {
      // Handshake timeout/other: leave the connection up (TCP is fine); just note it.
      _lastError.value = 'health check failed: $e';
    }
  }

  void _onDisconnected(String reason) {
    _lastError.value = reason;
    _failPending(EngineUnavailable(reason));
    _teardownSocketSync();
    if (_state.value != EngineConnectionState.incompatible) {
      _setState(EngineConnectionState.disconnected);
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    final delay = _backoff;
    _reconnectTimer = Timer(delay, () {
      if (_running && _socket == null) unawaited(_connect());
    });
    // Exponential backoff, capped.
    final next = _backoff * 2;
    _backoff = next > maxBackoff ? maxBackoff : next;
  }

  Future<void> _teardownSocket() async {
    final sub = _socketSub;
    final sock = _socket;
    _socketSub = null;
    _socket = null;
    await sub?.cancel();
    try {
      await sock?.close();
    } catch (_) {}
    sock?.destroy();
  }

  void _teardownSocketSync() {
    final sub = _socketSub;
    final sock = _socket;
    _socketSub = null;
    _socket = null;
    sub?.cancel();
    sock?.destroy();
  }

  void _failPending(Object error) {
    if (_pending.isEmpty) return;
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  void _setState(EngineConnectionState s) {
    if (_state.value != s) _state.value = s;
  }

  // -------------------------------------------------------------------------
  // Inbound framing
  // -------------------------------------------------------------------------

  void _onData(List<int> chunk) {
    _readBuffer += utf8.decode(chunk, allowMalformed: true);
    while (true) {
      final nl = _readBuffer.indexOf('\n');
      if (nl < 0) break;
      final line = _readBuffer.substring(0, nl).trim();
      _readBuffer = _readBuffer.substring(nl + 1);
      if (line.isNotEmpty) _handleLine(line);
    }
  }

  void _handleLine(String line) {
    Map<String, dynamic> envelope;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('top-level JSON is not an object');
      }
      envelope = decoded;
    } catch (e) {
      // Malformed inbound payload: never crash. Note it and move on.
      _lastError.value = 'malformed engine message: $e';
      return;
    }

    // Events carry an `event` object; responses carry a `request_id`.
    final eventObj = envelope['event'];
    if (eventObj is Map<String, dynamic>) {
      try {
        _events.add(EngineEvent.fromJson(eventObj));
      } catch (e) {
        _lastError.value = 'undecodable event: $e';
      }
      return;
    }

    final requestId = envelope['request_id'];
    if (requestId is String) {
      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) return;
      try {
        completer.complete(Response.fromJson(envelope));
      } catch (e) {
        completer.completeError(ProtocolException('$e'));
      }
      return;
    }

    // Neither a recognized response nor event.
    _lastError.value = 'unrecognized engine message: $line';
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  /// Send a request and await the engine's immediate response.
  ///
  /// Throws [EngineUnavailable] if the transport is down, [TimeoutException] if the engine does
  /// not respond in time, and [ProtocolException] on an undecodable response. A backend-level
  /// failure comes back as an [ErrorResponse] (not thrown).
  Future<Response> send(Request request, {Duration? timeout}) async {
    final socket = _socket;
    if (socket == null || _state.value == EngineConnectionState.incompatible) {
      throw const EngineUnavailable();
    }

    final id = (_nextRequestId++).toString();
    final envelope = <String, dynamic>{
      'protocol_version': protocolVersion,
      'request_id': id,
      ...request.toJson(),
    };

    final completer = Completer<Response>();
    _pending[id] = completer;

    try {
      socket.write('${jsonEncode(envelope)}\n');
    } catch (e) {
      _pending.remove(id);
      throw EngineUnavailable('write failed: $e');
    }

    return completer.future.timeout(
      timeout ?? requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
          'engine did not respond to ${request.type}',
          timeout ?? requestTimeout,
        );
      },
    );
  }

  // ---- Typed convenience wrappers over [send] ----

  /// Liveness probe; also updates [health].
  Future<HealthInfo> checkHealth({Duration? timeout}) async {
    final resp = await send(const Health(), timeout: timeout);
    if (resp is HealthResponse) {
      _health.value = resp.info;
      return resp.info;
    }
    throw _unexpected(resp, 'Health');
  }

  /// Submit a meeting for processing; returns the accepted job id. Progress arrives via [events].
  Future<String> processMeeting(ProcessInput input) async {
    final resp = await send(ProcessMeeting(input));
    if (resp is JobAcceptedResponse) return resp.jobId;
    throw _unexpected(resp, 'JobAccepted');
  }

  /// Fetch a job's current status.
  Future<Job> getJob(String jobId) async {
    final resp = await send(GetJob(jobId));
    if (resp is JobResponse) return resp.job;
    throw _unexpected(resp, 'Job');
  }

  /// Cancel an in-flight job; returns its updated status.
  Future<Job> cancelJob(String jobId) async {
    final resp = await send(CancelJob(jobId));
    if (resp is JobResponse) return resp.job;
    throw _unexpected(resp, 'Job');
  }

  /// Fetch meeting metadata.
  Future<Meeting> getMeeting(String meetingId) async {
    final resp = await send(GetMeeting(meetingId));
    if (resp is MeetingResponse) return resp.meeting;
    throw _unexpected(resp, 'Meeting');
  }

  /// Fetch the canonical transcript for a meeting.
  Future<Transcript> getTranscript(String meetingId) async {
    final resp = await send(GetTranscript(meetingId));
    if (resp is TranscriptResponse) return resp.transcript;
    throw _unexpected(resp, 'Transcript');
  }

  /// Fetch the rendered (Markdown) MOM for a meeting.
  Future<String> getMom(String meetingId) async {
    final resp = await send(GetMom(meetingId));
    if (resp is MomResponse) return resp.markdown;
    throw _unexpected(resp, 'Mom');
  }

  /// Full-text search the vault rooted at [vaultPath].
  Future<List<EngineSearchHit>> search(
    String query, {
    required String vaultPath,
    int? limit,
  }) async {
    final resp = await send(
      Search(query: query, vaultPath: vaultPath, limit: limit),
    );
    if (resp is SearchResultsResponse) return resp.hits;
    throw _unexpected(resp, 'SearchResults');
  }

  /// Ask a question grounded in the vault rooted at [vaultPath].
  ///
  /// Generation runs a local LLM, which can be slow, so this uses a generous timeout by default
  /// rather than the standard request timeout.
  Future<EngineAnswer> ask(
    String question, {
    required String vaultPath,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final resp = await send(
      Ask(question: question, vaultPath: vaultPath),
      timeout: timeout,
    );
    if (resp is AnswerResponse) return resp.answer;
    throw _unexpected(resp, 'Answer');
  }

  /// List captured meetings with their processing status (Inbox + recovery UI).
  Future<List<MeetingSummary>> listMeetings() async {
    final resp = await send(const ListMeetings());
    if (resp is MeetingListResponse) return resp.meetings;
    throw _unexpected(resp, 'MeetingList');
  }

  /// Retry AI enrichment for an existing meeting; returns the accepted job id. Progress arrives via
  /// [events]. Idempotent on the engine side — never creates a duplicate meeting.
  Future<String> reprocessMeeting(String meetingId) async {
    final resp = await send(ReprocessMeeting(meetingId));
    if (resp is JobAcceptedResponse) return resp.jobId;
    throw _unexpected(resp, 'JobAccepted');
  }

  /// Fetch the Knowledge Space for the vault rooted at [vaultPath]. Deriving concepts can touch the
  /// whole index, so this uses a slightly more generous timeout than a plain request.
  Future<KnowledgeMap> knowledgeMap(
    String vaultPath, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final resp = await send(GetKnowledgeMap(vaultPath), timeout: timeout);
    if (resp is KnowledgeMapResponse) return resp.map;
    throw _unexpected(resp, 'KnowledgeMap');
  }

  /// List importable channels for [kind] ('slack'|'teams') using [token] (kept in-memory only).
  /// Network + auth can be slow, so this uses a generous timeout.
  Future<({String workspace, List<SourceChannel> channels})>
  listSourceChannels({
    required String kind,
    required String token,
    String baseUrl = '',
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final resp = await send(
      ListSourceChannels(kind: kind, token: token, baseUrl: baseUrl),
      timeout: timeout,
    );
    if (resp is SourceChannelsResponse) {
      return (workspace: resp.workspace, channels: resp.channels);
    }
    throw _unexpected(resp, 'SourceChannels');
  }

  /// Import [scope] from an external source into the vault; returns a summary of what was brought in.
  Future<ImportSummary> importSource({
    required String kind,
    required String token,
    String baseUrl = '',
    required String vaultPath,
    required ImportScope scope,
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final resp = await send(
      ImportSource(
        kind: kind,
        token: token,
        baseUrl: baseUrl,
        vaultPath: vaultPath,
        scope: scope,
      ),
      timeout: timeout,
    );
    if (resp is ImportResultResponse) return resp.summary;
    throw _unexpected(resp, 'ImportResult');
  }

  /// List connected sources and what has been imported.
  Future<List<ConnectedSource>> listSources() async {
    final resp = await send(const ListSources());
    if (resp is SourcesResponse) return resp.sources;
    throw _unexpected(resp, 'Sources');
  }

  /// Disconnect a source; optionally delete its imported Markdown from the vault.
  Future<void> disconnectSource({
    required String kind,
    required String vaultPath,
    bool removeImported = false,
  }) async {
    final resp = await send(
      DisconnectSource(
        kind: kind,
        vaultPath: vaultPath,
        removeImported: removeImported,
      ),
    );
    if (resp is OkResponse) return;
    throw _unexpected(resp, 'Ok');
  }

  Exception _unexpected(Response resp, String expected) {
    if (resp is ErrorResponse) return EngineError(resp.message);
    return ProtocolException(
      'expected $expected response, got ${resp.runtimeType}',
    );
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  /// Stop connecting, drop the socket, and release resources. After this the client is inert.
  Future<void> dispose() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _failPending(const EngineUnavailable('client disposed'));
    await _teardownSocket();
    _setState(EngineConnectionState.disconnected);
    await _events.close();
    _state.dispose();
    _lastError.dispose();
    _health.dispose();
  }

  static String? _hostFromEnv() => _addrFromEnv()?.$1;
  static int? _portFromEnv() => _addrFromEnv()?.$2;

  /// Parse `NOTELY_IPC_ADDR` (e.g. "127.0.0.1:8765") if present, mirroring the engine's env knob.
  static (String, int)? _addrFromEnv() {
    final raw = Platform.environment['NOTELY_IPC_ADDR'];
    if (raw == null) return null;
    final idx = raw.lastIndexOf(':');
    if (idx <= 0) return null;
    final h = raw.substring(0, idx);
    final p = int.tryParse(raw.substring(idx + 1));
    if (p == null) return null;
    return (h, p);
  }
}
