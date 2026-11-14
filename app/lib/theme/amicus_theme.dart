import 'package:flutter/material.dart';

/// A quiet reading surface for a small circle of people, in two light levels.
abstract final class AmicusTheme {
  static final light = _build(
    const ColorScheme.light(
      primary: Color(0xFF146B68),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFDCEFED),
      onPrimaryContainer: Color(0xFF153E3B),
      secondary: Color(0xFF41616B),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFE0EBEF),
      onSecondaryContainer: Color(0xFF203F48),
      tertiary: Color(0xFF986019),
      onTertiary: Colors.white,
      error: Color(0xFFAB3549),
      onError: Colors.white,
      errorContainer: Color(0xFFFFE1E5),
      onErrorContainer: Color(0xFF5A1525),
      surface: Color(0xFFF3F7F8),
      onSurface: Color(0xFF18363A),
      onSurfaceVariant: Color(0xFF50686C),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Color(0xFFEDF3F4),
      surfaceContainer: Color(0xFFE7EFF0),
      surfaceContainerHigh: Color(0xFFDFE9EB),
      surfaceContainerHighest: Color(0xFFD6E3E5),
      outline: Color(0xFF6E878B),
      outlineVariant: Color(0xFFCCDCDD),
      inverseSurface: Color(0xFF203F44),
      onInverseSurface: Color(0xFFECF5F5),
      inversePrimary: Color(0xFF8DD5CB),
    ),
  );

  static final dark = _build(
    const ColorScheme.dark(
      primary: Color(0xFF8DD5CB),
      onPrimary: Color(0xFF103B37),
      primaryContainer: Color(0xFF28504F),
      onPrimaryContainer: Color(0xFFD8F2EB),
      secondary: Color(0xFFADCBD5),
      onSecondary: Color(0xFF153B46),
      secondaryContainer: Color(0xFF304C56),
      onSecondaryContainer: Color(0xFFD8ECF1),
      tertiary: Color(0xFFE9BB79),
      onTertiary: Color(0xFF47300E),
      error: Color(0xFFFFABB8),
      onError: Color(0xFF5A1525),
      errorContainer: Color(0xFF632B38),
      onErrorContainer: Color(0xFFFFDDE3),
      surface: Color(0xFF112B30),
      onSurface: Color(0xFFE5F1F2),
      onSurfaceVariant: Color(0xFFB0C8CC),
      surfaceContainerLowest: Color(0xFF19363B),
      surfaceContainerLow: Color(0xFF173237),
      surfaceContainer: Color(0xFF203E44),
      surfaceContainerHigh: Color(0xFF29484E),
      surfaceContainerHighest: Color(0xFF34565C),
      outline: Color(0xFF89A7AC),
      outlineVariant: Color(0xFF39595E),
      inverseSurface: Color(0xFFE5F1F2),
      onInverseSurface: Color(0xFF18363A),
      inversePrimary: Color(0xFF146B68),
    ),
  );

  static ThemeData _build(ColorScheme scheme) {
    TextStyle type(double size, FontWeight weight, double height) => TextStyle(
      fontFamily: 'Sofia Sans',
      locale: const Locale('ru'),
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: 0,
      color: scheme.onSurface,
    );
    final text = TextTheme(
      displayLarge: type(52, FontWeight.w700, 1.05),
      displayMedium: type(44, FontWeight.w700, 1.1),
      displaySmall: type(36, FontWeight.w700, 1.1),
      headlineLarge: type(32, FontWeight.w700, 1.15),
      headlineMedium: type(28, FontWeight.w700, 1.15),
      headlineSmall: type(24, FontWeight.w600, 1.2),
      titleLarge: type(21, FontWeight.w600, 1.25),
      titleMedium: type(17, FontWeight.w600, 1.3),
      titleSmall: type(15, FontWeight.w600, 1.3),
      bodyLarge: type(17, FontWeight.w400, 1.45),
      bodyMedium: type(15, FontWeight.w400, 1.45),
      bodySmall: type(
        13,
        FontWeight.w400,
        1.35,
      ).copyWith(color: scheme.onSurfaceVariant),
      labelLarge: type(15, FontWeight.w600, 1.25),
      labelMedium: type(13, FontWeight.w500, 1.25),
      labelSmall: type(12, FontWeight.w500, 1.25),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      fontFamily: 'Sofia Sans',
      textTheme: text,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        toolbarHeight: 72,
        titleSpacing: 20,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.headlineMedium,
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          textStyle: text.labelLarge,
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          textStyle: text.labelLarge,
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: text.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.all(16),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        minVerticalPadding: 12,
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.primaryContainer,
        labelStyle: text.labelMedium,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.headlineSmall,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
      ),
    );
  }
}
