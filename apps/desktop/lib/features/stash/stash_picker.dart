// Stash picker — the launch / switch experience.
//
// A two-pane modal inspired by Obsidian's vault picker: the left pane lists previously opened
// stashes (name + path, each with a "…" menu), and the right pane carries Notely's identity
// plus actions to create a new stash or open an existing folder. When a stash is already open
// (switching), the modal can be dismissed with the ✕ button, Esc, or a backdrop tap.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/stash/stash_store.dart';
import 'stash_switcher.dart' show StashAvatar;

class StashPicker extends StatefulWidget {
  const StashPicker({super.key});

  @override
  State<StashPicker> createState() => _StashPickerState();
}

class _StashPickerState extends State<StashPicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: NotelyDims.panelAnim,
  )..forward();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _close() => AppScope.of(context).stash.dismissPicker();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final stash = AppScope.of(context).stash;
    final canClose = stash.canDismissPicker;
    final size = MediaQuery.sizeOf(context);
    final w = size.width < 820 ? size.width - 64 : 760.0;
    final h = size.height < 620 ? size.height - 64 : 540.0;

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
                    // Absorb taps so a click inside the modal doesn't hit the backdrop.
                    child: GestureDetector(
                      onTap: () {},
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: _Modal(canClose: canClose, onClose: _close),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Modal extends StatelessWidget {
  const _Modal({required this.canClose, required this.onClose});
  final bool canClose;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.editor,
        borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
        border: Border.all(color: t.borderStrong),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 36,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Stack(
        children: [
          Row(
            children: [
              SizedBox(width: 288, child: _RecentList(onClose: onClose)),
              Container(width: 1, color: t.border),
              const Expanded(child: _RightPane()),
            ],
          ),
          if (canClose)
            Positioned(top: 10, right: 10, child: _CloseButton(onTap: onClose)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Left pane — recent stashes
// ─────────────────────────────────────────────────────────────────────────────
class _RecentList extends StatelessWidget {
  const _RecentList({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final stash = AppScope.of(context).stash;
    return Container(
      color: t.sidebar,
      child: AnimatedBuilder(
        animation: stash,
        builder: (context, _) {
          final recents = stash.recents;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                child: Text(
                  'YOUR STASHES',
                  style: NotelyType.sectionLabel.copyWith(color: t.textFaint),
                ),
              ),
              Expanded(
                child: recents.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Text(
                          'No stashes yet.\nCreate or open one on the right.',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: t.textFaint,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: recents.length,
                        itemBuilder: (context, i) => _RecentRow(
                          config: recents[i],
                          isCurrent: recents[i].path == stash.path,
                          onClose: onClose,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RecentRow extends StatefulWidget {
  const _RecentRow({
    required this.config,
    required this.isCurrent,
    required this.onClose,
  });
  final StashConfig config;
  final bool isCurrent;
  final VoidCallback onClose;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;

  Future<void> _openMenu(Offset pos) async {
    final t = context.tokens;
    final scope = AppScope.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        pos & Size.zero,
        Offset.zero & overlay.size,
      ),
      color: t.raised,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        side: BorderSide(color: t.borderStrong),
      ),
      items: [
        _menuItem(t, 0, Icons.folder_open_outlined, 'Reveal in Finder'),
        _menuItem(t, 1, Icons.close_rounded, 'Remove from list', danger: true),
      ],
    );
    if (selected == null || !mounted) return;
    if (selected == 0) {
      await scope.explorer.reveal(widget.config.path);
    } else {
      await scope.stash.removeRecent(widget.config.path);
    }
  }

  PopupMenuItem<int> _menuItem(
    NotelyTokens t,
    int value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final color = danger ? t.danger : t.textSecondary;
    return PopupMenuItem<int>(
      value: value,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 10),
          Text(
            label,
            style: NotelyType.row.copyWith(
              color: danger ? t.danger : t.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => AppScope.of(
          context,
        ).stash.open(name: widget.config.name, path: widget.config.path),
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          color: _hover ? t.hover : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: StashAvatar(name: widget.config.name, size: 30),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.config.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: t.textPrimary,
                            ),
                          ),
                        ),
                        if (widget.isCurrent) ...[
                          const SizedBox(width: 7),
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: t.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.config.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: t.textFaint,
                        fontFamily: kEditorFont,
                        fontFamilyFallback: kEditorFontFallback,
                      ),
                    ),
                  ],
                ),
              ),
              // "…" menu, revealed on hover.
              Opacity(
                opacity: _hover ? 1 : 0,
                child: GestureDetector(
                  onTapDown: (d) => _openMenu(d.globalPosition),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.more_horiz, size: 16, color: t.textFaint),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Right pane — identity + create / open actions
// ─────────────────────────────────────────────────────────────────────────────
class _RightPane extends StatefulWidget {
  const _RightPane();

  @override
  State<_RightPane> createState() => _RightPaneState();
}

class _RightPaneState extends State<_RightPane> {
  bool _creating = false;
  final TextEditingController _name = TextEditingController();
  String? _parent;

  @override
  void initState() {
    super.initState();
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null) _parent = p.join(home, 'Documents');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _chooseParent() async {
    final selected = await getDirectoryPath(
      confirmButtonText: 'Choose',
      initialDirectory: _parent,
    );
    if (selected != null) setState(() => _parent = selected);
  }

  Future<void> _create() async {
    final parent = _parent;
    if (parent == null || _name.text.trim().isEmpty) return;
    await AppScope.of(
      context,
    ).stash.createStash(parentPath: parent, name: _name.text.trim());
  }

  Future<void> _openExisting() async {
    final selected = await getDirectoryPath(confirmButtonText: 'Open');
    if (selected == null || !mounted) return;
    await AppScope.of(
      context,
    ).stash.open(name: p.basename(selected), path: selected);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      color: t.editor,
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _identity(t),
          const SizedBox(height: 30),
          _creating ? _createForm(t) : _actions(t),
        ],
      ),
    );
  }

  Widget _identity(NotelyTokens t) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.accent,
            borderRadius: BorderRadius.circular(15),
            boxShadow: [
              BoxShadow(
                color: t.accent.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            'N',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.0,
              color: t.onAccent,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Notely',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: t.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'A local-first notes workspace',
          style: TextStyle(fontSize: 12.5, color: t.textFaint),
        ),
      ],
    );
  }

  Widget _actions(NotelyTokens t) {
    return Container(
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        border: Border.all(color: t.border),
      ),
      child: Column(
        children: [
          _actionRow(
            t,
            title: 'Create new Stash',
            subtitle: 'Create a new Notely stash under a folder.',
            button: 'Create',
            primary: true,
            onTap: () => setState(() => _creating = true),
          ),
          Divider(height: 1, color: t.border),
          _actionRow(
            t,
            title: 'Open folder as Stash',
            subtitle: 'Choose an existing folder of Markdown notes.',
            button: 'Open',
            primary: false,
            onTap: _openExisting,
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    NotelyTokens t, {
    required String title,
    required String subtitle,
    required String button,
    required bool primary,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.textFaint,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          _PillButton(label: button, primary: primary, onTap: onTap),
        ],
      ),
    );
  }

  Widget _createForm(NotelyTokens t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _creating = false),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Icon(
                    Icons.arrow_back,
                    size: 16,
                    color: t.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'New Stash',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: t.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _fieldLabel(t, 'Stash name'),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            autofocus: true,
            onSubmitted: (_) => _create(),
            style: TextStyle(fontSize: 13, color: t.textPrimary),
            cursorColor: t.accent,
            decoration: _inputDecoration(t, 'Research'),
          ),
          const SizedBox(height: 12),
          _fieldLabel(t, 'Location'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: t.editor,
                    borderRadius: BorderRadius.circular(NotelyDims.radius),
                    border: Border.all(color: t.border),
                  ),
                  child: Text(
                    _parent ?? 'Choose a location…',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _parent == null ? t.textFaint : t.textSecondary,
                      fontFamily: kEditorFont,
                      fontFamilyFallback: kEditorFontFallback,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _PillButton(
                label: 'Choose',
                primary: false,
                onTap: _chooseParent,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: _PillButton(
              label: 'Create Stash',
              primary: true,
              onTap: _create,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(NotelyTokens t, String text) => Text(
    text.toUpperCase(),
    style: NotelyType.sectionLabel.copyWith(
      fontSize: 10,
      letterSpacing: 0.8,
      color: t.textFaint,
    ),
  );

  InputDecoration _inputDecoration(NotelyTokens t, String hint) =>
      InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: t.textFaint, fontSize: 13),
        isDense: true,
        filled: true,
        fillColor: t.editor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared little widgets
// ─────────────────────────────────────────────────────────────────────────────
class _PillButton extends StatefulWidget {
  const _PillButton({
    required this.label,
    required this.primary,
    required this.onTap,
  });
  final String label;
  final bool primary;
  final VoidCallback onTap;

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final Color bg = widget.primary
        ? (_hover ? Color.lerp(t.accent, Colors.white, 0.08)! : t.accent)
        : (_hover ? t.raised : t.raised.withValues(alpha: 0.5));
    final Color fg = widget.primary ? t.onAccent : t.textPrimary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(
              color: widget.primary ? Colors.transparent : t.border,
            ),
          ),
          child: Text(
            widget.label,
            style: NotelyType.button.copyWith(color: fg),
          ),
        ),
      ),
    );
  }
}

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
