// Streaming PCM16 → WAV file writer.
//
// Phase-1 ASR feeds the engine a *file* (`ProcessMeeting { Audio { path } }`), and the engine's
// FFmpeg step accepts any decodable container and normalizes to mono 16 kHz — so we just need to
// persist the captured PCM as a valid WAV. This writer appends frames as they arrive (a faithful
// continuous recording, NOT VAD segments concatenated) and patches the RIFF/data sizes on [finish].
//
// It is deliberately source-agnostic: the caller decides which [AudioSource] to record (Phase 1
// records the microphone). The file lives at an absolute path so the engine and the separate
// Qwen3-ASR runtime — which reads the file itself — can both reach it on the local machine.
//
// [add] never blocks the caller: writes are chained onto an internal queue so they stay ordered
// (concurrent RandomAccessFile writes would race) while capture keeps flowing.

import 'dart:io';
import 'dart:typed_data';

import 'audio_frame.dart' show AudioSource;

/// Appends 16-bit little-endian PCM to a WAV file and finalizes its header. One recorder per file.
class WavRecorder {
  WavRecorder._(this._raf, this.path, this.sampleRate, this.channels);

  final RandomAccessFile _raf;
  final String path;
  final int sampleRate;
  final int channels;

  int _dataBytes = 0;
  bool _closed = false;
  Future<void> _tail =
      Future<void>.value(); // serializes writes; keeps [add] non-blocking

  static const int _headerBytes = 44;
  static const int _bitsPerSample = 16;

  /// Open [path] for writing and emit a placeholder header (patched by [finish]). [sampleRate] and
  /// [channels] describe the incoming PCM (the engine re-samples/down-mixes downstream).
  static Future<WavRecorder> create({
    required String path,
    required int sampleRate,
    required int channels,
  }) async {
    final file = File(path);
    await file.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    final rec = WavRecorder._(raf, path, sampleRate, channels);
    await raf.writeFrom(rec._header(0));
    return rec;
  }

  /// Open a fresh recording under a temp directory, named for [source] and unique per session.
  static Future<WavRecorder> createTemp({
    required AudioSource source,
    required int sampleRate,
    required int channels,
    int? nonce,
  }) {
    final id = nonce ?? DateTime.now().millisecondsSinceEpoch;
    final dir = Directory('${Directory.systemTemp.path}/notely_captures');
    final path = '${dir.path}/session-$id-${source.name}.wav';
    return create(path: path, sampleRate: sampleRate, channels: channels);
  }

  /// Write a complete WAV file in one shot from [pcm] and return its path. For live per-segment ASR,
  /// where the whole segment's audio is already in hand. [nonce] disambiguates rapid segments.
  static Future<String> writeTemp({
    required AudioSource source,
    required int sampleRate,
    required int channels,
    required Uint8List pcm,
    int? nonce,
  }) async {
    final rec = await createTemp(
      source: source,
      sampleRate: sampleRate,
      channels: channels,
      nonce: nonce,
    );
    rec.add(pcm);
    return rec.finish();
  }

  /// Append one chunk of PCM16 bytes. Returns immediately; the write is queued in order. No-op after
  /// [finish]/[discard]. Pass a fresh/owned copy if [pcm] is a view that may be reused by the caller.
  void add(Uint8List pcm) {
    if (_closed || pcm.isEmpty) return;
    // Copy off any shared/aliased capture buffer before the async write reads it.
    final owned = Uint8List.fromList(pcm);
    _dataBytes += owned.lengthInBytes;
    _tail = _tail.then((_) => _raf.writeFrom(owned));
  }

  /// Patch the header with the real sizes, close the file, and return its path.
  Future<String> finish() async {
    if (_closed) return path;
    _closed = true;
    await _tail; // drain queued writes
    await _raf.setPosition(0);
    await _raf.writeFrom(_header(_dataBytes));
    await _raf.flush();
    await _raf.close();
    return path;
  }

  /// Abandon the recording and delete the file (best-effort). Safe to call once.
  Future<void> discard() async {
    if (_closed) return;
    _closed = true;
    try {
      await _tail;
    } catch (_) {
      // ignore queued write errors on discard
    }
    await _raf.close();
    try {
      await File(path).delete();
    } on FileSystemException {
      // Best-effort cleanup; nothing depends on the temp file being gone.
    }
  }

  /// Total PCM bytes queued so far (excludes the header). Diagnostic.
  int get dataBytes => _dataBytes;

  /// Best-effort delete of a temp recording (e.g. a consumed live chunk). Never throws.
  static Future<void> deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Best-effort; leftover temp files are harmless.
    }
  }

  Uint8List _header(int dataBytes) {
    final bytesPerSample = _bitsPerSample ~/ 8;
    final byteRate = sampleRate * channels * bytesPerSample;
    final blockAlign = channels * bytesPerSample;
    final bytes = Uint8List(_headerBytes);
    final bd = ByteData.view(bytes.buffer);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    bd.setUint32(4, 36 + dataBytes, Endian.little); // RIFF chunk size
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // fmt subchunk size (PCM)
    bd.setUint16(20, 1, Endian.little); // audio format = PCM
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, _bitsPerSample, Endian.little);
    ascii(36, 'data');
    bd.setUint32(40, dataBytes, Endian.little);
    return bytes;
  }
}
