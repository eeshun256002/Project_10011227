import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app/controller.dart';
import '../app/gateway.dart';
import '../backend/waste_backend.dart';
import 'design.dart';

const documentNames = {
  'driving_license': 'Driving licence',
  'profile_photo': 'Face photo',
  'vehicle_insurance': 'Vehicle insurance',
  'roadworthiness': 'Roadworthiness certificate',
  'ghana_card': 'Ghana Card (optional)',
};

class DriverApplicationScreen extends StatefulWidget {
  const DriverApplicationScreen(this.controller, {super.key});
  final AppController controller;
  @override
  State<DriverApplicationScreen> createState() =>
      _DriverApplicationScreenState();
}

class _DriverApplicationScreenState extends State<DriverApplicationScreen> {
  JsonObject? application;
  bool loading = true;
  String? error;
  final name = TextEditingController(), plate = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    plate.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final a = await widget.controller.gateway.read(
        'wm_my_driver_application',
      );
      if (mounted) {
        setState(() {
          application = a == null ? null : object(a);
          name.text = application?['full_name'] ?? '';
          plate.text = application?['vehicle_plate'] ?? '';
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
  Widget build(BuildContext context) {
    final editable =
        application == null ||
        ['draft', 'changes_requested'].contains(application!['status']);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver application'),
        actions: [
          IconButton(
            tooltip: 'Refresh application',
            onPressed: load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                sectionTitle(
                  context,
                  application == null
                      ? 'Let’s get you on the road'
                      : 'Your driver documents',
                  'Your operator checks your documents before activating your account.',
                ),
                if (error != null) Notice(error!, action: load),
                if (application != null) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Tag(
                      application!['status']
                          .toString()
                          .replaceAll('_', ' ')
                          .toUpperCase(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (!editable)
                    Notice(
                      application!['status'] == 'approved'
                          ? 'Application approved. Your operator must activate your employee and vehicle account before new work is available.'
                          : 'Your application is ${application!['status'].toString().replaceAll('_', ' ')}. Refresh to see your operator’s decision.',
                    ),
                  for (final review in objects(
                    application!['review_history'] ?? [],
                  ))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Notice(
                        review['reason']?.toString() ?? 'Application reviewed.',
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                Form(
                  key: form,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: name,
                        enabled: editable,
                        decoration: const InputDecoration(
                          labelText: 'Full name',
                        ),
                        maxLength: 120,
                        validator: (v) => (v?.trim().length ?? 0) < 2
                            ? 'Enter your full name'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: plate,
                        enabled: editable,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle registration plate',
                        ),
                        maxLength: 40,
                        validator: (v) => (v?.trim().length ?? 0) < 3
                            ? 'Enter your vehicle plate'
                            : null,
                      ),
                    ],
                  ),
                ),
                if (editable)
                  ActionButton(
                    application == null
                        ? 'Save and add documents'
                        : 'Save details',
                    onPressed: () async {
                      if (!form.currentState!.validate()) return;
                      await widget.controller.act('application.save', {
                        'full_name': name.text.trim(),
                        'vehicle_plate': plate.text.trim().toUpperCase(),
                        if (application != null)
                          'version': application!['version'],
                      }, onboarding: true);
                      await load();
                    },
                  ),
                if (application != null) ...[
                  const SizedBox(height: 26),
                  Text(
                    'Document checklist',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  for (final entry in documentNames.entries)
                    Builder(
                      builder: (context) {
                        final docs = objects(application!['documents'] ?? [])
                            .where((d) => d['kind'] == entry.key)
                            .toList();
                        final doc = docs.isEmpty ? null : docs.last;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Panel(
                            padding: 8,
                            child: ListTile(
                              leading: Icon(
                                doc?['uploaded_at'] != null
                                    ? Icons.task_alt
                                    : Icons.upload_file_outlined,
                                color: doc?['uploaded_at'] != null
                                    ? const Color(0xFF158653)
                                    : muted,
                              ),
                              title: Text(
                                entry.value,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                doc == null
                                    ? 'Not added'
                                    : doc['uploaded_at'] == null
                                    ? 'Upload not finalized'
                                    : '${doc['review_status'] ?? 'Awaiting review'}${doc['expires_on'] == null ? '' : ' · expires ${doc['expires_on']}'}',
                              ),
                              trailing: editable
                                  ? const Icon(Icons.chevron_right)
                                  : null,
                              onTap: !editable
                                  ? null
                                  : () async {
                                      await openPage(
                                        context,
                                        DocumentScreen(
                                          widget.controller,
                                          application: application!,
                                          kind: entry.key,
                                        ),
                                      );
                                      await load();
                                    },
                            ),
                          ),
                        );
                      },
                    ),
                  if (editable) ...[
                    const SizedBox(height: 14),
                    const Text(
                      'Ghana Card is optional. The four other documents must be current and uploaded.',
                      style: TextStyle(color: muted),
                    ),
                    const SizedBox(height: 20),
                    ActionButton(
                      'Submit for review',
                      onPressed: () async {
                        await widget.controller.act('application.submit', {
                          'version': application!['version'],
                        }, onboarding: true);
                        await load();
                      },
                    ),
                  ],
                  if (['approved', 'rejected'].contains(application!['status']))
                    TextButton(
                      onPressed: () async {
                        if (!await confirm(
                          context,
                          'Update your documents?',
                          'Renewed documents need a fresh review. New jobs may be unavailable until approval.',
                        )) {
                          return;
                        }
                        try {
                          await widget.controller.act('application.reopen', {
                            'version': application!['version'],
                          }, onboarding: true);
                          await load();
                        } catch (e) {
                          if (context.mounted) {
                            message(context, friendlyError(e));
                          }
                        }
                      },
                      child: const Text('Reopen application / renew documents'),
                    ),
                ],
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => widget.controller.gateway.signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
    );
  }
}

class DocumentScreen extends StatefulWidget {
  const DocumentScreen(
    this.controller, {
    super.key,
    required this.application,
    required this.kind,
  });
  final AppController controller;
  final JsonObject application;
  final String kind;
  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  final number = TextEditingController(),
      licenseClass = TextEditingController();
  DateTime? expiry;
  Uint8List? bytes;
  String mime = 'image/jpeg', filename = '';
  final form = GlobalKey<FormState>();
  String progress = '';
  @override
  void dispose() {
    number.dispose();
    licenseClass.dispose();
    super.dispose();
  }

  Future<void> choose(bool camera) async {
    Uint8List? data;
    String name = '';
    if (camera) {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: 2000,
      );
      if (file == null) return;
      data = await file.readAsBytes();
      name = file.name;
    } else {
      final result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: widget.kind == 'profile_photo'
            ? ['jpg', 'jpeg', 'png', 'webp']
            : ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
      );
      if (result == null) return;
      if ((await result.length() ?? 0) > 10485760) {
        throw const WasteBackendException('FILE_TOO_LARGE');
      }
      data = await result.readAsBytes();
      name = result.name;
    }
    if (data.length > 10485760) {
      throw const WasteBackendException('FILE_TOO_LARGE');
    }
    final ext = name.split('.').last.toLowerCase();
    if (!['jpg', 'jpeg', 'png', 'webp', 'pdf'].contains(ext)) {
      throw const WasteBackendException('FILE_TOO_LARGE');
    }
    if (mounted) {
      setState(() {
        bytes = data;
        filename = name;
        mime = ext == 'pdf'
            ? 'application/pdf'
            : ext == 'png'
            ? 'image/png'
            : ext == 'webp'
            ? 'image/webp'
            : 'image/jpeg';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(documentNames[widget.kind]!)),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          'Clear, current and readable',
          'Your documents are private and reviewed by your operator.',
        ),
        if (bytes != null)
          Panel(
            child: Column(
              children: [
                if (mime != 'application/pdf')
                  Image.memory(bytes!, height: 180, fit: BoxFit.contain),
                Text(filename),
              ],
            ),
          ),
        const SizedBox(height: 16),
        ActionButton(
          'Take a photo',
          icon: Icons.camera_alt_outlined,
          onPressed: () => choose(true),
        ),
        const SizedBox(height: 12),
        ActionButton(
          'Choose a file',
          icon: Icons.upload_file_outlined,
          onPressed: () => choose(false),
        ),
        const SizedBox(height: 24),
        Form(
          key: form,
          child: Column(
            children: [
              if (widget.kind == 'driving_license') ...[
                TextFormField(
                  controller: number,
                  decoration: const InputDecoration(
                    labelText: 'Ghana driving licence number',
                  ),
                  validator: (v) => (v?.trim().isEmpty ?? true)
                      ? 'Enter your licence number'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: licenseClass,
                  decoration: const InputDecoration(labelText: 'Licence class'),
                  validator: (v) => (v?.trim().isEmpty ?? true)
                      ? 'Enter the licence class'
                      : null,
                ),
                const SizedBox(height: 16),
              ],
              if ([
                'driving_license',
                'vehicle_insurance',
                'roadworthiness',
              ].contains(widget.kind))
                OutlinedButton.icon(
                  onPressed: () async {
                    final now = DateUtils.dateOnly(DateTime.now());
                    final date = await showDatePicker(
                      context: context,
                      firstDate: now,
                      lastDate: DateTime(now.year + 20),
                      initialDate: expiry ?? now,
                    );
                    if (date != null && mounted) setState(() => expiry = date);
                  },
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(
                    expiry == null
                        ? 'Choose expiry date'
                        : 'Expires ${expiry!.toIso8601String().split('T').first}',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (progress.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(progress),
          ),
        ActionButton(
          'Upload document',
          onPressed: bytes == null
              ? null
              : () async {
                  if (!form.currentState!.validate()) return;
                  if ([
                        'driving_license',
                        'vehicle_insurance',
                        'roadworthiness',
                      ].contains(widget.kind) &&
                      expiry == null) {
                    message(context, 'Choose the expiry date.');
                    return;
                  }
                  setState(() => progress = 'Preparing secure upload…');
                  final current = object(
                    await widget.controller.gateway.read(
                      'wm_my_driver_application',
                    ),
                  );
                  final reserved = await widget.controller.act(
                    'document.reserve',
                    {
                      'version': current['version'],
                      'kind': widget.kind,
                      'content_type': mime,
                      if (widget.kind == 'driving_license')
                        'document_number': number.text.trim(),
                      if (widget.kind == 'driving_license')
                        'license_class': licenseClass.text.trim(),
                      if (expiry != null)
                        'expires_on': expiry!
                            .toIso8601String()
                            .split('T')
                            .first,
                      'issuing_country': 'GH',
                    },
                    onboarding: true,
                  );
                  if (mounted) setState(() => progress = 'Uploading document…');
                  await widget.controller.gateway.upload(
                    reserved['bucket'],
                    reserved['path'],
                    bytes!,
                    mime,
                  );
                  final latest = object(
                    await widget.controller.gateway.read(
                      'wm_my_driver_application',
                    ),
                  );
                  await widget.controller.act('document.finalize', {
                    'version': latest['version'],
                    'document_id': reserved['document_id'],
                  }, onboarding: true);
                  if (context.mounted) {
                    message(context, 'Document uploaded for review.');
                    Navigator.pop(context);
                  }
                },
        ),
      ],
    ),
  );
}
