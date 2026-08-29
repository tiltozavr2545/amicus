import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/shared/delete_order.dart';

void main() {
  test('rows are deleted before objects', () async {
    final calls = <String>[];
    await deleteRowsThenObjects(
      rows: () async => calls.add('rows'),
      objects: () async => calls.add('objects'),
    );
    expect(calls, ['rows', 'objects']);
  });

  test('objects only start after rows have finished, not alongside', () async {
    // The whole point is ordering under latency: a naive implementation that
    // kicked both off and awaited them together would pass the test above and
    // still leave the reference alive while the bytes went away.
    final calls = <String>[];
    await deleteRowsThenObjects(
      rows: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        calls.add('rows');
      },
      objects: () async => calls.add('objects'),
    );
    expect(calls, ['rows', 'objects']);
  });

  test(
    'a failed cleanup is swallowed — the delete already succeeded',
    () async {
      var rowsRan = false;
      await expectLater(
        deleteRowsThenObjects(
          rows: () async => rowsRan = true,
          objects: () async => throw Exception('storage offline'),
        ),
        completes,
      );
      expect(rowsRan, true);
    },
  );

  test('a failed row delete propagates and never touches storage', () async {
    var objectsRan = false;
    await expectLater(
      deleteRowsThenObjects(
        rows: () async => throw Exception('timeout'),
        objects: () async => objectsRan = true,
      ),
      throwsException,
    );
    // This is the regression that mattered most: with the old order the bytes
    // were already gone by the time the row delete failed.
    expect(objectsRan, false);
  });
}
