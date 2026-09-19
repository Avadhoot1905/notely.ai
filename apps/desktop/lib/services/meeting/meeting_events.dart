// Meeting event stream — the domain boundary for everything that happens during a live meeting.
//
// One extensible, source-of-truth stream that many independent consumers subscribe to (Live Meeting
// State for the UI, and later a persistence sink). Producers (the mock transcript today, real ASR
// later) only emit these; they never touch widgets or storage directly.

import '../audio/meeting_audio_service.dart' show AudioCapabilities;
import 'transcript_segment.dart';

/// Base type for everything emitted on the meeting event stream. [at] is the position on the meeting
/// timeline when the event occurred.
sealed class MeetingEvent {
  const MeetingEvent(this.at);
  final Duration at;
}

class MeetingStarted extends MeetingEvent {
  const MeetingStarted(super.at);
}

class MeetingPaused extends MeetingEvent {
  const MeetingPaused(super.at);
}

class MeetingResumed extends MeetingEvent {
  const MeetingResumed(super.at);
}

class MeetingStopped extends MeetingEvent {
  const MeetingStopped(super.at);
}

/// An in-progress transcript revision (not yet settled). Emitted when the ASR engine supports it.
class TranscriptPartial extends MeetingEvent {
  const TranscriptPartial(super.at, this.segment);
  final TranscriptSegment segment;
}

/// A settled transcript segment.
class TranscriptFinalized extends MeetingEvent {
  const TranscriptFinalized(super.at, this.segment);
  final TranscriptSegment segment;
}

/// Capture health changed (a source started/stopped/failed). Lets the UI reflect capture state
/// without reaching into the audio service.
class AudioHealthChanged extends MeetingEvent {
  const AudioHealthChanged(super.at, this.health);
  final AudioCapabilities health;
}

// Future events (SpeakerChanged, TopicDetected, DecisionDetected, ActionItemDetected) slot in here
// as additional MeetingEvent subclasses without changing this stream's shape.
