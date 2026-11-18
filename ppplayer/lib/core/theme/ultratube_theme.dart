import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ultratube design tokens: OLED black, layered near-black surfaces and a
/// single red accent. Every Ultratube screen reads colours from here (or the
/// derived [ColorScheme]); nothing hard-codes ad-hoc values.
abstract final class UT {
  // Surfaces (elevation = lighter step, never coloured tint).
  static const bg = Color(0xFF000000);
  static const surface1 = Color(0xFF0D0D0D); // sheets, nav bar
  static const surface2 = Color(0xFF161616); // cards, inputs, chips
  static const surface3 = Color(0xFF212121); // pressed / selected chip
  static const line = Color(0xFF262626);

  // Text.
  static const text = Color(0xFFF4F4F4);
  static const text2 = Color(0xFFA6A6A6);
  static const text3 = Color(0xFF6B6B6B);

  // Accent.
  static const red = Color(0xFFFF0033);
  static const redDeep = Color(0xFFB80025);
  static const redSoft = Color(0x29FF0033); // 16 % red wash

  // Twitch module accent (follow buttons, selected chips, bits). Live
  // badges stay red everywhere.
  static const twitch = Color(0xFF9146FF);
  static const twitchSoft = Color(0x299146FF);

  // Spacing (4/8 scale) and radii.
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 20.0, s6 = 24.0, s8 = 32.0;
  static const rSm = 8.0, rMd = 12.0, rLg = 16.0, rXl = 24.0;

  static const motion = Duration(milliseconds: 220);
  static const curve = Curves.easeOutCubic;
}

abstract final class UltratubeTheme {
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: UT.red,
      onPrimary: Colors.white,
      primaryContainer: UT.redSoft,
      onPrimaryContainer: Color(0xFFFFB3C0),
      secondary: UT.text,
      onSecondary: UT.bg,
      secondaryContainer: UT.surface3,
      onSecondaryContainer: UT.text,
      tertiary: UT.text2,
      onTertiary: UT.bg,
      error: Color(0xFFFF6B6B),
      onError: UT.bg,
      errorContainer: Color(0xFF3A1010),
      onErrorContainer: Color(0xFFFFB4AB),
      surface: UT.bg,
      onSurface: UT.text,
      onSurfaceVariant: UT.text2,
      surfaceContainerLowest: UT.bg,
      surfaceContainerLow: UT.surface1,
      surfaceContainer: UT.surface1,
      surfaceContainerHigh: UT.surface2,
      surfaceContainerHighest: UT.surface2,
      surfaceTint: Colors.transparent,
      outline: UT.text3,
      outlineVariant: UT.line,
      inverseSurface: UT.text,
      onInverseSurface: UT.bg,
      inversePrimary: UT.redDeep,
      scrim: Colors.black,
      shadow: Colors.black,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
    final text = base.textTheme.apply(bodyColor: UT.text, displayColor: UT.text);
    final stadium = WidgetStatePropertyAll<OutlinedBorder>(const StadiumBorder());

    return base.copyWith(
      scaffoldBackgroundColor: UT.bg,
      canvasColor: UT.bg,
      splashFactory: InkSparkle.splashFactory,
      highlightColor: Colors.white.withValues(alpha: 0.04),
      splashColor: Colors.white.withValues(alpha: 0.06),
      dividerColor: UT.line,
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: -0.3),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 15.5, letterSpacing: -0.1),
        bodyMedium: text.bodyMedium?.copyWith(color: UT.text2, fontSize: 13.5),
        bodySmall: text.bodySmall?.copyWith(color: UT.text2, fontSize: 12),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: UT.bg,
        foregroundColor: UT.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: UT.text),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: UT.bg,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      ),
      iconTheme: const IconThemeData(color: UT.text, size: 24),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(UT.text),
          overlayColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: stadium,
          minimumSize: const WidgetStatePropertyAll(Size(64, 40)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? UT.surface3 : UT.text,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? UT.text3 : UT.bg,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: stadium,
          side: const WidgetStatePropertyAll(BorderSide(color: UT.line)),
          foregroundColor: const WidgetStatePropertyAll(UT.text),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(shape: stadium, foregroundColor: const WidgetStatePropertyAll(UT.text)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: UT.surface2,
        selectedColor: UT.text,
        disabledColor: UT.surface2,
        labelStyle: const TextStyle(color: UT.text, fontWeight: FontWeight.w600, fontSize: 13.5),
        secondaryLabelStyle: const TextStyle(color: UT.bg, fontWeight: FontWeight.w600, fontSize: 13.5),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UT.rSm)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        showCheckmark: false,
      ),
      cardTheme: CardThemeData(
        color: UT.surface2,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UT.rMd)),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: UT.text,
        textColor: UT.text,
        subtitleTextStyle: TextStyle(color: UT.text2, fontSize: 12.5),
      ),
      dividerTheme: const DividerThemeData(color: UT.line, thickness: 0.6, space: 1),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: UT.surface1,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: UT.surface1,
        dragHandleColor: UT.text3,
        dragHandleSize: Size(36, 4),
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(UT.rXl))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: UT.surface1,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UT.rXl)),
        titleTextStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: UT.text),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: UT.surface2,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UT.rLg)),
        textStyle: const TextStyle(color: UT.text, fontSize: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: UT.surface3,
        contentTextStyle: const TextStyle(color: UT.text, fontSize: 14),
        actionTextColor: UT.red,
        insetPadding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UT.rMd)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: UT.surface2,
        hintStyle: const TextStyle(color: UT.text3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(UT.rXl), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(UT.rXl),
          borderSide: const BorderSide(color: UT.line),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: UT.red,
        linearTrackColor: UT.surface3,
        circularTrackColor: Colors.transparent,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: UT.red,
        thumbColor: UT.red,
        inactiveTrackColor: Color(0x33FFFFFF),
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : UT.text2),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? UT.red : UT.surface3),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? UT.text : UT.surface2),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? UT.bg : UT.text),
          side: const WidgetStatePropertyAll(BorderSide.none),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: UT.surface3, borderRadius: BorderRadius.circular(UT.rSm)),
        textStyle: const TextStyle(color: UT.text, fontSize: 12),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()},
      ),
    );
  }
}
