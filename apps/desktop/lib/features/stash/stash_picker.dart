// Stash picker modal — the launch experience.
//
// Inspired by Obsidian's "Open Vault": a centered dialog over a subdued workspace. "Choose
// Folder" is mocked (it cycles through a few plausible paths rather than invoking a native
// picker); "Open Stash" transitions into the workspace.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';

class StashPicker extends StatefulWidget {
  const StashPicker({super.key});

  @override
  State<StashPicker> createState() => _StashPickerState();
}

class _StashPickerState extends State<StashPicker>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _name = TextEditingController(
    text: StashControllerDefaults.name,
  );
  String _path = StashControllerDefaults.path;
  int _pathIdx = 0;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: NotelyDims.panelAnim,
  )..forward();

  // Mocked folder choices cycled by "Choose Folder".
  static const _mockPaths = [
    '~/Documents/Notely/Work',
    '~/Documents/Notely/Personal',
    '~/Dev/notes/research',
    '~/Vaults/team',
  ];

  @override
  void dispose() {
    _name.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _chooseFolder() {
    setState(() {
      _pathIdx = (_pathIdx + 1) % _mockPaths.length;
      _path = _mockPaths[_pathIdx];
      final leaf = _path.split('/').last;
      if (leaf.isNotEmpty) _name.text = leaf;
    });
  }

  void _open() {
    final name = _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim();
    AppScope.of(context).stash.open(name: name, path: _path);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          color: NotelyColors.overlayScrim,
          alignment: Alignment.center,
          child: ScaleTransition(
            scale: Tween(begin: 0.98, end: 1.0).animate(
              CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
            ),
            child: _card(context),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    return Container(
      width: 440,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: NotelyColors.editor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: NotelyColors.borderStrong),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Open a Stash',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: NotelyColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Choose where you want to store your notes and meeting data.',
            style: TextStyle(
              fontSize: 13,
              color: NotelyColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 22),
          _label('Location'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: NotelyColors.window,
              borderRadius: BorderRadius.circular(NotelyDims.radius),
              border: Border.all(color: NotelyColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: NotelyColors.textFaint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _path,
                    style: const TextStyle(
                      fontFamily: kEditorFont,
                      fontFamilyFallback: kEditorFontFallback,
                      fontSize: 12.5,
                      color: NotelyColors.textSecondary,
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
              'Choose Folder',
              Icons.drive_folder_upload_outlined,
              _chooseFolder,
            ),
          ),
          const SizedBox(height: 20),
          _label('Stash name'),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            onSubmitted: (_) => _open(),
            style: const TextStyle(
              fontSize: 13.5,
              color: NotelyColors.textPrimary,
            ),
            cursorColor: NotelyColors.accent,
            decoration: _inputDecoration('Work'),
          ),
          const SizedBox(height: 26),
          Align(
            alignment: Alignment.centerRight,
            child: _primaryButton('Open Stash', _open),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 10.5,
      letterSpacing: 0.8,
      fontWeight: FontWeight.w600,
      color: NotelyColors.textFaint,
    ),
  );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: NotelyColors.textFaint, fontSize: 13.5),
    isDense: true,
    filled: true,
    fillColor: NotelyColors.window,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      borderSide: const BorderSide(color: NotelyColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      borderSide: const BorderSide(color: NotelyColors.accent),
    ),
  );

  Widget _secondaryButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: NotelyColors.raised,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          border: Border.all(color: NotelyColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: NotelyColors.textSecondary),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                color: NotelyColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: NotelyColors.accent,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0E1114),
          ),
        ),
      ),
    );
  }
}

/// Re-exported defaults so the picker doesn't import the controller's private constants path.
abstract final class StashControllerDefaults {
  static const path = '~/Documents/Notely/Work';
  static const name = 'Work';
}
