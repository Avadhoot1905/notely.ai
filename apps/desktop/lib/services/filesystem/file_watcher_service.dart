// Filesystem watching abstraction.
//
// The Stash filesystem is the source of truth, so the explorer must react when files change
// *outside* Notely (a note edited in another editor, a folder dropped in via the OS file
// manager, a Git checkout, …). Callers depend only on [FileWatcherService] and receive a single
// debounced "something changed under this root" signal — they never see raw, platform-specific
// [FileSystemEvent]s or care whether the OS mechanism is FSEvents (macOS), ReadDirectoryChangesW
// (Windows) or inotify (Linux). The default implementation uses dart:io's [Directory.watch],
// which maps onto exactly those native APIs.
//
// Tests (and any headless context) use [NoopFileWatcherService] so no OS watch is opened.

import 'dart:async';
import 'dart:io';

/// A live watch that can be stopped. Idempotent: [cancel] may be called more than once.
abstract class FileWatchHandle {
  void cancel();
}

/// Watches a directory tree and reports (debounced) that it changed.
abstract class FileWatcherService {
  const FileWatcherService();

  /// Start watching [rootPath] recursively where the platform supports it. [onChange] fires once
  /// per burst of activity, after [debounce] of quiet — collapsing the editor-save /
  /// atomic-replace / rename event storms that every OS emits into a single refresh.
  FileWatchHandle watch(
    String rootPath,
    void Function() onChange, {
    Duration debounce,
  });
}

/// Default watcher backed by dart:io [Directory.watch].
///
/// Recursive watching works on macOS and Windows. On Linux (inotify) recursive support is not
/// guaranteed across kernels/backends, so we fall back to a top-level watch if the recursive one
/// is rejected — top-level structural changes are still caught; deep external edits may require a
/// manual refresh. This limitation is documented in docs/cross-platform.md.
class IoFileWatcherService extends FileWatcherService {
  const IoFileWatcherService();

  @override
  FileWatchHandle watch(
    String rootPath,
    void Function() onChange, {
    Duration debounce = const Duration(milliseconds: 350),
  }) => _IoFileWatchHandle(rootPath, onChange, debounce);
}

class _IoFileWatchHandle implements FileWatchHandle {
  _IoFileWatchHandle(this._rootPath, this._onChange, this._debounce) {
    _start();
  }

  final String _rootPath;
  final void Function() _onChange;
  final Duration _debounce;

  StreamSubscription<FileSystemEvent>? _sub;
  Timer? _timer;

  void _start() {
    final dir = Directory(_rootPath);
    // Prefer a recursive watch; fall back to non-recursive where the platform rejects it.
    for (final recursive in const [true, false]) {
      try {
        _sub = dir
            .watch(recursive: recursive)
            .listen(_onEvent, onError: (_) {}, cancelOnError: false);
        return;
      } catch (_) {
        // Try the next option; if both fail, watching is simply unavailable (swallowed).
      }
    }
  }

  void _onEvent(FileSystemEvent _) {
    _timer?.cancel();
    _timer = Timer(_debounce, _onChange);
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
  }
}

/// A watcher that never opens an OS watch — the default for controllers so unit tests and
/// headless runs don't touch the filesystem watch APIs. The real app injects
/// [IoFileWatcherService].
class NoopFileWatcherService extends FileWatcherService {
  const NoopFileWatcherService();

  @override
  FileWatchHandle watch(
    String rootPath,
    void Function() onChange, {
    Duration debounce = const Duration(milliseconds: 350),
  }) => const _NoopHandle();
}

class _NoopHandle implements FileWatchHandle {
  const _NoopHandle();
  @override
  void cancel() {}
}
