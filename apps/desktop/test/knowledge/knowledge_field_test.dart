// Unit tests for the Knowledge Space terrain math (pure Dart — no Flutter binding needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/knowledge/knowledge_field.dart';

void main() {
  test('empty peaks produce a flat, contour-less field', () {
    final terrain = buildTerrain(const []);
    expect(terrain.maxValue, 0);
    expect(terrain.contours, isEmpty);
    expect(terrain.elevationAt(0.5, 0.5), 0);
  });

  test('a single peak raises the highest elevation at its centre', () {
    final terrain = buildTerrain([const FieldPeak(0.5, 0.5, 1.0)]);
    expect(terrain.maxValue, greaterThan(0));
    final atPeak = terrain.elevationAt(0.5, 0.5);
    final atEdge = terrain.elevationAt(0.02, 0.02);
    expect(atPeak, greaterThan(atEdge));
    expect(atPeak, closeTo(1.0, 0.05)); // normalized elevation peaks near 1
    // Contours are traced at every requested level.
    expect(terrain.contours, isNotEmpty);
    expect(terrain.contours.any((c) => c.segments.isNotEmpty), isTrue);
  });

  test('two nearby peaks merge into one continuous conceptual region', () {
    // Close peaks: the valley between them stays above a low contour level, i.e. they form one
    // landmass rather than two islands — the core metaphor.
    final terrain = buildTerrain([
      const FieldPeak(0.45, 0.5, 1.0),
      const FieldPeak(0.55, 0.5, 1.0),
    ]);
    final between = terrain.elevationAt(0.5, 0.5);
    final farAway = terrain.elevationAt(0.05, 0.5);
    expect(between, greaterThan(farAway));
    expect(
      between,
      greaterThan(0.3),
      reason: 'the merged saddle is still high ground',
    );
  });

  test('is deterministic for identical input', () {
    final peaks = [
      const FieldPeak(0.3, 0.3, 0.8),
      const FieldPeak(0.7, 0.6, 0.5),
    ];
    final a = buildTerrain(peaks);
    final b = buildTerrain(peaks);
    expect(a.maxValue, b.maxValue);
    expect(a.contours.length, b.contours.length);
    for (var i = 0; i < a.contours.length; i++) {
      expect(a.contours[i].segments.length, b.contours[i].segments.length);
    }
  });
}
