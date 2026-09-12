// Notely design system.
//
// A single source of truth for the visual language. Semantic color tokens live in
// [NotelyTokens] — a [ThemeExtension] so the exact same widget code resolves to the dark or
// light palette at runtime via `context.tokens`. Geometry ([NotelyDims]), motion
// ([NotelyMotion]), and the type scale ([NotelyType]) are centralized here too.
//
// Design intent: 90% calm, 10% punch. Surfaces are layered (never pure black / pure white),
// text has a clear three-step hierarchy, and one restrained accent carries identity —
// appearing only on active/selected/live/focus states and primary actions.

import 'package:flutter/material.dart';

/// Semantic color tokens, resolved per theme. Read via `context.tokens`.
@immutable
class NotelyTokens extends ThemeExtension<NotelyTokens> {
  const NotelyTokens({
    required this.background,
    required this.sidebar,
    required this.editor,
    required this.panel,
    required this.raised,
    required this.overlayScrim,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.accent,
    required this.accentMuted,
    required this.selection,
    required this.hover,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.recording,
    required this.speakers,
    required this.editorSyntax,
  });

  // Layered surfaces, darkest/outermost → most elevated.
  final Color background; // app window / chrome
  final Color sidebar; // explorer
  final Color editor; // center note surface (the focal reading plane)
  final Color panel; // transcript
  final Color raised; // menus, inputs, hover cards
  final Color overlayScrim; // modal backdrop

  // Lines.
  final Color border;
  final Color borderStrong;

  // Text, three-step hierarchy.
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;

  // Identity accent + supporting fills.
  final Color accent;
  final Color accentMuted; // solid soft fill (drop targets, etc.)
  final Color selection; // translucent accent (active file / selection bg)
  final Color hover; // translucent neutral hover
  final Color onAccent; // text/icon on a filled accent surface

  // Status.
  final Color success;
  final Color warning; // paused
  final Color danger; // destructive
  final Color recording; // live listening

  /// Stable per-speaker accents for the transcript timeline.
  final List<Color> speakers;

  /// Accent used for markdown heading/marker syntax in the editor.
  final Color editorSyntax;

  Color speakerFor(String name) =>
      speakers[name.hashCode.abs() % speakers.length];

  @override
  NotelyTokens copyWith({
    Color? background,
    Color? sidebar,
    Color? editor,
    Color? panel,
    Color? raised,
    Color? overlayScrim,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textFaint,
    Color? accent,
    Color? accentMuted,
    Color? selection,
    Color? hover,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? recording,
    List<Color>? speakers,
    Color? editorSyntax,
  }) {
    return NotelyTokens(
      background: background ?? this.background,
      sidebar: sidebar ?? this.sidebar,
      editor: editor ?? this.editor,
      panel: panel ?? this.panel,
      raised: raised ?? this.raised,
      overlayScrim: overlayScrim ?? this.overlayScrim,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textFaint: textFaint ?? this.textFaint,
      accent: accent ?? this.accent,
      accentMuted: accentMuted ?? this.accentMuted,
      selection: selection ?? this.selection,
      hover: hover ?? this.hover,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      recording: recording ?? this.recording,
      speakers: speakers ?? this.speakers,
      editorSyntax: editorSyntax ?? this.editorSyntax,
    );
  }

  @override
  NotelyTokens lerp(ThemeExtension<NotelyTokens>? other, double t) {
    if (other is! NotelyTokens) return this;
    List<Color> lerpList(List<Color> a, List<Color> b) => [
      for (var i = 0; i < a.length; i++)
        Color.lerp(a[i], i < b.length ? b[i] : a[i], t)!,
    ];
    return NotelyTokens(
      background: Color.lerp(background, other.background, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      editor: Color.lerp(editor, other.editor, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      overlayScrim: Color.lerp(overlayScrim, other.overlayScrim, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      recording: Color.lerp(recording, other.recording, t)!,
      speakers: lerpList(speakers, other.speakers),
      editorSyntax: Color.lerp(editorSyntax, other.editorSyntax, t)!,
    );
  }

  // ── Dark (primary/reference) ──────────────────────────────────────────────
  static const dark = NotelyTokens(
    background: Color(0xFF15171B),
    sidebar: Color(0xFF191C21),
    editor: Color(0xFF1E2127),
    panel: Color(0xFF191C21),
    raised: Color(0xFF23272E),
    overlayScrim: Color(0xCC0C0D0F),
    border: Color(0xFF2A2E36),
    borderStrong: Color(0xFF394049),
    textPrimary: Color(0xFFE8EBEF),
    textSecondary: Color(0xFF9AA2AD),
    textFaint: Color(0xFF616873),
    accent: Color(0xFF5E8BEF),
    accentMuted: Color(0xFF2B3A57),
    selection: Color(0x335E8BEF),
    hover: Color(0x0FFFFFFF),
    onAccent: Color(0xFF0E1116),
    success: Color(0xFF6FBF8E),
    warning: Color(0xFFE0A95B),
    danger: Color(0xFFE8645E),
    recording: Color(0xFFEC6A64),
    speakers: [
      Color(0xFF5E8BEF),
      Color(0xFF6FBF8E),
      Color(0xFFE0A95B),
      Color(0xFFC98BE0),
      Color(0xFF56C0C8),
    ],
    editorSyntax: Color(0xFF7FA6F2),
  );

  // ── Light (warm, first-class — not an inversion) ──────────────────────────
  static const light = NotelyTokens(
    background: Color(0xFFF1EFEA),
    sidebar: Color(0xFFEAE7E0),
    editor: Color(0xFFFBFAF7),
    panel: Color(0xFFEAE7E0),
    raised: Color(0xFFFFFFFF),
    overlayScrim: Color(0x552A2822),
    border: Color(0xFFDBD6CD),
    borderStrong: Color(0xFFC3BDB1),
    textPrimary: Color(0xFF272A2E),
    textSecondary: Color(0xFF63615B),
    textFaint: Color(0xFF98958C),
    accent: Color(0xFF3D6FD6),
    accentMuted: Color(0xFFDCE6F8),
    selection: Color(0x223D6FD6),
    hover: Color(0x0A000000),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF4F9A60),
    warning: Color(0xFF9C7326),
    danger: Color(0xFFC4463E),
    recording: Color(0xFFCE4A44),
    speakers: [
      Color(0xFF3D6FD6),
      Color(0xFF4F9A60),
      Color(0xFF9C7326),
      Color(0xFF8E52B0),
      Color(0xFF2C8C98),
    ],
    editorSyntax: Color(0xFF3460BE),
  );
}

/// Ergonomic access to the active palette.
extension NotelyContextTokens on BuildContext {
  NotelyTokens get tokens => Theme.of(this).extension<NotelyTokens>()!;
}

/// Shared geometry.
abstract final class NotelyDims {
  static const double sidebarWidth = 260;
  static const double transcriptWidth = 340;
  static const double transcriptMinWidth = 280;
  static const double titleBarHeight = 40;
  static const double statusBarHeight = 24;
  static const double rowHeight = 26;
  static const double radius = 6; // inputs, buttons, rows
  static const double radiusSmall = 4; // tiny affordances
  static const double radiusLarge = 10; // dialogs / menus
  static const Duration panelAnim = Duration(milliseconds: 240);
}

/// Motion tokens — fast and restrained.
abstract final class NotelyMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 180);
  static const Duration emphasized = Duration(milliseconds: 240);
  static const Curve curve = Curves.easeOutCubic;
}

/// Type scale (color applied by callers from [NotelyTokens]).
abstract final class NotelyType {
  /// Uppercase workspace/section labels (WORK, LIVE TRANSCRIPT).
  static const TextStyle sectionLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
    height: 1.0,
  );
  static const TextStyle dialogTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const TextStyle row = TextStyle(fontSize: 12.5, height: 1.0);
  static const TextStyle body = TextStyle(fontSize: 13, height: 1.45);
  static const TextStyle meta = TextStyle(fontSize: 11, height: 1.0);
  static const TextStyle button = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle statusMono = TextStyle(
    fontSize: 11,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Editor-appropriate monospace stack. Falls back gracefully if a family is missing.
const String kEditorFont = 'SF Mono';
const List<String> kEditorFontFallback = <String>[
  'SFMono-Regular',
  'Menlo',
  'Consolas',
  'monospace',
];

/// Build the app [ThemeData] for a given [brightness], attaching [NotelyTokens].
ThemeData buildNotelyTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final t = isDark ? NotelyTokens.dark : NotelyTokens.light;

  final scheme = ColorScheme.fromSeed(
    seedColor: t.accent,
    brightness: brightness,
  ).copyWith(primary: t.accent, surface: t.editor, onSurface: t.textPrimary);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.background,
    canvasColor: t.background,
    dividerColor: t.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    extensions: [t],
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: t.selection,
      cursorColor: t.accent,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
        border: Border.all(color: t.border),
      ),
      textStyle: TextStyle(color: t.textPrimary, fontSize: 12),
    ),
    textTheme: const TextTheme().apply(
      bodyColor: t.textPrimary,
      displayColor: t.textPrimary,
    ),
  );
}
