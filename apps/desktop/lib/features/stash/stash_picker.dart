// Stash picker modal — the launch experience.
//
// Inspired by Obsidian's "Open Vault": a centered dialog over a subdued workspace. "Choose
// Folder" opens the real native/system folder picker; "Open Stash" points the workspace at the
// chosen directory and persists it. A small accent mark gives Notely identity without turning
// this into a landing page.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_scope.dart';
import '../../app/theme.dart';

class StashPicker extends StatefulWidget {
  const StashPicker({super.key});

  @override
  State<StashPicker> createState() => _StashPickerState();
}

class _StashPickerState extends State<StashPicker>
    with SingleTickerProviderStateMixin {
  final TextEditingController _name = TextEditingController();
  String? _path;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: NotelyDims.panelAnim,
  )..forward();

  @override
  void initState() {
    super.initState();
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null) {
      _path = p.join(home, 'Documents');
      _name.text = 'Notely';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder() async {
    final selected = await getDirectoryPath(
      confirmButtonText: 'Choose',
      initialDirectory: _path,
    );
    if (selected == null) return; // cancelled
    setState(() {
      _path = selected;
      final leaf = p.basename(selected);
      if (leaf.isNotEmpty) _name.text = leaf;
    });
  }

  Future<void> _open() async {
    final path = _path;
    if (path == null) {
      await _chooseFolder();
      return;
    }
    final name = _name.text.trim().isEmpty
        ? p.basename(path)
        : _name.text.trim();
    await AppScope.of(context).stash.open(name: name, path: path);
  }

  void _close() => AppScope.of(context).stash.dismissPicker();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final canClose = AppScope.of(context).stash.canDismissPicker;
    return FadeTransition(
      opacity: _anim,
      child: CallbackShortcuts(
        bindings: {
          if (canClose)
            const SingleActivator(LogicalKeyboardKey.escape): _close,
        },
        child: Focus(
          autofocus: true,
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                // Tap the dimmed backdrop to cancel (only when there's a stash to return to).
                Positioned.fill(
                  child: GestureDetector(
                    onTap: canClose ? _close : null,
                    child: Container(color: t.overlayScrim),
                  ),
                ),
                Center(
                  child: ScaleTransition(
                    scale: Tween(begin: 0.985, end: 1.0).animate(
                      CurvedAnimation(parent: _anim, curve: NotelyMotion.curve),
                    ),
                    child: _card(t, canClose),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(NotelyTokens t, bool canClose) {
    return Container(
      width: 440,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: t.editor,
        borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
        border: Border.all(color: t.borderStrong),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Small identity mark.
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'Open a Stash',
                style: NotelyType.dialogTitle.copyWith(
                  fontSize: 19,
                  color: t.textPrimary,
                ),
              ),
              const Spacer(),
              if (canClose) _CloseButton(onTap: _close),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Choose where you want to store your notes and meeting data.',
            style: TextStyle(fontSize: 13, color: t.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 22),
          _label(t, 'Location'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: t.background,
              borderRadius: BorderRadius.circular(NotelyDims.radius),
              border: Border.all(color: t.border),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 16, color: t.textFaint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _path ?? 'No folder chosen yet',
                    style: TextStyle(
                      fontFamily: kEditorFont,
                      fontFamilyFallback: kEditorFontFallback,
                      fontSize: 12.5,
                      color: _path == null ? t.textFaint : t.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _secondaryButton(
              t,
              'Choose Folder',
              Icons.drive_folder_upload_outlined,
              _chooseFolder,
            ),
          ),
          const SizedBox(height: 20),
          _label(t, 'Stash name'),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            onSubmitted: (_) => _open(),
            style: TextStyle(fontSize: 13.5, color: t.textPrimary),
            cursorColor: t.accent,
            decoration: _inputDecoration(t, 'Work'),
          ),
          const SizedBox(height: 26),
          Align(
            alignment: Alignment.centerRight,
            child: _primaryButton(t, 'Open Stash', _open),
          ),
        ],
      ),
    );
  }

  Widget _label(NotelyTokens t, String text) => Text(
    text.toUpperCase(),
    style: NotelyType.sectionLabel.copyWith(
      fontSize: 10.5,
      letterSpacing: 0.9,
      color: t.textFaint,
    ),
  );

  InputDecoration _inputDecoration(NotelyTokens t, String hint) =>
      InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: t.textFaint, fontSize: 13.5),
        isDense: true,
        filled: true,
        fillColor: t.background,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
      );

  Widget _secondaryButton(
    NotelyTokens t,
    String label,
    IconData icon,
    VoidCallback onTap,
  ) {
    return _HoverButton(
      onTap: onTap,
      builder: (hover) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: hover ? t.raised : t.raised.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          border: Border.all(color: hover ? t.borderStrong : t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: t.textSecondary),
            const SizedBox(width: 8),
            Text(
              label,
              style: NotelyType.button.copyWith(color: t.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _primaryButton(NotelyTokens t, String label, VoidCallback onTap) {
    return _HoverButton(
      onTap: onTap,
      builder: (hover) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: hover ? Color.lerp(t.accent, Colors.white, 0.08)! : t.accent,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          boxShadow: hover
              ? [
                  BoxShadow(
                    color: t.accent.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: NotelyType.button.copyWith(fontSize: 13, color: t.onAccent),
        ),
      ),
    );
  }
}

/// Compact close (X) affordance in the modal corner.
class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: 'Close  (Esc)',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NotelyMotion.fast,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: _hover ? t.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 17,
              color: _hover ? t.textSecondary : t.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small hover wrapper so the picker buttons animate consistently.
class _HoverButton extends StatefulWidget {
  const _HoverButton({required this.onTap, required this.builder});
  final VoidCallback onTap;
  final Widget Function(bool hover) builder;

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: widget.builder(_hover),
      ),
    );
  }
}
