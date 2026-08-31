import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechanix_terminal/features/screen/settings_screen.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/l10n/app_localizations.dart';

void main() {
  group('TerminalSettingsPage Unit Tests', () {
    testWidgets('Renders settings page correctly and applies settings', (
      WidgetTester tester,
    ) async {
      final settings = AppSettings(
        id: 1,
        fontSize: 16.0,
        fontFamily: 'monospace',
        colorForeground: '#CDD6F4',
        colorBackground: '#1E1E2E',
        colorCursor: '#F5C2E7',
        colorSelection: '#45475A',
      );

      AppSettings? updatedSettings;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(useMaterial3: false),
          home: TerminalSettingsPage(
            settings: settings,
            onSettingsChanged: (s) {
              updatedSettings = s;
            },
          ),
        ),
      );

      // Verify header and basic tiles are rendered
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Customize'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Font'), findsOneWidget);
      expect(find.text('Foreground'), findsOneWidget);

      // Verify the passed settings are displayed
      expect(find.text('monospace 16px'), findsOneWidget);

      // Tap on Apply to apply settings
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Verify onSettingsChanged was called
      expect(updatedSettings, isNotNull);
      expect(updatedSettings!.fontSize, 16.0);
      expect(updatedSettings!.fontFamily, 'monospace');
      expect(updatedSettings!.colorForeground, '#cdd6f4'); // parsed format
    });
  });
}
