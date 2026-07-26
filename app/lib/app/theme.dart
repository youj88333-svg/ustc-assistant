import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  const seed = Color(0xFF1F6B45);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      ).copyWith(
        primary: seed,
        secondary: const Color(0xFF9A5A18),
        error: const Color(0xFFB3261E),
        surface: const Color(0xFFF8FAF8),
      );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: const CardThemeData(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
}
