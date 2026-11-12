import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/gateway.dart';
import 'design.dart';
import 'driver_application.dart';
import 'collection.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen(this.controller, {super.key});
  final AppController controller;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      sectionTitle(
        context,
        'Your account',
        'Everything you need, in one place.',
      ),
      Panel(
        child: Row(
          children: [
            const CircleAvatar(
              radius: 28,
              backgroundColor: Color(0xFFD9F7E8),
              child: Icon(Icons.person_outline, size: 30, color: ink),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.gateway.identity,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${controller.kind.name} account',
                    style: const TextStyle(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      ListTile(
        leading: const Icon(Icons.edit_outlined),
        title: const Text('Edit display name'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(context, EditNameScreen(controller)),
      ),
      if (controller.kind == AppKind.driver)
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('My documents'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(context, DriverApplicationScreen(controller)),
        ),
      ListTile(
        leading: const Icon(Icons.help_outline),
        title: const Text('Report a problem'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(context, ReportScreen(controller)),
      ),
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('How collections work'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('From pickup to receipt'),
            content: const Text(
              'Request a collection, meet your driver and pay at pickup. Your driver takes the waste to the receiving partner. The warehouse confirms each pickup separately.\n\nCollection, payment and warehouse receipt are shown as separate steps.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      if (controller.pending != null) ...[
        Notice(
          'An earlier action needs to be checked: ${controller.pending!.replaceAll('.', ' ')}.',
        ),
        const SizedBox(height: 12),
        ActionButton(
          'Check pending action',
          onPressed: () async {
            await controller.gateway.retryPending();
            await controller.refresh();
          },
        ),
        const SizedBox(height: 20),
      ],
      ActionButton(
        'Sign out',
        onPressed: () async {
          if (await confirm(
            context,
            'Sign out?',
            controller.active.isEmpty ? 'You can sign in again at any time.' : 'You still have active work. Signing out does not cancel a collection. Your operator must resolve any outstanding obligations.',
            action: 'Sign out',
          )) {
            await controller.gateway.signOut();
          }
        },
      ),
      const SizedBox(height: 24),
      const Center(
        child: Text(
          'Mohotew · East Legon, Ghana',
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ),
    ],
  );
}

class EditNameScreen extends StatefulWidget {
  const EditNameScreen(this.controller, {super.key});
  final AppController controller;
  @override
  State<EditNameScreen> createState() => _EditNameScreenState();
}

class _EditNameScreenState extends State<EditNameScreen> {
  final name = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Display name')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Form(
          key: form,
          child: TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Display name'),
            maxLength: 120,
            validator: (v) =>
                (v?.trim().isEmpty ?? true) ? 'Enter your name' : null,
          ),
        ),
        const SizedBox(height: 20),
        ActionButton(
          'Save name',
          onPressed: () async {
            if (!form.currentState!.validate()) return;
            await widget.controller.act('profile.update', {
              'display_name': name.text.trim(),
            });
            if (context.mounted) {
              message(context, 'Display name updated.');
              Navigator.pop(context);
            }
          },
        ),
      ],
    ),
  );
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen(this.controller, {super.key});
  final AppController controller;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> rows = [];
  bool loading = true, more = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool reset = false}) async {
    try {
      final result = objects(
        await widget.controller.gateway.read('wm_list_orders', {
          'p_limit': 30,
          if (!reset && rows.isNotEmpty) 'p_before': rows.last['created_at'],
        }),
      );
      if (mounted) {
        setState(() {
          rows = reset ? result : [...rows, ...result];
          more = result.length == 30;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () => load(reset: true),
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          'Your collections',
          'A record of every pickup and handoff.',
        ),
        if (loading) const Center(child: CircularProgressIndicator()),
        if (error != null) Notice(error!, action: () => load(reset: true)),
        if (!loading && rows.isEmpty)
          const Panel(
            child: Column(
              children: [
                Icon(Icons.receipt_long_outlined, size: 48, color: muted),
                SizedBox(height: 16),
                Text(
                  'No collections yet',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text(
                  'Your collection history will appear here.',
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          ),
        for (final o in rows)
          CollectionTile(
            o,
            onTap: () => openPage(
              context,
              CollectionScreen(widget.controller, id: o['id']),
            ),
          ),
        if (more && !loading) ActionButton('Load more', onPressed: load),
      ],
    ),
  );
}
