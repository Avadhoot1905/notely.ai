// "Ask Notely" — question answering over the current stash.
//
// The UI depends only on [AskService]; today a [MockAskService] does real retrieval over the
// stash's Markdown notes (keyword-ranked passages) and returns an answer with the exact files
// it read and clickable citations (file + line range). Tomorrow a Rust/LLM-backed service can
// replace it behind the same interface — the panel, citations, and highlight-on-click stay.

import 'package:path/path.dart' as p;

import '../filesystem/file_system_service.dart';
import '../filesystem/fs_node.dart';

/// A pointer into a note: the passage an answer draws from. Line indices are 0-based.
class Citation {
  const Citation({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.snippet,
  });

  final String path;
  final int startLine;
  final int endLine;
  final String snippet;

  String get fileName => p.basename(path);

  /// Human label like "3–7" (1-based, inclusive) or "3" for a single line.
  String get lineLabel => startLine == endLine
      ? '${startLine + 1}'
      : '${startLine + 1}–${endLine + 1}';

  Map<String, dynamic> toJson() => {
    'path': path,
    'startLine': startLine,
    'endLine': endLine,
    'snippet': snippet,
  };

  static Citation? fromJson(Object? json) {
    if (json is Map && json['path'] is String) {
      return Citation(
        path: json['path'] as String,
        startLine: (json['startLine'] as num?)?.toInt() ?? 0,
        endLine: (json['endLine'] as num?)?.toInt() ?? 0,
        snippet: json['snippet'] as String? ?? '',
      );
    }
    return null;
  }
}

class AskAnswer {
  const AskAnswer({
    required this.text,
    required this.filesRead,
    required this.citations,
  });

  /// Markdown-ish answer body; `[n]` markers reference [citations] (1-based).
  final String text;

  /// Absolute paths of the notes the answer actually drew from.
  final List<String> filesRead;
  final List<Citation> citations;

  Map<String, dynamic> toJson() => {
    'text': text,
    'filesRead': filesRead,
    'citations': [for (final c in citations) c.toJson()],
  };

  static AskAnswer? fromJson(Object? json) {
    if (json is Map && json['text'] is String) {
      return AskAnswer(
        text: json['text'] as String,
        filesRead:
            (json['filesRead'] as List?)?.whereType<String>().toList() ??
            const [],
        citations:
            (json['citations'] as List?)
                ?.map(Citation.fromJson)
                .whereType<Citation>()
                .toList() ??
            const [],
      );
    }
    return null;
  }
}

abstract class AskService {
  Future<AskAnswer> ask({required String query, required String stashRoot});
}

/// Offline retrieval answerer: ranks note passages by keyword overlap with the question.
class MockAskService implements AskService {
  const MockAskService({this.fs = const FileSystemService()});

  final FileSystemService fs;

  static const int _maxFiles = 300;
  static const int _maxCitations = 5;

  static const _stopwords = {
    'the',
    'a',
    'an',
    'is',
    'are',
    'was',
    'were',
    'of',
    'to',
    'in',
    'on',
    'and',
    'or',
    'for',
    'with',
    'about',
    'what',
    'whats',
    'how',
    'why',
    'where',
    'when',
    'who',
    'which',
    'do',
    'does',
    'did',
    'can',
    'could',
    'should',
    'would',
    'i',
    'me',
    'my',
    'you',
    'your',
    'it',
    'this',
    'that',
    'there',
    'here',
    'from',
    'into',
    'as',
    'at',
    'be',
    'by',
    'notely',
    'note',
    'notes',
    'stash',
    'tell',
    'show',
    'give',
    'find',
    'any',
  };

  @override
  Future<AskAnswer> ask({
    required String query,
    required String stashRoot,
  }) async {
    final tokens = _tokenize(query);
    if (tokens.isEmpty) {
      return const AskAnswer(
        text:
            'Ask me something about your notes — for example a topic, a person, '
            'or a decision, and I’ll point you to where it’s written.',
        filesRead: [],
        citations: [],
      );
    }

    final files = <String>[];
    _collectMarkdown(await fs.readTree(stashRoot), files);

    final scored = <_Passage>[];
    for (final path in files.take(_maxFiles)) {
      String content;
      try {
        content = await fs.readFile(path);
      } catch (_) {
        continue;
      }
      scored.addAll(_scoreFile(path, content, tokens));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final top = scored.take(_maxCitations).toList();
    final citations = [
      for (final s in top)
        Citation(
          path: s.path,
          startLine: s.start,
          endLine: s.end,
          snippet: s.snippet,
        ),
    ];
    final filesRead = <String>[];
    for (final c in citations) {
      if (!filesRead.contains(c.path)) filesRead.add(c.path);
    }

    return AskAnswer(
      text: _compose(query.trim(), citations),
      filesRead: filesRead,
      citations: citations,
    );
  }

  void _collectMarkdown(List<FsNode> nodes, List<String> out) {
    for (final n in nodes) {
      if (n.isDirectory) {
        _collectMarkdown(n.children, out);
      } else if (n.isMarkdown) {
        out.add(n.path);
      }
    }
  }

  List<String> _tokenize(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty);
    final kept = words
        .where((w) => w.length >= 3 && !_stopwords.contains(w))
        .toSet()
        .toList();
    if (kept.isNotEmpty) return kept;
    // Fall back to any 2+ char words so very short questions still search.
    return words.where((w) => w.length >= 2).toSet().toList();
  }

  List<_Passage> _scoreFile(String path, String content, List<String> tokens) {
    final lines = content.split('\n');
    final results = <_Passage>[];
    var i = 0;
    while (i < lines.length) {
      if (lines[i].trim().isEmpty) {
        i++;
        continue;
      }
      final start = i;
      final buf = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        buf.add(lines[i]);
        i++;
      }
      final end = i - 1;
      final lower = buf.join(' ').toLowerCase();
      var score = 0;
      for (final tk in tokens) {
        var idx = 0;
        while ((idx = lower.indexOf(tk, idx)) != -1) {
          score++;
          idx += tk.length;
        }
      }
      // Small bump for heading matches (title relevance).
      if (buf.first.trimLeft().startsWith('#')) score = (score * 1.5).round();
      if (score > 0) {
        results.add(_Passage(path, start, end, score, _snippet(buf.join(' '))));
      }
    }
    return results;
  }

  String _snippet(String text) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length > 220
        ? '${collapsed.substring(0, 220).trimRight()}…'
        : collapsed;
  }

  String _compose(String query, List<Citation> cites) {
    if (cites.isEmpty) {
      return "I couldn't find anything about **$query** in this stash.\n\n"
          'Try different keywords, or add a note about it.';
    }
    final b = StringBuffer();
    b.writeln('Here’s what I found in your notes about **$query**:');
    b.writeln();
    for (var i = 0; i < cites.length; i++) {
      b.writeln('- ${_lead(cites[i].snippet)} [${i + 1}]');
    }
    b.writeln();
    b.writeln('Click a citation to open the exact passage.');
    return b.toString().trimRight();
  }

  String _lead(String snippet) {
    final s = snippet.trim();
    final match = RegExp(r'[.!?]').firstMatch(s);
    final cut = (match != null && match.start > 20)
        ? match.start + 1
        : (s.length > 150 ? 150 : s.length);
    var lead = s.substring(0, cut).trim();
    // Strip a leading markdown heading marker for readability.
    lead = lead.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    if (cut < s.length) lead += '…';
    return lead;
  }
}

class _Passage {
  const _Passage(this.path, this.start, this.end, this.score, this.snippet);
  final String path;
  final int start;
  final int end;
  final int score;
  final String snippet;
}
