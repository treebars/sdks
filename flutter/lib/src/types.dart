/// The settings `Treebars.init` starts the native SDK with.
///
/// Every field but [writeKey] and [backendUrl] is optional, and an unset one is left out of what
/// crosses to the native SDK rather than filled in here, so the native SDK's own default is the
/// one that applies.
class TreebarsConfig {
  const TreebarsConfig({
    required this.writeKey,
    required this.backendUrl,
    this.env,
    this.debug,
    this.flushIntervalMs,
    this.inAppEnabled,
    this.inAppPollIntervalMs,
    this.autoTrackLifecycle,
    this.autoTrackSessions,
    this.acquisitionConsent,
    this.deferredHandoff,
    this.linkHosts,
  });

  /// The project's write key: `pk_live_…` or `pk_test_…`.
  final String writeKey;

  /// Where events go: an https address. Plain http is accepted only for a local stack.
  final String backendUrl;

  /// `production`, `stage` or `test`. Anything else is refused by `init`, never defaulted.
  final String? env;

  final bool? debug;

  /// How often queued events are sent, when the app wants a pace of its own.
  final int? flushIntervalMs;

  /// `false` turns in-app messages off entirely: nothing is fetched and nothing is drawn.
  final bool? inAppEnabled;

  final int? inAppPollIntervalMs;
  final bool? autoTrackLifecycle;
  final bool? autoTrackSessions;

  /// Whether the install referrer and Apple's ad attribution may be read. Absent is yes.
  final bool? acquisitionConsent;

  /// iOS only: carry a link's destination across the App Store install.
  final bool? deferredHandoff;

  /// The app's own link domains, for links that open the app.
  final List<String>? linkHosts;

  /// The config in the shape the native SDKs read, with unset fields left out.
  Map<String, Object?> toWire() {
    final wire = <String, Object?>{
      'write_key': writeKey,
      'backend_url': backendUrl,
      'env': env,
      'debug': debug,
      'flush_interval_ms': flushIntervalMs,
      'in_app_enabled': inAppEnabled,
      'in_app_poll_interval_ms': inAppPollIntervalMs,
      'auto_track_lifecycle': autoTrackLifecycle,
      'auto_track_sessions': autoTrackSessions,
      'acquisition_consent': acquisitionConsent,
      'deferred_handoff': deferredHandoff,
      'link_hosts': linkHosts,
    };
    wire.removeWhere((_, value) => value == null);
    return wire;
  }
}

/// Which service a push token belongs to.
///
/// An enum rather than a string so a token cannot be filed under a provider that does not exist:
/// such a token is accepted everywhere and fails only when a push is sent, as a device that is
/// never reached.
enum PushProvider {
  fcm('fcm'),
  apns('apns');

  const PushProvider(this.wire);
  final String wire;
}

/// Where a nudge may appear on the current screen.
enum NudgePosition {
  top('top'),
  bottom('bottom'),
  any('any');

  const NudgePosition(this.wire);
  final String wire;
}

/// A failure the native SDK reported, with its code.
///
/// The codes are `bad_config` (the config was refused), `bad_payload` (something could not be
/// read on one side or the other), `not_initialized` (a call that needs `init` came first),
/// `not_linked` (the native SDK is missing from the build) and `unexpected`.
class TreebarsException implements Exception {
  const TreebarsException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'TreebarsException($code): $message';
}

/// One upload attempt, for an app's own debug screen.
class UploadLog {
  const UploadLog({
    required this.type,
    required this.status,
    required this.message,
    this.count,
    this.eventNames,
    this.statusCode,
  });

  factory UploadLog.fromJson(Map<String, Object?> json) => UploadLog(
        type: json['type'] as String? ?? '',
        status: json['status'] as String? ?? '',
        message: json['message'] as String? ?? '',
        count: (json['count'] as num?)?.toInt(),
        eventNames: (json['eventNames'] as List<Object?>?)?.whereType<String>().toList(),
        statusCode: (json['statusCode'] as num?)?.toInt(),
      );

  final String type;
  final String status;
  final String message;
  final int? count;
  final List<String>? eventNames;
  final int? statusCode;
}

/// An action a message or a push handed the app.
class AppAction {
  const AppAction({required this.name, required this.payload, required this.source});

  factory AppAction.fromJson(Map<String, Object?> json) => AppAction(
        name: json['name'] as String? ?? '',
        payload: (json['payload'] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const {},
        source: (json['source'] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const {},
      );

  final String name;
  final Map<String, Object?> payload;

  /// `kind`, `campaign_id` and `message_id`: where the action came from.
  final Map<String, Object?> source;
}

/// One tab of the notification centre, All first, with its counts.
class NotificationTopic {
  const NotificationTopic({required this.key, required this.name, required this.unread, required this.total});

  factory NotificationTopic.fromJson(Map<String, Object?> json) => NotificationTopic(
        key: json['key'] as String?,
        name: json['name'] as String? ?? '',
        unread: (json['unread'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
      );

  /// Null for All.
  final String? key;
  final String name;
  final int unread;
  final int total;
}

/// A page of the notification centre.
///
/// Each notification is kept as the map the native SDK handed over, so a field this version does
/// not name is still there to read.
class NotificationPage {
  const NotificationPage({
    required this.notifications,
    required this.unreadCount,
    required this.nextCursor,
    required this.fromCache,
    this.topics,
  });

  factory NotificationPage.fromJson(Map<String, Object?> json) => NotificationPage(
        notifications: ((json['notifications'] as List<Object?>?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((row) => row.cast<String, Object?>())
            .toList(),
        unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
        nextCursor: json['nextCursor'] as String?,
        fromCache: json['fromCache'] as bool? ?? false,
        topics: (json['topics'] as List<Object?>?)
            ?.whereType<Map<Object?, Object?>>()
            .map((row) => NotificationTopic.fromJson(row.cast<String, Object?>()))
            .toList(),
      );

  final List<Map<String, Object?>> notifications;
  final int unreadCount;
  final String? nextCursor;
  final bool fromCache;
  final List<NotificationTopic>? topics;
}
