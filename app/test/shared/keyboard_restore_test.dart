import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/shared/keyboard_restore.dart';

void main() {
  for (final removeEditor in [false, true]) {
    testWidgets(
      'background keyboard restoration respects editor lifetime: $removeEditor',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        var visible = true;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: KeyboardRestore(
              child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return visible
                        ? const TextField(
                            maxLines: 3,
                            decoration: InputDecoration(labelText: 'Note'),
                          )
                        : const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        try {
          await tester.showKeyboard(find.byType(TextField));
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pump();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.view.viewInsets = FakeViewPadding.zero;
          if (removeEditor) {
            update(() => visible = false);
            await tester.pump();
          }
          tester.testTextInput.log.clear();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.show',
            ),
            removeEditor ? isEmpty : isNotEmpty,
          );
          expect(tester.takeException(), isNull);
        } finally {
          tester.view.resetViewInsets();
          await tester.pumpWidget(const SizedBox());
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        }
      },
    );
  }
}
