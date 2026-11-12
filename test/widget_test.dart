import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mohotew/app/demo_gateway.dart';
import 'package:mohotew/app/gateway.dart';
import 'package:mohotew/main.dart';

Future<void> tapText(
  WidgetTester tester,
  String label, {
  bool button = true,
}) async {
  final finder = button
      ? find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        )
      : find.text(label);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      220,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder.last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<DemoGateway> start(
  WidgetTester tester, {
  AppKind kind = AppKind.client,
  bool signedIn = false,
}) async {
  final gateway = DemoGateway();
  if (signedIn) await gateway.authenticate('preview', 'preview');
  await tester.pumpWidget(MohotewApp(gateway: gateway, kind: kind));
  await tester.pumpAndSettle();
  return gateway;
}

void main() {
  testWidgets('welcome, authentication choice and password visibility work', (
    tester,
  ) async {
    await start(tester);
    expect(find.text('A cleaner space,\na tap away.'), findsOneWidget);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Phone', button: false);
    expect(find.text('Phone number (+233…)'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await tapText(tester, 'Create account');
    expect(find.text('Use at least 8 characters'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('client can review quote, request once and cancel searching', (
    tester,
  ) async {
    final gateway = await start(tester, signedIn: true);
    await tapText(tester, 'Request a collection');
    await tapText(tester, 'Confirm pickup point');
    expect(find.text('Biodegradable'), findsOneWidget);
    await tapText(tester, 'See price');
    expect(find.text('GH₵25.00'), findsOneWidget);
    await tapText(tester, 'Request collection');
    expect(gateway.orders.length, 1);
    expect(find.text('Finding your driver'), findsOneWidget);
    await tapText(tester, 'Cancel request');
    await tapText(tester, 'Cancel request');
    expect(gateway.orders.single['state'], 'cancelled');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'driver lifecycle separates collection, payment and warehouse receipt',
    (tester) async {
      final gateway = DemoGateway();
      await gateway.authenticate('preview', 'preview');
      gateway.orders.add(gateway.sampleOrder());
      await tester.pumpWidget(
        MohotewApp(gateway: gateway, kind: AppKind.driver),
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Driver assigned', button: false);
      await tapText(tester, 'Start journey');
      await tapText(tester, 'I’ve arrived');
      await tapText(tester, 'Start loading');
      await tapText(tester, 'Confirm');
      await tapText(tester, 'Photograph & record collection');
      expect(gateway.orders.single['state'], 'collected');
      expect(gateway.orders.single['payment_status'], isNull);
      await tapText(tester, 'Confirm cash received');
      await tapText(tester, 'Cash received');
      await tapText(tester, 'Leave pickup');
      expect(gateway.orders.single['departed_at'], isNotNull);
      expect(gateway.orders.single['warehouse_confirmed_at'], isNull);
      await tapText(tester, 'Show warehouse QR');
      await tapText(tester, 'Generate handoff code');
      expect(find.text('Keep this code on your screen.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('receiver review requires explicit confirmation', (tester) async {
    await start(tester, kind: AppKind.receiver, signedIn: true);
    await tapText(tester, 'Scan driver’s QR code');
    expect(find.text('Confirm receipt outcome'), findsOneWidget);
    await tapText(tester, 'Confirm receipt outcome');
    await tapText(tester, 'Confirm');
    expect(find.text('Receipt recorded: confirmed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('startup failure has a retry action', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MohotewApp(
        onRetry: () async {
          retried = true;
        },
      ),
    );
    expect(find.textContaining('Check the app configuration'), findsOneWidget);
    await tapText(tester, 'Try again');
    expect(retried, isTrue);
  });
}
