// The terrain math for the Knowledge Space — pure Dart, no Flutter, so it is unit-testable.
//
// Concepts are peaks: each contributes a Gaussian "hill" to a scalar height field, taller and
// broader with more mass. Summed, nearby peaks MERGE into continuous conceptual regions (exactly
// the metaphor we want — related ideas form one landmass). We then trace iso-height contour lines
// with marching squares, which is what gives the calm, editorial topographic-map look. Everything
// is computed once in normalized [0,1] space; the painter just transforms and strokes it.

import 'dart:math' as math;
import 'dart:ui' show Offset;

/// A peak in the field: normalized position and a normalized mass in (0,1].
class FieldPeak {
  const FieldPeak(this.x, this.y, this.mass);
  final double x;
  final double y;
  final double mass;
}

/// One iso-height contour: its normalized height [0,1] and the line segments that trace it.
class Contour {
  const Contour(this.height, this.segments);
  final double height;
  final List<(Offset, Offset)> segments;
}

/// The precomputed terrain: contour lines plus the raw field (for elevation lookups/labels).
class TerrainField {
  const TerrainField({
    required this.contours,
    required this.width,
    required this.height,
    required this.values,
    required this.maxValue,
  });

  final List<Contour> contours;
  final int width;
  final int height;
  final List<double> values; // row-major, length width*height, in [0,maxValue]
  final double maxValue;

  /// Sample the (normalized) elevation at a normalized point, bilinearly. 0 when out of range.
  double elevationAt(double nx, double ny) {
    if (maxValue <= 0) return 0;
    final fx = (nx * (width - 1)).clamp(0.0, (width - 1).toDouble());
    final fy = (ny * (height - 1)).clamp(0.0, (height - 1).toDouble());
    final x0 = fx.floor();
    final y0 = fy.floor();
    final x1 = math.min(x0 + 1, width - 1);
    final y1 = math.min(y0 + 1, height - 1);
    final tx = fx - x0;
    final ty = fy - y0;
    final v00 = values[y0 * width + x0];
    final v10 = values[y0 * width + x1];
    final v01 = values[y1 * width + x0];
    final v11 = values[y1 * width + x1];
    final top = v00 + (v10 - v00) * tx;
    final bot = v01 + (v11 - v01) * tx;
    return (top + (bot - top) * ty) / maxValue;
  }
}

/// Build the terrain for a set of peaks. [levels] are fractions of the field maximum to trace.
TerrainField buildTerrain(
  List<FieldPeak> peaks, {
  int gridWidth = 128,
  int gridHeight = 96,
  List<double> levels = const [0.1, 0.22, 0.36, 0.52, 0.7, 0.88],
}) {
  final w = gridWidth;
  final h = gridHeight;
  final values = List<double>.filled(w * h, 0);
  if (peaks.isEmpty) {
    return TerrainField(
      contours: const [],
      width: w,
      height: h,
      values: values,
      maxValue: 0,
    );
  }

  // Accumulate Gaussian hills. Bigger mass → taller and slightly broader.
  for (final p in peaks) {
    final amp = 0.35 + 0.65 * p.mass;
    final sigma = 0.045 + 0.05 * math.sqrt(p.mass.clamp(0.0, 1.0));
    final inv2s2 = 1.0 / (2 * sigma * sigma);
    // Only touch cells within ~3σ of the peak (the rest contributes ~0).
    final reach = (3 * sigma);
    final mingx = ((p.x - reach) * (w - 1)).floor().clamp(0, w - 1);
    final maxgx = ((p.x + reach) * (w - 1)).ceil().clamp(0, w - 1);
    final mingy = ((p.y - reach) * (h - 1)).floor().clamp(0, h - 1);
    final maxgy = ((p.y + reach) * (h - 1)).ceil().clamp(0, h - 1);
    for (var gy = mingy; gy <= maxgy; gy++) {
      final ny = gy / (h - 1);
      final dy = ny - p.y;
      for (var gx = mingx; gx <= maxgx; gx++) {
        final nx = gx / (w - 1);
        final dx = nx - p.x;
        values[gy * w + gx] += amp * math.exp(-(dx * dx + dy * dy) * inv2s2);
      }
    }
  }

  var maxValue = 0.0;
  for (final v in values) {
    if (v > maxValue) maxValue = v;
  }
  if (maxValue <= 0) {
    return TerrainField(
      contours: const [],
      width: w,
      height: h,
      values: values,
      maxValue: 0,
    );
  }

  final contours = <Contour>[];
  for (final frac in levels) {
    final level = frac * maxValue;
    contours.add(Contour(frac, _marchingSquares(values, w, h, level)));
  }
  return TerrainField(
    contours: contours,
    width: w,
    height: h,
    values: values,
    maxValue: maxValue,
  );
}

/// Trace one iso-line at [level] through the scalar grid, returning normalized segments.
List<(Offset, Offset)> _marchingSquares(
  List<double> v,
  int w,
  int h,
  double level,
) {
  final segs = <(Offset, Offset)>[];
  // Interpolate the crossing point on an edge between two corner values.
  Offset lerpEdge(
    double ax,
    double ay,
    double av,
    double bx,
    double by,
    double bv,
  ) {
    final t = ((level - av) / (bv - av)).clamp(0.0, 1.0);
    return Offset(ax + (bx - ax) * t, ay + (by - ay) * t);
  }

  for (var y = 0; y < h - 1; y++) {
    for (var x = 0; x < w - 1; x++) {
      final tl = v[y * w + x];
      final tr = v[y * w + x + 1];
      final br = v[(y + 1) * w + x + 1];
      final bl = v[(y + 1) * w + x];
      var caseId = 0;
      if (tl > level) caseId |= 8;
      if (tr > level) caseId |= 4;
      if (br > level) caseId |= 2;
      if (bl > level) caseId |= 1;
      if (caseId == 0 || caseId == 15) continue;

      final nx0 = x / (w - 1);
      final nx1 = (x + 1) / (w - 1);
      final ny0 = y / (h - 1);
      final ny1 = (y + 1) / (h - 1);
      // Edge crossing points (top, right, bottom, left).
      final top = lerpEdge(nx0, ny0, tl, nx1, ny0, tr);
      final right = lerpEdge(nx1, ny0, tr, nx1, ny1, br);
      final bottom = lerpEdge(nx0, ny1, bl, nx1, ny1, br);
      final left = lerpEdge(nx0, ny0, tl, nx0, ny1, bl);

      switch (caseId) {
        case 1:
        case 14:
          segs.add((left, bottom));
          break;
        case 2:
        case 13:
          segs.add((bottom, right));
          break;
        case 3:
        case 12:
          segs.add((left, right));
          break;
        case 4:
        case 11:
          segs.add((top, right));
          break;
        case 5:
          segs.add((left, top));
          segs.add((bottom, right));
          break;
        case 6:
        case 9:
          segs.add((top, bottom));
          break;
        case 7:
        case 8:
          segs.add((left, top));
          break;
        case 10:
          segs.add((left, bottom));
          segs.add((top, right));
          break;
      }
    }
  }
  return segs;
}
