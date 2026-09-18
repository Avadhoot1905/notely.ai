// Integrations state: connect Slack/Teams as knowledge sources and import selected channels.
//
// Privacy stance: tokens are held ONLY in memory for the session ([_tokens]) and passed to the
// engine per request — never written to disk, never into the knowledge DB. The engine likewise
// keeps no token; only non-secret bookkeeping (what's connected/imported) is persisted. This is a
// deliberate, dependency-free credential model with a clean seam to swap in an OS keychain later.

import 'package:flutter/foundation.dart';

import '../../ipc/engine_client.dart';
import '../../ipc/protocol.dart' as ipc;

/// Supported source kinds (mirrors the engine's `SourceKind`).
enum SourceKind {
  slack,
  teams;

  String get wire => switch (this) {
    SourceKind.slack => 'slack',
    SourceKind.teams => 'teams',
  };

  String get label => switch (this) {
    SourceKind.slack => 'Slack',
    SourceKind.teams => 'Microsoft Teams',
  };

  /// A hint for the token field so users know what to paste.
  String get tokenHint => switch (this) {
    SourceKind.slack => 'Slack token (xoxb-… / xoxp-…)',
    SourceKind.teams => 'Microsoft Graph access token',
  };

  static SourceKind fromWire(String s) =>
      s == 'teams' ? SourceKind.teams : SourceKind.slack;
}

class IntegrationsController extends ChangeNotifier {
  // ignore_for_file: prefer_initializing_formals
  // (private fields fed by public named params — no valid initializing-formal form exists)
  IntegrationsController({
    required EngineClient engine,
    required String? Function() resolveVault,
  }) : _engine = engine,
       _resolveVault = resolveVault;

  final EngineClient _engine;
  final String? Function() _resolveVault;

  /// Session-only tokens, keyed by source wire tag. Never persisted.
  final Map<String, String> _tokens = {};

  List<ipc.ConnectedSource> _sources = const [];
  bool _loading = false;
  String? _error;

  List<ipc.ConnectedSource> get sources => _sources;
  bool get loading => _loading;
  String? get error => _error;

  /// A session token previously used for [kind], if any (so "import more" needn't re-ask).
  String? tokenFor(SourceKind kind) => _tokens[kind.wire];

  bool get _connected => _engine.isConnected;

  /// Reload the connected-sources list from the engine.
  Future<void> refresh() async {
    if (!_connected) {
      _sources = const [];
      _error = 'Engine offline — start it to manage connected sources.';
      notifyListeners();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _sources = await _engine.listSources();
    } catch (e) {
      _error = '$e';
    }
    _loading = false;
    notifyListeners();
  }

  /// List importable channels for a source using [token] (kept in memory only).
  Future<({String workspace, List<ipc.SourceChannel> channels})> listChannels(
    SourceKind kind,
    String token, {
    String baseUrl = '',
  }) async {
    final result = await _engine.listSourceChannels(
      kind: kind.wire,
      token: token,
      baseUrl: baseUrl,
    );
    _tokens[kind.wire] = token; // remember for the session
    return result;
  }

  /// Import [scope] from [kind]. Returns the summary; refreshes the connected list on success.
  Future<ipc.ImportSummary> import(
    SourceKind kind,
    String token, {
    String baseUrl = '',
    required ipc.ImportScope scope,
  }) async {
    final vault = _resolveVault();
    if (vault == null) {
      throw StateError('Open a stash before importing.');
    }
    final summary = await _engine.importSource(
      kind: kind.wire,
      token: token,
      baseUrl: baseUrl,
      vaultPath: vault,
      scope: scope,
    );
    _tokens[kind.wire] = token;
    await refresh();
    return summary;
  }

  /// Disconnect a source; optionally delete its imported Markdown from the vault.
  Future<void> disconnect(
    SourceKind kind, {
    bool removeImported = false,
  }) async {
    final vault = _resolveVault();
    if (vault == null) return;
    await _engine.disconnectSource(
      kind: kind.wire,
      vaultPath: vault,
      removeImported: removeImported,
    );
    _tokens.remove(kind.wire);
    await refresh();
  }
}
