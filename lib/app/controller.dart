import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../backend/waste_backend.dart';
import 'gateway.dart';

JsonObject object(dynamic value) => Map<String, dynamic>.from(value as Map);
List<JsonObject> objects(dynamic value) => (value as List).map(object).toList();
String money(dynamic minor) =>
    'GH₵${((minor as num? ?? 0) / 100).toStringAsFixed(2)}';
String categoryName(dynamic code) =>
    code == 'biodegradable' ? 'Biodegradable' : 'Non-biodegradable';
String orderLabel(JsonObject o) {
  if (o['warehouse_confirmed_at'] != null) return 'Warehouse confirmed';
  if (o['departed_at'] != null) return 'Awaiting warehouse receipt';
  return switch (o['state']) {
    'searching' => 'Finding your driver',
    'accepted' => 'Driver assigned',
    'en_route' => 'Driver on the way',
    'arrived' => 'Driver has arrived',
    'loading' => 'Loading your collection',
    'collected' => 'Collection recorded',
    'failed' => 'Visit could not be completed',
    'cancelled' => 'Cancelled',
    _ => 'Checking collection',
  };
}

class AppController extends ChangeNotifier {
  AppController(this.gateway, this.kind);
  final AppGateway gateway;
  final AppKind kind;
  bool loading = true, refreshing = false;
  bool _disposed = false;
  String? error, pending, locationError;
  JsonObject catalog = {}, access = {}, driver = {}, staff = {};
  List<JsonObject> active = [], offers = [];
  StreamSubscription<void>? _auth;
  StreamSubscription<Position>? _positions;
  Timer? _poll;
  bool _sendingPosition = false;
  int _sequence = 0;
  String? _session;
  bool get signedIn => gateway.userId != null;
  bool get serviceReady => catalog['bookings_enabled'] == true;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    _auth = gateway.authChanges.listen((_) => refresh());
    await refresh();
    if (_disposed) return;
    _poll = Timer.periodic(
      const Duration(seconds: 8),
      (_) => refresh(silent: true),
    );
  }

  void pause() {
    _poll?.cancel();
    _poll = null;
  }

  void resume() {
    refresh();
    _poll ??= Timer.periodic(
      const Duration(seconds: 8),
      (_) => refresh(silent: true),
    );
  }

  Future<void> refresh({bool silent = false}) async {
    if (refreshing || _disposed) return;
    refreshing = true;
    final current = gateway.userId;
    if (_session != current) {
      active = [];
      offers = [];
      access = {};
      driver = {};
      staff = {};
      pending = null;
      _session = current;
      await _positions?.cancel();
      _positions = null;
    }
    try {
      final nextCatalog = object(await gateway.read('wm_catalog'));
      if (current != gateway.userId) return;
      catalog = nextCatalog;
      if (current != null) {
        final nextAccess = object(await gateway.read('wm_account_access'));
        final nextStaff = object(await gateway.read('wm_staff_access'));
        if (current != gateway.userId) return;
        access = nextAccess;
        staff = nextStaff;
        pending = await gateway.pendingAction();
        if (kind == AppKind.client ||
            (kind == AppKind.driver && access['driver_provisioned'] == true)) {
          final restored = <JsonObject>[];
          JsonObject? cursor;
          while (true) {
            final page = objects(
              await gateway.read('wm_active_orders', {
                'p_app': kind.name,
                'p_limit': 100,
                if (cursor != null) 'p_before': cursor['created_at'],
                if (cursor != null) 'p_before_id': cursor['id'],
              }),
            );
            restored.addAll(page);
            if (page.length < 100) break;
            cursor = page.last;
          }
          if (current != gateway.userId) return;
          active = restored;
        }
        if (kind == AppKind.driver && access['driver_provisioned'] == true) {
          driver = object(await gateway.read('wm_driver_status'));
          offers = objects(await gateway.read('wm_my_offers'));
          _sequence = (driver['location_sequence'] as num? ?? -1).toInt();
          // Only restart an already-authorized location stream; never prompt on boot.
          if (driver['online'] == true &&
              !gateway.demo &&
              _positions == null &&
              await Geolocator.checkPermission() != LocationPermission.denied &&
              await Geolocator.checkPermission() !=
                  LocationPermission.deniedForever) {
            _startLocation();
          }
          if (driver['online'] != true) {
            await _positions?.cancel();
            _positions = null;
          }
        }
      }
      error = null;
    } catch (e) {
      error = friendlyError(e);
    } finally {
      refreshing = false;
      loading = false;
      changed();
    }
  }

  Future<JsonObject> act(
    String action,
    JsonObject payload, {
    bool onboarding = false,
  }) async {
    try {
      return await gateway.command(action, payload, onboarding: onboarding);
    } finally {
      await refresh();
    }
  }

  Future<Position> locate() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const WasteBackendException('LOCATION_DISABLED');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const WasteBackendException('LOCATION_PERMISSION');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 25),
      ),
    );
  }

  Future<void> setOnline(bool online) async {
    final position = online && !gateway.demo ? await locate() : null;
    await act('driver.availability', {'online': online});
    if (position != null) {
      await _sendPosition(position);
      _startLocation();
    }
  }

  void _startLocation() {
    if (_positions != null || _disposed) return;
    final settings = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
            intervalDuration: const Duration(seconds: 15),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Mohotew Driver is online',
              notificationText: 'Sharing your location for collection work.',
              enableWakeLock: true,
            ),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          );
    _positions = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
          (p) => _sendPosition(p),
          onError: (Object e) {
            locationError = friendlyError(e);
            changed();
          },
        );
  }

  Future<void> _sendPosition(Position p) async {
    if (_sendingPosition) return;
    _sendingPosition = true;
    try {
      // GPS is ephemeral: fresh read recovers sequence after reinstall or races.
      final current = object(await gateway.read('wm_driver_status'));
      _sequence = (current['location_sequence'] as num).toInt() + 1;
      if (gateway is LiveGateway) {
        await (gateway as LiveGateway).backend.execute(
          WasteCommand(
            action: 'driver.location',
            payload: {
              'latitude': p.latitude,
              'longitude': p.longitude,
              'accuracy_m': p.accuracy,
              'measured_at': p.timestamp.toUtc().toIso8601String(),
              'sequence': _sequence,
            },
          ),
        );
      }
      locationError = null;
    } catch (e) {
      locationError = friendlyError(e);
    } finally {
      _sendingPosition = false;
      changed();
    }
  }

  Future<void> refreshLocation() async {
    if (!gateway.demo) await _sendPosition(await locate());
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _auth?.cancel();
    _positions?.cancel();
    super.dispose();
  }
}
