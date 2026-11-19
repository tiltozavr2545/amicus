import 'package:flutter/material.dart';

/// Restores the active editor's keyboard after Android backgrounds the app.
class KeyboardRestore extends StatefulWidget {
  const KeyboardRestore({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardRestore> createState() => _KeyboardRestoreState();
}

class _KeyboardRestoreState extends State<KeyboardRestore>
    with WidgetsBindingObserver {
  AppLifecycleState? _lifecycle = WidgetsBinding.instance.lifecycleState;
  EditableTextState? _editor;
  FocusNode? _focus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lifecycle;
    _lifecycle = state;
    if (state == AppLifecycleState.inactive &&
        previous == AppLifecycleState.resumed) {
      final focus = FocusManager.instance.primaryFocus;
      _focus = View.of(context).viewInsets.bottom > 0 ? focus : null;
      _editor = _focus?.context?.findAncestorStateOfType<EditableTextState>();
    } else if (state == AppLifecycleState.resumed) {
      final editor = _editor;
      final focus = _focus;
      _editor = null;
      _focus = null;
      if (editor == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _lifecycle == AppLifecycleState.resumed &&
            editor.mounted &&
            FocusManager.instance.primaryFocus == focus) {
          editor.requestKeyboard();
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
