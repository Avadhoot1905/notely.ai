// The Knowledge Space: a semantic-topographic map of the vault, rendered as terrain + typography.
//
// Design stance (see the product brief): NOT a node-link graph. Concepts are peaks; related ideas
// merge into continuous conceptual regions; important concepts form higher hills; semantic distance
// is spatial distance. Typography carries the meaning — contour lines are quiet, labels lead. The
// view supports pan, zoom, semantic zoom (labels appear in rank tiers as you zoom), region focus,
// concept inspection, and drilling from a concept to its underlying evidence (which opens in the
// existing editor). Everything re-themes via `context.tokens`; no neon, no glow, no dashboard.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../ipc/protocol.dart' as ipc;
import 'knowledge_field.dart';
import 'knowledge_state.dart';

class KnowledgeSpace extends StatefulWidget {
  const KnowledgeSpace({super.key});

  @override
  State<KnowledgeSpace> createState() => _KnowledgeSpaceState();
}

class _KnowledgeSpaceState extends State<KnowledgeSpace> {
  Offset _pan = Offset.zero;
  double _zoom = 1.0;
  Offset? _lastFocal;

  void _resetView() {
    setState(() {
      _pan = Offset.zero;
      _zoom = 1.0;
    });
  }

  void _zoomAbout(Offset focus, double factor, Size size) {
    final next = (_zoom * factor).clamp(0.6, 6.0);
    if (next == _zoom) return;
    // Keep the point under the cursor stationary while zooming.
    final center = Offset(size.width / 2, size.height / 2);
    final before = (focus - center - _pan) / _zoom;
    final after = (focus - center - _pan) / next;
    setState(() {
      _pan += (after - before) * next;
      _zoom = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final t = context.tokens;
    final k = scope.knowledge;
    return Material(
      color: t.background,
      child: AnimatedBuilder(
        animation: k,
        builder: (context, _) {
          return Column(
            children: [
              _Header(controller: k, onReset: _resetView),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      children: [
                        _canvas(context, k, size, t),
                        if (k.status == KnowledgeStatus.loading)
                          _centered(t, _loading(t)),
                        if (k.status == KnowledgeStatus.ready && k.isEmpty)
                          _centered(t, _empty(t, k)),
                        if (k.status == KnowledgeStatus.error)
                          _centered(t, _errorState(t, k)),
                        if (k.inspected != null)
                          Positioned(
                            right: 16,
                            top: 16,
                            bottom: 16,
                            child: _Inspector(concept: k.inspected!),
                          ),
                        Positioned(
                          left: 16,
                          bottom: 14,
                          child: _Legend(t: t, zoom: _zoom),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _canvas(
    BuildContext context,
    KnowledgeController k,
    Size size,
    NotelyTokens t,
  ) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          final factor = e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
          _zoomAbout(e.localPosition, factor, size);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) => _lastFocal = d.localFocalPoint,
        onScaleUpdate: (d) {
          setState(() {
            final focal = d.localFocalPoint;
            _pan += focal - (_lastFocal ?? focal);
            _lastFocal = focal;
            if (d.scale != 1.0) {
              final next = (_zoom * (1 + (d.scale - 1) * 0.5)).clamp(0.6, 6.0);
              _zoom = next;
            }
          });
        },
        onTapUp: (d) => _handleTap(d.localPosition, size, k),
        onDoubleTap: _resetView,
        child: CustomPaint(
          size: size,
          painter: _TerrainPainter(
            terrain: k.terrain,
            regions: k.regions,
            concepts: k.concepts,
            tokens: t,
            pan: _pan,
            zoom: _zoom,
            focusedRegionId: k.focusedRegionId,
            inspectedTerm: k.inspected?.term,
          ),
        ),
      ),
    );
  }

  void _handleTap(Offset pos, Size size, KnowledgeController k) {
    final tf = _MapTransform(size: size, pan: _pan, zoom: _zoom);
    // Prefer a nearby concept label (semantic-zoom aware: only tap what's visible).
    final visible = _visibleConceptRanks(k, _zoom);
    ipc.KnowledgeConcept? nearest;
    var best = 30.0;
    for (final c in k.concepts) {
      if (!visible(c)) continue;
      final p = tf.toScreen(Offset(c.x, c.y));
      final d = (p - pos).distance;
      if (d < best) {
        best = d;
        nearest = c;
      }
    }
    if (nearest != null) {
      k.inspect(nearest);
      return;
    }
    // Otherwise focus the region whose footprint contains the tap.
    for (final r in k.regions) {
      final c = tf.toScreen(Offset(r.x, r.y));
      final rad = r.radius * tf.scale * 1.3;
      if ((c - pos).distance <= rad) {
        k.focusRegion(k.focusedRegionId == r.id ? null : r.id);
        k.clearInspect();
        return;
      }
    }
    k.clearInspect();
    k.focusRegion(null);
  }

  // ── States ──────────────────────────────────────────────────────────────
  Widget _centered(NotelyTokens t, Widget child) =>
      IgnorePointer(ignoring: false, child: Center(child: child));

  Widget _loading(NotelyTokens t) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
      ),
      const SizedBox(height: 14),
      Text(
        'Reading the shape of your knowledge…',
        style: TextStyle(fontSize: 13, color: t.textSecondary),
      ),
    ],
  );

  Widget _empty(NotelyTokens t, KnowledgeController k) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.terrain_outlined, size: 30, color: t.textFaint),
        const SizedBox(height: 14),
        Text(
          'Your knowledge space is quiet',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          k.error ??
              'As you write notes and import from Slack or Teams, related ideas will '
                  'rise into domains here — the shape of what you know.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, height: 1.5, color: t.textFaint),
        ),
      ],
    ),
  );

  Widget _errorState(NotelyTokens t, KnowledgeController k) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 380),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_outlined, size: 26, color: t.textFaint),
        const SizedBox(height: 12),
        Text(
          'Couldn’t map your knowledge',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          k.error ?? 'Unknown error.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: t.textFaint),
        ),
      ],
    ),
  );
}

/// Rank-tier predicate for semantic zoom: which concepts are legible at [zoom].
bool Function(ipc.KnowledgeConcept) _visibleConceptRanks(
  KnowledgeController k,
  double zoom,
) {
  final total = k.concepts.length;
  final regionCount = k.regions.length;
  // Always show region peaks; reveal more concepts as you zoom in.
  final base = math.max(regionCount, 6);
  final boost = ((zoom - 1.0).clamp(0.0, 3.0) / 3.0 * total).round();
  final threshold = math.min(total, base + boost);
  final focused = k.focusedRegionId;
  final peakRankByRegion = <int, int>{};
  for (final c in k.concepts) {
    final cur = peakRankByRegion[c.regionId];
    if (cur == null || c.rank < cur) peakRankByRegion[c.regionId] = c.rank;
  }
  return (c) {
    if (focused != null && c.regionId == focused) return true;
    if (peakRankByRegion[c.regionId] == c.rank) return true;
    return c.rank < threshold;
  };
}

/// Normalized [0,1] ↔ screen mapping with pan/zoom, shared by painter and hit-testing.
class _MapTransform {
  _MapTransform({required this.size, required this.pan, required this.zoom}) {
    final fit = math.min(size.width, size.height) * 0.82;
    _scale = fit;
    _base = Offset((size.width - fit) / 2, (size.height - fit) / 2);
    _center = Offset(size.width / 2, size.height / 2);
  }

  final Size size;
  final Offset pan;
  final double zoom;
  late final double _scale;
  late final Offset _base;
  late final Offset _center;

  /// Effective normalized→screen scale (px per unit).
  double get scale => _scale * zoom;

  Offset toScreen(Offset n) {
    final p0 = _base + Offset(n.dx * _scale, n.dy * _scale);
    return _center + (p0 - _center) * zoom + pan;
  }
}

class _TerrainPainter extends CustomPainter {
  _TerrainPainter({
    required this.terrain,
    required this.regions,
    required this.concepts,
    required this.tokens,
    required this.pan,
    required this.zoom,
    required this.focusedRegionId,
    required this.inspectedTerm,
  });

  final TerrainField terrain;
  final List<ipc.KnowledgeRegion> regions;
  final List<ipc.KnowledgeConcept> concepts;
  final NotelyTokens tokens;
  final Offset pan;
  final double zoom;
  final int? focusedRegionId;
  final String? inspectedTerm;

  @override
  void paint(Canvas canvas, Size size) {
    final tf = _MapTransform(size: size, pan: pan, zoom: zoom);

    // 1. Region landmasses — a very subtle radial wash so a domain reads as ground, not a node.
    for (final r in regions) {
      final center = tf.toScreen(Offset(r.x, r.y));
      final radius = r.radius * tf.scale * 1.45;
      if (radius <= 1) continue;
      final focused = focusedRegionId == r.id;
      final base = focused ? tokens.accent : tokens.textFaint;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            base.withValues(alpha: focused ? 0.10 : 0.05),
            base.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    // 2. Contour lines — the topographic texture. One path per level, drawn once.
    for (final contour in terrain.contours) {
      if (contour.segments.isEmpty) continue;
      final path = Path();
      for (final (a, b) in contour.segments) {
        final pa = tf.toScreen(a);
        final pb = tf.toScreen(b);
        path.moveTo(pa.dx, pa.dy);
        path.lineTo(pb.dx, pb.dy);
      }
      // Higher elevation → slightly stronger line (subtle elevation shading).
      final alpha = 0.06 + contour.height * 0.16;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = tokens.textFaint.withValues(alpha: alpha);
      canvas.drawPath(path, paint);
    }

    // 3. Concept peaks (typography). Semantic zoom decides which are legible.
    final visible = _semanticVisible();
    final maxMass = concepts.fold<double>(0, (m, c) => c.mass > m ? c.mass : m);
    // Draw lighter, smaller concepts first so heavier peaks sit on top.
    final ordered = [...concepts]..sort((a, b) => a.mass.compareTo(b.mass));
    for (final c in ordered) {
      if (!visible(c)) continue;
      final isPeak = _isRegionPeak(c);
      final norm = maxMass <= 0 ? 0.5 : c.mass / maxMass;
      final p = tf.toScreen(Offset(c.x, c.y));
      if (!size.contains(p)) continue;
      final inspected = inspectedTerm == c.term;
      final fontSize = (11.0 + norm * 12.0) * (isPeak ? 1.05 : 0.92);
      final color = inspected
          ? tokens.accent
          : isPeak
          ? tokens.textPrimary
          : tokens.textSecondary;
      _label(
        canvas,
        c.term,
        p,
        fontSize: fontSize.clamp(10.0, 30.0),
        color: color,
        weight: isPeak ? FontWeight.w600 : FontWeight.w400,
        underline: inspected,
      );
    }

    // 4. Region labels — quiet uppercase, fading out as concepts take over on zoom-in.
    final regionLabelAlpha = (1.6 - zoom).clamp(0.0, 1.0);
    if (regionLabelAlpha > 0.02) {
      for (final r in regions) {
        if (r.label.isEmpty) continue;
        final p = tf.toScreen(Offset(r.x, r.y - r.radius - 0.02));
        _label(
          canvas,
          r.label.toUpperCase(),
          p,
          fontSize: (13.0 + (r.mass) * 0.0).clamp(12.0, 20.0),
          color:
              (focusedRegionId == r.id ? tokens.accent : tokens.textSecondary)
                  .withValues(alpha: regionLabelAlpha),
          weight: FontWeight.w700,
          letterSpacing: 1.6,
        );
      }
    }
  }

  bool Function(ipc.KnowledgeConcept) _semanticVisible() {
    final total = concepts.length;
    final base = math.max(regions.length, 6);
    final boost = ((zoom - 1.0).clamp(0.0, 3.0) / 3.0 * total).round();
    final threshold = math.min(total, base + boost);
    return (c) {
      if (focusedRegionId != null && c.regionId == focusedRegionId) return true;
      if (_isRegionPeak(c)) return true;
      return c.rank < threshold;
    };
  }

  final Map<int, int> _peakCache = {};
  bool _isRegionPeak(ipc.KnowledgeConcept c) {
    if (_peakCache.isEmpty) {
      for (final x in concepts) {
        final cur = _peakCache[x.regionId];
        if (cur == null || x.rank < cur) _peakCache[x.regionId] = x.rank;
      }
    }
    return _peakCache[c.regionId] == c.rank;
  }

  void _label(
    Canvas canvas,
    String text,
    Offset center, {
    required double fontSize,
    required Color color,
    FontWeight weight = FontWeight.w400,
    double letterSpacing = 0.0,
    bool underline = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: weight,
          letterSpacing: letterSpacing,
          decoration: underline
              ? TextDecoration.underline
              : TextDecoration.none,
          decorationColor: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: 220);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TerrainPainter old) =>
      old.pan != pan ||
      old.zoom != zoom ||
      old.focusedRegionId != focusedRegionId ||
      old.inspectedTerm != inspectedTerm ||
      !identical(old.terrain, terrain);
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.onReset});
  final KnowledgeController controller;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final scope = AppScope.of(context);
    final stats = controller.map.stats;
    return Container(
      height: NotelyDims.titleBarHeight + 6,
      padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
      decoration: BoxDecoration(
        color: t.background,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.terrain_outlined, size: 16, color: t.accent),
          const SizedBox(width: 10),
          Text(
            'KNOWLEDGE SPACE',
            style: NotelyType.sectionLabel.copyWith(color: t.textPrimary),
          ),
          const SizedBox(width: 12),
          if (!controller.isEmpty)
            Text(
              '${stats.conceptCount} concepts · ${stats.regionCount} domains · '
              '${stats.noteCount} notes${stats.truncated ? ' (sampled)' : ''}',
              style: TextStyle(fontSize: 11.5, color: t.textFaint),
            ),
          const Spacer(),
          _HeaderBtn(
            icon: Icons.center_focus_strong_outlined,
            tip: 'Reset view',
            onTap: onReset,
          ),
          _HeaderBtn(
            icon: Icons.refresh,
            tip: 'Rebuild map',
            onTap: () {
              final root = scope.stash.path;
              if (root != null) controller.load(root);
            },
          ),
          _HeaderBtn(
            icon: Icons.close_rounded,
            tip: 'Close',
            onTap: controller.close,
          ),
        ],
      ),
    );
  }
}

class _HeaderBtn extends StatelessWidget {
  const _HeaderBtn({
    required this.icon,
    required this.tip,
    required this.onTap,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 16, color: t.textFaint),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Legend
// ─────────────────────────────────────────────────────────────────────────────
class _Legend extends StatelessWidget {
  const _Legend({required this.t, required this.zoom});
  final NotelyTokens t;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: t.raised.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        border: Border.all(color: t.border),
      ),
      child: Text(
        'Scroll to zoom · drag to pan · click a concept for evidence',
        style: TextStyle(fontSize: 10.5, color: t.textFaint),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Concept inspector — drill from a concept to its underlying evidence.
// ─────────────────────────────────────────────────────────────────────────────
class _Inspector extends StatefulWidget {
  const _Inspector({required this.concept});
  final ipc.KnowledgeConcept concept;

  @override
  State<_Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<_Inspector> {
  // Memoize the evidence lookup by term so the parent's frequent rebuilds (pan/zoom) don't re-fire
  // a Search on every frame — the future is created once per inspected concept.
  Future<List<ipc.EngineSearchHit>>? _future;
  String? _forKey;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final scope = AppScope.of(context);
    final k = scope.knowledge;
    final root = scope.stash.path;
    final concept = widget.concept;
    final key = '${concept.term}@$root';
    if (_forKey != key) {
      _forKey = key;
      _future = root == null
          ? Future.value(const [])
          : k.evidence(concept.term, root);
    }
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: t.panel,
        borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
        border: Border.all(color: t.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        concept.term,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: t.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'appears in ${concept.docCount} '
                        '${concept.docCount == 1 ? 'note' : 'notes'}',
                        style: TextStyle(fontSize: 11.5, color: t.textFaint),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: k.clearInspect,
                  borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: t.textFaint,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (concept.sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in concept.sources) _SourceChip(kind: s),
                ],
              ),
            ),
          Divider(height: 1, color: t.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(
              'EVIDENCE',
              style: NotelyType.sectionLabel.copyWith(
                fontSize: 10,
                color: t.textFaint,
              ),
            ),
          ),
          Expanded(
            child: root == null
                ? Center(
                    child: Text(
                      'Open a stash to see evidence.',
                      style: TextStyle(fontSize: 12, color: t.textFaint),
                    ),
                  )
                : FutureBuilder<List<ipc.EngineSearchHit>>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return Center(
                          child: SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: t.accent,
                            ),
                          ),
                        );
                      }
                      final hits = snap.data ?? const [];
                      if (hits.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              'No evidence found (is the engine running?).',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: t.textFaint,
                              ),
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                        itemCount: hits.length,
                        itemBuilder: (context, i) => _EvidenceRow(hit: hits[i]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (IconData icon, String label) = switch (kind) {
      'slack' => (Icons.tag, 'Slack'),
      'teams' => (Icons.groups_outlined, 'Teams'),
      _ => (Icons.description_outlined, 'Notes'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: t.textFaint),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11, color: t.textSecondary)),
        ],
      ),
    );
  }
}

class _EvidenceRow extends StatefulWidget {
  const _EvidenceRow({required this.hit});
  final ipc.EngineSearchHit hit;

  @override
  State<_EvidenceRow> createState() => _EvidenceRowState();
}

class _EvidenceRowState extends State<_EvidenceRow> {
  bool _hover = false;

  Future<void> _open() async {
    final scope = AppScope.of(context);
    final h = widget.hit;
    scope.explorer.selectFile(h.path);
    await scope.editor.open(h.path);
    if (!mounted) return;
    scope.editor.selectLines(h.startLine, h.endLine);
    // Leave the map for the evidence, matching "visualization → concept → source evidence".
    scope.knowledge.close();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final h = widget.hit;
    final name = h.path.split(RegExp(r'[/\\]')).last;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _open,
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
                  Flexible(
                    child: Text(
                      h.title.isEmpty ? name : h.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.textPrimary,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.north_east, size: 12, color: t.textFaint),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                h.snippet,
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
