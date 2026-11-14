import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:treebars_flutter_sdk/treebars_flutter_sdk.dart';

/// The bridge's half of the contract: what crosses the channel, in what order, and what comes back.
///
/// The native halves are stood in for by a handler that records every call, so these tests say
/// nothing about the native SDKs themselves; they pin that Dart sends what the Kotlin and Swift
/// plugins read, and that it decides nothing of its own on the way.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel(TreebarsSdk.methodChannelName);
  const events = EventChannel(TreebarsSdk.eventChannelName);

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> answers;
  late MockStreamHandlerEventSink? eventSink;
  late TreebarsSdk sdk;

  const config = TreebarsConfig(writeKey: 'pk_test_x', backendUrl: 'http://localhost:5156', env: 'test');

  setUp(() {
    calls = [];
    answers = {};
    eventSink = null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      final answer = answers[call.method];
      return answer?.call(call);
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, sink) => eventSink = sink),
    );
    sdk = TreebarsSdk();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  Map<String, Object?> argsOf(MethodCall call) => (call.arguments as Map<Object?, Object?>).cast<String, Object?>();
  Map<String, Object?> jsonArg(MethodCall call, String key) =>
      (jsonDecode(argsOf(call)[key] as String) as Map<Object?, Object?>).cast<String, Object?>();

  void push(String name, Object? data) => eventSink!.success(jsonEncode({'name': name, 'data': data}));

  group('init', () {
    test('sends the config as the native SDKs read it, and names this SDK', () async {
      await sdk.init(config);

      expect(calls.single.method, 'initialize');
      final wire = jsonArg(calls.single, 'config');
      expect(wire['write_key'], 'pk_test_x');
      expect(wire['backend_url'], 'http://localhost:5156');
      expect(wire['env'], 'test');
      expect(wire['adopt'], {'sdkName': 'treebars-flutter'});
    });

    test('leaves an unset option out, so the native default applies', () async {
      await sdk.init(config);
      final wire = jsonArg(calls.single, 'config');
      expect(wire.containsKey('flush_interval_ms'), isFalse);
      expect(wire.containsKey('in_app_enabled'), isFalse);
      expect(wire.values, isNot(contains(null)));
    });

    test('starts once, however often it is called', () async {
      await Future.wait([sdk.init(config), sdk.init(config)]);
      expect(calls.where((c) => c.method == 'initialize'), hasLength(1));
    });

    test('a refused config fails with its code, and can be tried again', () async {
      answers['initialize'] = (_) => throw PlatformException(code: 'bad_config', message: 'no write_key');
      await expectLater(
        sdk.init(config),
        throwsA(isA<TreebarsException>().having((e) => e.code, 'code', 'bad_config')),
      );
      answers.remove('initialize');
      await sdk.init(config);
      expect(calls.where((c) => c.method == 'initialize'), hasLength(2));
    });
  });

  group('calls', () {
    test('a call made without awaiting init goes down after it', () async {
      final started = Completer<void>();
      answers['initialize'] = (_) => started.future;
      unawaited(sdk.init(config));
      final tracked = sdk.track('purchase', {'value': 12.5});
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['initialize']);

      started.complete();
      await tracked;
      expect(calls.map((c) => c.method), ['initialize', 'track']);
      expect(argsOf(calls.last)['name'], 'purchase');
      expect(jsonArg(calls.last, 'properties'), {'value': 12.5});
    });

    test('identify carries the user, the attributes and the signature untouched', () async {
      await sdk.init(config);
      await sdk.identify('user_1', attributes: {'plan': 'pro'}, signature: 'sig');
      final args = argsOf(calls.last);
      expect(args['userId'], 'user_1');
      expect(args['signature'], 'sig');
      expect(jsonArg(calls.last, 'attributes'), {'plan': 'pro'});
    });

    test('a push token names its provider by the wire name', () async {
      await sdk.init(config);
      await sdk.registerPushToken('tok', PushProvider.apns);
      expect(argsOf(calls.last), {'token': 'tok', 'provider': 'apns'});
    });

    test('a native refusal arrives as a TreebarsException with its code', () async {
      answers['track'] = (_) => throw PlatformException(code: 'not_initialized', message: 'init() has not run.');
      await expectLater(
        sdk.track('x'),
        throwsA(isA<TreebarsException>().having((e) => e.code, 'code', 'not_initialized')),
      );
    });

    test('a build without the native half says so by name', () async {
      messenger.setMockMethodCallHandler(methods, null);
      await expectLater(
        sdk.optOut(),
        throwsA(isA<TreebarsException>().having((e) => e.code, 'code', 'not_linked')),
      );
    });

    test('an unparseable answer is a bad_payload, never an empty list', () async {
      await sdk.init(config);
      answers['inboxList'] = (_) => '{not json';
      await expectLater(
        sdk.inbox(),
        throwsA(isA<TreebarsException>().having((e) => e.code, 'code', 'bad_payload')),
      );
    });

    test('the queue telemetry maps "nothing scheduled" to null', () async {
      answers['msUntilNextFlush'] = (_) => -1;
      expect(await sdk.msUntilNextFlush(), isNull);
      answers['msUntilNextFlush'] = (_) => 1200;
      expect(await sdk.msUntilNextFlush(), 1200);
    });
  });

  group('remote config', () {
    test('a read with a fallback carries the fallback down', () async {
      answers['configBoolean'] = (call) => argsOf(call)['fallback'];
      expect(await sdk.getConfigBoolean('new_checkout', true), isTrue);
      expect(argsOf(calls.single), {'key': 'new_checkout', 'fallback': true});
    });

    test('a read without one asks for the held value and answers null when there is none', () async {
      answers['configValue'] = (call) => argsOf(call)['kind'] == 'number' ? '25' : null;
      expect(await sdk.getConfigNumber('limit'), 25.0);
      expect(await sdk.getConfigString('title'), isNull);
    });

    test('reads need no init', () async {
      answers['configString'] = (_) => 'held';
      expect(await sdk.getConfigString('title', 'fallback'), 'held');
      expect(calls.map((c) => c.method), ['configString']);
    });
  });

  group('the event stream', () {
    test('subscriptions made before init are sent once it has run', () async {
      sdk.on('pushClicked', (_) {});
      sdk.onAction('open_offer', (_) {});
      await sdk.init(config);

      final methodsSent = calls.map((c) => c.method).toList();
      expect(methodsSent, ['initialize', 'setEventsSubscribed', 'subscribeAppAction']);
      expect(jsonDecode(argsOf(calls[1])['names'] as String), ['pushClicked']);
      expect(argsOf(calls[2])['name'], 'open_offer');
    });

    test('an unknown event name is refused', () {
      expect(() => sdk.on('pushClickd', (_) {}), throwsArgumentError);
    });

    test('an app action reaches the handler it was subscribed for', () async {
      final got = <AppAction>[];
      sdk.onAction('open_offer', got.add);
      await sdk.init(config);
      final id = argsOf(calls.firstWhere((c) => c.method == 'subscribeAppAction'))['id'];

      push('appAction', {
        'id': id,
        'action': {'name': 'open_offer', 'payload': {'sku': 'A1'}, 'source': {'kind': 'in_app'}},
      });
      await Future<void>.delayed(Duration.zero);

      expect(got.single.name, 'open_offer');
      expect(got.single.payload, {'sku': 'A1'});
    });

    test('pages, config changes and upload logs reach their listeners', () async {
      NotificationPage? page;
      var changes = 0;
      UploadLog? log;
      sdk.onNotificationsChange((p) => page = p);
      sdk.onConfigChange(() => changes++);
      sdk.onUploadLog((l) => log = l);
      await sdk.init(config);

      push('notificationsChange', {
        'notifications': [
          {'group_id': 'g1'},
        ],
        'unreadCount': 1,
        'nextCursor': null,
        'fromCache': false,
      });
      push('configChange', null);
      push('uploadLog', {'type': 'upload', 'status': 'success', 'message': 'sent 3', 'count': 3});
      await Future<void>.delayed(Duration.zero);

      expect(page!.unreadCount, 1);
      expect(page!.notifications.single['group_id'], 'g1');
      expect(changes, 1);
      expect(log!.count, 3);
    });
  });
}
