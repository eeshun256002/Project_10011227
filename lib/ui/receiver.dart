import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/controller.dart';
import '../backend/waste_backend.dart';
import 'design.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen(this.controller, {super.key});
  final AppController controller;
  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final token = TextEditingController(), reason = TextEditingController();
  JsonObject? preview;
  String? outcome;
  String choice = 'confirmed';
  @override
  void dispose() {
    token.clear();
    token.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> inspect() async {
    final p = object(
      await widget.controller.gateway.read('wm_preview_handoff', {
        'p_token': token.text.trim(),
      }),
    );
    if (mounted) {
      setState(() {
        preview = p;
        outcome = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Warehouse receiving'),
      actions: [
        IconButton(
          tooltip: 'Sign out',
          onPressed: () => widget.controller.gateway.signOut(),
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          'Receive a collection',
          'Scan, review, then confirm each pickup separately.',
        ),
        if ((widget.controller.staff['warehouses'] as List? ?? []).isEmpty)
          const Notice(
            'Your operator must assign this account to a receiving warehouse.',
          )
        else ...[
          for (final w in objects(widget.controller.staff['warehouses']))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Tag(w['name']),
            ),
          if (outcome != null) ...[
            Panel(
              color: const Color(0xFFD9F7E8),
              child: Text(
                'Receipt recorded: $outcome',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 20),
            ActionButton(
              'Receive another pickup',
              onPressed: () async {
                setState(() {
                  token.clear();
                  preview = null;
                  outcome = null;
                  reason.clear();
                  choice = 'confirmed';
                });
              },
            ),
          ] else if (preview == null) ...[
            ActionButton(
              'Scan driver’s QR code',
              icon: Icons.qr_code_scanner,
              onPressed: () async {
                if (widget.controller.gateway.demo) {
                  token.text = 'MOHOTEW-PROTOTYPE-ONLY';
                  await inspect();
                  return;
                }
                final value = await Navigator.of(context).push<String>(
                  MaterialPageRoute(builder: (_) => const ScannerScreen()),
                );
                if (value != null) {
                  token.text = value;
                  await inspect();
                }
              },
            ),
            const SizedBox(height: 20),
            TextField(
              controller: token,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Or enter handoff code',
              ),
              onChanged: (_) => setState(() => preview = null),
            ),
            const SizedBox(height: 16),
            ActionButton('Review code', onPressed: inspect),
          ] else ...[
            Panel(
              child: Column(
                children: [
                  detailRow('Pickup', preview!['order_id'].toString()),
                  detailRow('Category', categoryName(preview!['category'])),
                  detailRow(
                    'Collected',
                    preview!['collected_at']?.toString() ?? 'Recorded',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              initialValue: choice,
              decoration: const InputDecoration(labelText: 'Receipt outcome'),
              items: const [
                DropdownMenuItem(
                  value: 'confirmed',
                  child: Text('Received in full'),
                ),
                DropdownMenuItem(
                  value: 'partial',
                  child: Text('Partially received'),
                ),
                DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
              ],
              onChanged: (v) => setState(() => choice = v!),
            ),
            if (choice != 'confirmed')
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextField(
                  controller: reason,
                  maxLength: 2000,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Reason (required)',
                  ),
                ),
              ),
            const SizedBox(height: 24),
            ActionButton(
              'Confirm receipt outcome',
              onPressed: () async {
                if (choice != 'confirmed' && reason.text.trim().length < 3) {
                  message(
                    context,
                    'Give a reason for partial or rejected receipt.',
                  );
                  return;
                }
                if (!await confirm(
                  context,
                  'Record this receipt?',
                  'Confirm the physical receipt you inspected. This applies only to this pickup.',
                )) {
                  return;
                }
                await widget.controller.act('handoff.confirm', {
                  'token': token.text.trim(),
                  'outcome': choice,
                  if (choice != 'confirmed') 'reason': reason.text.trim(),
                });
                if (mounted) {
                  setState(() {
                    outcome = choice;
                    token.clear();
                  });
                }
              },
            ),
            TextButton(
              onPressed: () => setState(() => preview = null),
              child: const Text('Use another code'),
            ),
          ],
        ],
        if (widget.controller.pending != null) ...[
          const SizedBox(height: 16),
          const Notice(
            'A receipt action needs checking. Do not submit it again as a new action.',
          ),
          const SizedBox(height: 12),
          ActionButton(
            'Check pending receipt',
            onPressed: () async {
              await widget.controller.gateway.retryPending();
              await widget.controller.refresh();
              if (context.mounted) {
                message(
                  context,
                  'Pending command checked. Ask the driver to refresh their receipt status.',
                );
              }
            },
          ),
        ],
      ],
    ),
  );
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final camera = MobileScannerController();
  bool detected = false;
  @override
  void dispose() {
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scan handoff code'),
      actions: [
        IconButton(
          tooltip: 'Toggle torch',
          onPressed: () => camera.toggleTorch(),
          icon: const Icon(Icons.flashlight_on_outlined),
        ),
      ],
    ),
    body: MobileScanner(
      controller: camera,
      onDetect: (capture) {
        if (detected) return;
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (value != null && value.isNotEmpty) {
            detected = true;
            Navigator.pop(context, value);
            break;
          }
        }
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Notice(
            'Camera is unavailable. Enable camera permission in settings, or return and enter the code manually.',
          ),
        ),
      ),
    ),
  );
}
