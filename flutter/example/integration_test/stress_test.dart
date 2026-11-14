import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:treebars_flutter_sdk/treebars_flutter_sdk.dart';

/// A stress run of every feature the Flutter SDK carries, on a real simulator or emulator.
///
/// It drives the plugin and the native SDK under it hard — bursts of concurrent calls, sign-in
/// churn, listener churn, every remote config read kind — and asserts what the device itself can
/// see: every call answers, nothing throws that should not, the queue drains. What reached the
/// server is counted afterwards by `tool/stress.sh`, from the run id every event carries.
///
/// Run it with `tool/stress.sh <device>`, which picks the run id, runs this file and counts.
const runId = String.fromEnvironment('STRESS_RUN', defaultValue: 'manual');

/// Events in each drained wave, and how many waves. Kept under the native queue's cap so every
/// one of them is expected to land.
const waveSize = 200;
const waves = 5;

/// One more burst, larger than the native queue holds, sent without waiting for a drain. What lands
/// of it is reported, not asserted: the native SDK drops past its cap by design.
const overflowSize = 1500;

const identityCycles = 20;
const screens = 100;
const pushOpens = 20;
const configReads = 500;
const listenerChurn = 200;
const optedOutEvents = 50;

String get backendUrl {
  const configured = String.fromEnvironment('TREEBARS_BACKEND_URL');
  if (configured.isNotEmpty) return configured;
  return Platform.isAndroid ? 'http://10.0.2.2:5156' : 'http://localhost:5156';
}

const writeKey = String.fromEnvironment('TREEBARS_WRITE_KEY', defaultValue: 'pk_test_demo0000000000000000demo');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final uploads = <UploadLog>[];
  final timings = <String, int>{};

  Future<T> timed<T>(String phase, Future<T> Function() body) async {
    final watch = Stopwatch()..start();
    final result = await body();
    timings[phase] = watch.elapsedMilliseconds;
    // ignore: avoid_print
    print('STRESS phase=$phase ms=${watch.elapsedMilliseconds}');
    return result;
  }

  /// Flushes until the native queue is empty, or fails after [timeout].
  Future<void> drain({Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      await treebars.flush();
      final pending = await treebars.pendingCount();
      if (pending == 0) return;
      if (DateTime.now().isAfter(deadline)) fail('the queue still held $pending events after $timeout');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Map<String, Object?> props(String wave, int seq) => {
        'stress_run': runId,
        'wave': wave,
        'seq': seq,
        'price': seq * 1.25,
        'in_stock': seq.isEven,
        'tags': ['a', 'b', 'c'],
        'nested': {'level': 1, 'more': {'level': 2}},
        'note': 'مرحبا ✓ ${'x' * 40}',
        'nothing': null,
      };

  testWidgets('stress every feature of the Flutter SDK', (tester) async {
    treebars.onUploadLog(uploads.add);

    await timed('init', () => treebars.init(TreebarsConfig(writeKey: writeKey, backendUrl: backendUrl, env: 'test', debug: true)));
    // A second init is the first one's Future, not a second start.
    await treebars.init(TreebarsConfig(writeKey: writeKey, backendUrl: backendUrl, env: 'test'));
    expect(await treebars.isOptedOut(), isFalse);
    await drain();

    // Events, in drained waves of concurrent calls.
    await timed('events', () async {
      for (var wave = 0; wave < waves; wave++) {
        await Future.wait([
          for (var seq = 0; seq < waveSize; seq++) treebars.track('stress_event', props('w$wave', seq)),
        ]);
        await drain();
      }
    });

    // Screens.
    await timed('screens', () async {
      await Future.wait([
        for (var i = 0; i < screens; i++) treebars.screen('stress_screen_${i % 10}', {'stress_run': runId, 'seq': i}),
      ]);
      await drain();
    });

    // Sign-in churn: sign in, act, sign out, many times.
    await timed('identity', () async {
      for (var i = 0; i < identityCycles; i++) {
        await treebars.identify('stress_${runId}_$i', attributes: {'plan': i.isEven ? 'pro' : 'free', 'cycle': i});
        await treebars.track('stress_signed_in', {'stress_run': runId, 'cycle': i});
        await treebars.identify(null, attributes: {'last_cycle': i});
        await treebars.reset();
      }
      await drain();
    });

    // The same churn, with every cycle drained before the next: the control for the phase above.
    // If attribution is right here and wrong there, it goes wrong only when a sign-in and a
    // sign-out share one upload.
    await timed('identity_drained', () async {
      for (var i = 0; i < identityCycles; i++) {
        await treebars.identify('stress_${runId}_d$i', attributes: {'cycle': i});
        await drain();
        await treebars.track('stress_signed_in_drained', {'stress_run': runId, 'cycle': i});
        await drain();
        await treebars.reset();
        await drain();
      }
    });

    // Push: a token for this platform's provider, then opens and dismissals of a Treebars push.
    await timed('push', () async {
      final provider = Platform.isIOS ? PushProvider.apns : PushProvider.fcm;
      // A token in the provider's own shape: APNs tokens are 64 hex characters.
      final hex = runId.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join().padRight(64, '0').substring(0, 64);
      await treebars.registerPushToken(Platform.isIOS ? hex : 'stress-fcm-token-$runId', provider);
      if (Platform.isIOS) {
        // The native SDK refuses an APNs token that is not hex, and the refusal arrives here by name.
        await expectLater(
          treebars.registerPushToken('not-hex', PushProvider.apns),
          throwsA(isA<TreebarsException>().having((e) => e.code, 'code', 'bad_payload')),
        );
      }
      for (var i = 0; i < pushOpens; i++) {
        final payload = {'treebars_delivery_id': 'stress-$runId-$i', 'treebars_campaign_id': 'stress-campaign'};
        await treebars.trackNotificationOpened(payload);
        await treebars.trackNotificationDismissed(payload);
      }
      // A push that is not a Treebars one is not drawn.
      expect(await treebars.handleRemotePush({'title': 'not ours'}), isFalse);
      await drain();
    });

    // Remote config: every read kind, concurrently, with and without fallbacks.
    await timed('config', () async {
      await treebars.setConfigAttributes({'stress_run': runId, 'tier': 3, 'beta': true});
      await treebars.fetchConfig();
      await treebars.configReady(2000);
      final reads = await Future.wait([
        for (var i = 0; i < configReads; i++) ...[
          treebars.getConfigBoolean('stress_flag_$i', true),
          treebars.getConfigString('stress_text_$i', 'fallback'),
          treebars.getConfigNumber('stress_number_$i', 7),
          treebars.getConfigJson('stress_json_$i', const {'fallback': true}),
          treebars.getConfigBoolean('stress_flag_$i'),
        ],
      ]);
      expect(reads, hasLength(configReads * 5));
      // An unknown key answers its fallback, and null without one.
      expect(reads[0], isTrue);
      expect(reads[1], 'fallback');
      expect(reads[2], 7.0);
      expect(reads[4], isNull);

      await treebars.setConfigOverride('stress_override', 'overridden');
      expect(await treebars.getConfigString('stress_override', 'fallback'), 'overridden');
      await treebars.setConfigOverride('stress_override', null);
      expect(await treebars.getConfigString('stress_override', 'fallback'), 'fallback');
      expect(await treebars.allConfig(), isA<Map<String, Object?>>());
      expect(await treebars.activateConfig(), isA<bool>());
    });

    // In-app messages: sync, contexts, hold and release, show, nudges, self-handled, the inbox.
    await timed('in_app', () async {
      for (var i = 0; i < 10; i++) {
        await treebars.syncInAppMessages();
      }
      await treebars.setCurrentContext(['stress', 'checkout']);
      await treebars.resetCurrentContext();
      for (var i = 0; i < 50; i++) {
        await treebars.holdInApp();
        await treebars.releaseInApp();
      }
      await treebars.showInApp();
      await treebars.showNudge(NudgePosition.bottom);
      expect(await treebars.getSelfHandledInApps(), isA<List<Map<String, Object?>>>());
      expect(await treebars.inbox(), isA<List<Map<String, Object?>>>());
      // A report on a self-handled message never handed over: refused by name, or ignored, never a crash.
      try {
        await treebars.selfHandledShown('not-a-delivery');
      } on TreebarsException catch (error) {
        expect(error.code, 'bad_payload');
      }
    });

    // The notification centre, and watcher churn on it.
    await timed('notifications', () async {
      final page = await treebars.notifications(limit: 20);
      expect(page.unreadCount, greaterThanOrEqualTo(0));
      final topics = await treebars.notificationTopics();
      expect(topics, isA<List<NotificationTopic>>());
      await treebars.markAllNotificationsRead();
      for (var i = 0; i < listenerChurn; i++) {
        final stop = treebars.onNotificationsChange((_) {});
        stop();
      }
    });

    // Listener churn: every event name and app actions, on and off.
    await timed('listeners', () async {
      for (var i = 0; i < listenerChurn; i++) {
        final stops = [for (final name in eventNames) treebars.on(name, (_) {})];
        final stopAction = treebars.onAction(i.isEven ? 'stress_action' : null, (_) {});
        final stopConfig = treebars.onConfigChange(() {});
        final stopLink = treebars.onDeferredDeepLink((_) {});
        for (final stop in stops) {
          stop();
        }
        stopAction();
        stopConfig();
        stopLink();
      }
      // Let the subscriptions those queued settle before the next phase.
      await treebars.flush();
    });

    // Opt-out: nothing is collected while opted out, and opting in again works.
    await timed('opt_out', () async {
      await treebars.optOut();
      expect(await treebars.isOptedOut(), isTrue);
      for (var i = 0; i < optedOutEvents; i++) {
        await treebars.track('stress_opted_out', {'stress_run': runId, 'seq': i});
      }
      await treebars.optIn();
      expect(await treebars.isOptedOut(), isFalse);
      await treebars.track('stress_opted_in', {'stress_run': runId});
      await drain();
    });

    // The rest of the surface.
    await timed('misc', () async {
      await treebars.contextToken();
      await treebars.msUntilNextFlush();
      await treebars.setAcquisitionConsent(true);
      await treebars.handleLink('https://tbrs.cc/stress-$runId');
    });

    // One burst past the native queue's cap, sent all at once. Counted, not asserted.
    await timed('overflow', () async {
      await Future.wait([
        for (var seq = 0; seq < overflowSize; seq++) treebars.track('stress_event', props('overflow', seq)),
      ]);
      await drain(timeout: const Duration(seconds: 180));
    });

    final sent = uploads.where((log) => log.status == 'success').fold<int>(0, (sum, log) => sum + (log.count ?? 0));
    final failed = uploads.where((log) => log.status == 'error' || log.status == 'failure').length;
    // ignore: avoid_print
    print('STRESS run=$runId platform=${Platform.operatingSystem} uploaded=$sent failed_uploads=$failed '
        'timings=$timings');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
