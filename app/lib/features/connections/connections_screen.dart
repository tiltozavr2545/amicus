import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connections_repository.dart';

class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  final _codeController = TextEditingController();

  String? _myInviteCode;
  bool _isCreatingLink = false;

  bool _isActivating = false;
  String? _activationMessage;
  bool _activationSucceeded = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _createInviteLink() async {
    setState(() => _isCreatingLink = true);
    try {
      final code = await ref
          .read(connectionsRepositoryProvider)
          .createInviteLink();
      setState(() => _myInviteCode = code);
    } finally {
      if (mounted) setState(() => _isCreatingLink = false);
    }
  }

  Future<void> _activate() async {
    setState(() {
      _isActivating = true;
      _activationMessage = null;
    });
    try {
      final connection = await ref
          .read(connectionsRepositoryProvider)
          .activateInviteLink(_codeController.text.trim());
      setState(() {
        _activationSucceeded = true;
        _activationMessage = 'Вы теперь знакомы с ${connection.ownerName}';
      });
    } on PostgrestException catch (e) {
      setState(() {
        _activationSucceeded = false;
        _activationMessage = e.message;
      });
    } finally {
      if (mounted) setState(() => _isActivating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Знакомства')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Пригласить', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (_myInviteCode != null)
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _myInviteCode!,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Скопировать',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _myInviteCode!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Код скопирован')),
                    );
                  },
                ),
              ],
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _isCreatingLink ? null : _createInviteLink,
            child: _isCreatingLink
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _myInviteCode == null
                        ? 'Создать код приглашения'
                        : 'Создать новый код',
                  ),
          ),
          const SizedBox(height: 32),
          Text(
            'У меня есть код',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: const InputDecoration(labelText: 'Код приглашения'),
          ),
          const SizedBox(height: 12),
          if (_activationMessage != null) ...[
            Text(
              _activationMessage!,
              style: TextStyle(
                color: _activationSucceeded
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            onPressed: _isActivating ? null : _activate,
            child: _isActivating
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Активировать'),
          ),
        ],
      ),
    );
  }
}
