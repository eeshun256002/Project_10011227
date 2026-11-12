import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final values = <String, String>{};
    for (final line in await File('.env').readAsLines()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final separator = trimmed.indexOf('=');
      if (separator < 1) continue;
      var value = trimmed.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[trimmed.substring(0, separator).trim()] = value;
    }
    final url = Uri.tryParse(values['SUPABASE_URL'] ?? '');
    final key = values['SUPABASE_PUBLISHABLE_KEY'] ?? '';
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.host.contains('YOUR_PROJECT_REF') ||
        key.isEmpty ||
        key == 'YOUR_PUBLISHABLE_KEY' ||
        key.startsWith('sb_secret_')) {
      throw StateError(
        'Set a hosted Supabase URL and publishable key in .env.',
      );
    }
    await (() async {
      final request = await client.getUrl(url.resolve('/auth/v1/settings'));
      request.headers.set('apikey', key);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          'Supabase Auth returned HTTP ${response.statusCode}.',
        );
      }
      final data = jsonDecode(await utf8.decoder.bind(response).join());
      if (data is! Map || data['external'] is! Map) {
        throw const FormatException('Unexpected Auth settings response.');
      }
    })().timeout(const Duration(seconds: 20));
    stdout.writeln(
      'Connected to hosted Supabase. Auth settings are accessible.',
    );
    stdout.writeln(
      'Database table access depends on your schema and RLS policies.',
    );
  } catch (error) {
    stderr.writeln(
      'Connection check failed (${error.runtimeType}). Check .env, network access, and project status.',
    );
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}
