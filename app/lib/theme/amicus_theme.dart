import 'package:flutter/material.dart';

/// Neutral album surfaces with a restrained berry accent for actions.
abstract final class AmicusTheme {
  static final light = _build(
    const ColorScheme.light(
      primary: Color(0xFF6354A5),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFEDEAF5),
      onPrimaryContainer: Color(0xFF3B305F),
      secondary: Color(0xFF62616D),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFEBEBEF),
      onSecondaryContainer: Color(0xFF373640),
      tertiary: Color(0xFF88651E),
      onTertiary: Colors.white,
      error: Color(0xFFAB3549),
      onError: Colors.white,
      errorContainer: Color(0xFFFFE1E5),
      onErrorContainer: Color(0xFF5A1525),
      surface: Color(0xFFF5F5F7),
      onSurface: Color(0xFF25252B),
      onSurfaceVariant: Color(0xFF666670),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Color(0xFFF0F0F3),
      surfaceContainer: Color(0xFFEBEBEF),
      surfaceContainerHigh: Color(0xFFE3E3E9),
      surfaceContainerHighest: Color(0xFFDCDCE3),
      outline: Color(0xFF7A7985),
      outlineVariant: Color(0xFFDADAE2),
      inverseSurface: Color(0xFF303036),
      onInverseSurface: Color(0xFFF4F4F7),
      inversePrimary: Color(0xFFC3B6F2),
    ),
  );

  static final dark = _build(
    const ColorScheme.dark(
      primary: Color(0xFFC3B6F2),
      onPrimary: Color(0xFF30234E),
      primaryContainer: Color(0xFF383146),
      onPrimaryContainer: Color(0xFFEBE4FF),
      secondary: Color(0xFFC8C5D1),
      onSecondary: Color(0xFF302E38),
      secondaryContainer: Color(0xFF3B3943),
      onSecondaryContainer: Color(0xFFEAE7F0),
      tertiary: Color(0xFFD9BB79),
      onTertiary: Color(0xFF47300E),
      error: Color(0xFFFFABB8),
      onError: Color(0xFF5A1525),
      errorContainer: Color(0xFF632B38),
      onErrorContainer: Color(0xFFFFDDE3),
      surface: Color(0xFF1B1B1F),
      onSurface: Color(0xFFEFEFF3),
      onSurfaceVariant: Color(0xFFB9B8C2),
      surfaceContainerLowest: Color(0xFF242429),
      surfaceContainerLow: Color(0xFF222227),
      surfaceContainer: Color(0xFF29292F),
      surfaceContainerHigh: Color(0xFF313138),
      surfaceContainerHighest: Color(0xFF3B3B43),
      outline: Color(0xFF92919D),
      outlineVariant: Color(0xFF45454F),
      inverseSurface: Color(0xFFEFEFF3),
      onInverseSurface: Color(0xFF25252B),
      inversePrimary: Color(0xFF6354A5),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.surfaceContainerHigh,
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
          foregroundColor: scheme.onSurface,
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
        selectedColor: scheme.surfaceContainerHigh,
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
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.2),
        selectionHandleColor: scheme.primary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
      ),
    );
  }
}
