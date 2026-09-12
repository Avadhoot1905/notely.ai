// Bottom-of-sidebar Stash switcher.
//
// Shows the current stash as a button — a small initials avatar, the stash name, and an
// unfold indicator — that opens a menu to switch to a recent stash or open another one. Sits
// above the status bar, mirroring the workspace/account switchers in VS Code / editors.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/stash/stash_store.dart';

/// Initials avatar for a stash (e.g. "Qnulabs" → "QN").
class StashAvatar extends StatelessWidget {
  const StashAvatar({super.key, required this.name, this.size = 26});
  final String name;
  final double size;

  static String initialsFor(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'[\s_\-/]+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    final first = parts[0];
    return (first.length >= 2 ? first.substring(0, 2) : first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.accentMuted,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: t.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        initialsFor(name),
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: t.accent,
        ),
      ),
    );
  }
}

class StashSwitcher extends StatefulWidget {
  const StashSwitcher({super.key});

  @override
  State<StashSwitcher> createState() => _StashSwitcherState();
}

class _StashSwitcherState extends State<StashSwitcher> {
  bool _hover = false;

  Future<void> _openMenu() async {
    final scope = AppScope.of(context);
    final stash = scope.stash;
    final t = context.tokens;

    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero) & box.size,
      Offset.zero & overlay.size,
    );

    // -1 = open another, -2 = reveal current; >=0 = recents index.
    final others = stash.recents
        .where((c) => c.path != stash.path)
        .toList(growable: false);

    final selected = await showMenu<int>(
      context: context,
      position: rect,
      color: t.raised,
      elevation: 10,
      constraints: const BoxConstraints(minWidth: 232),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NotelyDims.radius),
        side: BorderSide(color: t.borderStrong),
      ),
      items: [
        for (var i = 0; i < others.length; i++) _recentItem(t, i, others[i]),
        if (others.isNotEmpty) PopupMenuDivider(height: 9, color: t.border),
        _actionItem(t, -1, Icons.swap_horiz, 'Open another Stash…'),
        if (stash.path != null)
          _actionItem(t, -2, Icons.folder_open_outlined, 'Reveal in Finder'),
      ],
    );
    if (selected == null || !mounted) return;

    if (selected == -1) {
      stash.requestPicker();
    } else if (selected == -2) {
      if (stash.path != null) await scope.explorer.reveal(stash.path!);
    } else {
      final c = others[selected];
      await stash.open(name: c.name, path: c.path);
    }
  }

  PopupMenuItem<int> _recentItem(NotelyTokens t, int index, StashConfig c) {
    return PopupMenuItem<int>(
      value: index,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          StashAvatar(name: c.name, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  overflow: TextOverflow.ellipsis,
                  style: NotelyType.row.copyWith(color: t.textPrimary),
                ),
                Text(
                  _shortenPath(c.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: t.textFaint,
                    fontFamily: kEditorFont,
                    fontFamilyFallback: kEditorFontFallback,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<int> _actionItem(
    NotelyTokens t,
    int value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<int>(
      value: value,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: t.textSecondary),
          const SizedBox(width: 10),
          Text(label, style: NotelyType.row.copyWith(color: t.textPrimary)),
        ],
      ),
    );
  }

  String _shortenPath(String path) {
    final home = Uri.file(path).pathSegments;
    if (home.length > 3) {
      return '…/${home.sublist(home.length - 2).join('/')}';
    }
    return path;
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final t = context.tokens;
    return AnimatedBuilder(
      animation: scope.stash,
      builder: (context, _) {
        final name = scope.stash.name ?? 'Stash';
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _openMenu,
              child: AnimatedContainer(
                duration: NotelyMotion.fast,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: _hover ? t.hover : Colors.transparent,
                  borderRadius: BorderRadius.circular(NotelyDims.radius),
                  border: Border.all(
                    color: _hover ? t.border : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    StashAvatar(name: name),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: t.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.unfold_more, size: 16, color: t.textFaint),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
