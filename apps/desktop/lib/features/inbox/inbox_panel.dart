// The Inbox panel: a calm list of captured meetings and where their enrichment stands.
//
// Intentionally not a dashboard — no charts, no counts-of-counts. Each row is a capture with a
// single state chip and, when enrichment was deferred/failed, a one-click Retry. It reads its data
// from [InboxController] (a view over the engine's meetings + processing status).

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../ipc/protocol.dart';
import 'inbox_state.dart';

class InboxPanel extends StatelessWidget {
  const InboxPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final inbox = AppScope.of(context).inbox;
    return Container(
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(left: BorderSide(color: t.border)),
      ),
      child: AnimatedBuilder(
        animation: inbox,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(count: inbox.pendingCount, onClose: inbox.close),
            Expanded(child: _Body(inbox: inbox)),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count, required this.onClose});
  final int count;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.inbox_outlined, size: 16, color: t.textSecondary),
          const SizedBox(width: 8),
          Text(
            'Inbox',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: t.textPrimary,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: t.accentMuted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 11, color: t.onAccent),
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: t.textSecondary),
            splashRadius: 16,
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.inbox});
  final InboxController inbox;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final items = inbox.items;
    if (inbox.isLoading && items.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            inbox.error ??
                'Nothing captured yet.\nRecordings and meetings will appear here, '
                    'safely saved — even if AI is unavailable.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: t.textFaint, height: 1.5),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: items.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: t.border),
      itemBuilder: (context, i) => _InboxTile(summary: items[i]),
    );
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.summary});
  final MeetingSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final status = summary.status;
    final state = status?.state ?? ProcessingState.ready;
    final retryable = status?.isRetryable ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  summary.meeting.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: t.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              _StateChip(state: state),
            ],
          ),
          if (retryable) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _RetryButton(
                onTap: () =>
                    AppScope.of(context).inbox.retry(summary.meeting.id),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});
  final ProcessingState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (label, color) = switch (state) {
      ProcessingState.ready => ('Ready', t.success),
      ProcessingState.processing => ('Processing', t.accent),
      ProcessingState.deferred => ('AI deferred', t.warning),
      ProcessingState.failed => ('Failed', t.danger),
      ProcessingState.unknown => ('Saved', t.textFaint),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: t.raised,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          border: Border.all(color: t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh_rounded, size: 14, color: t.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Retry with AI',
              style: TextStyle(fontSize: 12, color: t.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
