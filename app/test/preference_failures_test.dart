import 'dart:async';

import 'package:amicus/l10n/locale_provider.dart';
import 'package:amicus/shared/local_preferences.dart';
import 'package:amicus/theme/navigation_style_provider.dart';
import 'package:amicus/theme/theme_mode_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Preferences implements SharedPreferences {
  final values = <String, Object>{
    'theme_mode': 'dark',
    'app_locale': 'ru',
    'floating_navigation': true,
  };
  final writes = <Completer<bool>>[];

  @override
  String? getString(String key) => values[key] as String?;
  @override
  bool? getBool(String key) => values[key] as bool?;

  Future<bool> _write(String key, Object? value) async {
    final result = Completer<bool>();
    writes.add(result);
    final accepted = await result.future;
    if (accepted) {
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
    }
    return accepted;
  }

  @override
  Future<bool> setString(String key, String value) => _write(key, value);
  @override
  Future<bool> setBool(String key, bool value) => _write(key, value);
  @override
  Future<bool> remove(String key) => _write(key, null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Object? _read(ProviderContainer container, String kind) => switch (kind) {
  'theme' => container.read(themeModeProvider),
  'locale' => container.read(localeProvider),
  _ => container.read(floatingNavigationProvider),
};

Future<void> _set(ProviderContainer container, String kind, bool second) =>
    switch (kind) {
      'theme' =>
        container
            .read(themeModeProvider.notifier)
            .setMode(second ? ThemeMode.system : ThemeMode.light),
      'locale' =>
        container
            .read(localeProvider.notifier)
            .setLocale(second ? null : const Locale('en')),
      _ =>
        container.read(floatingNavigationProvider.notifier).setFloating(second),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['theme', 'locale', 'navigation']) {
    final initial = switch (kind) {
      'theme' => ThemeMode.dark,
      'locale' => const Locale('ru'),
      _ => true,
    };
    test('$kind uses saved preferences on the first read', () {
      final container = ProviderContainer(
        overrides: [localPreferencesProvider.overrideWithValue(_Preferences())],
      );
      addTearDown(container.dispose);
      expect(_read(container, kind), initial);
    });

    for (final firstSucceeds in [false, true]) {
      test(
        '$kind rolls back to the last saved value: $firstSucceeds',
        () async {
          final prefs = _Preferences();
          final container = ProviderContainer(
            overrides: [localPreferencesProvider.overrideWithValue(prefs)],
          );
          addTearDown(container.dispose);
          final first = _set(container, kind, false);
          final firstCheck = firstSucceeds
              ? expectLater(first, completes)
              : expectLater(first, throwsStateError);
          final second = _set(container, kind, true);
          final secondCheck = expectLater(second, throwsStateError);
          await Future<void>.delayed(Duration.zero);
          expect(prefs.writes, hasLength(1));
          prefs.writes.first.complete(firstSucceeds);
          await firstCheck;
          await Future<void>.delayed(Duration.zero);
          expect(prefs.writes, hasLength(2));
          prefs.writes.last.complete(false);
          await secondCheck;
          final firstValue = switch (kind) {
            'theme' => ThemeMode.light,
            'locale' => const Locale('en'),
            _ => false,
          };
          expect(_read(container, kind), firstSucceeds ? firstValue : initial);
        },
      );
    }

    test(
      '$kind finishes storage without touching a disposed notifier',
      () async {
        final prefs = _Preferences();
        final container = ProviderContainer(
          overrides: [localPreferencesProvider.overrideWithValue(prefs)],
        );
        final result = _set(container, kind, false);
        final check = expectLater(result, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        container.dispose();
        prefs.writes.single.complete(false);
        await check;
      },
    );
  }

  test(
    'an immediate language choice survives asynchronous hydration',
    () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'ru'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(localeProvider.notifier)
          .setLocale(const Locale('en'));
      expect(container.read(localeProvider), const Locale('en'));
      expect(
        (await SharedPreferences.getInstance()).getString('app_locale'),
        'en',
      );
    },
  );
}
