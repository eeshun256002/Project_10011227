import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mohotew/app/gateway.dart';
import 'package:mohotew/backend/waste_backend.dart';

void main() {
  late Map<String, String> storage;
  late CommandJournal journal;
  setUp(() {
    storage = {};
    journal = CommandJournal(
      readValue: (k) async => storage[k],
      writeValue: (k, v) async {
        storage[k] = v;
      },
      deleteValue: (k) async {
        storage.remove(k);
      },
    );
  });
  test(
    'uncertain booking survives restart and reuses exact command key',
    () async {
      final intent = WasteCommand(
        action: 'booking.submit',
        payload: {'quote_id': 'quote', 'address': 'Pickup'},
      );
      await expectLater(
        journal.send(
          'alice',
          intent,
          false,
          (_, _) async => throw TimeoutException('interrupted'),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(await journal.pending('alice'), isNotNull);
      expect(await journal.pending('bob'), isNull);
      await expectLater(
        journal.send('alice', intent, false, (_, _) async => {}),
        throwsA(isA<WasteBackendException>()),
      );
      final restored = CommandJournal(
        readValue: (k) async => storage[k],
        writeValue: (k, v) async {
          storage[k] = v;
        },
        deleteValue: (k) async {
          storage.remove(k);
        },
      );
      await restored.send(
        'alice',
        WasteCommand(action: 'ignored', payload: {}),
        false,
        (command, onboarding) async {
          expect(command.key, intent.key);
          expect(command.payload, intent.payload);
          expect(command.action, intent.action);
          return {'id': 'one-order'};
        },
        retry: true,
      );
      expect(await restored.pending('alice'), isNull);
    },
  );
  test(
    'business rejection clears intent but ambiguous server failure retains it',
    () async {
      final intent = WasteCommand(
        action: 'offer.accept',
        payload: {'offer_id': 'expired'},
      );
      await expectLater(
        journal.send(
          'alice',
          intent,
          false,
          (_, _) async => throw const WasteBackendException('OFFER_EXPIRED'),
        ),
        throwsA(isA<WasteBackendException>()),
      );
      expect(await journal.pending('alice'), isNull);
      await expectLater(
        journal.send(
          'alice',
          intent,
          false,
          (_, _) async =>
              throw const WasteBackendException('SERVICE_UNAVAILABLE'),
        ),
        throwsA(isA<WasteBackendException>()),
      );
      expect(await journal.pending('alice'), isNotNull);
    },
  );
  test('parallel taps cannot submit two commands', () async {
    final blocked = Completer<JsonObject>();
    final intent = WasteCommand(
      action: 'payment.cash',
      payload: {'amount_minor': 2500},
    );
    final first = journal.send(
      'alice',
      intent,
      false,
      (_, _) => blocked.future,
    );
    await expectLater(
      journal.send('alice', intent, false, (_, _) async => {}),
      throwsA(isA<WasteBackendException>()),
    );
    blocked.complete({'paid': true});
    await first;
  });
}
