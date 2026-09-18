// Knowledge Space state: loads the derived map from the engine and holds view selection.
//
// Kept UI-agnostic (like the other controllers). The map is deterministic, derived data from the
// engine's index — losing/refreshing it is cheap. When the engine is unavailable the controller
// simply reports an empty landscape rather than failing, matching the app's "degrade, never die"
// stance.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ipc/engine_client.dart';
import '../../ipc/protocol.dart' as ipc;
import 'knowledge_field.dart';

/// Load lifecycle of the map.
enum KnowledgeStatus { idle, loading, ready, error }

class KnowledgeController extends ChangeNotifier {
  KnowledgeController({required EngineClient engine})
    // ignore: prefer_initializing_formals (private field fed by a public named param)
    : _engine = engine;

  final EngineClient _engine;

  bool _open = false;
  KnowledgeStatus _status = KnowledgeStatus.idle;
  String? _error;
  ipc.KnowledgeMap _map = const ipc.KnowledgeMap();
  TerrainField _terrain = buildTerrain(const []);
  int? _focusedRegionId;
  ipc.KnowledgeConcept? _inspected;

  bool get isOpen => _open;
  KnowledgeStatus get status => _status;
  String? get error => _error;
  ipc.KnowledgeMap get map => _map;
  TerrainField get terrain => _terrain;
  int? get focusedRegionId => _focusedRegionId;
  ipc.KnowledgeConcept? get inspected => _inspected;

  List<ipc.KnowledgeRegion> get regions => _map.regions;
  List<ipc.KnowledgeConcept> get concepts => _map.concepts;
  bool get isEmpty => _map.isEmpty;

  // ── Panel visibility ──────────────────────────────────────────────────────
  void open(String? vaultPath) {
    _open = true;
    notifyListeners();
    // Load fresh each open (cheap, derived data). No-op if no vault.
    if (vaultPath != null) unawaited(load(vaultPath));
  }

  void close() {
    if (!_open) return;
    _open = false;
    _inspected = null;
    notifyListeners();
  }

  /// Fetch and rebuild the map for [vaultPath].
  Future<void> load(String vaultPath) async {
    _status = KnowledgeStatus.loading;
    _error = null;
    notifyListeners();
    if (!_engine.isConnected) {
      _map = const ipc.KnowledgeMap();
      _terrain = buildTerrain(const []);
      _status =
          KnowledgeStatus.ready; // an honest empty landscape, not an error
      _error = 'Engine offline — start it to map your knowledge.';
      notifyListeners();
      return;
    }
    try {
      final map = await _engine.knowledgeMap(vaultPath);
      _map = map;
      _terrain = _buildTerrain(map);
      _status = KnowledgeStatus.ready;
    } catch (e) {
      _status = KnowledgeStatus.error;
      _error = '$e';
    }
    notifyListeners();
  }

  TerrainField _buildTerrain(ipc.KnowledgeMap map) {
    if (map.concepts.isEmpty) return buildTerrain(const []);
    final maxMass = map.concepts.fold<double>(
      0,
      (m, c) => c.mass > m ? c.mass : m,
    );
    final peaks = [
      for (final c in map.concepts)
        FieldPeak(c.x, c.y, maxMass <= 0 ? 0.5 : (c.mass / maxMass)),
    ];
    return buildTerrain(peaks);
  }

  void focusRegion(int? id) {
    if (_focusedRegionId == id) return;
    _focusedRegionId = id;
    notifyListeners();
  }

  void inspect(ipc.KnowledgeConcept? concept) {
    _inspected = concept;
    if (concept != null) _focusedRegionId = concept.regionId;
    notifyListeners();
  }

  void clearInspect() {
    if (_inspected == null) return;
    _inspected = null;
    notifyListeners();
  }

  /// Fetch the underlying evidence for a concept term (reuses vault Search). Never throws — returns
  /// an empty list when the engine is down, so drill-down degrades gracefully.
  Future<List<ipc.EngineSearchHit>> evidence(
    String term,
    String vaultPath,
  ) async {
    if (!_engine.isConnected) return const [];
    try {
      return await _engine.search(term, vaultPath: vaultPath, limit: 12);
    } catch (_) {
      return const [];
    }
  }
}
