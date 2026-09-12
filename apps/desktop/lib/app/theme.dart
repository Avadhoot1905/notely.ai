// Deliberate dark desktop theme for Notely.
//
// The palette is centralized here so it can be retuned in one place. Values are chosen for a
// calm, information-dense editor feel (VS Code + Obsidian + Granola), not a web dashboard.
// Nothing here is pure black; borders and secondary text are muted, primary text is bright,
// and the accent is restrained.

import 'package:flutter/material.dart';

/// Centralized color + spacing tokens for the app. Change these to reskin Notely.
abstract final class NotelyColors {
  // Surfaces, from darkest (window) to lightest (raised panels).
  static const Color window = Color(0xFF17191C); // title bar / outermost
  static const Color sidebar = Color(0xFF1B1E22); // left explorer
  static const Color editor = Color(0xFF202329); // center note surface
  static const Color panel = Color(0xFF1B1E22); // right transcript
  static const Color raised = Color(0xFF262A31); // cards, inputs, hovers
  static const Color overlayScrim = Color(0xCC0E0F11); // modal backdrop

  // Lines.
  static const Color border = Color(0xFF2C3138);
  static const Color borderStrong = Color(0xFF3A4048);

  // Text.
  static const Color textPrimary = Color(0xFFE6E9ED);
  static const Color textSecondary = Color(0xFF9AA3AD);
  static const Color textFaint = Color(0xFF646C76);

  // Accent — a restrained desk-blue.
  static const Color accent = Color(0xFF5B9BD5);
  static const Color accentMuted = Color(0xFF2E4456);

  // Status.
  static const Color recording = Color(0xFFE05C5C);
  static const Color selection = Color(0x332E4456);
  static const Color hover = Color(0x14FFFFFF);
}

/// Shared spacing/sizing constants.
abstract final class NotelyDims {
  static const double sidebarWidth = 260;
  static const double transcriptWidth = 340;
  static const double transcriptMinWidth = 280;
  static const double titleBarHeight = 40;
  static const double statusBarHeight = 24;
  static const double rowHeight = 26;
  static const double radius = 6;
  static const Duration panelAnim = Duration(milliseconds: 240);
}

/// Editor-appropriate monospace stack. Falls back gracefully if a family is missing.
const String kEditorFont = 'SF Mono';
const List<String> kEditorFontFallback = <String>[
  'SFMono-Regular',
  'Menlo',
  'Consolas',
  'monospace',
];

ThemeData buildNotelyTheme() {
  const base = ColorScheme.dark(
    primary: NotelyColors.accent,
    surface: NotelyColors.editor,
    onSurface: NotelyColors.textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: base,
    scaffoldBackgroundColor: NotelyColors.window,
    canvasColor: NotelyColors.window,
    dividerColor: NotelyColors.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textSelectionTheme: const TextSelectionThemeData(
      selectionColor: NotelyColors.accentMuted,
      cursorColor: NotelyColors.accent,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: NotelyColors.raised,
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      textStyle: TextStyle(color: NotelyColors.textPrimary, fontSize: 12),
    ),
    textTheme: const TextTheme().apply(
      bodyColor: NotelyColors.textPrimary,
      displayColor: NotelyColors.textPrimary,
    ),
  );
}
