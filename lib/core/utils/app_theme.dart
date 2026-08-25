import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppTheme {
  static const String fontFamily = 'monospace';

  static final dark = ThemeData.dark(useMaterial3: true).copyWith(
    primaryColor: Colors.black,
    scaffoldBackgroundColor: Colors.black,
    scrollbarTheme: const ScrollbarThemeData(
      thumbVisibility: WidgetStatePropertyAll(false),
      trackVisibility: WidgetStatePropertyAll(false),
      thickness: WidgetStatePropertyAll(0.0),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.linux: CupertinoPageTransitionsBuilder()},
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Colors.white70,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: Colors.white, size: 20),
      actionsIconTheme: IconThemeData(color: Colors.white, size: 20),
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF151515),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Colors.white10,
      space: 16,
      thickness: 1,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFF8E8E93),
      textColor: Colors.white,
      contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      visualDensity: VisualDensity(vertical: -1),
    ),
  );

  static final light = ThemeData.light(useMaterial3: true).copyWith(
    primaryColor: Colors.white,
    scaffoldBackgroundColor: Colors.white,
    scrollbarTheme: const ScrollbarThemeData(
      thumbVisibility: WidgetStatePropertyAll(false),
      trackVisibility: WidgetStatePropertyAll(false),
      thickness: WidgetStatePropertyAll(0.0),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.linux: CupertinoPageTransitionsBuilder()},
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Colors.black54,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: Colors.black, size: 20),
      actionsIconTheme: IconThemeData(color: Colors.black, size: 20),
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        color: Colors.black,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFFF5F5F5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Colors.black12,
      space: 16,
      thickness: 1,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFF8E8E93),
      textColor: Colors.black,
      contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      visualDensity: VisualDensity(vertical: -1),
    ),
  );
}
