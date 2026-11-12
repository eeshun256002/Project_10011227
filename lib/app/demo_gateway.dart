import 'dart:async';
import 'dart:typed_data';

import '../backend/waste_backend.dart';
import 'gateway.dart';

/// Isolated, explicitly labelled prototype. Never constructs a Supabase client.
class DemoGateway extends AppGateway {
  DemoGateway();
  final _auth = StreamController<void>.broadcast();
  String? _user;
  bool registered = false;
  bool provisioned = true;
  bool online = false;
  String load = 'available';
  final List<JsonObject> orders = [];
  JsonObject? application;
  bool hasOffer = true;
  @override
  bool get demo => true;
  @override
  String? get userId => _user;
  @override
  String get identity => 'Prototype account';
  @override
  Stream<void> get authChanges => _auth.stream;
  @override
  Future<void> authenticate(
    String identity,
    String password, {
    bool signup = false,
  }) async {
    _user = 'prototype';
    provisioned = !signup;
    registered = !signup;
    _auth.add(null);
  }

  @override
  Future<void> verify(String identity, String code) async {}
  @override
  Future<void> resend(String identity) async {}
  @override
  Future<void> resetPassword(String email) async {}
  @override
  Future<void> updatePassword(String password) async {}
  @override
  Future<void> signOut() async {
    _user = null;
    _auth.add(null);
  }

  JsonObject sampleOrder() => {
    'id': 'preview-collection-${orders.length + 1}',
    'version': 1,
    'state': 'accepted',
    'category': 'non_biodegradable',
    'address': 'Boundary Road, East Legon',
    'access_note': 'Use the main gate',
    'latitude': 5.640,
    'longitude': -0.160,
    'transport_minor': 2400,
    'booking_minor': 100,
    'waiting_minor': 0,
    'total_minor': 2500,
    'payment_status': null,
    'driver_id': 'preview-driver',
    'created_at': DateTime.now().toUtc().toIso8601String(),
  };
  @override
  Future<dynamic> read(String name, [JsonObject params = const {}]) async {
    switch (name) {
      case 'wm_catalog':
        return {
          'bookings_enabled': true,
          'booking_minor': 100,
          'waiting_rate_minor': 90,
          'waiting_grace_seconds': 300,
          'mobile_money_ready': false,
          'categories': [
            {
              'code': 'non_biodegradable',
              'enabled': true,
              'pricing_ready': true,
            },
            {
              'code': 'biodegradable',
              'enabled': false,
              'receiver_pending': true,
            },
          ],
          'warehouses': [
            {'name': 'Coliba / Lapaz Buyback Center'},
          ],
        };
      case 'wm_account_access':
        return {
          'client_registered': registered,
          'driver_provisioned': provisioned,
          'driver_can_take_jobs': provisioned,
        };
      case 'wm_staff_access':
        return {
          'operator': false,
          'warehouses': [
            {'id': 'preview', 'name': 'Prototype receiving warehouse'},
          ],
        };
      case 'wm_driver_status':
        return {
          'online': online,
          'load_state': load,
          'location_sequence': 1,
          'can_take_jobs': true,
          'vehicle': {'plate': 'PREVIEW'},
        };
      case 'wm_my_driver_application':
        return application;
      case 'wm_active_orders':
        return params['p_before'] != null
            ? <JsonObject>[]
            : orders
                  .where(
                    (o) =>
                        !['cancelled', 'failed'].contains(o['state']) &&
                        o['warehouse_confirmed_at'] == null,
                  )
                  .toList();
      case 'wm_list_orders':
        return params['p_before'] != null ? <JsonObject>[] : orders;
      case 'wm_my_offers':
        return online && hasOffer
            ? [
                {
                  'offer_id': 'preview-offer',
                  'area': 'East Legon',
                  'category': 'non_biodegradable',
                  'expires_at': DateTime.now()
                      .add(const Duration(minutes: 2))
                      .toUtc()
                      .toIso8601String(),
                },
              ]
            : [];
      case 'wm_get_order':
        return orders.firstWhere((o) => o['id'] == params['p_order_id']);
      case 'wm_order_presentation':
        final o = orders.firstWhere((o) => o['id'] == params['p_order_id']);
        return {
          'order': o,
          'driver': o['state'] == 'searching'
              ? null
              : {'display_name': 'Prototype driver', 'plate': 'PREVIEW'},
          'payments': [],
          'handoffs': [],
        };
      case 'wm_tracking':
        return {
          'available': true,
          'latitude': 5.638,
          'longitude': -0.162,
          'measured_at': DateTime.now().toUtc().toIso8601String(),
        };
      case 'edge:wm-quote':
        return {
          'quote_id': 'preview-quote',
          'transport_minor': 2400,
          'booking_minor': 100,
          'estimated_total_minor': 2500,
          'expires_at': DateTime.now()
              .add(const Duration(minutes: 5))
              .toUtc()
              .toIso8601String(),
        };
      case 'edge:wm-eta':
        return {
          'duration_s': 240,
          'calculated_at': DateTime.now().toUtc().toIso8601String(),
        };
      case 'wm_driver_destination':
        return {
          'name': 'Coliba / Lapaz Buyback Center',
          'address': 'Abeka Lapaz, Accra',
          'latitude': 5.60601,
          'longitude': -0.24717,
        };
      case 'wm_preview_handoff':
        return {
          'order_id': 'preview-collection',
          'category': 'non_biodegradable',
          'warehouse_id': 'preview',
          'collected_at': DateTime.now().toUtc().toIso8601String(),
        };
      default:
        return <JsonObject>[];
    }
  }

  @override
  Future<JsonObject> command(
    String action,
    JsonObject payload, {
    bool onboarding = false,
  }) async {
    if (action == 'client.register') registered = true;
    if (action == 'application.save') {
      application = {
        ...payload,
        'version': 1,
        'status': 'draft',
        'documents': [],
      };
    }
    if (action == 'application.reopen') application!['status'] = 'draft';
    if (action == 'application.submit') application!['status'] = 'submitted';
    if (action == 'document.reserve') {
      (application!['documents'] as List).removeWhere(
        (d) => d['kind'] == payload['kind'],
      );
      (application!['documents'] as List).add({
        ...payload,
        'id': payload['kind'],
        'uploaded_at': 'preview',
        'review_status': 'pending',
      });
      return {
        'document_id': payload['kind'],
        'bucket': 'preview',
        'path': 'preview',
        'version': application!['version'],
      };
    }
    if (action == 'driver.availability') online = payload['online'] as bool;
    if (action == 'driver.load') load = payload['load_state'] as String;
    if (action == 'booking.submit') {
      final o = sampleOrder()
        ..addAll({
          'state': 'searching',
          'address': payload['address'],
          'access_note': payload['access_note'] ?? '',
        });
      orders.add(o);
      return o;
    }
    if (action == 'offer.decline') hasOffer = false;
    if (action == 'offer.accept') {
      hasOffer = false;
      final o = sampleOrder();
      orders.add(o);
      return o;
    }
    if (action == 'handoff.issue') {
      return {
        'token': 'MOHOTEW-PROTOTYPE-ONLY',
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 5))
            .toUtc()
            .toIso8601String(),
      };
    }
    if (action == 'evidence.reserve') {
      return {'bucket': 'preview', 'path': 'preview', 'evidence_id': 'preview'};
    }
    if (action == 'incident.report') return {'incident_id': 'prototype-report'};
    if (payload['order_id'] != null && orders.isNotEmpty) {
      final o = orders.firstWhere((o) => o['id'] == payload['order_id']);
      final now = DateTime.now().toUtc().toIso8601String();
      switch (action) {
        case 'booking.cancel':
          o['state'] = 'cancelled';
        case 'driver.travel':
          o['state'] = 'en_route';
        case 'driver.arrive':
          o.addAll({'state': 'arrived', 'arrived_at': now});
        case 'driver.start_loading':
          o.addAll({'state': 'loading', 'ready_at': now});
        case 'driver.collect':
          o.addAll({'state': 'collected', 'collected_at': now});
        case 'payment.cash':
          o['payment_status'] = 'paid';
        case 'driver.depart':
          o['departed_at'] = now;
      }
      o['version'] = (o['version'] as int) + 1;
      return o;
    }
    return application ?? {'updated': true};
  }

  @override
  Future<void> upload(
    String bucket,
    String path,
    Uint8List bytes,
    String mime,
  ) async {}
  @override
  Future<String?> pendingAction() async => null;
  @override
  Future<void> retryPending() async {}
}
