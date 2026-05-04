import 'package:flutter/material.dart';

import 'deckhand_tokens.dart';

/// Deckhand's Material 3 theme. Drives every screen in the app.
///
/// The visual language is documented in the design handoff and
/// captured as design tokens in [DeckhandTokens]. This class wires
/// those tokens into a Material [ThemeData]:
///
///  * Token bundle is attached as a [ThemeExtension] so widgets can
///    pull the canonical OKLCH-derived palette via
///    `DeckhandTokens.of(context)`.
///  * The [ColorScheme] mirrors the tokens so existing widgets that
///    already reach for `theme.colorScheme.*` pick up the new palette
///    without code changes.
///  * Typography is forced onto IBM Plex Sans (and IBM Plex Mono is
///    available as a sibling family for monospace surfaces — paths,
///    hashes, screen-IDs, log streams, etc).
///  * Component themes (buttons, inputs, cards) flatten radii to the
///    technical scale (2/4/6/10) and lock in the compact-but-comfy
///    density the source spec asks for.
class DeckhandTheme {
  static ThemeData light() => _build(DeckhandTokens.light());
  static ThemeData dark() => _build(DeckhandTokens.dark());

  static ThemeData _build(DeckhandTokens t) {
    final isDark = t.brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: t.brightness,
      primary: t.accent,
      onPrimary: t.accentFg,
      primaryContainer: t.accentSoft,
      onPrimaryContainer: t.accent,
      secondary: t.info,
      onSecondary: isDark ? t.text : t.ink0,
      secondaryContainer: Color.alphaBlend(
        t.info.withValues(alpha: 0.12),
        t.ink1,
      ),
      onSecondaryContainer: t.info,
      tertiary: t.ok,
      onTertiary: isDark ? t.text : t.ink0,
      tertiaryContainer: Color.alphaBlend(
        t.ok.withValues(alpha: 0.12),
        t.ink1,
      ),
      onTertiaryContainer: t.ok,
      error: t.bad,
      onError: isDark ? t.text : const Color(0xFFFFFFFF),
      errorContainer: Color.alphaBlend(
        t.bad.withValues(alpha: 0.12),
        t.ink1,
      ),
      onErrorContainer: t.bad,
      surface: t.ink0,
      onSurface: t.text,
      onSurfaceVariant: t.text2,
      surfaceContainerLowest: t.ink0,
      surfaceContainerLow: t.ink1,
      surfaceContainer: t.ink1,
      surfaceContainerHigh: t.ink2,
      surfaceContainerHighest: t.ink3,
      outline: t.line,
      outlineVariant: t.lineSoft,
      shadow: Colors.black,
      scrim: Colors.black54,
      inverseSurface: isDark ? t.ink4 : t.ink1,
      onInverseSurface: isDark ? t.text : t.text,
      inversePrimary: t.accentBright,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.ink0,
      canvasColor: t.ink0,
      fontFamily: DeckhandTokens.fontSans,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      extensions: [t],
    );

    return base.copyWith(
      textTheme: _textTheme(t),
      iconTheme: IconThemeData(color: t.text2, size: 16),
      dividerTheme: DividerThemeData(
        color: t.lineSoft,
        space: 1,
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        color: t.ink1,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: t.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.accentFg,
          minimumSize: const Size(0, DeckhandTokens.hitHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          textStyle: const TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tMd,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.005 * DeckhandTokens.tMd,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.text,
          minimumSize: const Size(0, DeckhandTokens.hitHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          side: BorderSide(color: t.line),
          textStyle: const TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tMd,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.text2,
          minimumSize: const Size(0, DeckhandTokens.hitHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          textStyle: const TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tMd,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: t.text2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.ink2,
        hoverColor: t.ink3,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          borderSide: BorderSide(color: t.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          borderSide: BorderSide(color: t.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          borderSide: BorderSide(color: t.bad),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          borderSide: BorderSide(color: t.bad, width: 1.5),
        ),
        labelStyle: TextStyle(
          color: t.text3,
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tMd,
        ),
        hintStyle: TextStyle(
          color: t.text4,
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tMd,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(t.accentFg),
        side: BorderSide(color: t.rule),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r1),
        ),
        visualDensity: VisualDensity.compact,
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.rule;
        }),
        visualDensity: VisualDensity.compact,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accentFg;
          return t.text3;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.ink3;
        }),
        trackOutlineColor: WidgetStateProperty.all(t.line),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.ink2,
        circularTrackColor: t.accentSoft,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.ink3,
          border: Border.all(color: t.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
        ),
        textStyle: TextStyle(
          color: t.text,
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tSm,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.ink2,
        contentTextStyle: TextStyle(
          color: t.text,
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tMd,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          side: BorderSide(color: t.line),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.ink1,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r3),
          side: BorderSide(color: t.line),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: t.ink1,
        foregroundColor: t.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: t.text,
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tLg,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.01 * DeckhandTokens.tLg,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        thumbColor: WidgetStateProperty.all(t.ink3),
        radius: const Radius.circular(DeckhandTokens.r1),
      ),
    );
  }

  static TextTheme _textTheme(DeckhandTokens t) {
    const sans = DeckhandTokens.fontSans;
    return TextTheme(
      // Display — only used in design-language showcases, big hero
      // headlines on Foundations / S910 Done splash.
      displayLarge: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tDisplay,
        height: 1.05,
        letterSpacing: -0.02 * DeckhandTokens.tDisplay,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      displayMedium: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.t3Xl,
        height: 1.15,
        letterSpacing: -0.02 * DeckhandTokens.t3Xl,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      displaySmall: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.t2Xl,
        height: 1.3,
        letterSpacing: -0.015 * DeckhandTokens.t2Xl,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      // Headline — screen titles ("How should we install the new firmware?").
      headlineLarge: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.t2Xl,
        height: 1.3,
        letterSpacing: -0.015 * DeckhandTokens.t2Xl,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      headlineMedium: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.t2Xl,
        height: 1.3,
        letterSpacing: -0.015 * DeckhandTokens.t2Xl,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      headlineSmall: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tXl,
        height: 1.35,
        letterSpacing: -0.01 * DeckhandTokens.tXl,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      // Title — section heads, panel labels.
      titleLarge: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tLg,
        height: 1.4,
        letterSpacing: -0.01 * DeckhandTokens.tLg,
        fontWeight: FontWeight.w600,
        color: t.text,
      ),
      titleMedium: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tMd,
        height: 1.45,
        fontWeight: FontWeight.w600,
        color: t.text,
      ),
      titleSmall: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tSm,
        height: 1.45,
        fontWeight: FontWeight.w600,
        color: t.text,
      ),
      // Body — default reading text.
      bodyLarge: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tMd,
        height: 1.5,
        color: t.text,
      ),
      bodyMedium: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tMd,
        height: 1.5,
        color: t.text2,
      ),
      bodySmall: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tSm,
        height: 1.5,
        color: t.text3,
      ),
      // Label — chips, captions, dim metadata. Used as the source for
      // `theme.textTheme.labelSmall` which StatusPill reaches for.
      labelLarge: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tMd,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: t.text,
      ),
      labelMedium: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tSm,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: t.text2,
      ),
      labelSmall: TextStyle(
        fontFamily: sans,
        fontSize: DeckhandTokens.tXs,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: t.text3,
        letterSpacing: 0.04 * DeckhandTokens.tXs,
      ),
    );
  }
}
