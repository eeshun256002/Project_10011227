import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mohotew/backend/waste_backend.dart';

void main() {
  test('persisted booking retry preserves idempotency key and payload', () {
    final command = WasteCommand(
      action: 'booking.submit',
      payload: {'quote_id': 'test-quote', 'address': 'Test address'},
    );
    final restored = WasteCommand.fromJson(
      jsonDecode(jsonEncode(command.toJson())) as JsonObject,
    );
    expect(restored.key, command.key);
    expect(restored.payload, command.payload);
    expect(restored.action, command.action);
    expect(
      command.key,
      matches(
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ),
      ),
    );
    expect(
      WasteCommand(action: command.action, payload: command.payload).key,
      isNot(command.key),
    );
  });
}
