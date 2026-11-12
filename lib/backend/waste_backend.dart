import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

typedef JsonObject = Map<String, dynamic>;

/// Keep the same instance/key for an uncertain network retry. Persist [toJson]
/// before sending mutations from an offline-capable screen.
class WasteCommand {
  WasteCommand({required this.action, required JsonObject payload, String? key})
    : payload = Map.unmodifiable(payload),
      key = key ?? _uuid();

  factory WasteCommand.fromJson(JsonObject json) => WasteCommand(
    action: json['action'] as String,
    payload: Map<String, dynamic>.from(json['payload'] as Map),
    key: json['key'] as String,
  );

  final String action;
  final JsonObject payload;
  final String key;

  JsonObject toJson() => {'action': action, 'payload': payload, 'key': key};

  static String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class WasteBackendException implements Exception {
  const WasteBackendException(this.code);
  final String code;

  /// An uncertain network result needs reconciliation with the original command
  /// key, not a new booking or payment command.
  bool get needsRefresh => const {
    'VERSION_CONFLICT',
    'OFFER_EXPIRED',
    'QUOTE_EXPIRED',
    'RESOURCE_CONFLICT',
    'PAYMENT_RECONCILIATION_REQUIRED',
  }.contains(code);

  @override
  String toString() => 'WasteBackendException($code)';
}

/// Application API only: prices, permissions and transitions stay in Postgres.
/// Sign in through [SupabaseClient.auth] before calling authenticated methods.
class WasteBackend {
  WasteBackend(this.client);
  final SupabaseClient client;

  Future<T> _call<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PostgrestException catch (error) {
      final code = RegExp(r'^[A-Z][A-Z0-9_]{2,100}$').hasMatch(error.message)
          ? error.message
          : error.code == '23505'
          ? 'RESOURCE_CONFLICT'
          : error.code == '42501'
          ? 'FORBIDDEN'
          : 'REQUEST_REJECTED';
      throw WasteBackendException(code);
    } on FunctionException catch (error) {
      final details = error.details;
      throw WasteBackendException(
        details is Map && details['error'] is String
            ? details['error'] as String
            : 'SERVICE_UNAVAILABLE',
      );
    }
    // Transport exceptions intentionally propagate: the caller cannot assume
    // the mutation failed and must reuse its persisted command key.
  }

  Future<JsonObject> _rpc(String name, [JsonObject params = const {}]) => _call(
    () async => Map<String, dynamic>.from(
      await client.rpc(name, params: params) as Map,
    ),
  );

  Future<JsonObject> catalog() => _rpc('wm_catalog');

  Future<JsonObject> quote({
    required String category,
    required double latitude,
    required double longitude,
  }) => _call(() async {
    final result = await client.functions.invoke(
      'wm-quote',
      body: {
        'category': category,
        'latitude': latitude,
        'longitude': longitude,
      },
    );
    return Map<String, dynamic>.from(result.data as Map);
  });

  Future<JsonObject> execute(WasteCommand command) => _rpc('wm_command', {
    'p_action': command.action,
    'p_payload': command.payload,
    'p_command_key': command.key,
  });

  Future<JsonObject> executeOnboarding(WasteCommand command) =>
      _rpc('wm_onboarding_command', {
        'p_action': command.action,
        'p_payload': command.payload,
        'p_command_key': command.key,
      });

  Future<JsonObject> accountAccess() => _rpc('wm_account_access');

  Future<JsonObject> driverStatus() => _rpc('wm_driver_status');

  Future<JsonObject> staffAccess() => _rpc('wm_staff_access');

  /// Foreground status catch-up, not push delivery. Offers are fetched separately.
  Future<List<JsonObject>> updates({int afterId = 0, int limit = 50}) => _call(
    () async => (await client.rpc(
      'wm_updates',
      params: {'p_after_id': afterId, 'p_limit': limit},
    ) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
  );

  Future<JsonObject> orderPresentation(String id) =>
      _rpc('wm_order_presentation', {'p_order_id': id});

  /// Fetch pages until a short page is returned; cursor uses both fields of
  /// the last row so pickups sharing a timestamp are not skipped.
  Future<List<JsonObject>> activeOrders({
    required String app,
    DateTime? before,
    String? beforeId,
    int limit = 30,
  }) => _call(
    () async => (await client.rpc(
      'wm_active_orders',
      params: {
        'p_app': app,
        'p_before': before?.toUtc().toIso8601String(),
        'p_before_id': beforeId,
        'p_limit': limit,
      },
    ) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
  );

  /// On-demand traffic-aware approach estimate; never a fare or arrival promise.
  Future<JsonObject> eta(String orderId) => _call(() async {
    final result = await client.functions.invoke(
      'wm-eta',
      body: {'order_id': orderId},
    );
    return Map<String, dynamic>.from(result.data as Map);
  });

  Future<JsonObject?> myDriverApplication() => _call(() async {
    final result = await client.rpc('wm_my_driver_application');
    return result == null ? null : Map<String, dynamic>.from(result as Map);
  });

  Future<JsonObject> driverApplication(String id) =>
      _rpc('wm_driver_application', {'p_application_id': id});

  Future<JsonObject> order(String id) =>
      _rpc('wm_get_order', {'p_order_id': id});
  Future<JsonObject> tracking(String id) =>
      _rpc('wm_tracking', {'p_order_id': id});
  Future<JsonObject> previewHandoff(String token) =>
      _rpc('wm_preview_handoff', {'p_token': token});
  Future<JsonObject> warehouseDestination() => _rpc('wm_driver_destination');

  Future<List<JsonObject>> orders({DateTime? before, int limit = 30}) => _call(
    () async => (await client.rpc(
      'wm_list_orders',
      params: {'p_before': before?.toUtc().toIso8601String(), 'p_limit': limit},
    ) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
  );

  Future<List<JsonObject>> offers() => _call(
    () async => (await client.rpc('wm_my_offers') as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
  );
}
