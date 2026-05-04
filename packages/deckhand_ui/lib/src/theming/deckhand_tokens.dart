import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Design tokens for the Deckhand visual system.
///
/// The source spec is OKLCH. Flutter's [Color] is sRGB, so we convert
/// once at construction time via [oklch]. Keeping the OKLCH source in
/// the call sites means the palette reads the same as the design doc
/// and re-tinting (different accent hue, etc.) stays a one-line edit.
@immutable
class DeckhandTokens extends ThemeExtension<DeckhandTokens> {
  const DeckhandTokens({
    required this.brightness,
    required this.ink0,
    required this.ink1,
    required this.ink2,
    required this.ink3,
    required this.ink4,
    required this.line,
    required this.lineSoft,
    required this.rule,
    required this.text,
    required this.text2,
    required this.text3,
    required this.text4,
    required this.gridLine,
    required this.accent,
    required this.accentDim,
    required this.accentBright,
    required this.accentSoft,
    required this.accentFg,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.info,
  });

  /// Default UV-violet accent hue. Locked to a single brand value.
  static const double accentHue = 285;
  static const double accentChroma = 0.15;
  static const double accentLightness = 0.72;

  /// Cool slate hue used for every neutral. Flat across the system —
  /// only the accent varies in chroma.
  static const double mutedHue = 250;

  /// Density (`--u` in the source). All spacing should be a multiple
  /// of this value.
  static const double unit = 5;

  /// Default row height (nav items, list rows).
  static const double rowHeight = 36;

  /// Default hit target (buttons, inputs).
  static const double hitHeight = 40;

  /// Horizontal padding inside surfaces.
  static const double padX = 16;

  /// Vertical padding inside surfaces.
  static const double padY = 12;

  // --- Type sizes ---------------------------------------------------
  static const double tXs = 11;
  static const double tSm = 12;
  static const double tMd = 14;
  static const double tLg = 16;
  static const double tXl = 18;
  static const double t2Xl = 22;
  static const double t3Xl = 32;
  static const double tDisplay = 56;

  // --- Radii (small, technical) -------------------------------------
  static const double r1 = 2;
  static const double r2 = 4;
  static const double r3 = 6;
  static const double r4 = 10;

  // --- Font families ------------------------------------------------
  static const String fontSans = 'IBMPlexSans';
  static const String fontMono = 'IBMPlexMono';

  /// Where this token bundle lives. Light vs dark.
  final Brightness brightness;

  // Surface ladder — backgrounds, panels, cards, hover, raised.
  final Color ink0;
  final Color ink1;
  final Color ink2;
  final Color ink3;
  final Color ink4;

  // Lines and rules.
  final Color line;
  final Color lineSoft;
  final Color rule;

  // Text ladder.
  final Color text;
  final Color text2;
  final Color text3;
  final Color text4;

  // Decorative grid line for the workshop background.
  final Color gridLine;

  // Accent family (UV violet).
  final Color accent;
  final Color accentDim;
  final Color accentBright;
  final Color accentSoft;
  final Color accentFg;

  // Status family.
  final Color ok;
  final Color warn;
  final Color bad;
  final Color info;

  /// Dark theme tokens. Default / preferred mode.
  factory DeckhandTokens.dark() {
    return DeckhandTokens(
      brightness: Brightness.dark,
      ink0:     oklch(0.13, 0.012, mutedHue),
      ink1:     oklch(0.17, 0.013, mutedHue),
      ink2:     oklch(0.21, 0.014, mutedHue),
      ink3:     oklch(0.26, 0.015, mutedHue),
      ink4:     oklch(0.32, 0.016, mutedHue),
      line:     oklch(0.30, 0.014, mutedHue),
      lineSoft: oklch(0.25, 0.013, mutedHue),
      rule:     oklch(0.40, 0.014, mutedHue),
      text:     oklch(0.96, 0.005, mutedHue),
      text2:    oklch(0.78, 0.010, mutedHue),
      text3:    oklch(0.60, 0.012, mutedHue),
      text4:    oklch(0.45, 0.013, mutedHue),
      gridLine: oklch(0.22, 0.012, mutedHue, alpha: 0.6),
      accent:       oklch(accentLightness, accentChroma, accentHue),
      accentDim:    oklch(accentLightness - 0.08, accentChroma - 0.04, accentHue),
      accentBright: oklch(0.82, accentChroma, accentHue),
      accentSoft:   oklch(accentLightness, accentChroma, accentHue, alpha: 0.12),
      accentFg:     oklch(0.16, 0.012, accentHue),
      ok:   oklch(0.78, 0.13, 145),
      warn: oklch(0.80, 0.14,  75),
      bad:  oklch(0.70, 0.18,  25),
      info: oklch(0.78, 0.10, 220),
    );
  }

  /// Light theme tokens. Mirrors the dark ladder with warm-tinted
  /// near-whites; status hues are darkened for legibility on light
  /// surfaces (per the source spec — pale-green ok was unreadable on
  /// white).
  ///
  /// The accent is also darkened relative to dark mode. The source
  /// spec used the same UV violet (L=0.72) for both themes, but a
  /// pale-purple FilledButton on a near-white surface read as
  /// decorative rather than clickable. A darker accent (L≈0.55)
  /// gives white-on-violet enough contrast to feel like a real
  /// primary action.
  factory DeckhandTokens.light() {
    const lightAccentLightness = 0.55;
    const lightAccentChroma = 0.20;
    return DeckhandTokens(
      brightness: Brightness.light,
      ink0:     oklch(0.985, 0.003, mutedHue),
      ink1:     oklch(0.97,  0.004, mutedHue),
      ink2:     oklch(0.945, 0.005, mutedHue),
      ink3:     oklch(0.92,  0.006, mutedHue),
      ink4:     oklch(0.88,  0.008, mutedHue),
      line:     oklch(0.85,  0.008, mutedHue),
      lineSoft: oklch(0.90,  0.006, mutedHue),
      rule:     oklch(0.72,  0.010, mutedHue),
      text:     oklch(0.18,  0.012, mutedHue),
      text2:    oklch(0.36,  0.012, mutedHue),
      text3:    oklch(0.50,  0.012, mutedHue),
      text4:    oklch(0.62,  0.010, mutedHue),
      gridLine: oklch(0.90,  0.006, mutedHue, alpha: 0.7),
      accent:       oklch(lightAccentLightness, lightAccentChroma, accentHue),
      accentDim:    oklch(lightAccentLightness - 0.08, lightAccentChroma - 0.03, accentHue),
      accentBright: oklch(lightAccentLightness + 0.08, lightAccentChroma, accentHue),
      accentSoft:   oklch(lightAccentLightness, lightAccentChroma, accentHue, alpha: 0.10),
      accentFg:     const Color(0xFFFCFCFC),
      ok:   oklch(0.50, 0.16, 145),
      warn: oklch(0.55, 0.16,  65),
      bad:  oklch(0.52, 0.20,  25),
      info: oklch(0.55, 0.13, 220),
    );
  }

  /// Convenience — fetches the active token bundle from the nearest
  /// theme. Throws if the theme has not been wired up; that would be a
  /// developer mistake we want to surface loudly.
  static DeckhandTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<DeckhandTokens>();
    assert(
      tokens != null,
      'DeckhandTokens missing — did you build with DeckhandTheme?',
    );
    return tokens!;
  }

  @override
  DeckhandTokens copyWith({
    Brightness? brightness,
    Color? ink0,
    Color? ink1,
    Color? ink2,
    Color? ink3,
    Color? ink4,
    Color? line,
    Color? lineSoft,
    Color? rule,
    Color? text,
    Color? text2,
    Color? text3,
    Color? text4,
    Color? gridLine,
    Color? accent,
    Color? accentDim,
    Color? accentBright,
    Color? accentSoft,
    Color? accentFg,
    Color? ok,
    Color? warn,
    Color? bad,
    Color? info,
  }) {
    return DeckhandTokens(
      brightness: brightness ?? this.brightness,
      ink0:        ink0        ?? this.ink0,
      ink1:        ink1        ?? this.ink1,
      ink2:        ink2        ?? this.ink2,
      ink3:        ink3        ?? this.ink3,
      ink4:        ink4        ?? this.ink4,
      line:        line        ?? this.line,
      lineSoft:    lineSoft    ?? this.lineSoft,
      rule:        rule        ?? this.rule,
      text:        text        ?? this.text,
      text2:       text2       ?? this.text2,
      text3:       text3       ?? this.text3,
      text4:       text4       ?? this.text4,
      gridLine:    gridLine    ?? this.gridLine,
      accent:      accent      ?? this.accent,
      accentDim:   accentDim   ?? this.accentDim,
      accentBright:accentBright?? this.accentBright,
      accentSoft:  accentSoft  ?? this.accentSoft,
      accentFg:    accentFg    ?? this.accentFg,
      ok:          ok          ?? this.ok,
      warn:        warn        ?? this.warn,
      bad:         bad         ?? this.bad,
      info:        info        ?? this.info,
    );
  }

  @override
  DeckhandTokens lerp(ThemeExtension<DeckhandTokens>? other, double t) {
    if (other is! DeckhandTokens) return this;
    return DeckhandTokens(
      brightness:   t < 0.5 ? brightness : other.brightness,
      ink0:         Color.lerp(ink0, other.ink0, t)!,
      ink1:         Color.lerp(ink1, other.ink1, t)!,
      ink2:         Color.lerp(ink2, other.ink2, t)!,
      ink3:         Color.lerp(ink3, other.ink3, t)!,
      ink4:         Color.lerp(ink4, other.ink4, t)!,
      line:         Color.lerp(line, other.line, t)!,
      lineSoft:     Color.lerp(lineSoft, other.lineSoft, t)!,
      rule:         Color.lerp(rule, other.rule, t)!,
      text:         Color.lerp(text, other.text, t)!,
      text2:        Color.lerp(text2, other.text2, t)!,
      text3:        Color.lerp(text3, other.text3, t)!,
      text4:        Color.lerp(text4, other.text4, t)!,
      gridLine:     Color.lerp(gridLine, other.gridLine, t)!,
      accent:       Color.lerp(accent, other.accent, t)!,
      accentDim:    Color.lerp(accentDim, other.accentDim, t)!,
      accentBright: Color.lerp(accentBright, other.accentBright, t)!,
      accentSoft:   Color.lerp(accentSoft, other.accentSoft, t)!,
      accentFg:     Color.lerp(accentFg, other.accentFg, t)!,
      ok:           Color.lerp(ok, other.ok, t)!,
      warn:         Color.lerp(warn, other.warn, t)!,
      bad:          Color.lerp(bad, other.bad, t)!,
      info:         Color.lerp(info, other.info, t)!,
    );
  }
}

/// Build an sRGB [Color] from OKLCH coordinates. Hue is in degrees,
/// chroma and lightness are 0..1. Optional [alpha] is sRGB linear.
///
/// The OKLab matrix is Björn Ottosson's reference (oklab.com).
/// Out-of-gamut colors are clamped after the linear→sRGB transfer.
/// We accept that "deep red at high chroma" can land slightly off
/// the gamut edge — better than refusing to render the color at all.
Color oklch(double l, double c, double hDegrees, {double alpha = 1.0}) {
  final hRad = hDegrees * math.pi / 180.0;
  final a = c * math.cos(hRad);
  final b = c * math.sin(hRad);

  // OKLab → linear sRGB (Ottosson reference matrix, expanded form).
  final lp = l + 0.3963377774 * a + 0.2158037573 * b;
  final mp = l - 0.1055613458 * a - 0.0638541728 * b;
  final sp = l - 0.0894841775 * a - 1.2914855480 * b;

  final lc = lp * lp * lp;
  final mc = mp * mp * mp;
  final sc = sp * sp * sp;

  final rLin =  4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc;
  final gLin = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc;
  final bLin = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc;

  final r = _linearToSrgb(rLin);
  final g = _linearToSrgb(gLin);
  final bb = _linearToSrgb(bLin);

  return Color.from(
    alpha: alpha,
    red: r.clamp(0.0, 1.0),
    green: g.clamp(0.0, 1.0),
    blue: bb.clamp(0.0, 1.0),
  );
}

double _linearToSrgb(double c) {
  if (c <= 0.0031308) return 12.92 * c;
  return 1.055 * math.pow(c, 1.0 / 2.4) - 0.055;
}
