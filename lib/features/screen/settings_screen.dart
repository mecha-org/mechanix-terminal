import 'package:flutter/material.dart';
import 'package:mechanix_terminal/core/utils/constants.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/features/widgets/color_tile.dart';
import 'package:mechanix_terminal/features/widgets/settings_tile.dart';
import 'package:mechanix_terminal/l10n/app_localizations.dart';

class TerminalSettingsPage extends StatefulWidget {
  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;

  const TerminalSettingsPage({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
  });

  @override
  State<TerminalSettingsPage> createState() => _TerminalSettingsPageState();
}

class _TerminalSettingsPageState extends State<TerminalSettingsPage> {
  late double _fontSize;
  late String _fontFamily;
  late int _colorFg;
  late int _colorBg;
  late int _colorCursor;
  late int _colorSelection;
  late String _themeName;

  static const _surface = Color(0xFF25262B);
  static const _border = Color(0xFF2C2D32);
  static const _textPrimary = Color(0xFFCDD6F4);
  static const _textMuted = Color(0xFF6C7086);
  static const _accent = Color(0xFFFFAB40);

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _fontSize = s.fontSize;
    _fontFamily = s.fontFamily ?? 'monospace';
    _colorFg = _parseColorToInt(s.colorForeground) ?? 0xCDD6F4;
    _colorBg = _parseColorToInt(s.colorBackground) ?? 0x1E1E2E;
    _colorCursor = _parseColorToInt(s.colorCursor) ?? 0xF5C2E7;
    _colorSelection = _parseColorToInt(s.colorSelection) ?? 0x45475A;
    _themeName = _detectTheme();
  }

  int? _parseColorToInt(String? hexString) {
    if (hexString == null) return null;
    final clean = hexString.replaceFirst('#', '');
    return int.tryParse(clean, radix: 16);
  }

  String _detectTheme() {
    for (final t in terminalThemes) {
      if (t.bg == _colorBg && t.fg == _colorFg) return t.name;
    }
    return 'custom';
  }

  void _applyTheme(TermTheme t) {
    setState(() {
      _themeName = t.name;
      _colorFg = t.fg;
      _colorBg = t.bg;
      _colorCursor = t.cursor;
      _colorSelection = t.selection;
    });
  }

  void _applySettings() {
    final updated = AppSettings(
      id: widget.settings.id,
      fontSize: _fontSize,
      fontFamily: _fontFamily,
      colorForeground: '#${_colorFg.toRadixString(16).padLeft(6, '0')}',
      colorBackground: '#${_colorBg.toRadixString(16).padLeft(6, '0')}',
      colorCursor: '#${_colorCursor.toRadixString(16).padLeft(6, '0')}',
      colorSelection: '#${_colorSelection.toRadixString(16).padLeft(6, '0')}',
    );
    widget.onSettingsChanged(updated);
    Navigator.pop(context);
  }

  void _showThemePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: _textMuted,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          ...terminalThemes.map(
            (t) => ListTile(
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Color(0xFF000000 | t.bg),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _border),
                ),
                child: Center(
                  child: Text(
                    'A',
                    style: TextStyle(
                      color: Color(0xFF000000 | t.fg),
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              title: Text(
                t.name,
                style: const TextStyle(
                  color: _textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 14,
                ),
              ),
              trailing: _themeName == t.name
                  ? const Icon(Icons.check, color: _accent, size: 18)
                  : null,
              onTap: () {
                _applyTheme(t);
                Navigator.pop(context);
              },
              splashColor: Colors.transparent,
              hoverColor: Colors.white.withValues(alpha: 0.05),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _showFontPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        double tempFontSize = _fontSize;
        String tempFontFamily = _fontFamily;

        return StatefulBuilder(
          builder: (context, modalSetState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _textMuted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'Font Size: ${_fontSize.round()}px',
                    style: const TextStyle(
                      color: _textMuted,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Slider(
                    value: tempFontSize,
                    min: 8,
                    max: 32,
                    divisions: 24,
                    activeColor: _accent,
                    inactiveColor: _border,
                    label: '${_fontSize.round()}px',
                    onChanged: (v) {
                      modalSetState(() {
                        tempFontSize = v;
                      });
                      setState(() {
                        _fontSize = v;
                      });
                    },
                  ),
                ),
                const Divider(color: _border, height: 1),
                ...fontFamilies.map(
                  (f) => ListTile(
                    title: Text(
                      f,
                      style: TextStyle(
                        color: _textPrimary,
                        fontFamily: f == 'monospace' ? 'monospace' : null,
                        fontSize: 14,
                      ),
                    ),
                    trailing: tempFontFamily == f
                        ? const Icon(Icons.check, color: _accent, size: 18)
                        : null,
                    onTap: () {
                      modalSetState(() {
                        tempFontFamily = f;
                      });
                      setState(() {
                        _fontFamily = f;
                      });
                      Navigator.pop(context);
                    },
                    splashColor: Colors.transparent,
                    hoverColor: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFF141414); // Dark background
    const textColor = Colors.white70;
    const accentColor = Colors.deepOrange;

    final buttonStyle = ButtonStyle(
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.pressed)) {
          return Colors.white.withValues(alpha: 0.2);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return Colors.white.withValues(alpha: 0.05);
        }
        return null;
      }),
    );

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Row(
                children: [
                  Icon(Icons.arrow_back_ios, size: 16, color: textColor),
                  SizedBox(width: 4),
                  Text(
                    AppLocalizations.of(context)!.settings,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            TextButton(
              style: buttonStyle,
              onPressed: _applySettings,
              child: Text(
                AppLocalizations.of(context)!.apply,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 16,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        children: [
          _buildSectionHeader(AppLocalizations.of(context)!.customize, textColor),
          _buildDivider(),
          SettingsTile(
            label: AppLocalizations.of(context)!.theme,
            value: _themeName,
            onTap: _showThemePicker,
          ),
          _buildDivider(),
          SettingsTile(
            label: AppLocalizations.of(context)!.font,
            value: "$_fontFamily ${_fontSize.toInt()}px",
            onTap: _showFontPicker,
          ),
          _buildSectionHeader(AppLocalizations.of(context)!.color, textColor),

          _buildDivider(),
          ColorTile(label: AppLocalizations.of(context)!.foreground, color: _colorFg),
          _buildDivider(),
          ColorTile(label: AppLocalizations.of(context)!.background, color: _colorBg),
          _buildDivider(),
          ColorTile(label: AppLocalizations.of(context)!.cursor, color: _colorCursor),
          _buildDivider(),
          ColorTile(label: AppLocalizations.of(context)!.selection, color: _colorSelection),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 20.0, top: 16.0, bottom: 12.0),
      child: Text(
        title,
        style: TextStyle(
          color: color.withValues(alpha: 0.5),
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(height: 1, thickness: 1, color: Color(0xFF2C2C2C));
  }
}
