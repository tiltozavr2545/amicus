import 'package:amicus/theme/navigation_style_provider.dart';
import 'package:amicus/theme/theme_mode_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    test('Existing ${mode.name} preference survives the redesign', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': mode.name});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(themeModeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(themeModeProvider), mode);
    });
  }

  test(
    'An immediate choice wins over preference loading and survives restart',
    () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      final first = ProviderContainer();
      addTearDown(first.dispose);
      await first.read(themeModeProvider.notifier).setMode(ThemeMode.light);
      expect(first.read(themeModeProvider), ThemeMode.light);
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      restarted.read(themeModeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(restarted.read(themeModeProvider), ThemeMode.light);
    },
  );

  test('Rapid appearance selections persist the last choice', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final theme = container.read(themeModeProvider.notifier);
    final navigation = container.read(floatingNavigationProvider.notifier);
    await Future.wait([
      theme.setMode(ThemeMode.dark),
      theme.setMode(ThemeMode.light),
      theme.setMode(ThemeMode.system),
      navigation.setFloating(true),
      navigation.setFloating(false),
    ]);
    expect(container.read(themeModeProvider), ThemeMode.system);
    expect(container.read(floatingNavigationProvider), false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'system');
    expect(prefs.getBool('floating_navigation'), false);
  });
}
