// Tests for Ask Notely chat history: multiple conversations, persistence, new/open/delete.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/ask/ask_state.dart';
import 'package:notely_desktop/services/ask/ask_service.dart';
import 'package:notely_desktop/services/ask/ask_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Returns a fixed answer without touching disk, so tests focus on conversation state.
class _FixedAsk implements AskService {
  @override
  Future<AskAnswer> ask({
    required String query,
    required String stashRoot,
  }) async {
    return const AskAnswer(text: 'ok', filesRead: [], citations: []);
  }
}

void main() {
  const root = '/tmp/stashA';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('sending starts a conversation, titled from the question', () async {
    final c = AskController(service: _FixedAsk(), store: AskStore());
    c.setStash(root);
    expect(c.messages, isEmpty);

    await c.send('What did we decide about the release?', stashRoot: root);
    expect(c.messages.length, 2); // user + assistant
    expect(c.history.length, 1);
    expect(c.history.first.title, contains('release'));
  });

  test(
    'conversations persist and restore across controller instances',
    () async {
      final store = AskStore();
      final c1 = AskController(service: _FixedAsk(), store: store);
      c1.setStash(root);
      await c1.send('first question', stashRoot: root);

      // A fresh controller restores the stash's history + most-recent chat.
      final c2 = AskController(service: _FixedAsk(), store: store);
      await c2.restore();
      c2.setStash(root);
      expect(c2.history.length, 1);
      expect(c2.messages.length, 2); // active = most recent conversation
    },
  );

  test(
    'new chat starts an empty thread; each send is its own conversation',
    () async {
      final c = AskController(service: _FixedAsk(), store: AskStore());
      c.setStash(root);
      await c.send('question one', stashRoot: root);

      c.newChat();
      expect(c.messages, isEmpty);
      await c.send('question two', stashRoot: root);

      expect(c.history.length, 2);
      // Most-recent first.
      expect(c.history.first.title, contains('two'));
    },
  );

  test('history is scoped per stash', () async {
    final c = AskController(service: _FixedAsk(), store: AskStore());
    c.setStash(root);
    await c.send('about A', stashRoot: root);

    c.setStash('/tmp/stashB');
    expect(c.history, isEmpty); // different stash, no chats yet
    await c.send('about B', stashRoot: '/tmp/stashB');
    expect(c.history.length, 1);

    c.setStash(root);
    expect(c.history.length, 1);
    expect(c.history.first.title, contains('A'));
  });

  test('deleting a chat removes it and clears active if needed', () async {
    final c = AskController(service: _FixedAsk(), store: AskStore());
    c.setStash(root);
    await c.send('to be deleted', stashRoot: root);
    final id = c.history.first.id;

    await c.deleteChat(id);
    expect(c.history, isEmpty);
    expect(c.messages, isEmpty);
  });

  test('openChat switches the active conversation', () async {
    final c = AskController(service: _FixedAsk(), store: AskStore());
    c.setStash(root);
    await c.send('chat one', stashRoot: root);
    final first = c.history.first.id;
    c.newChat();
    await c.send('chat two', stashRoot: root);

    c.openChat(first);
    expect(c.messages.first.text, 'chat one');
  });
}
