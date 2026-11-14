import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'generated/constants.dart';
import 'types.dart';

/// The Treebars SDK for Flutter: a bridge, and nothing else.
///
/// Everything below this class is a native Treebars SDK — Kotlin on Android, Swift on iOS. The
/// queue, the retries, sessions, storage, device details and in-app messages all live there, and
/// none of it is written again in Dart: two copies of a policy drift, and nothing reports it when
/// they do. What this class does is carry a call down and its answer back.
///
/// **Structured values cross as JSON text.** Properties, attributes, payloads and pages are
/// encoded once here and decoded once on the native side, so both platforms read exactly the same
/// shape, and a native SDK older or newer than this package ignores a key it does not know rather
/// than failing.
///
/// **Nothing here swallows.** A failure on the native side arrives as a [TreebarsException] with
/// its code; this class never answers an empty list or a default in place of an error.
///
/// **What a completed write means.** `track`, `registerPushToken` and the other writes complete
/// once the native SDK has accepted the call, not once anything has been sent.
///
/// **Remote config reads are Futures here.** Flutter has no synchronous call into the platform, so
/// where the React Native SDK answers a config read at once, this one answers on the next turn of
/// the event loop. The value comes from the native SDK's memory either way; nothing is cached in
/// Dart.
class TreebarsSdk {
  TreebarsSdk({
    MethodChannel? methods,
    EventChannel? events,
  })  : _methods = methods ?? const MethodChannel(methodChannelName),
        _events = events ?? const EventChannel(eventChannelName);

  static const String methodChannelName = 'com.treebars.sdk/flutter';
  static const String eventChannelName = 'com.treebars.sdk/flutter/events';

  final MethodChannel _methods;
  final EventChannel _events;

  Future<void>? _ready;
  StreamSubscription<Object?>? _subscription;

  final Map<String, Set<void Function(Object?)>> _listeners = {};
  final Map<int, void Function(AppAction)> _actionHandlers = {};
  final Map<int, String?> _actionNames = {};
  int _nextActionId = 1;
  final Set<void Function(NotificationPage)> _notificationWatchers = {};
  final Set<VoidCallback> _configWatchers = {};
  void Function(String path)? _deepLinkListener;
  void Function(UploadLog log)? _uploadListener;

  // ---------------------------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------------------------

  /// Starts the native SDK. Safe to call without awaiting: every other call waits for it.
  ///
  /// A second call returns the first one's Future; the native SDK is started once per launch.
  Future<void> init(TreebarsConfig config) {
    return _ready ??= _start(config).catchError((Object error) {
      // A failed start can be tried again, with a corrected config.
      _ready = null;
      throw error;
    });
  }

  Future<void> _start(TreebarsConfig config) async {
    /*
     * Listening before `initialize`, so what the native SDK reports while it starts — the first
     * upload, a config change, a push action it was holding — has somewhere to go.
     */
    _subscription ??= _events.receiveBroadcastStream().listen(_receive, onError: (Object error) {
      debugPrint('Treebars: the event stream failed: $error');
    });

    final wire = config.toWire();
    /*
     * Marks this install as Flutter. The native SDK reports the real operating system as the
     * platform, so without this a Flutter device would be indistinguishable from a native one
     * in every report.
     */
    wire['adopt'] = <String, Object?>{'sdkName': sdkName};
    await _call<void>('initialize', {'config': jsonEncode(wire)});

    /*
     * Subscriptions made before `init` — the normal order when a widget subscribes in its
     * `initState` and the app starts the SDK in `main` without awaiting — are sent now.
     */
    if (_listeners.isNotEmpty) await _sendEventSubscriptions();
    for (final entry in _actionNames.entries) {
      await _call<void>('subscribeAppAction', {'id': entry.key, 'name': entry.value});
    }
    if (_deepLinkListener != null) await _call<void>('setDeferredDeepLinkSubscribed', {'subscribed': true});
    if (_notificationWatchers.isNotEmpty) await _call<void>('setNotificationsSubscribed', {'subscribed': true});
  }

  /// Signs the current person out; the device becomes anonymous again.
  Future<void> reset() => _after('reset');

  /// Sends what is queued now rather than at the next scheduled send.
  Future<void> flush() => _after('flush');

  /// Stops all collection, kept by the native SDK across launches. Needs no `init`.
  Future<void> optOut() => _call<void>('optOut');

  /// Undoes [optOut]. Needs no `init`.
  Future<void> optIn() => _call<void>('optIn');

  Future<bool> isOptedOut() async => await _call<bool>('isOptedOut') ?? false;

  /// A token Treebars issued for this device and session, or null when there is none to give.
  Future<String?> contextToken() => _call<String>('contextToken');

  /// Forgets this device: its id, who was signed in, and everything not yet sent.
  Future<void> wipeLocalData() => _after('wipeLocalData');

  /// Whether the install referrer and Apple's ad attribution may be read.
  Future<void> setAcquisitionConsent(bool granted) => _call<void>('setAcquisitionConsent', {'granted': granted});

  /// A link opened the app. Answers the in-app path the link carried, or null.
  Future<String?> handleLink(String url) => _call<String>('handleLink', {'url': url});

  // ---------------------------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------------------------

  Future<void> track(String eventName, [Map<String, Object?> properties = const {}]) =>
      _after('track', {'name': eventName, 'properties': jsonEncode(properties)});

  Future<void> screen(String name, [Map<String, Object?> properties = const {}]) =>
      _after('screen', {'name': name, 'properties': jsonEncode(properties)});

  /// Signs [userId] in. A null [userId] signs nobody in: the attributes go on whoever the device
  /// is now. [signature] is the app backend's, carried to the native SDK untouched.
  Future<void> identify(String? userId, {Map<String, Object?> attributes = const {}, String? signature}) =>
      _after('identify', {'userId': userId, 'attributes': jsonEncode(attributes), 'signature': signature});

  // ---------------------------------------------------------------------------------------------
  // Push
  // ---------------------------------------------------------------------------------------------

  Future<void> registerPushToken(String token, PushProvider provider) =>
      _after('registerPushToken', {'token': token, 'provider': provider.wire});

  /// A push was opened. [payload] is the push's data as the messaging library gave it.
  Future<void> trackNotificationOpened(Map<String, Object?> payload) =>
      _after('trackNotificationOpened', {'payload': jsonEncode(payload)});

  Future<void> trackNotificationDismissed(Map<String, Object?> payload) =>
      _after('trackNotificationDismissed', {'payload': jsonEncode(payload)});

  /// A push's data from the app's messaging library, drawn by the native SDK when it is one the
  /// SDK draws. Answers whether it was. Android draws; iOS draws rich pushes in its notification
  /// service extension instead, so it answers false. Needs no `init`.
  Future<bool> handleRemotePush(Map<String, Object?> data) async =>
      await _call<bool>('handleRemotePush', {'payload': jsonEncode(data)}) ?? false;

  /// Asks for permission to show pushes. Answers whether they may be shown now.
  Future<bool> requestPushPermission({bool provisional = false}) async {
    await _waitReady();
    return await _call<bool>('requestPushPermission', {'provisional': provisional}) ?? false;
  }

  // ---------------------------------------------------------------------------------------------
  // In-app messages
  //
  // The native SDK draws every message itself. This package registers no renderer of its own.
  // ---------------------------------------------------------------------------------------------

  Future<void> syncInAppMessages() => _after('syncInAppMessages');

  /// The app's contexts: a message naming contexts shows only while one of them is set.
  Future<void> setCurrentContext(List<String> contexts) =>
      _after('setInAppContext', {'contexts': jsonEncode(contexts)});

  Future<void> resetCurrentContext() => _after('resetInAppContext');

  /// Draw no message until [releaseInApp]. Needs no `init`.
  Future<void> holdInApp() => _call<void>('holdInApp');

  Future<void> releaseInApp() => _call<void>('releaseInApp');

  /// Evaluate the messages for this screen now.
  Future<void> showInApp() => _after('showInApp');

  Future<void> showNudge([NudgePosition position = NudgePosition.any]) =>
      _after('showNudge', {'position': position.wire});

  /// Every self-handled message eligible now, for the app to draw itself.
  Future<List<Map<String, Object?>>> getSelfHandledInApps() async {
    await _waitReady();
    return _decodeList(await _call<String>('getSelfHandledInApps'), 'the self-handled messages');
  }

  Future<void> selfHandledShown(String deliveryId) => _after('selfHandledShown', {'deliveryId': deliveryId});

  /// [button] is the pressed button as the message carries it, or null.
  Future<void> selfHandledClicked(String deliveryId, [Map<String, Object?>? button]) =>
      _after('selfHandledClicked', {'deliveryId': deliveryId, 'button': button == null ? '' : jsonEncode(button)});

  Future<void> selfHandledDismissed(String deliveryId) => _after('selfHandledDismissed', {'deliveryId': deliveryId});

  /// A form's answers, by field id, for the message with this delivery id.
  Future<void> submitInAppForm(String deliveryId, Map<String, Object> responses) =>
      _after('submitInAppForm', {'deliveryId': deliveryId, 'responses': jsonEncode(responses)});

  /// The in-app inbox: messages kept for the person to come back to.
  Future<List<Map<String, Object?>>> inbox() async {
    await _waitReady();
    return _decodeList(await _call<String>('inboxList'), 'the inbox');
  }

  Future<void> inboxDismiss(String deliveryId) => _after('inboxDismiss', {'deliveryId': deliveryId});

  Future<void> inboxViewed(String deliveryId) => _after('inboxViewed', {'deliveryId': deliveryId});

  Future<void> inboxClicked(String deliveryId, [String? destination]) =>
      _after('inboxClicked', {'deliveryId': deliveryId, 'destination': destination ?? ''});

  // ---------------------------------------------------------------------------------------------
  // The notification centre
  // ---------------------------------------------------------------------------------------------

  Future<NotificationPage> notifications({int? limit, String? cursor, List<String>? channels, String? topic}) async {
    await _waitReady();
    final options = <String, Object?>{'limit': limit, 'cursor': cursor, 'channels': channels, 'topic': topic}
      ..removeWhere((_, value) => value == null);
    final raw = await _call<String>('notificationsList', {'options': jsonEncode(options)});
    return NotificationPage.fromJson(_decodeObject(raw, 'a notification page'));
  }

  /// The centre's tabs with their counts, All first.
  Future<List<NotificationTopic>> notificationTopics() async {
    await _waitReady();
    return _decodeList(await _call<String>('notificationsTopics'), 'the notification topics')
        .map(NotificationTopic.fromJson)
        .toList();
  }

  Future<void> markNotificationRead(String groupId) => _after('notificationsMarkRead', {'groupId': groupId});

  /// A notification tapped in the centre: opened, and read with it.
  Future<void> markNotificationOpened(String groupId) => _after('notificationsMarkOpened', {'groupId': groupId});

  /// Everything read, or only one tab's when [topic] is given.
  Future<void> markAllNotificationsRead([String? topic]) => _after('notificationsMarkAllRead', {'topic': topic});

  Future<void> dismissNotification(String groupId) => _after('notificationsDismiss', {'groupId': groupId});

  /// Calls [watcher] with every new page of the centre. Returns the function that stops it.
  VoidCallback onNotificationsChange(void Function(NotificationPage page) watcher) {
    final first = _notificationWatchers.isEmpty;
    _notificationWatchers.add(watcher);
    if (first && _ready != null) unawaited(_after('setNotificationsSubscribed', {'subscribed': true}));
    return () {
      if (_notificationWatchers.remove(watcher) && _notificationWatchers.isEmpty && _ready != null) {
        unawaited(_after('setNotificationsSubscribed', {'subscribed': false}));
      }
    };
  }

  // ---------------------------------------------------------------------------------------------
  // Remote config
  //
  // None of these waits for `init`: the native SDK answers a read with the fallback until it has
  // started, and keeps attributes and overrides given early.
  // ---------------------------------------------------------------------------------------------

  /// The value held for [key], else [fallback]. Without a fallback, null when nothing is held.
  Future<bool?> getConfigBoolean(String key, [bool? fallback]) async {
    if (fallback != null) return await _call<bool>('configBoolean', {'key': key, 'fallback': fallback}) ?? fallback;
    final value = await _configValue(key, 'boolean');
    return value is bool ? value : null;
  }

  Future<String?> getConfigString(String key, [String? fallback]) async {
    if (fallback != null) return await _call<String>('configString', {'key': key, 'fallback': fallback}) ?? fallback;
    final value = await _configValue(key, 'string');
    return value is String ? value : null;
  }

  Future<double?> getConfigNumber(String key, [double? fallback]) async {
    if (fallback != null) {
      return (await _call<num>('configNumber', {'key': key, 'fallback': fallback}))?.toDouble() ?? fallback;
    }
    final value = await _configValue(key, 'number');
    return value is num ? value.toDouble() : null;
  }

  /// A JSON value, decoded, or [fallback] when nothing is held for [key].
  Future<Object?> getConfigJson(String key, [Object? fallback]) async {
    final raw = await _call<String>('configJson', {'key': key});
    return raw == null ? fallback : _decode(raw, 'the config value of "$key"');
  }

  /// Every key held, with the value a read would answer.
  Future<Map<String, Object?>> allConfig() async =>
      _decodeObject(await _call<String>('allConfig'), 'the config values');

  /// Asks for the values now. Answers whether they arrived.
  Future<bool> fetchConfig() async => await _call<bool>('fetchConfig') ?? false;

  /// Applies the newest values to keys already read.
  Future<bool> activateConfig() async => await _call<bool>('activateConfig') ?? false;

  /// Completes once values are held or [timeoutMs] has passed, with whether any are.
  Future<bool> configReady([int timeoutMs = configReadyTimeoutMs]) async =>
      await _call<bool>('configReady', {'timeoutMs': timeoutMs}) ?? false;

  /// What the app knows about this install: text, numbers and booleans. The whole set each time.
  Future<void> setConfigAttributes(Map<String, Object> attributes) =>
      _call<void>('setConfigAttributes', {'attributes': jsonEncode(attributes)});

  /// Answers [key] with [value] for this run of the app; null takes the override back.
  Future<void> setConfigOverride(String key, Object? value) =>
      _call<void>('setConfigOverride', {'key': key, 'value': value == null ? null : jsonEncode(value)});

  /// What a config read answers may have changed. Returns the function that stops listening.
  VoidCallback onConfigChange(VoidCallback listener) {
    _configWatchers.add(listener);
    return () => _configWatchers.remove(listener);
  }

  Future<Object?> _configValue(String key, String kind) async {
    final raw = await _call<String>('configValue', {'key': key, 'kind': kind});
    return raw == null ? null : _decode(raw, 'the config value of "$key"');
  }

  // ---------------------------------------------------------------------------------------------
  // Listeners
  // ---------------------------------------------------------------------------------------------

  /// Listens to one of [eventNames]: a push action, or something that happened to an in-app
  /// message. Returns the function that stops it.
  ///
  /// Listening to `inAppCampaignSelfHandled` changes what happens: a self-handled message is
  /// handed here for the app to draw, instead of being left alone.
  VoidCallback on(String name, void Function(Object? data) listener) {
    if (!eventNames.contains(name)) {
      throw ArgumentError.value(name, 'name', 'not one of ${eventNames.join(', ')}');
    }
    final set = _listeners.putIfAbsent(name, () => {});
    final first = set.isEmpty;
    set.add(listener);
    if (first && _ready != null) unawaited(_waitReady().then((_) => _sendEventSubscriptions()));
    return () {
      final current = _listeners[name];
      if (current == null || !current.remove(listener)) return;
      if (current.isEmpty) {
        _listeners.remove(name);
        if (_ready != null) unawaited(_waitReady().then((_) => _sendEventSubscriptions()));
      }
    };
  }

  /// Handles an app action: [name]'s, or every action when [name] is null. The native SDK holds
  /// an action nothing has subscribed to yet, so the tap that opened the app still arrives.
  VoidCallback onAction(String? name, void Function(AppAction action) handler) {
    final id = _nextActionId++;
    _actionHandlers[id] = handler;
    _actionNames[id] = name;
    if (_ready != null) unawaited(_after('subscribeAppAction', {'id': id, 'name': name}));
    return () {
      _actionHandlers.remove(id);
      _actionNames.remove(id);
      if (_ready != null) unawaited(_after('unsubscribeAppAction', {'id': id}));
    };
  }

  /// The path a tracker link carried through the install, delivered once per install.
  VoidCallback onDeferredDeepLink(void Function(String path) listener) {
    _deepLinkListener = listener;
    if (_ready != null) unawaited(_after('setDeferredDeepLinkSubscribed', {'subscribed': true}));
    return () {
      if (_deepLinkListener != listener) return;
      _deepLinkListener = null;
      if (_ready != null) unawaited(_after('setDeferredDeepLinkSubscribed', {'subscribed': false}));
    };
  }

  /// Every upload attempt, for an app's own debug screen.
  void onUploadLog(void Function(UploadLog log)? listener) => _uploadListener = listener;

  // ---------------------------------------------------------------------------------------------
  // Queue telemetry
  // ---------------------------------------------------------------------------------------------

  Future<int> pendingCount() async {
    await _waitReady();
    return (await _call<num>('pendingCount'))?.toInt() ?? 0;
  }

  /// Milliseconds until the next scheduled send, or null when none is scheduled.
  Future<int?> msUntilNextFlush() async {
    final ms = (await _call<num>('msUntilNextFlush'))?.toInt();
    return ms == null || ms < 0 ? null : ms;
  }

  // ---------------------------------------------------------------------------------------------
  // The wire
  // ---------------------------------------------------------------------------------------------

  void _receive(Object? raw) {
    if (raw is! String) return;
    final Map<String, Object?> event;
    try {
      event = _decodeObject(raw, 'an event');
    } on TreebarsException catch (error) {
      debugPrint('Treebars: $error');
      return;
    }
    final name = event['name'];
    final data = event['data'];
    switch (name) {
      case 'appAction':
        final body = (data as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const {};
        final handler = _actionHandlers[(body['id'] as num?)?.toInt()];
        final action = (body['action'] as Map<Object?, Object?>?)?.cast<String, Object?>();
        if (handler != null && action != null) handler(AppAction.fromJson(action));
      case 'notificationsChange':
        final page = NotificationPage.fromJson((data as Map<Object?, Object?>).cast<String, Object?>());
        for (final watcher in [..._notificationWatchers]) {
          watcher(page);
        }
      case 'configChange':
        for (final watcher in [..._configWatchers]) {
          watcher();
        }
      case 'uploadLog':
        _uploadListener?.call(UploadLog.fromJson((data as Map<Object?, Object?>).cast<String, Object?>()));
      case 'deferredDeepLink':
        if (data is String) _deepLinkListener?.call(data);
      default:
        for (final listener in [...?_listeners[name]]) {
          listener(data);
        }
    }
  }

  Future<void> _sendEventSubscriptions() =>
      _call<void>('setEventsSubscribed', {'names': jsonEncode(_listeners.keys.toList())});

  /// Waits for `init` when it has been called, so `init(); track()` works without awaiting.
  /// Before any `init`, the call goes straight down and the native side refuses it by name.
  Future<void> _waitReady() async {
    final ready = _ready;
    if (ready != null) await ready;
  }

  Future<void> _after(String method, [Map<String, Object?>? arguments]) async {
    await _waitReady();
    await _call<void>(method, arguments);
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw TreebarsException(error.code, error.message ?? 'Treebars: $method failed');
    } on MissingPluginException {
      throw const TreebarsException(
        'not_linked',
        'Treebars: the native SDK is not in this build. Stop the app and run it again with '
            '`flutter run`; a hot restart does not add a plugin.',
      );
    }
  }

  Object? _decode(String raw, String what) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (error) {
      throw TreebarsException('bad_payload', 'Treebars: $what was not readable JSON. ${error.message}');
    }
  }

  Map<String, Object?> _decodeObject(String? raw, String what) {
    final value = raw == null ? null : _decode(raw, what);
    if (value is Map<String, Object?>) return value;
    throw TreebarsException('bad_payload', 'Treebars: $what was not a JSON object.');
  }

  List<Map<String, Object?>> _decodeList(String? raw, String what) {
    final value = raw == null ? null : _decode(raw, what);
    if (value is! List) throw TreebarsException('bad_payload', 'Treebars: $what was not a JSON list.');
    return value.whereType<Map<String, Object?>>().toList();
  }
}

/// The SDK, ready to use: `treebars.init(...)`, `treebars.track(...)`.
final TreebarsSdk treebars = TreebarsSdk();
