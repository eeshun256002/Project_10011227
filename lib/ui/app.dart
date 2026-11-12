import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/gateway.dart';
import 'design.dart';
import 'auth.dart';
import 'account.dart';
import 'booking.dart';
import 'collection.dart';
import 'driver_application.dart';
import 'pickup_map.dart';
import 'receiver.dart';

class MohotewApp extends StatefulWidget {
  const MohotewApp({
    super.key,
    this.gateway,
    this.kind = AppKind.client,
    this.onRetry,
  });
  final AppGateway? gateway;
  final AppKind kind;
  final Future<void> Function()? onRetry;
  @override
  State<MohotewApp> createState() => _MohotewAppState();
}

class _MohotewAppState extends State<MohotewApp> with WidgetsBindingObserver {
  AppController? controller;
  bool reconciling = false;
  String? recoveryError;

  Future<void> reconcile() async {
    setState(() {
      reconciling = true;
      recoveryError = null;
    });
    try {
      await controller!.gateway.retryPending();
    } catch (e) {
      if (mounted) setState(() => recoveryError = friendlyError(e));
    } finally {
      await controller!.refresh();
      if (mounted) setState(() => reconciling = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.gateway != null) {
      controller = AppController(widget.gateway!, widget.kind);
      controller!.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller?.resume();
    } else {
      controller?.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: mohotewTheme(),
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Brand(),
                    const SizedBox(height: 30),
                    const Text(
                      'Unable to start',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Check the app configuration and your connection, then try again.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ActionButton('Try again', onPressed: widget.onRetry),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => MaterialApp(
        key: ValueKey('${c.gateway.userId}:${c.gateway.recovering}'),
        title: widget.kind == AppKind.driver ? 'Mohotew Driver' : 'Mohotew',
        debugShowCheckedModeBanner: false,
        theme: mohotewTheme(),
        builder: (context, child) => Column(
          children: [
            if (c.gateway.demo)
              Material(
                color: const Color(0xFFFFDA88),
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 7,
                      horizontal: 12,
                    ),
                    child: const Text(
                      'PROTOTYPE · Sample data · No real bookings or payments',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
                ),
              ),
            if (c.signedIn && (c.pending != null || recoveryError != null))
              Material(
                color: const Color(0xFFFFF2D5),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      children: [
                        Text(
                          recoveryError ?? 'An earlier action needs checking before you continue.',
                        ),
                        TextButton(
                          onPressed: reconciling
                              ? null
                              : c.pending != null
                              ? reconcile
                              : () => setState(() => recoveryError = null),
                          child: Text(
                            reconciling
                                ? 'Checking…'
                                : c.pending != null
                                ? 'Check pending action'
                                : 'Dismiss',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(child: child!),
          ],
        ),
        home: c.loading
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : c.gateway.recovering
            ? RecoveryScreen(c, update: true)
            : !c.signedIn
            ? WelcomeScreen(c)
            : c.access.isEmpty
            ? Scaffold(
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Notice(
                          c.error ?? 'Unable to check account access.',
                          action: c.refresh,
                        ),
                        TextButton(
                          onPressed: () => c.gateway.signOut(),
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : widget.kind == AppKind.receiver
            ? ReceiverScreen(c)
            : widget.kind == AppKind.client &&
                  c.access['client_registered'] != true
            ? EnrollmentScreen(c)
            : widget.kind == AppKind.driver &&
                  c.access['driver_provisioned'] != true
            ? DriverApplicationScreen(c)
            : AppShell(c),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell(this.controller, {super.key});
  final AppController controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final driver = c.kind == AppKind.driver;
    return Scaffold(
      appBar: AppBar(
        title: Brand(driver: driver),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: c.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Notice(c.error!, action: c.refresh),
            ),
          if (c.pending != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Notice(
                'A previous action needs checking.',
                label: 'Open account',
                action: () => setState(() => tab = 2),
              ),
            ),
          Expanded(
            child: tab == 2
                ? AccountScreen(c)
                : tab == 1
                ? driver
                      ? LoadScreen(c)
                      : HistoryScreen(c)
                : driver
                ? DriverHome(c)
                : ClientHome(c),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: [
          NavigationDestination(
            icon: Icon(driver ? Icons.work_outline : Icons.home_outlined),
            selectedIcon: Icon(driver ? Icons.work : Icons.home),
            label: driver ? 'Work' : 'Home',
          ),
          NavigationDestination(
            icon: Icon(
              driver
                  ? Icons.local_shipping_outlined
                  : Icons.receipt_long_outlined,
            ),
            label: driver ? 'Load' : 'Collections',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}

class ClientHome extends StatelessWidget {
  const ClientHome(this.controller, {super.key});
  final AppController controller;
  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: controller.refresh,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Tag('EAST LEGON, ACCRA'),
        ),
        const SizedBox(height: 16),
        Text(
          'A little less waste.\nA lot more space.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 24),
        ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            height: 230,
            child: PickupMap(demo: controller.gateway.demo),
          ),
        ),
        const SizedBox(height: 20),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Where should we collect?',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose your pickup point and get a clear price.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 20),
              ActionButton(
                'Request a collection',
                icon: Icons.arrow_forward,
                onPressed: () async =>
                    openPage(context, BookingScreen(controller)),
              ),
            ],
          ),
        ),
        if (!controller.serviceReady) ...[
          const SizedBox(height: 16),
          const Notice(
            'Collections are not open for booking yet. You can prepare your pickup details; requesting a driver will be available when service opens.',
          ),
        ],
        const SizedBox(height: 24),
        if (controller.active.isNotEmpty) ...[
          Text(
            'Your active collections',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 14),
          for (final o in controller.active)
            CollectionTile(
              o,
              onTap: () =>
                  openPage(context, CollectionScreen(controller, id: o['id'])),
            ),
        ],
        const Panel(
          color: Color(0xFFD9F7E8),
          child: Row(
            children: [
              Icon(Icons.verified_outlined, size: 32, color: ink),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  'From your doorstep to an approved receiving partner.',
                  style: TextStyle(fontWeight: FontWeight.w600, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class DriverHome extends StatelessWidget {
  const DriverHome(this.controller, {super.key});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final online = controller.driver['online'] == true;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                online ? 'You’re online.' : 'Ready for the day?',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            Tag(
              online ? 'ONLINE' : 'OFFLINE',
              color: online ? const Color(0xFFD9F7E8) : const Color(0xFFE8ECE9),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          online
              ? 'Keep the app open for new offers. Background push alerts are not connected yet.'
              : 'Go online when your vehicle and documents are ready.',
          style: const TextStyle(color: muted, height: 1.5),
        ),
        const SizedBox(height: 22),
        ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            height: 210,
            child: PickupMap(demo: controller.gateway.demo),
          ),
        ),
        const SizedBox(height: 20),
        ActionButton(
          online ? 'Go offline' : 'Go online',
          icon: Icons.power_settings_new,
          onPressed: !online && controller.driver['can_take_jobs'] != true
              ? null
              : () async {
                  if (!online &&
                      !await confirm(
                        context,
                        'Share your work location?',
                        'While online, your location helps dispatch and lets assigned clients follow your arrival. You can go offline when your work allows it.',
                        action: 'Go online',
                      )) {
                    return;
                  }
                  await controller.setOnline(!online);
                },
        ),
        if (controller.locationError != null) ...[
          const SizedBox(height: 16),
          Notice(
            controller.locationError!,
            label: 'Refresh location',
            action: () async {
              try {
                await controller.refreshLocation();
              } catch (e) {
                if (context.mounted) message(context, friendlyError(e));
              }
            },
          ),
        ],
        if (controller.driver['can_take_jobs'] != true) ...[
          const SizedBox(height: 16),
          Notice(
            'Your documents or vehicle need operator approval for new jobs.',
            label: 'View documents',
            action: () =>
                openPage(context, DriverApplicationScreen(controller)),
          ),
        ],
        const SizedBox(height: 24),
        for (final offer in controller.offers)
          OfferCard(controller, offer: offer),
        for (final o in controller.active.where(
          (o) => o['departed_at'] == null,
        ))
          CollectionTile(
            o,
            onTap: () =>
                openPage(context, CollectionScreen(controller, id: o['id'])),
          ),
        if (controller.offers.isEmpty &&
            controller.active.where((o) => o['departed_at'] == null).isEmpty)
          Panel(
            child: Column(
              children: [
                const Icon(Icons.work_outline, size: 40, color: muted),
                const SizedBox(height: 12),
                Text(
                  online ? 'Waiting for an offer' : 'No active visit',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only offers assigned to you will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class OfferCard extends StatelessWidget {
  const OfferCard(this.controller, {super.key, required this.offer});
  final AppController controller;
  final Map<String, dynamic> offer;
  @override
  Widget build(BuildContext context) {
    final valid =
        DateTime.tryParse(offer['expires_at'].toString())
            ?.isAfter(DateTime.now()) ==
        true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Panel(
        color: const Color(0xFFD9F7E8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Tag('NEW COLLECTION', color: Colors.white),
            const SizedBox(height: 16),
            Text(
              offer['area'] ?? 'East Legon',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(categoryName(offer['category'])),
            const SizedBox(height: 8),
            Text(
              valid ? 'Offer expires ${offer['expires_at']}' : 'Offer expired',
              style: const TextStyle(fontSize: 12, color: muted),
            ),
            const SizedBox(height: 20),
            ActionButton(
              'Accept collection',
              onPressed: !valid
                  ? null
                  : () async {
                      final o = await controller.act('offer.accept', {
                        'offer_id': offer['offer_id'],
                      });
                      if (context.mounted) {
                        await openPage(
                          context,
                          CollectionScreen(controller, id: o['id']),
                        );
                      }
                    },
            ),
            const SizedBox(height: 10),
            ActionButton(
              'Decline offer',
              onPressed: !valid
                  ? null
                  : () async {
                      await controller.act('offer.decline', {
                        'offer_id': offer['offer_id'],
                      });
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class LoadScreen extends StatelessWidget {
  const LoadScreen(this.controller, {super.key});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final loads = controller.active
        .where((o) => o['departed_at'] != null)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          'Your load',
          'Keep each collected pickup accounted for until the warehouse confirms it.',
        ),
        Panel(
          child: Column(
            children: [
              detailRow(
                'Reported load',
                controller.driver['load_state']?.toString().replaceAll(
                      '_',
                      ' ',
                    ) ??
                    'Unknown',
              ),
              detailRow('Awaiting warehouse', loads.length.toString()),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final state in ['nearly_full', 'full', 'unknown'])
                    OutlinedButton(
                      onPressed: () async {
                        try {
                          if (await confirm(
                            context,
                            'Report ${state.replaceAll('_', ' ')} load?',
                            'Your operator handles resetting your truck to available after reconciliation.',
                          )) {
                            await controller.act('driver.load', {
                              'load_state': state,
                            });
                          }
                        } catch (e) {
                          if (context.mounted) {
                            message(context, friendlyError(e));
                          }
                        }
                      },
                      child: Text(state.replaceAll('_', ' ')),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        for (final o in loads)
          CollectionTile(
            o,
            onTap: () =>
                openPage(context, CollectionScreen(controller, id: o['id'])),
          ),
        if (loads.isEmpty)
          const Panel(
            child: Text('No pickups are awaiting warehouse receipt.'),
          ),
        const SizedBox(height: 20),
        ActionButton(
          'Warehouse destination',
          icon: Icons.near_me_outlined,
          onPressed: () async {
            final w = object(
              await controller.gateway.read('wm_driver_destination'),
            );
            if (!context.mounted) return;
            if (await confirm(
              context,
              w['name'],
              w['address'],
              action: controller.gateway.demo
                  ? 'Close preview'
                  : 'Open navigation',
            )) {
              await navigateTo(
                w['latitude'],
                w['longitude'],
                controller.gateway.demo,
              );
            }
          },
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () => openPage(context, ReportScreen(controller)),
          child: const Text('Report a load or receiving problem'),
        ),
      ],
    );
  }
}
