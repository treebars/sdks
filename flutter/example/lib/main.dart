import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:treebars_flutter_sdk/treebars_flutter_sdk.dart';

/// A test project's write key. Replace it with your own project's `pk_test_…` key.
const writeKey = String.fromEnvironment('TREEBARS_WRITE_KEY', defaultValue: 'pk_test_demo0000000000000000demo');

/// Where events go. An Android emulator reaches this computer at 10.0.2.2; the iOS simulator at
/// localhost. Pass `--dart-define=TREEBARS_BACKEND_URL=...` for anything else.
String get backendUrl {
  const configured = String.fromEnvironment('TREEBARS_BACKEND_URL');
  if (configured.isNotEmpty) return configured;
  return Platform.isAndroid ? 'http://10.0.2.2:5156' : 'http://localhost:5156';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Not awaited: every other call waits for it.
  treebars.init(TreebarsConfig(writeKey: writeKey, backendUrl: backendUrl, env: 'test', debug: true));
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Treebars Flutter',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF16A34A), useMaterial3: true),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<String> _log = [];
  int? _pending;

  @override
  void initState() {
    super.initState();
    treebars.onUploadLog((log) => _note('upload ${log.status}: ${log.message}'));
    treebars.screen('home');
  }

  void _note(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      _pending = await treebars.pendingCount();
      _note('$label: ok');
    } on TreebarsException catch (error) {
      _note('$label: ${error.code} ${error.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Treebars Flutter example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Sending to $backendUrl', style: Theme.of(context).textTheme.bodySmall),
          Text('Queued: ${_pending ?? '-'}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => _run('product_view', () => treebars.track('product_view', {'product_id': 'sku_1', 'price': 19.99})),
                child: const Text('Track product_view'),
              ),
              FilledButton(
                onPressed: () => _run(
                  'purchase',
                  () => treebars.track('purchase', {'value': 19.99, 'currency': 'USD', 'items': 1}),
                ),
                child: const Text('Track purchase'),
              ),
              OutlinedButton(
                onPressed: () => _run('identify', () => treebars.identify('flutter_user_1', attributes: {'plan': 'pro'})),
                child: const Text('Identify'),
              ),
              OutlinedButton(onPressed: () => _run('flush', treebars.flush), child: const Text('Flush')),
              OutlinedButton(onPressed: () => _run('reset', treebars.reset), child: const Text('Sign out')),
            ],
          ),
          const Divider(height: 32),
          for (final line in _log) Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}
