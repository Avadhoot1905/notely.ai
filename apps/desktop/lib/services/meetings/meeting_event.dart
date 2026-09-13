// Normalized meeting-detection domain.
//
// Detection is inherently OS- and app-specific (Zoom vs Teams vs a Google Meet browser tab), but
// the rest of Notely must not care where a meeting came from. Native detectors emit these
// normalized events; everything above the detector boundary works in terms of
// [MeetingDetectedEvent] / [MeetingEndedEvent] and a stable [MeetingDetectedEvent.meetingKey].

import 'package:flutter/foundation.dart';

/// A conferencing source Notely can recognize. [generic] covers a detected call whose app we
/// can't classify (e.g. an unknown VoIP client that has the microphone open).
enum MeetingProvider {
  teams,
  zoom,
  googleMeet,
  whatsapp,
  discord,
  generic;

  /// Human-readable label for notifications / the companion.
  String get displayName => switch (this) {
    MeetingProvider.teams => 'Microsoft Teams',
    MeetingProvider.zoom => 'Zoom',
    MeetingProvider.googleMeet => 'Google Meet',
    MeetingProvider.whatsapp => 'WhatsApp',
    MeetingProvider.discord => 'Discord',
    MeetingProvider.generic => 'Meeting',
  };

  /// Parse a provider id sent from native code; unknown ids fall back to [generic].
  static MeetingProvider fromId(String? id) => switch (id) {
    'teams' => MeetingProvider.teams,
    'zoom' => MeetingProvider.zoom,
    'googleMeet' || 'google_meet' || 'meet' => MeetingProvider.googleMeet,
    'whatsapp' => MeetingProvider.whatsapp,
    'discord' => MeetingProvider.discord,
    _ => MeetingProvider.generic,
  };

  /// Stable id used in settings and across the native boundary.
  String get id => switch (this) {
    MeetingProvider.teams => 'teams',
    MeetingProvider.zoom => 'zoom',
    MeetingProvider.googleMeet => 'googleMeet',
    MeetingProvider.whatsapp => 'whatsapp',
    MeetingProvider.discord => 'discord',
    MeetingProvider.generic => 'generic',
  };
}

/// A meeting/call the user appears to have joined or started.
@immutable
class MeetingDetectedEvent {
  const MeetingDetectedEvent({
    required this.provider,
    required this.startedAt,
    this.title,
    this.participantHint,
    this.sourceApplication,
    this.meetingId,
  });

  final MeetingProvider provider;
  final DateTime startedAt;

  /// Best-effort meeting title (e.g. a window/tab title) when the source exposes one.
  final String? title;

  /// Best-effort hint about who's on the call, when available.
  final String? participantHint;

  /// The OS application the meeting was observed in (bundle id / process name).
  final String? sourceApplication;

  /// A provider-native meeting id, when the source exposes one.
  final String? meetingId;

  /// Stable identity for deduplication. Prefers `provider + meetingId`; when no meeting id is
  /// available, falls back to `provider + sourceApplication + coarse start bucket` so the same
  /// ongoing call doesn't produce a new key every time it's re-observed.
  String get meetingKey {
    if (meetingId != null && meetingId!.isNotEmpty) {
      return '${provider.id}:$meetingId';
    }
    final app = sourceApplication ?? provider.id;
    // Bucket the start time to ~10 minutes so re-detections of one call collapse together.
    final bucket = startedAt.millisecondsSinceEpoch ~/ (10 * 60 * 1000);
    return '${provider.id}:$app:$bucket';
  }

  MeetingEndedEvent toEnded({DateTime? endedAt}) =>
      MeetingEndedEvent(meetingKey: meetingKey, endedAt: endedAt);

  /// Build from a native platform-channel map.
  factory MeetingDetectedEvent.fromMap(Map<dynamic, dynamic> map) {
    final startedMs = map['startedAtMs'];
    return MeetingDetectedEvent(
      provider: MeetingProvider.fromId(map['provider'] as String?),
      startedAt: startedMs is int
          ? DateTime.fromMillisecondsSinceEpoch(startedMs)
          : DateTime.now(),
      title: map['title'] as String?,
      participantHint: map['participantHint'] as String?,
      sourceApplication: map['sourceApplication'] as String?,
      meetingId: map['meetingId'] as String?,
    );
  }

  @override
  String toString() =>
      'MeetingDetectedEvent(${provider.id}, key=$meetingKey, title=$title)';
}

/// A previously-detected meeting has ended.
@immutable
class MeetingEndedEvent {
  const MeetingEndedEvent({required this.meetingKey, this.endedAt});

  /// Matches [MeetingDetectedEvent.meetingKey]. Null/empty means "whatever is active ended".
  final String meetingKey;
  final DateTime? endedAt;

  factory MeetingEndedEvent.fromMap(Map<dynamic, dynamic> map) {
    final endedMs = map['endedAtMs'];
    return MeetingEndedEvent(
      meetingKey: (map['meetingKey'] as String?) ?? '',
      endedAt: endedMs is int
          ? DateTime.fromMillisecondsSinceEpoch(endedMs)
          : null,
    );
  }
}
