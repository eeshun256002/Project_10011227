import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../backend/waste_backend.dart';

enum AppKind { client, driver, receiver }

abstract class AppGateway {
  bool get demo => false;
  String? get userId;
  String get identity;
  Stream<void> get authChanges;
  bool get recovering => false;
  Future<void> authenticate(
    String identity,
    String password, {
    bool signup = false,
  });
  Future<void> verify(String identity, String code);
  Future<void> resend(String identity);
  Future<void> resetPassword(String email);
  Future<void> updatePassword(String password);
  Future<void> signOut();
  Future<dynamic> read(String name, [JsonObject params = const {}]);
  Future<JsonObject> command(
    String action,
    JsonObject payload, {
    bool onboarding = false,
  });
  Future<void> upload(String bucket, String path, Uint8List bytes, String mime);
  Future<String?> pendingAction();
  Future<void> retryPending();
}

/// One durable, user-scoped intent at a time. A transport timeout never becomes
/// a new booking/payment. Secrets in handoff payloads stay in secure storage.
class CommandJournal {
  CommandJournal({
    required this.readValue,
    required this.writeValue,
    required this.deleteValue,
  });
  final Future<String?> Function(String) readValue;
  final Future<void> Function(String, String) writeValue;
  final Future<void> Function(String) deleteValue;
  bool _sending = false;
  String key(String user) => 'mohotew.pending.$user';
  Future<JsonObject?> pending(String user) async {
    final value = await readValue(key(user));
    return value == null ? null : jsonDecode(value) as JsonObject;
  }

  Future<JsonObject> send(
    String user,
    WasteCommand command,
    bool onboarding,
    Future<JsonObject> Function(WasteCommand, bool) execute, {
    bool retry = false,
  }) async {
    if (_sending) throw const WasteBackendException('COMMAND_PENDING');
    _sending = true;
    try {
      final existing = await pending(user);
      if (existing != null && !retry) {
        throw const WasteBackendException('COMMAND_PENDING');
      }
      final envelope =
          existing ?? {'command': command.toJson(), 'onboarding': onboarding};
      final intent = WasteCommand.fromJson(
        Map<String, dynamic>.from(envelope['command'] as Map),
      );
      await writeValue(key(user), jsonEncode(envelope));
      try {
        final result = await execute(intent, envelope['onboarding'] as bool);
        await deleteValue(key(user));
        return result;
      } on WasteBackendException catch (error) {
        if (!['REQUEST_REJECTED', 'SERVICE_UNAVAILABLE'].contains(error.code)) {
          await deleteValue(key(user));
        }
        rethrow;
      }
    } finally {
      _sending = false;
    }
  }
}

class LiveGateway extends AppGateway {
  LiveGateway(this.client, {this.redirectTo = 'mohotew-client://auth/callback'})
    : backend = WasteBackend(client) {
    const storage = FlutterSecureStorage();
    journal = CommandJournal(
      readValue: (key) => storage.read(key: key),
      writeValue: (key, value) => storage.write(key: key, value: value),
      deleteValue: (key) => storage.delete(key: key),
    );
  }
  final SupabaseClient client;
  final String redirectTo;
  final WasteBackend backend;
  late final CommandJournal journal;
  bool _recovering = false;
  @override
  bool get recovering => _recovering;
  @override
  String? get userId => client.auth.currentUser?.id;
  @override
  String get identity =>
      client.auth.currentUser?.email ?? client.auth.currentUser?.phone ?? '';
  @override
  Stream<void> get authChanges => client.auth.onAuthStateChange.map((event) {
    if (event.event == AuthChangeEvent.passwordRecovery) _recovering = true;
  });
  bool phone(String value) => !value.contains('@');
  @override
  Future<void> authenticate(
    String identity,
    String password, {
    bool signup = false,
  }) async {
    if (signup) {
      await client.auth.signUp(
        email: phone(identity) ? null : identity,
        phone: phone(identity) ? identity : null,
        password: password,
        emailRedirectTo: redirectTo,
      );
    } else {
      await client.auth.signInWithPassword(
        email: phone(identity) ? null : identity,
        phone: phone(identity) ? identity : null,
        password: password,
      );
    }
  }

  @override
  Future<void> verify(String identity, String code) async {
    await client.auth.verifyOTP(
      email: phone(identity) ? null : identity,
      phone: phone(identity) ? identity : null,
      token: code,
      type: phone(identity) ? OtpType.sms : OtpType.signup,
    );
  }

  @override
  Future<void> resend(String identity) async {
    await client.auth.resend(
      email: phone(identity) ? null : identity,
      phone: phone(identity) ? identity : null,
      type: phone(identity) ? OtpType.sms : OtpType.signup,
    );
  }

  @override
  Future<void> resetPassword(String email) =>
      client.auth.resetPasswordForEmail(email, redirectTo: redirectTo);
  @override
  Future<void> updatePassword(String password) async {
    await client.auth.updateUser(UserAttributes(password: password));
    _recovering = false;
  }

  @override
  Future<void> signOut() => client.auth.signOut();
  @override
  Future<dynamic> read(String name, [JsonObject params = const {}]) async {
    try {
      if (name.startsWith('edge:')) {
        final result = await client.functions.invoke(
          name.substring(5),
          body: params,
        );
        return result.data;
      }
      return await client.rpc(name, params: params);
    } on PostgrestException catch (e) {
      throw WasteBackendException(
        RegExp(r'^[A-Z_]+$').hasMatch(e.message)
            ? e.message
            : 'REQUEST_REJECTED',
      );
    } on FunctionException catch (e) {
      throw WasteBackendException(
        e.details is Map
            ? e.details['error']?.toString() ?? 'SERVICE_UNAVAILABLE'
            : 'SERVICE_UNAVAILABLE',
      );
    }
  }

  @override
  Future<JsonObject> command(
    String action,
    JsonObject payload, {
    bool onboarding = false,
  }) async {
    final user = userId;
    if (user == null) {
      throw const WasteBackendException('AUTHENTICATION_REQUIRED');
    }
    return journal.send(
      user,
      WasteCommand(action: action, payload: payload),
      onboarding,
      (command, onboarding) => onboarding
          ? backend.executeOnboarding(command)
          : backend.execute(command),
    );
  }

  @override
  Future<void> upload(
    String bucket,
    String path,
    Uint8List bytes,
    String mime,
  ) async {
    await client.storage
        .from(bucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: false),
        );
  }

  @override
  Future<String?> pendingAction() async => userId == null
      ? null
      : (await journal.pending(userId!))?['command']?['action'] as String?;
  @override
  Future<void> retryPending() async {
    final user = userId;
    if (user == null) return;
    final pending = await journal.pending(user);
    if (pending == null) return;
    await journal.send(
      user,
      WasteCommand.fromJson(Map<String, dynamic>.from(pending['command'])),
      pending['onboarding'] as bool,
      (command, onboarding) => onboarding
          ? backend.executeOnboarding(command)
          : backend.execute(command),
      retry: true,
    );
  }
}

String friendlyError(Object error) {
  if (error is AuthException) return error.message;
  if (error is WasteBackendException) {
    return switch (error.code) {
      'COMMAND_PENDING' => 'An earlier action needs checking. Use “Check pending action” before continuing.',
      'VERSION_CONFLICT' =>
        'This collection has changed. Refresh and review its latest status.',
      'QUOTE_EXPIRED' =>
        'This quote expired. Get a fresh quote and review the price.',
      'OFFER_EXPIRED' =>
        'This offer is no longer available. Refresh your work.',
      'STALE_LOCATION' =>
        'A fresh, accurate location is needed. Enable GPS and try again.',
      'PAYMENT_PROVIDER_NOT_CONFIGURED' =>
        'Mobile money is not available yet. Cash is supported.',
      'PRICING_NOT_CONFIGURED' =>
        'Transport pricing is not ready yet. Please try again later.',
      'ROUTING_NOT_CONFIGURED' => 'Travel estimates are not available yet.',
      'SERVICE_CATEGORY_UNAVAILABLE' =>
        'This collection service is not currently available.',
      'OUTSIDE_SERVICE_AREA' =>
        'This pickup is outside the current service area.',
      'AUTHENTICATION_REQUIRED' =>
        'Please sign in again. Your account may need verification.',
      'FORBIDDEN' => 'Your account does not have access to this action.',
      'UNRESOLVED_CUSTODY' => 'Some pickups still need warehouse confirmation. Contact your operator.',
      'INVALID_QR' || 'QR_EXPIRED_OR_USED' =>
        'This code is expired, already used, or not for your warehouse.',
      'DRIVER_DOCUMENT_APPROVAL_REQUIRED' =>
        'Your documents need firm approval before you can take jobs.',
      'LOCATION_PERMISSION' => 'Location permission is needed. Enable it in your device settings or enter a pickup pin manually.',
      'LOCATION_DISABLED' => 'Turn on location services and try again.',
      'PROTOTYPE_NAVIGATION' => 'This prototype uses an illustrative map. Live mode opens navigation to the verified pickup or warehouse.',
      'FILE_TOO_LARGE' => 'Choose a supported file smaller than 10 MB.',
      _ =>
        'This action could not be completed. Refresh and try again. (${error.code.toLowerCase().replaceAll('_', ' ')})',
    };
  }
  return 'Connection interrupted. Refresh to check the latest status. An action may still be pending.';
}
