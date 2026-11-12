import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/gateway.dart';
import 'app/demo_gateway.dart';
import 'ui/app.dart';
export 'ui/app.dart' show MohotewApp;

Future<void> main() => launchMohotew(AppKind.client);
Future<void> launchMohotew(AppKind kind) async {
  WidgetsFlutterBinding.ensureInitialized();
  AppGateway? gateway;
  if (const bool.fromEnvironment('DEMO_MODE')) {
    if (!kReleaseMode) gateway = DemoGateway();
  } else {
    try {
      const url = String.fromEnvironment('SUPABASE_URL');
      const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
      if (Uri.tryParse(url)?.scheme != 'https' ||
          key.isEmpty ||
          key.startsWith('sb_secret_')) {
        throw StateError('Invalid configuration');
      }
      await Supabase.initialize(url: url, publishableKey: key);
      gateway = LiveGateway(
        Supabase.instance.client,
        redirectTo: 'mohotew-${kind.name}://auth/callback',
      );
    } catch (_) {
      /* Safe startup screen; no credential output. */
    }
  }
  runApp(
    MohotewApp(
      gateway: gateway,
      kind: kind,
      onRetry: () => launchMohotew(kind),
    ),
  );
}
