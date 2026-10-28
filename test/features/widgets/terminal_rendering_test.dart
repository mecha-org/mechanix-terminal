import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechanix_terminal/core/utils/constants.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/features/data/terminal_screen.dart';
import 'package:mechanix_terminal/features/screen/terminal_tabs_screen.dart';
import 'package:mechanix_terminal/features/widgets/terminal_painter.dart';
import 'package:mechanix_terminal/features/widgets/terminal_view.dart';
import 'package:mechanix_terminal/src/rust/frb_generated.dart';
import 'package:mechanix_terminal/src/rust/terminal.dart';

TerminalRow _plainRow(int index, String text, int cols) => TerminalRow(
  index: index,
  text: text,
  fgColors: Uint32List(cols),
  bgColors: Uint32List(cols),
  flags: Uint16List(cols),
);

TerminalUpdate _fullUpdate({
  required int rows,
  required int cols,
  required String Function(int) line,
  bool isClosed = false,
}) => TerminalUpdate(
  rows: rows,
  cols: cols,
  full: true,
  changedRows: List.generate(rows, (i) => _plainRow(i, line(i), cols)),
  cursorX: 0,
  cursorY: 0,
  cursorVisible: true,
  isClosed: isClosed,
);

class MockRustLibApi implements RustLibApi {
  final StreamController<int> streamController = StreamController<int>.broadcast();
  TerminalUpdate? currentUpdate;
  final Map<int, TerminalUpdate> updates = {};
  int _nextId = 1;

  @override
  int crateApiSimpleAddTerminal({required int rows, required int cols, String? cwd}) {
    final id = _nextId++;
    if (currentUpdate != null) {
      updates[id] = currentUpdate!;
    }
    return id;
  }

  @override
  Stream<int> crateApiSimpleCreateTerminalStream() => streamController.stream;

  @override
  String? crateApiSimpleGetTerminalCwd({required int id}) => '/home/test';

  @override
  TerminalUpdate? crateApiSimpleGetTerminalUpdate({required int id, required bool forceFull}) =>
      updates[id] ?? currentUpdate;

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  bool crateApiSimpleIsTerminalClosed({required int id}) =>
      updates[id]?.isClosed ?? currentUpdate?.isClosed ?? false;

  @override
  void crateApiSimplePasteTerminal({required int id, required String input}) {}

  @override
  void crateApiSimpleRemoveTerminal({required int id}) {}

  @override
  void crateApiSimpleResizeTerminal({required int id, required int rows, required int cols}) {}

  @override
  void crateApiSimpleScrollTerminal({required int id, required int lines}) {}

  bool isAppCursorValue = false;
  bool isAltScreenValue = false;
  final List<({int id, String input})> sentInputs = [];
  final List<({int id, String normalSeq, String appSeq})> sentKeys = [];

  void clearRecords() {
    sentInputs.clear();
    sentKeys.clear();
  }

  @override
  bool crateApiSimpleIsTerminalAppCursor({required int id}) => isAppCursorValue;

  @override
  bool crateApiSimpleIsTerminalAltScreen({required int id}) => isAltScreenValue;

  @override
  void crateApiSimpleSendInput({required int id, required String input}) {
    sentInputs.add((id: id, input: input));
  }

  @override
  void crateApiSimpleSendKey({required int id, required String normalSeq, required String appSeq}) {
    sentKeys.add((id: id, normalSeq: normalSeq, appSeq: appSeq));
  }

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
    test('TerminalScreen keeps unchanged rows identical across partial updates', () {
      final screen = TerminalScreen()
        ..apply(_fullUpdate(rows: 3, cols: 5, line: (i) => 'Row $i'));
      final row0 = screen.lines[0];
      final row2 = screen.lines[2];

      screen.apply(
        TerminalUpdate(
          rows: 3,
          cols: 5,
          full: false,
          changedRows: [_plainRow(1, 'Edit!', 5)],
          cursorX: 4,
          cursorY: 1,
          cursorVisible: false,
          isClosed: false,
        ),
      );

      expect(identical(screen.lines[0], row0), isTrue);
      expect(identical(screen.lines[2], row2), isTrue);
      expect(screen.lines[1]!.text, 'Edit!');
      expect((screen.cursorX, screen.cursorY), (4, 1));
      expect(screen.cursorVisible, isFalse);
    });

    test('TerminalScreen drops held rows on a full update with a new size', () {
      final screen = TerminalScreen()
        ..apply(_fullUpdate(rows: 3, cols: 5, line: (i) => 'Row $i'));
      screen.apply(_fullUpdate(rows: 2, cols: 4, line: (i) => 'New$i'));

      expect((screen.rows, screen.cols), (2, 4));
      expect(screen.lines.map((r) => r!.text), ['New0', 'New1']);
    });

    testWidgets('TerminalRowPainter paints styled ANSI runs with custom palette', (
      WidgetTester tester,
    ) async {
      final rows = [
        TerminalRow(
          index: 0,
          text: 'RedFg',
          fgColors: Uint32List.fromList([0x01000001, 0x01000001, 0x01000001, 0x01000001, 0x01000001]), // Tagged Red
          bgColors: Uint32List(5),
          flags: Uint16List.fromList([1, 1, 1, 1, 1]), // bold
        ),
        TerminalRow(
          index: 1,
          text: 'BgClr',
          fgColors: Uint32List(5),
          bgColors: Uint32List.fromList([0x01000004, 0x01000004, 0x01000004, 0, 0]), // Tagged Blue
          flags: Uint16List(5),
        ),
        TerminalRow(
          index: 2,
          text: 'Under',
          fgColors: Uint32List.fromList([0x01000006, 0x01000006, 0x01000006, 0x01000006, 0x01000006]), // Tagged Cyan
          bgColors: Uint32List(5),
          flags: Uint16List.fromList([4, 4, 4, 4, 4]), // underline
        ),
      ];

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

      final style = TerminalPaintStyle(
        fontSize: 14.0,
        cellWidth: 8.4,
        cellHeight: 16.8,
        textColor: Colors.white,
        backgroundColor: const Color(0xFF1E1E2E),
        cursorColor: Colors.pink,
        fontFamily: 'monospace',
        terminalId: 1,
        colorPalette: customPalette,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final row in rows)
                      CustomPaint(
                        size: const Size(200, 16.8),
                        painter: TerminalRowPainter(row, style),
                      ),
                  ],
                ),
                CustomPaint(
                  size: const Size(200, 100),
                  painter: TerminalSelectionPainter(
                    selectionStart: (col: 0, row: 0),
                    selectionEnd: (col: 3, row: 0),
                    rows: 3,
                    cols: 5,
                    cellWidth: 8.4,
                    cellHeight: 16.8,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is TerminalRowPainter,
        ),
        findsNWidgets(3),
      );
    });

    test('TerminalRowPainter repaints only when its row or style changes', () {
      TerminalPaintStyle style({double fontSize = 14.0}) => TerminalPaintStyle(
        fontSize: fontSize,
        cellWidth: 8.0,
        cellHeight: 16.0,
        textColor: Colors.white,
        backgroundColor: Colors.black,
        cursorColor: Colors.pink,
        fontFamily: 'monospace',
        terminalId: 1,
      );
      final row = _plainRow(0, 'A', 1);

      final painter = TerminalRowPainter(row, style());
      expect(painter.shouldRepaint(TerminalRowPainter(row, style())), isFalse);
      expect(painter.shouldRepaint(TerminalRowPainter(_plainRow(0, 'A', 1), style())), isTrue);
      expect(painter.shouldRepaint(TerminalRowPainter(row, style(fontSize: 16.0))), isTrue);
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

      mockApi.currentUpdate = _fullUpdate(rows: 10, cols: 20, line: (i) => 'Line $i              ');

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
      // One isolated layer per row, so a row change damages only that row.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is RepaintBoundary &&
              w.child is CustomPaint &&
              (w.child as CustomPaint).painter is TerminalRowPainter,
        ),
        findsNWidgets(10),
      );
    });

    testWidgets('TerminalView invokes onClosed when terminalStream emits closed terminal', (
      WidgetTester tester,
    ) async {
      final settings = AppSettings(
        fontSize: 14.0,
        fontFamily: 'monospace',
      );
      final tabController = TabController(length: 1, vsync: const TestVSync());

      mockApi.currentUpdate = _fullUpdate(rows: 10, cols: 20, line: (i) => 'Line $i              ');

      bool closedCalled = false;

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
                terminalStream: mockApi.streamController.stream,
                onClosed: () {
                  closedCalled = true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(closedCalled, isFalse);

      // Now simulate terminal process exit
      mockApi.currentUpdate = _fullUpdate(
        rows: 10,
        cols: 20,
        line: (i) => 'Line $i              ',
        isClosed: true,
      );

      mockApi.streamController.add(1);
      await tester.pump();

      expect(closedCalled, isTrue);
    });

    testWidgets('TerminalTabs removes tab when terminal process terminates', (
      WidgetTester tester,
    ) async {
      final settings = AppSettings(
        fontSize: 14.0,
        fontFamily: 'monospace',
      );

      mockApi.currentUpdate = _fullUpdate(rows: 10, cols: 20, line: (i) => 'Line $i              ');

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalTabs(
            settings: settings,
            onSettingsChanged: (_) {},
            terminalStream: mockApi.streamController.stream,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tab 1'), findsOneWidget);

      // Add a second tab
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('Tab 1'), findsOneWidget);
      expect(find.text('Tab 2'), findsOneWidget);

      // Now close Tab 2 via shell exit simulation
      mockApi.updates[2] = _fullUpdate(
        rows: 10,
        cols: 20,
        line: (i) => 'Line $i              ',
        isClosed: true,
      );

      mockApi.streamController.add(2);
      await tester.pumpAndSettle();

      expect(find.text('Tab 1'), findsOneWidget);
      expect(find.text('Tab 2'), findsNothing);
    });

    testWidgets('Inactive TerminalView does not update frame until tab becomes active', (
      WidgetTester tester,
    ) async {
      final settings = AppSettings(
        fontSize: 14.0,
        fontFamily: 'monospace',
      );
      final tabController = TabController(length: 2, vsync: const TestVSync(), initialIndex: 0);

      final initialUpdate = _fullUpdate(rows: 10, cols: 20, line: (i) => 'Initial $i           ');
      final updatedUpdate = _fullUpdate(rows: 10, cols: 20, line: (i) => 'Updated $i           ');

      bool firstRowStartsWith(Widget widget, String prefix) {
        if (widget is CustomPaint && widget.painter is TerminalRowPainter) {
          final row = (widget.painter as TerminalRowPainter).row;
          return row != null && row.index == 0 && row.text.startsWith(prefix);
        }
        return false;
      }

      mockApi.updates[2] = initialUpdate;

      // Mount Tab 2 with index = 1 (inactive, tabController.index == 0)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminalId: 2,
              settings: settings,
              tabController: tabController,
              index: 1,
              terminalStream: mockApi.streamController.stream,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Update mock screen in backend
      mockApi.updates[2] = updatedUpdate;

      // Stream notification for terminalId 2 while tab is inactive
      mockApi.streamController.add(2);
      await tester.pump();

      // State is NOT updated while inactive
      expect(find.byWidgetPredicate((w) => firstRowStartsWith(w, 'Initial')), findsOneWidget);

      // Now switch tab to active
      tabController.index = 1;
      await tester.pump();

      // Screen catches up immediately on active switch
      expect(find.byWidgetPredicate((w) => firstRowStartsWith(w, 'Updated')), findsOneWidget);
    });
  });

  group('Terminal Keyboard Input Resolution Tests', () {
    test('Unmodified cursor and home/end keys resolve to TerminalAppCursorInput with normal and app sequences', () {
      final up = resolveTerminalInput(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowUp,
        logicalKey: LogicalKeyboardKey.arrowUp,
        timeStamp: Duration.zero,
      ));
      expect(up, isA<TerminalAppCursorInput>());
      final upResult = up as TerminalAppCursorInput;
      expect(upResult.normalSeq, '\x1b[A');
      expect(upResult.appSeq, '\x1bOA');

      final down = resolveTerminalInput(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration.zero,
      )) as TerminalAppCursorInput;
      expect(down.normalSeq, '\x1b[B');
      expect(down.appSeq, '\x1bOB');

      final right = resolveTerminalInput(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        timeStamp: Duration.zero,
      )) as TerminalAppCursorInput;
      expect(right.normalSeq, '\x1b[C');
      expect(right.appSeq, '\x1bOC');

      final left = resolveTerminalInput(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowLeft,
        logicalKey: LogicalKeyboardKey.arrowLeft,
        timeStamp: Duration.zero,
      )) as TerminalAppCursorInput;
      expect(left.normalSeq, '\x1b[D');
      expect(left.appSeq, '\x1bOD');

      final home = resolveTerminalInput(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.home,
        logicalKey: LogicalKeyboardKey.home,
        timeStamp: Duration.zero,
      )) as TerminalAppCursorInput;
      expect(home.normalSeq, '\x1b[H');
      expect(home.appSeq, '\x1bOH');

      final end = resolveTerminalInput(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.end,
        logicalKey: LogicalKeyboardKey.end,
        timeStamp: Duration.zero,
      )) as TerminalAppCursorInput;
      expect(end.normalSeq, '\x1b[F');
      expect(end.appSeq, '\x1bOF');
    });

    test('Modified arrow keys resolve to standard xterm modifier sequences', () {
      // Test Shift+ArrowUp (mod = 2)
      final shiftUp = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowUp,
          logicalKey: LogicalKeyboardKey.arrowUp,
          timeStamp: Duration.zero,
        ),
        isShift: true,
      );
      expect(shiftUp, isA<TerminalNormalInput>());
      expect((shiftUp as TerminalNormalInput).text, '\x1b[1;2A');

      // Test Shift+Tab (BackTab)
      final shiftTab = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.tab,
          logicalKey: LogicalKeyboardKey.tab,
          timeStamp: Duration.zero,
        ),
        isShift: true,
      );
      expect((shiftTab as TerminalNormalInput).text, '\x1b[Z');
    });

    test('Critical Ctrl shortcuts for nano, vim, htop, less resolve correctly', () {
      // Ctrl+O (Nano Save)
      final ctrlO = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyO,
          logicalKey: LogicalKeyboardKey.keyO,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlO as TerminalNormalInput).text, '\x0f');

      // Ctrl+X (Nano Exit)
      final ctrlX = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyX,
          logicalKey: LogicalKeyboardKey.keyX,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlX as TerminalNormalInput).text, '\x18');

      // Ctrl+V (Vim Visual Block)
      final ctrlV = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyV,
          logicalKey: LogicalKeyboardKey.keyV,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlV as TerminalNormalInput).text, '\x16');

      // Ctrl+[ (Vim Escape)
      final ctrlEsc = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.bracketLeft,
          logicalKey: LogicalKeyboardKey.bracketLeft,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlEsc as TerminalNormalInput).text, '\x1b');

      // Ctrl+C (SIGINT)
      final ctrlC = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlC as TerminalNormalInput).text, '\x03');

      // Ctrl+D (EOF)
      final ctrlD = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyD,
          logicalKey: LogicalKeyboardKey.keyD,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlD as TerminalNormalInput).text, '\x04');

      // Ctrl+Z (SIGTSTP)
      final ctrlZ = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyZ,
          logicalKey: LogicalKeyboardKey.keyZ,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlZ as TerminalNormalInput).text, '\x1a');

      // Ctrl+L (Clear screen / redraw)
      final ctrlL = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyL,
          logicalKey: LogicalKeyboardKey.keyL,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlL as TerminalNormalInput).text, '\x0c');

      // Ctrl+ArrowUp (mod = 5)
      final ctrlUp = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowUp,
          logicalKey: LogicalKeyboardKey.arrowUp,
          timeStamp: Duration.zero,
        ),
        isCtrl: true,
      );
      expect((ctrlUp as TerminalNormalInput).text, '\x1b[1;5A');
    });

    test('Standard function keys and navigation keys resolve correctly', () {
      // F1..F4
      expect(
        (resolveTerminalInput(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.f1,
          logicalKey: LogicalKeyboardKey.f1,
          timeStamp: Duration.zero,
        )) as TerminalNormalInput).text,
        '\x1bOP',
      );
      // F10 (htop quit)
      expect(
        (resolveTerminalInput(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.f10,
          logicalKey: LogicalKeyboardKey.f10,
          timeStamp: Duration.zero,
        )) as TerminalNormalInput).text,
        '\x1b[21~',
      );
      // Enter and Numpad Enter
      expect(
        (resolveTerminalInput(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        )) as TerminalNormalInput).text,
        '\r',
      );
      expect(
        (resolveTerminalInput(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpadEnter,
          logicalKey: LogicalKeyboardKey.numpadEnter,
          timeStamp: Duration.zero,
        )) as TerminalNormalInput).text,
        '\r',
      );
      // Backspace
      expect(
        (resolveTerminalInput(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.backspace,
          logicalKey: LogicalKeyboardKey.backspace,
          timeStamp: Duration.zero,
        )) as TerminalNormalInput).text,
        '\x7f',
      );
    });

    test('Alt combinations prefix escape correctly', () {
      // Alt+X
      final altX = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyX,
          logicalKey: LogicalKeyboardKey.keyX,
          timeStamp: Duration.zero,
        ),
        isAlt: true,
      );
      expect((altX as TerminalNormalInput).text, '\x1bx');

      // Alt+Enter
      final altEnter = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
        isAlt: true,
      );
      expect((altEnter as TerminalNormalInput).text, '\x1b\r');

      // Alt+Backspace
      final altBk = resolveTerminalInput(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.backspace,
          logicalKey: LogicalKeyboardKey.backspace,
          timeStamp: Duration.zero,
        ),
        isAlt: true,
      );
      expect((altBk as TerminalNormalInput).text, '\x1b\x7f');
    });
  });

  group('TerminalView Key Dispatch Widget Tests', () {
    testWidgets('TerminalView dispatches ArrowUp via sendKey with both normal and app sequences', (tester) async {
      mockApi.clearRecords();
      final tabController = TabController(length: 1, vsync: const TestVSync());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminalId: 1,
              index: 0,
              tabController: tabController,
              settings: AppSettings(fontSize: 14.0, fontFamily: 'monospace'),
              terminalStream: mockApi.streamController.stream,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();

      expect(mockApi.sentKeys.length, 1);
      expect(mockApi.sentKeys.first.normalSeq, '\x1b[A');
      expect(mockApi.sentKeys.first.appSeq, '\x1bOA');
      expect(mockApi.sentKeys.first.id, 1);
    });

    testWidgets('TerminalView dispatches F10 and Enter via sendInput', (tester) async {
      mockApi.clearRecords();
      final tabController = TabController(length: 1, vsync: const TestVSync());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminalId: 1,
              index: 0,
              tabController: tabController,
              settings: AppSettings(fontSize: 14.0, fontFamily: 'monospace'),
              terminalStream: mockApi.streamController.stream,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.pump();
      expect(mockApi.sentInputs.length, 1);
      expect(mockApi.sentInputs.first.input, '\x1b[21~');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(mockApi.sentInputs.length, 2);
      expect(mockApi.sentInputs.last.input, '\r');
    });
  });
}
