import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/controller.dart';
import '../app/gateway.dart';
import '../app/demo_gateway.dart';
import '../backend/waste_backend.dart';
import 'design.dart';
import 'pickup_map.dart';
import 'booking.dart';

class CollectionScreen extends StatefulWidget {
  const CollectionScreen(this.controller, {super.key, required this.id});
  final AppController controller;
  final String id;
  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen>
    with WidgetsBindingObserver {
  JsonObject? order, driver, tracking, eta;
  List<JsonObject> handoffs = [];
  String? error;
  bool fetching = false;
  Timer? poll, tick;
  bool get isDriver => widget.controller.kind == AppKind.driver;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    poll = Timer.periodic(const Duration(seconds: 8), (_) => load());
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    poll?.cancel();
    tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      load();
      poll ??= Timer.periodic(const Duration(seconds: 8), (_) => load());
    } else {
      poll?.cancel();
      poll = null;
    }
  }

  Future<void> load() async {
    if (fetching) return;
    fetching = true;
    try {
      final p = object(
        await widget.controller.gateway.read('wm_order_presentation', {
          'p_order_id': widget.id,
        }),
      );
      final o = object(p['order']);
      JsonObject? position;
      if (['accepted', 'en_route', 'arrived'].contains(o['state'])) {
        position = object(
          await widget.controller.gateway.read('wm_tracking', {
            'p_order_id': widget.id,
          }),
        );
      }
      if (mounted) {
        setState(() {
          order = o;
          driver = p['driver'] == null ? null : object(p['driver']);
          tracking = position;
          handoffs = objects(p['handoffs'] ?? []);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      fetching = false;
    }
  }

  Future<void> action(String action, [JsonObject extra = const {}]) async {
    try {
      await widget.controller.act(action, {
        'order_id': widget.id,
        'version': order!['version'],
        ...extra,
      });
    } finally {
      await load();
    }
  }

  Future<void> evidence() async {
    if (widget.controller.gateway.demo) {
      await action('driver.collect');
      return;
    }
    final file = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
      maxWidth: 2000,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 10485760) {
      throw const WasteBackendException('FILE_TOO_LARGE');
    }
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use this collection photo?'),
        content: Image.memory(bytes),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Retake'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final reservation = await widget.controller.act('evidence.reserve', {
      'order_id': widget.id,
      'version': order!['version'],
      'purpose': 'pickup',
    });
    final mime = file.name.toLowerCase().endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';
    await widget.controller.gateway.upload(
      reservation['bucket'],
      reservation['path'],
      bytes,
      mime,
    );
    await widget.controller.act('evidence.finalize', {
      'evidence_id': reservation['evidence_id'],
    });
    await load();
    await action('driver.collect');
  }

  String waitingText() {
    final arrived = DateTime.tryParse(order?['arrived_at']?.toString() ?? '');
    if (arrived == null) return 'Waiting starts after confirmed arrival.';
    final end =
        DateTime.tryParse(order?['ready_at']?.toString() ?? '') ??
        DateTime.now();
    final seconds = end.difference(arrived).inSeconds.clamp(0, 86400);
    if (order?['ready_at'] != null) {
      return 'Waiting stopped when loading started.';
    }
    if (seconds < 300) {
      return '${((300 - seconds) / 60).ceil()} min of free waiting remaining';
    }
    return '${((seconds - 300) / 60).floor()} min ${((seconds - 300) % 60)} sec after the free period. Final waiting amount is calculated by the server.';
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collection details'),
        actions: [
          IconButton(
            tooltip: 'Refresh collection',
            onPressed: load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: o == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Notice(error!, action: load),
                    ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (error != null) ...[
                  Notice(error!, action: load),
                  const SizedBox(height: 16),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: Tag(categoryName(o['category'])),
                ),
                const SizedBox(height: 16),
                sectionTitle(context, orderLabel(o), o['address']?.toString()),
                if ([
                  'accepted',
                  'en_route',
                  'arrived',
                ].contains(o['state'])) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: SizedBox(
                      height: 220,
                      child: PickupMap(
                        demo: widget.controller.gateway.demo,
                        latitude: (o['latitude'] as num).toDouble(),
                        longitude: (o['longitude'] as num).toDouble(),
                        driver: tracking?['available'] == true
                            ? LatLng(
                                (tracking!['latitude'] as num).toDouble(),
                                (tracking!['longitude'] as num).toDouble(),
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tracking?['available'] == true
                        ? 'Location updated ${tracking!['measured_at']}'
                        : 'Live driver location is currently unavailable.',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                ],
                if (driver != null && !isDriver)
                  Panel(
                    child: Row(
                      children: [
                        const CircleAvatar(
                          radius: 26,
                          backgroundColor: Color(0xFFD9F7E8),
                          child: Icon(Icons.person_outline, color: ink),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                driver!['display_name'] ?? 'Assigned driver',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                              ),
                              Text(
                                driver!['plate'] ?? '',
                                style: const TextStyle(color: muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (['accepted', 'en_route'].contains(o['state'])) ...[
                  const SizedBox(height: 12),
                  ActionButton(
                    'Check arrival estimate',
                    onPressed: () async {
                      final value = object(
                        await widget.controller.gateway.read('edge:wm-eta', {
                          'order_id': widget.id,
                        }),
                      );
                      if (mounted) setState(() => eta = value);
                    },
                  ),
                  if (eta != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        'About ${((eta!['duration_s'] as num) / 60).ceil()} min · estimate checked ${eta!['calculated_at']}',
                        style: const TextStyle(color: muted),
                      ),
                    ),
                ],
                if (o['state'] == 'searching') ...[
                  const Panel(
                    child: Column(
                      children: [
                        Icon(Icons.radar, size: 64, color: Color(0xFF15995D)),
                        SizedBox(height: 14),
                        Text(
                          'Looking for an available driver',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'We’ll show your driver here once your request is accepted.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!isDriver)
                    ActionButton(
                      'Cancel request',
                      onPressed: () async {
                        if (await confirm(
                          context,
                          'Cancel this request?',
                          'You can cancel while we are still finding a driver.',
                          action: 'Cancel request',
                        )) {
                          await action('booking.cancel');
                        }
                      },
                    ),
                ],
                if (o['arrived_at'] != null) ...[
                  const SizedBox(height: 16),
                  Notice(waitingText(), icon: Icons.timer_outlined),
                ],
                if (isDriver &&
                    o['access_note']?.toString().isNotEmpty == true) ...[
                  const SizedBox(height: 16),
                  Panel(child: Text('Access note: ${o['access_note']}')),
                ],
                if (isDriver && o['departed_at'] == null) ...[
                  const SizedBox(height: 24),
                  if (['accepted', 'en_route'].contains(o['state'])) ...[
                    ActionButton(
                      'Open navigation',
                      icon: Icons.near_me_outlined,
                      onPressed: () => navigateTo(
                        o['latitude'],
                        o['longitude'],
                        widget.controller.gateway.demo,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (o['state'] == 'accepted')
                    ActionButton(
                      'Start journey',
                      onPressed: () => action('driver.travel'),
                    ),
                  if (o['state'] == 'en_route')
                    ActionButton(
                      'I’ve arrived',
                      onPressed: () async {
                        await widget.controller.refreshLocation();
                        await action('driver.arrive');
                      },
                    ),
                  if (o['state'] == 'arrived')
                    ActionButton(
                      'Start loading',
                      onPressed: () async {
                        if (await confirm(
                          context,
                          'Start loading?',
                          'This stops the waiting meter. Continue when the collection is ready.',
                        )) {
                          await action('driver.start_loading');
                        }
                      },
                    ),
                  if (o['state'] == 'loading')
                    ActionButton(
                      'Photograph & record collection',
                      icon: Icons.camera_alt_outlined,
                      onPressed: evidence,
                    ),
                ],
                if (o['state'] == 'collected' ||
                    o['warehouse_confirmed_at'] != null) ...[
                  const SizedBox(height: 20),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Collection total',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        detailRow('Transport', money(o['transport_minor'])),
                        detailRow('Booking fee', money(o['booking_minor'])),
                        detailRow('Waiting', money(o['waiting_minor'])),
                        const Divider(),
                        detailRow('Total', money(o['total_minor'])),
                        detailRow(
                          'Payment',
                          o['payment_status'] == 'paid'
                              ? 'Recorded paid'
                              : 'Not confirmed',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (isDriver &&
                      o['departed_at'] == null &&
                      o['payment_status'] != 'paid')
                    ActionButton(
                      'Confirm cash received',
                      onPressed: () async {
                        if (await confirm(
                          context,
                          'Received ${money(o['total_minor'])}?',
                          'Confirm only after the requesting client has handed you the exact cash amount.',
                          action: 'Cash received',
                        )) {
                          await action('payment.cash', {
                            'amount_minor': o['total_minor'],
                          });
                        }
                      },
                    ),
                  if (isDriver && o['departed_at'] == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ActionButton(
                        'Leave pickup',
                        onPressed: () => action('driver.depart'),
                      ),
                    ),
                  if (!isDriver && o['payment_status'] != 'paid')
                    const Notice(
                      'Pay the requesting client’s total to your driver in cash. Your driver records the payment. Mobile money is not available yet.',
                    ),
                  if (isDriver &&
                      o['departed_at'] != null &&
                      o['warehouse_confirmed_at'] == null)
                    ActionButton(
                      'Show warehouse QR',
                      icon: Icons.qr_code,
                      onPressed: () async => openPage(
                        context,
                        HandoffScreen(widget.controller, order: o),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Panel(
                    child: Column(
                      children: [
                        milestone(
                          'Collection recorded',
                          o['collected_at'] != null,
                        ),
                        milestone(
                          'Payment recorded',
                          o['payment_status'] == 'paid',
                        ),
                        milestone(
                          'Warehouse receipt confirmed',
                          o['warehouse_confirmed_at'] != null,
                        ),
                      ],
                    ),
                  ),
                  for (final h in handoffs.where(
                    (h) => ['partial', 'rejected'].contains(h['status']),
                  ))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Notice(
                        'Warehouse ${h['status']}: ${h['reason'] ?? 'Your operator is reviewing this handoff.'}',
                      ),
                    ),
                ],
                if (!isDriver && o['state'] == 'failed')
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: ActionButton(
                      'Request a replacement',
                      onPressed: () async => openPage(
                        context,
                        BookingScreen(
                          widget.controller,
                          replacementOf: widget.id,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                TextButton.icon(
                  onPressed: () => openPage(
                    context,
                    ReportScreen(widget.controller, order: o),
                  ),
                  icon: const Icon(Icons.support_agent),
                  label: const Text('Report a problem'),
                ),
                if (widget.controller.gateway.demo && o['state'] == 'searching')
                  TextButton(
                    onPressed: () {
                      (widget.controller.gateway as DemoGateway)
                              .orders
                              .firstWhere((item) => item['id'] == widget.id)['state'] =
                          'accepted';
                      load();
                    },
                    child: const Text('Prototype: simulate driver acceptance'),
                  ),
                if (widget.controller.gateway.demo && !isDriver &&
                    ['accepted','en_route','arrived','loading','collected'].contains(o['state']) && o['departed_at']==null)
                  TextButton(onPressed: () {
                    final item=(widget.controller.gateway as DemoGateway).orders.firstWhere((item)=>item['id']==widget.id);
                    final now=DateTime.now().toUtc().toIso8601String();
                    switch(item['state']) {
                      case 'accepted': item['state']='en_route';
                      case 'en_route': item.addAll({'state':'arrived','arrived_at':now});
                      case 'arrived': item.addAll({'state':'loading','ready_at':now});
                      case 'loading': item.addAll({'state':'collected','collected_at':now});
                      case 'collected': item.addAll({'payment_status':'paid','departed_at':now});
                    }
                    load();
                  }, child: const Text('Prototype: advance collection')),
                if (widget.controller.gateway.demo &&
                    o['departed_at'] != null &&
                    o['warehouse_confirmed_at'] == null)
                  TextButton(
                    onPressed: () {
                      (widget.controller.gateway as DemoGateway).orders.firstWhere((item)=>item['id']==widget.id)['warehouse_confirmed_at'] = DateTime.now()
                          .toUtc()
                          .toIso8601String();
                      load();
                    },
                    child: const Text('Prototype: simulate warehouse receipt'),
                  ),
              ],
            ),
    );
  }

  Widget milestone(String text, bool done) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      done ? Icons.check_circle : Icons.radio_button_unchecked,
      color: done ? const Color(0xFF158653) : muted,
    ),
    title: Text(text),
  );
}

Future<void> navigateTo(dynamic lat, dynamic lng, bool demo) async {
  if (demo) throw const WasteBackendException('PROTOTYPE_NAVIGATION');
  final uri = Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': '$lat,$lng',
    'travelmode': 'driving',
  });
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw const WasteBackendException('NAVIGATION_UNAVAILABLE');
  }
}

class ReportScreen extends StatefulWidget {
  const ReportScreen(this.controller, {super.key, this.order});
  final AppController controller;
  final JsonObject? order;
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final details = TextEditingController();
  final form = GlobalKey<FormState>();
  String kind = 'collection_problem';
  String? reference;
  @override
  void dispose() {
    details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Report a problem')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          reference == null ? 'How can we help?' : 'Report received',
          reference == null
              ? 'Your report goes to the operator. Reporting does not cancel a collection or confirm payment.'
              : 'Your operator can review this report. A response time is not guaranteed.',
        ),
        if (reference != null)
          Panel(child: SelectableText('Report reference: $reference'))
        else ...[
          DropdownButtonFormField<String>(
            initialValue: kind,
            decoration: const InputDecoration(labelText: 'What happened?'),
            items: const [
              DropdownMenuItem(
                value: 'collection_problem',
                child: Text('Collection problem'),
              ),
              DropdownMenuItem(
                value: 'payment_problem',
                child: Text('Payment problem'),
              ),
              DropdownMenuItem(
                value: 'vehicle_problem',
                child: Text('Vehicle / access problem'),
              ),
              DropdownMenuItem(
                value: 'account_problem',
                child: Text('Account or documents'),
              ),
            ],
            onChanged: (v) => setState(() => kind = v!),
          ),
          const SizedBox(height: 16),
          Form(
            key: form,
            child: TextFormField(
              controller: details,
              minLines: 4,
              maxLines: 8,
              maxLength: 4000,
              decoration: const InputDecoration(
                labelText: 'Describe the problem',
              ),
              validator: (v) => (v?.trim().length ?? 0) < 3
                  ? 'Add a short description'
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          ActionButton(
            'Send report',
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              JsonObject? current;
              if (widget.order != null) {
                current = object(
                  await widget.controller.gateway.read('wm_get_order', {
                    'p_order_id': widget.order!['id'],
                  }),
                );
              }
              final r = await widget.controller.act('incident.report', {
                'kind': kind,
                'details': details.text.trim(),
                if (current != null) 'order_id': current['id'],
                if (current != null) 'version': current['version'],
              });
              if (mounted) {
                setState(() => reference = r['incident_id'].toString());
              }
            },
          ),
        ],
      ],
    ),
  );
}

class HandoffScreen extends StatefulWidget {
  const HandoffScreen(this.controller, {super.key, required this.order});
  final AppController controller;
  final JsonObject order;
  @override
  State<HandoffScreen> createState() => _HandoffScreenState();
}

class _HandoffScreenState extends State<HandoffScreen> {
  JsonObject? qr;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    qr = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        qr != null &&
        DateTime.tryParse(qr!['expires_at'].toString())
                ?.isAfter(DateTime.now()) ==
            true;
    return Scaffold(
      appBar: AppBar(title: const Text('Warehouse handoff')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          sectionTitle(
            context,
            'One pickup. One receipt.',
            'An authorized receiver scans this code and confirms receipt.',
          ),
          Panel(
            child: Column(
              children: [
                Text(
                  widget.order['address'] ?? 'Collection',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 20),
                if (valid)
                  QrImageView(
                    data: qr!['token'],
                    size: 240,
                    backgroundColor: Colors.white,
                  )
                else
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Icon(Icons.qr_code_2, size: 140, color: muted),
                  ),
                Text(
                  valid
                      ? 'Keep this code on your screen.'
                      : 'Generate a fresh code when the receiver is ready.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ActionButton(
            qr == null ? 'Generate handoff code' : 'Refresh handoff code',
            onPressed: () async {
              final o = object(
                await widget.controller.gateway.read('wm_get_order', {
                  'p_order_id': widget.order['id'],
                }),
              );
              final r = await widget.controller.act('handoff.issue', {
                'order_id': o['id'],
                'version': o['version'],
              });
              if (mounted) setState(() => qr = r);
            },
          ),
          const SizedBox(height: 16),
          const Notice(
            'A scan alone does not finish the collection. The receiver must confirm. Each pickup on your truck has its own code.',
          ),
        ],
      ),
    );
  }
}
