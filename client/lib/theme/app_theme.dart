import 'package:flutter/material.dart';

class AppTheme {
  // 颜色直接在 LumiColors factory 中内联定义
  static const _darkAccent = Color(0xFF5BACF0);
  static const _darkText = Color(0xFFEEF2F6);
  static const _darkBg = Color(0xFF17212B);

  static const _lightAccent = Color(0xFF2481CC);
  static const _lightText = Color(0xFF000000);
  static const _lightBg = Color(0xFFF0F2F5);

  static ThemeData dark({String? fontFamily}) {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _darkBg,
      colorScheme: const ColorScheme.dark(
        primary: _darkAccent,
        surface: _darkBg,
        onSurface: _darkText,
      ),
      fontFamily: fontFamily,
      extensions: [LumiColors.dark()],
    );
  }

  static ThemeData light({String? fontFamily}) {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: _lightBg,
      colorScheme: const ColorScheme.light(
        primary: _lightAccent,
        surface: _lightBg,
        onSurface: _lightText,
      ),
      fontFamily: fontFamily,
      extensions: [LumiColors.light()],
    );
  }
}

/// 自定义颜色扩展，在 widget 中用 Theme.of(context).extension(LumiColors)!.xxx 访问。
class LumiColors extends ThemeExtension<LumiColors> {
  final Color sidebar;
  final Color bubbleThem;
  final Color bubbleMe;
  final Color accent;
  final Color subtext;
  final Color inputBg;
  final Color divider;
  final Color onBubbleMe;
  final Color onBubbleThem;

  const LumiColors({
    required this.sidebar,
    required this.bubbleThem,
    required this.bubbleMe,
    required this.accent,
    required this.subtext,
    required this.inputBg,
    required this.divider,
    required this.onBubbleMe,
    required this.onBubbleThem,
  });

  factory LumiColors.dark() => const LumiColors(
    sidebar: Color(0xFF0E1621),
    bubbleThem: Color(0xFF182533),
    bubbleMe: Color(0xFF2B5278),
    accent: Color(0xFF5BACF0),
    subtext: Color(0xFF6C8EAD),
    inputBg: Color(0xFF0E1621),
    divider: Color(0xFF0D1117),
    onBubbleMe: Color(0xFFEEF2F6),
    onBubbleThem: Color(0xFFEEF2F6),
  );

  factory LumiColors.light() => const LumiColors(
    sidebar: Color(0xFFFFFFFF),
    bubbleThem: Color(0xFFFFFFFF),
    bubbleMe: Color(0xFFEFFBFF),
    accent: Color(0xFF2481CC),
    subtext: Color(0xFF707579),
    inputBg: Color(0xFFFFFFFF),
    divider: Color(0xFFDADDE1),
    onBubbleMe: Color(0xFF000000),
    onBubbleThem: Color(0xFF000000),
  );

  @override
  LumiColors copyWith({
    Color? sidebar,
    Color? bubbleThem,
    Color? bubbleMe,
    Color? accent,
    Color? subtext,
    Color? inputBg,
    Color? divider,
    Color? onBubbleMe,
    Color? onBubbleThem,
  }) {
    return LumiColors(
      sidebar: sidebar ?? this.sidebar,
      bubbleThem: bubbleThem ?? this.bubbleThem,
      bubbleMe: bubbleMe ?? this.bubbleMe,
      accent: accent ?? this.accent,
      subtext: subtext ?? this.subtext,
      inputBg: inputBg ?? this.inputBg,
      divider: divider ?? this.divider,
      onBubbleMe: onBubbleMe ?? this.onBubbleMe,
      onBubbleThem: onBubbleThem ?? this.onBubbleThem,
    );
  }

  @override
  LumiColors lerp(LumiColors? other, double t) {
    if (other == null) return this;
    return LumiColors(
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      bubbleThem: Color.lerp(bubbleThem, other.bubbleThem, t)!,
      bubbleMe: Color.lerp(bubbleMe, other.bubbleMe, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      subtext: Color.lerp(subtext, other.subtext, t)!,
      inputBg: Color.lerp(inputBg, other.inputBg, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      onBubbleMe: Color.lerp(onBubbleMe, other.onBubbleMe, t)!,
      onBubbleThem: Color.lerp(onBubbleThem, other.onBubbleThem, t)!,
    );
  }
}
