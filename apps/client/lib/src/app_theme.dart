import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 集中定义语义颜色，页面和弹层共用同一套 Material 3 层级。
abstract final class AppTheme {
  static final ThemeData light = _build(
    ColorScheme.fromSeed(seedColor: const Color(0xFF275DCA)).copyWith(
      primary: const Color(0xFF245AC3),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFE0EBFF),
      onPrimaryContainer: const Color(0xFF173B79),
      secondary: const Color(0xFF465D7E),
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFE7EDF7),
      onSecondaryContainer: const Color(0xFF263A56),
      tertiary: const Color(0xFF35675C),
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFD5EEE4),
      onTertiaryContainer: const Color(0xFF174E40),
      surface: const Color(0xFFF8FAFF),
      onSurface: const Color(0xFF1A2333),
      onSurfaceVariant: const Color(0xFF515D70),
      surfaceDim: const Color(0xFFDCE2EE),
      surfaceBright: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF2F5FC),
      surfaceContainer: const Color(0xFFECF0F8),
      surfaceContainerHigh: const Color(0xFFE6EBF5),
      surfaceContainerHighest: const Color(0xFFDFE6F1),
      outline: const Color(0xFF738096),
      outlineVariant: const Color(0xFFD7DFED),
      error: const Color(0xFFB3261E),
      onError: Colors.white,
      errorContainer: const Color(0xFFFFDAD6),
      onErrorContainer: const Color(0xFF7C1D18),
      inverseSurface: const Color(0xFF293244),
      onInverseSurface: const Color(0xFFF3F5FA),
      inversePrimary: const Color(0xFFAFC7FF),
      surfaceTint: const Color(0xFF245AC3),
    ),
  );

  static final ThemeData dark = _build(
    ColorScheme.fromSeed(
      seedColor: const Color(0xFFA481E7),
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFFC8ADFF),
      onPrimary: const Color(0xFF29164B),
      primaryContainer: const Color(0xFF3C2B5D),
      onPrimaryContainer: const Color(0xFFECDCFF),
      secondary: const Color(0xFFC6BDD9),
      onSecondary: const Color(0xFF30283E),
      secondaryContainer: const Color(0xFF342D44),
      onSecondaryContainer: const Color(0xFFE8DEF5),
      tertiary: const Color(0xFFA3D7CA),
      onTertiary: const Color(0xFF103B32),
      tertiaryContainer: const Color(0xFF244D44),
      onTertiaryContainer: const Color(0xFFC3F1E4),
      surface: const Color(0xFF101016),
      onSurface: const Color(0xFFF0EDF5),
      onSurfaceVariant: const Color(0xFFC1BACD),
      surfaceDim: const Color(0xFF101016),
      surfaceBright: const Color(0xFF37333F),
      surfaceContainerLowest: const Color(0xFF0B0B10),
      surfaceContainerLow: const Color(0xFF19171F),
      surfaceContainer: const Color(0xFF211E29),
      surfaceContainerHigh: const Color(0xFF2A2633),
      surfaceContainerHighest: const Color(0xFF35303F),
      outline: const Color(0xFF928A9F),
      outlineVariant: const Color(0xFF494251),
      error: const Color(0xFFFFB4AB),
      onError: const Color(0xFF690005),
      errorContainer: const Color(0xFF642624),
      onErrorContainer: const Color(0xFFFFDAD6),
      inverseSurface: const Color(0xFFE8E1F0),
      onInverseSurface: const Color(0xFF302B38),
      inversePrimary: const Color(0xFF65448F),
      surfaceTint: const Color(0xFFC8ADFF),
    ),
  );

  static ThemeData _build(ColorScheme colors) {
    final isDark = colors.brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
    final text = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        height: 1.22,
        letterSpacing: -0.8,
      ),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w600,
        height: 1.3,
        letterSpacing: -0.5,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        height: 1.35,
        letterSpacing: -0.4,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: -0.2,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.5,
        letterSpacing: 0,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.45,
        letterSpacing: 0,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontSize: 16,
        height: 1.6,
        letterSpacing: 0,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.55,
        letterSpacing: 0,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        height: 1.5,
        letterSpacing: 0.1,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0,
      ),
      labelMedium: base.textTheme.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0.1,
      ),
    );
    const pill = StadiumBorder();
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
    );
    final inputShape = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    final cardColor = isDark
        ? colors.surfaceContainerLow
        : colors.surfaceContainerLowest;

    return base.copyWith(
      textTheme: text,
      appBarTheme: AppBarThemeData(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        toolbarHeight: 72,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: cardShape,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: cardColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        border: inputShape,
        enabledBorder: inputShape,
        disabledBorder: inputShape.copyWith(
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: inputShape.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: inputShape.copyWith(
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: inputShape.copyWith(
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
        labelStyle: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        hintStyle: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        helperStyle: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        errorStyle: text.bodySmall?.copyWith(color: colors.error),
        errorMaxLines: 4,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: text.labelLarge,
          shape: pill,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          textStyle: text.labelLarge,
          shape: pill,
          side: BorderSide(color: colors.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: text.labelLarge,
          shape: pill,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(12),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.primaryContainer,
        foregroundColor: colors.onPrimaryContainer,
        elevation: 0,
        focusElevation: 2,
        hoverElevation: 2,
        highlightElevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 80,
        indicatorColor: colors.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return text.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.onPrimaryContainer
                : colors.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors.surface,
        indicatorColor: colors.primaryContainer,
        selectedIconTheme: IconThemeData(color: colors.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: colors.onSurfaceVariant),
        selectedLabelTextStyle: text.labelLarge?.copyWith(
          color: colors.primary,
        ),
        unselectedLabelTextStyle: text.labelLarge?.copyWith(
          color: colors.onSurfaceVariant,
        ),
        useIndicator: true,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: text.headlineSmall,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        modalBackgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? colors.surfaceContainerHigh : cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        textStyle: text.bodyMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            isDark ? colors.surfaceContainerHigh : cardColor,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surfaceContainerLow,
        selectedColor: colors.primaryContainer,
        labelStyle: text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
        secondaryLabelStyle: text.labelMedium?.copyWith(
          color: colors.onPrimaryContainer,
        ),
        side: BorderSide.none,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.onSurfaceVariant,
        textColor: colors.onSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        selectedTileColor: colors.primaryContainer,
        selectedColor: colors.onPrimaryContainer,
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: colors.onInverseSurface,
        ),
        actionTextColor: colors.inversePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: text.bodySmall?.copyWith(color: colors.onInverseSurface),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.primary,
        selectionColor: colors.primary.withValues(alpha: 0.24),
        selectionHandleColor: colors.primary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
        linearTrackColor: colors.surfaceContainerHighest,
        circularTrackColor: colors.surfaceContainerHighest,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: colors.primary,
        collapsedIconColor: colors.onSurfaceVariant,
        textColor: colors.onSurface,
        collapsedTextColor: colors.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}
