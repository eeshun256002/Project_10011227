import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app/controller.dart';
import '../backend/waste_backend.dart';
import 'design.dart';
import 'pickup_map.dart';
import 'collection.dart';

class BookingScreen extends StatefulWidget {
  const BookingScreen(this.controller, {super.key, this.replacementOf});
  final AppController controller;
  final String? replacementOf;
  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  final form = GlobalKey<FormState>();
  final address = TextEditingController(),
      note = TextEditingController(),
      lat = TextEditingController(),
      lng = TextEditingController();
  int step = 0;
  String category = 'non_biodegradable';
  JsonObject? quote;
  Timer? ticker;
  bool ready = false;
  String get draftKey => 'mohotew.pickup.${widget.controller.gateway.userId}';
  @override
  void initState() {
    super.initState();
    restore();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && step == 2) setState(() {});
    });
  }

  Future<void> restore() async {
    if (widget.controller.gateway.demo) {
      address.text = 'Boundary Road, East Legon';
      lat.text = '5.64';
      lng.text = '-0.16';
    } else {
      try {
        final saved = await const FlutterSecureStorage().read(key: draftKey);
        if (saved != null) {
          final d = jsonDecode(saved);
          address.text = d['address'];
          note.text = d['note'];
          lat.text = d['lat'];
          lng.text = d['lng'];
        }
      } catch (_) {}
    }
    if (mounted) setState(() => ready = true);
  }

  Future<void> save() async {
    if (!widget.controller.gateway.demo) {
      await const FlutterSecureStorage().write(
        key: draftKey,
        value: jsonEncode({
          'address': address.text,
          'note': note.text,
          'lat': lat.text,
          'lng': lng.text,
        }),
      );
    }
  }

  @override
  void dispose() {
    ticker?.cancel();
    address.dispose();
    note.dispose();
    lat.dispose();
    lng.dispose();
    super.dispose();
  }

  bool get validQuote =>
      quote != null &&
      DateTime.tryParse(quote!['expires_at'].toString())
              ?.isAfter(DateTime.now()) ==
          true;
  bool get categoryReady =>
      objects(widget.controller.catalog['categories'] ?? []).any(
        (c) =>
            c['code'] == category &&
            c['enabled'] == true &&
            c['pricing_ready'] == true,
      );
  Future<void> getQuote() async {
    final result = object(
      await widget.controller.gateway.read('edge:wm-quote', {
        'category': category,
        'latitude': double.parse(lat.text),
        'longitude': double.parse(lng.text),
      }),
    );
    if (mounted) {
      setState(() {
        quote = result;
        step = 2;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Request collection'),
      leading: IconButton(
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          if (step > 0) {
            setState(() => step--);
          } else {
            Navigator.pop(context);
          }
        },
      ),
    ),
    body: !ready
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: List.generate(
                  3,
                  (i) => Expanded(
                    child: Container(
                      height: 4,
                      margin: const EdgeInsets.only(right: 6, bottom: 24),
                      decoration: BoxDecoration(
                        color: i <= step ? green : const Color(0xFFDDE5DF),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              if (step == 0) ...[
                sectionTitle(
                  context,
                  'Where’s the pickup?',
                  'Confirm your exact pickup point. Add a landmark to help your driver.',
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: SizedBox(
                    height: 220,
                    child: PickupMap(
                      demo: widget.controller.gateway.demo,
                      latitude: double.tryParse(lat.text) ?? 5.64,
                      longitude: double.tryParse(lng.text) ?? -.16,
                      onPick: (p) => setState(() {
                        lat.text = p.latitude.toStringAsFixed(6);
                        lng.text = p.longitude.toStringAsFixed(6);
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ActionButton(
                  'Use my current location',
                  icon: Icons.my_location,
                  onPressed: () async {
                    if (widget.controller.gateway.demo) {
                      setState(() {
                        lat.text = '5.64';
                        lng.text = '-0.16';
                      });
                      return;
                    }
                    final p = await widget.controller.locate();
                    if (mounted) {
                      setState(() {
                        lat.text = p.latitude.toStringAsFixed(6);
                        lng.text = p.longitude.toStringAsFixed(6);
                      });
                    }
                  },
                ),
                const SizedBox(height: 20),
                Form(
                  key: form,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: address,
                        decoration: const InputDecoration(
                          labelText: 'Pickup address / landmark',
                        ),
                        maxLength: 500,
                        validator: (v) => (v?.trim().length ?? 0) < 3
                            ? 'Enter your pickup address'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: lat,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                    signed: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Latitude',
                              ),
                              validator: (v) => coordinate(v, 90),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: lng,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                    signed: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Longitude',
                              ),
                              validator: (v) => coordinate(v, 180),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: note,
                        decoration: const InputDecoration(
                          labelText: 'Access note (optional)',
                          hintText: 'Gate, floor or parking instructions',
                        ),
                        maxLength: 2000,
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ActionButton(
                  'Confirm pickup point',
                  onPressed: () async {
                    if (form.currentState!.validate()) {
                      await save();
                      if (mounted) setState(() => step = 1);
                    }
                  },
                ),
              ],
              if (step == 1) ...[
                sectionTitle(
                  context,
                  'What are we collecting?',
                  'Choose a service. No weighing or measuring needed.',
                ),
                for (final c in objects(
                  widget.controller.catalog['categories'] ?? [],
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: c['enabled'] == true
                          ? () => setState(() => category = c['code'])
                          : null,
                      child: Panel(
                        color: category == c['code'] && c['enabled'] == true
                            ? const Color(0xFFD9F7E8)
                            : Colors.white,
                        child: Row(
                          children: [
                            Icon(
                              c['code'] == 'biodegradable'
                                  ? Icons.compost
                                  : Icons.recycling,
                              size: 36,
                              color: c['enabled'] == true ? ink : muted,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    categoryName(c['code']),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    c['enabled'] == true
                                        ? 'Collection to an approved receiving partner'
                                        : 'Unavailable · receiving partner pending',
                                    style: const TextStyle(color: muted),
                                  ),
                                ],
                              ),
                            ),
                            if (c['enabled'] == true)
                              Icon(
                                category == c['code']
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                const Notice(
                  'The final transport price is shown before you request. Waiting charges may apply after arrival.',
                ),
                const SizedBox(height: 24),
                ActionButton(
                  'See price',
                  onPressed: widget.controller.serviceReady && categoryReady
                      ? getQuote
                      : null,
                ),
                if (!widget.controller.serviceReady || !categoryReady)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Notice(
                      'Collections are not open for booking yet. Your pickup details are saved.',
                    ),
                  ),
              ],
              if (step == 2 && quote != null) ...[
                sectionTitle(
                  context,
                  'Your collection,\npriced clearly.',
                  widget.controller.gateway.demo
                      ? 'Illustrative prototype price. No real charge.'
                      : 'Review your quote before requesting a driver.',
                ),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tag(categoryName(category)),
                      const SizedBox(height: 18),
                      Text(
                        money(quote!['estimated_total_minor']),
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Before any eligible waiting',
                        style: TextStyle(color: muted),
                      ),
                      const Divider(height: 32),
                      detailRow('Transport', money(quote!['transport_minor'])),
                      detailRow('Booking fee', money(quote!['booking_minor'])),
                      detailRow('Payment', 'Cash at pickup'),
                      const SizedBox(height: 12),
                      Text(
                        address.text,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Notice(
                  'First 5 minutes of waiting are free. After that: GH₵0.90/minute until loading starts. Loading and payment time are excluded.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'MTN MoMo and Telecel Cash are not available yet.',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                if (!validQuote) ...[
                  const Notice(
                    'This quote expired. Review a fresh price to continue.',
                  ),
                  const SizedBox(height: 16),
                  ActionButton('Refresh quote', onPressed: getQuote),
                ] else
                  ActionButton(
                    'Request collection',
                    onPressed: () async {
                      if (!validQuote) {
                        throw const WasteBackendException('QUOTE_EXPIRED');
                      }
                      final o = await widget.controller.act('booking.submit', {
                        'quote_id': quote!['quote_id'],
                        'address': address.text.trim(),
                        'access_note': note.text.trim(),
                        if (widget.replacementOf != null)
                          'replacement_of': widget.replacementOf,
                      });
                      if (!widget.controller.gateway.demo) {
                        await const FlutterSecureStorage().delete(
                          key: draftKey,
                        );
                      }
                      if (!context.mounted) return;
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              CollectionScreen(widget.controller, id: o['id']),
                        ),
                      );
                    },
                  ),
              ],
            ],
          ),
  );
  String? coordinate(String? value, int bound) {
    final v = double.tryParse(value ?? '');
    return v == null || !v.isFinite || v.abs() > bound
        ? 'Enter a valid coordinate'
        : null;
  }
}
