import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/features/widgets/terminal_painter.dart';
import 'package:mechanix_terminal/features/widgets/terminal_view.dart';
import 'package:mechanix_terminal/src/rust/frb_generated.dart';
import 'package:mechanix_terminal/src/rust/terminal.dart';

class MockRustLibApi implements RustLibApi {
  final StreamController<int> streamController = StreamController<int>.broadcast();
  TerminalFrame? currentFrame;

  @override
  int crateApiSimpleAddTerminal({required int rows, required int cols, String? cwd}) => 1;

  @override
  Stream<int> crateApiSimpleCreateTerminalStream() => streamController.stream;

  @override
  String? crateApiSimpleGetTerminalCwd({required int id}) => '/home/test';

  @override
  TerminalFrame? crateApiSimpleGetTerminalFrame({required int id}) => currentFrame;

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  bool crateApiSimpleIsTerminalClosed({required int id}) => false;

  @override
  void crateApiSimplePasteTerminal({required int id, required String input}) {}

  @override
  void crateApiSimpleRemoveTerminal({required int id}) {}

  @override
  void crateApiSimpleResizeTerminal({required int id, required int rows, required int cols}) {}

  @override
  void crateApiSimpleScrollTerminal({required int id, required int lines}) {}

  @override
  void crateApiSimpleSendInput({required int id, required String input}) {}

  @override
  void crateApiSimpleSendKey({required int id, required String normalSeq, required String appSeq}) {}

  @override
  void crateApiSimpleSetActiveTerminal({required int id}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mockApi = MockRustLibApi();

  setUpAll(() {
    RustLib.initMock(api: mockApi);
  });

  group('Terminal Rendering Tests', () {
    test('TerminalFrame contains pre-split lines, tagged ANSI colors, and flags', () {
      final frame = TerminalFrame(
        rows: 4,
        cols: 6,
        lines: [
          'Hello!',
          'World~',
          '┌────┐',
          '🚀 汉字',
        ],
        fgColors: Uint32List.fromList([
          0x01000001, 0x01000002, 0x01000003, 0x01000004, 0x01000005, 0x01000006,
          0, 0, 0, 0, 0, 0,
          0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
          0, 0, 0, 0, 0, 0,
        ]),
        bgColors: Uint32List.fromList([
          0, 0, 0, 0, 0, 0,
          0x01000000, 0x01000000, 0xFF585B70, 0xFF585B70, 0, 0,
          0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0,
        ]),
        flags: Uint16List.fromList([
          1, 2, 4, 8, 16, 32, // Bold, Italic, Underline, Dim, Inverse, Strikeout
          0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0,
          256, 512, 0, 256, 512, 0, // Wide char and wide char spacer
        ]),
        cursorX: 2,
        cursorY: 0,
        isClosed: false,
      );

      expect(frame.rows, 4);
      expect(frame.cols, 6);
      expect(frame.lines.length, 4);
      expect(frame.lines[0], 'Hello!');
      expect(frame.lines[2], '┌────┐');
      expect(frame.lines[3], '🚀 汉字');
      expect(frame.fgColors[0], 0x01000001); // Tagged ANSI Red
      expect(frame.bgColors[8], 0xFF585B70); // TrueColor
      expect(frame.flags[0], 1); // Bold
      expect(frame.flags[2], 4); // Underline
      expect(frame.flags[4], 16); // Inverse
      expect(frame.flags[19], 512); // Wide char spacer
      expect(frame.isClosed, isFalse);
    });

    testWidgets('TerminalPainter paints styled ANSI runs with custom palette', (
      WidgetTester tester,
    ) async {
      final frame = TerminalFrame(
        rows: 3,
        cols: 5,
        lines: ['RedFg', 'BgClr', 'Under'],
        fgColors: Uint32List.fromList([
          0x01000001, 0x01000001, 0x01000001, 0x01000001, 0x01000001, // Tagged Red
          0, 0, 0, 0, 0,
          0x01000006, 0x01000006, 0x01000006, 0x01000006, 0x01000006, // Tagged Cyan
        ]),
        bgColors: Uint32List.fromList([
          0, 0, 0, 0, 0,
          0x01000004, 0x01000004, 0x01000004, 0, 0, // Tagged Blue
          0, 0, 0, 0, 0,
        ]),
        flags: Uint16List.fromList([
          1, 1, 1, 1, 1, // bold
          0, 0, 0, 0, 0,
          4, 4, 4, 4, 4, // underline
        ]),
        cursorX: 0,
        cursorY: 0,
        isClosed: false,
      );

      final customPalette = Uint32List.fromList([
        0x1E1E2E, // 0: Black
        0xF38BA8, // 1: Red (Catppuccin Pinkish Red)
        0xA6E3A1, // 2: Green
        0xF9E2AF, // 3: Yellow
        0x89B4FA, // 4: Blue
        0xF5C2E7, // 5: Magenta
        0x94E2D5, // 6: Cyan
        0xBAC2DE, // 7: White
        0x585B70, // 8: Bright Black
        0xF38BA8, // 9: Bright Red
        0xA6E3A1, // 10: Bright Green
        0xF9E2AF, // 11: Bright Yellow
        0x89B4FA, // 12: Bright Blue
        0xF5C2E7, // 13: Bright Magenta
        0x94E2D5, // 14: Bright Cyan
        0xA6ADC8, // 15: Bright White
      ]);

      final painter = TerminalPainter(
        frame,
        14.0,
        8.4,
        16.8,
        Colors.white,
        const Color(0xFF1E1E2E),
        Colors.pink,
        'monospace',
        1,
        colorPalette: customPalette,
        selectionStart: (col: 0, row: 0),
        selectionEnd: (col: 3, row: 0),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomPaint(
              size: const Size(200, 100),
              painter: painter,
            ),
          ),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is TerminalPainter,
        ),
        findsOneWidget,
      );
    });

    testWidgets('TerminalPainter repaints when font, metrics, or colors change', (
      WidgetTester tester,
    ) async {
      final frame = TerminalFrame(
        rows: 1,
        cols: 1,
        lines: ['A'],
        fgColors: Uint32List.fromList([0]),
        bgColors: Uint32List.fromList([0]),
        flags: Uint16List.fromList([0]),
        cursorX: 0,
        cursorY: 0,
        isClosed: false,
      );

      final painter1 = TerminalPainter(
        frame,
        14.0,
        8.0,
        16.0,
        Colors.white,
        Colors.black,
        Colors.pink,
        'monospace',
        1,
      );

      final painter2 = TerminalPainter(
        frame,
        16.0,
        9.0,
        18.0,
        Colors.white,
        Colors.black,
        Colors.pink,
        'monospace',
        1,
      );

      expect(painter1.shouldRepaint(painter2), isTrue);
    });

    testWidgets('TerminalView renders and handles symmetric padding', (
      WidgetTester tester,
    ) async {
      final settings = AppSettings(
        fontSize: 14.0,
        fontFamily: 'monospace',
        colorForeground: '#CDD6F4',
        colorBackground: '#1E1E2E',
      );
      final tabController = TabController(length: 1, vsync: const TestVSync());

      mockApi.currentFrame = TerminalFrame(
        rows: 10,
        cols: 20,
        lines: List.generate(10, (i) => 'Line $i              '),
        fgColors: Uint32List(200),
        bgColors: Uint32List(200),
        flags: Uint16List(200),
        cursorX: 0,
        cursorY: 0,
        isClosed: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: TerminalView(
                terminalId: 1,
                settings: settings,
                tabController: tabController,
                index: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
