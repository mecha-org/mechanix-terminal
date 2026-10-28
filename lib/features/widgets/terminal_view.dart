import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mechanix_terminal/core/utils/constants.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/features/data/terminal_screen.dart';
import 'package:mechanix_terminal/features/widgets/terminal_painter.dart';
import 'package:mechanix_terminal/src/rust/api/simple.dart';

class TerminalView extends StatefulWidget {
  final int terminalId;
  final AppSettings settings;
  final TabController tabController;
  final int index;
  final Stream<int>? terminalStream;
  final VoidCallback? onClosed;

  const TerminalView({
    super.key,
    required this.terminalId,
    required this.settings,
    required this.tabController,
    required this.index,
    this.terminalStream,
    this.onClosed,
  });

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView>
    with AutomaticKeepAliveClientMixin {
  TerminalScreen _screen = TerminalScreen();
  StreamSubscription? _subscription;
  final FocusNode _focusNode = FocusNode();

  // ── TEXT SELECTION STATE ───────────────────────────────────────────────────
  // Cell coordinates (col, row) for selection anchor and active end.
  ({int col, int row})? _selectionStart;
  ({int col, int row})? _selectionEnd;
  bool _isSelecting = false;

  bool get _isActive => widget.tabController.index == widget.index;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    widget.tabController.addListener(_handleTabChange);

    if (_isActive) {
      _activateTerminal();
    }

    _subscription = widget.terminalStream?.listen(_onStreamEvent);
    _loadFullScreen();
  }

  // A fresh view holds no rows, so ask Rust to resend the whole screen.
  void _loadFullScreen() {
    _screen = TerminalScreen();
    final update = getTerminalUpdate(id: widget.terminalId, forceFull: true);
    if (update == null) return;
    _screen.apply(update);
    if (update.isClosed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onClosed?.call();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabController != widget.tabController) {
      oldWidget.tabController.removeListener(_handleTabChange);
      widget.tabController.addListener(_handleTabChange);

      if (_isActive) {
        _activateTerminal();
        _fetchLatestFrame();
      }
    }
    if (oldWidget.terminalId != widget.terminalId ||
        oldWidget.terminalStream != widget.terminalStream) {
      _subscription?.cancel();
      _subscription = widget.terminalStream?.listen(_onStreamEvent);
      _loadFullScreen();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    widget.tabController.removeListener(_handleTabChange);
    _subscription?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _onStreamEvent(int id) {
    if (id != widget.terminalId || !mounted) return;

    // Inactive tabs skip frame fetch; only check closure for background tab cleanup.
    if (!_isActive) {
      if (isTerminalClosed(id: widget.terminalId)) {
        widget.onClosed?.call();
      }
      return;
    }

    _applyLatestUpdate();
  }

  // Fetches latest buffered output when tab becomes active.
  void _fetchLatestFrame() {
    if (!mounted) return;
    _applyLatestUpdate();
  }

  // Patches only the rows Rust reports as changed since the last update.
  void _applyLatestUpdate() {
    final update = getTerminalUpdate(id: widget.terminalId, forceFull: false);
    if (update == null) return;
    if (update.isClosed) {
      widget.onClosed?.call();
      return;
    }
    setState(() {
      _screen.apply(update);
    });
  }

  void _handleFocusChange() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleTabChange() {
    if (_isActive) {
      _activateTerminal();
      _fetchLatestFrame();
    }
  }

  void _activateTerminal() {
    setActiveTerminal(id: widget.terminalId);

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      });
    }
  }


  // ── SELECTION HELPERS ──────────────────────────────────────────────────────

  /// Convert a pixel offset to a terminal cell coordinate.
  ({int col, int row}) _pixelToCell(
    Offset position,
    double charWidth,
    double charHeight, {
    double padLeft = 0.0,
    double padTop = 0.0,
  }) {
    final screen = _screen;
    int col = ((position.dx - padLeft) / charWidth).floor();
    int row = ((position.dy - padTop) / charHeight).floor();
    if (!screen.isEmpty) {
      col = col.clamp(0, screen.cols - 1);
      row = row.clamp(0, screen.rows - 1);
    } else {
      col = col.clamp(0, 9999);
      row = row.clamp(0, 9999);
    }
    return (col: col, row: row);
  }

  /// Extract the plain-text content of the current selection from [screen].
  String _extractSelection(TerminalScreen screen) {
    final start = _selectionStart;
    final end = _selectionEnd;
    if (start == null || end == null) return '';

    // Normalise so startCell always comes before endCell in reading order.
    final ({int col, int row}) a;
    final ({int col, int row}) b;
    if (start.row < end.row || (start.row == end.row && start.col <= end.col)) {
      a = start;
      b = end;
    } else {
      a = end;
      b = start;
    }

    final buffer = StringBuffer();
    for (int y = a.row; y <= b.row; y++) {
      if (y >= screen.rows) break;
      final line = screen.lines[y];
      final chars = line?.text.characters.toList() ?? const <String>[];
      final flags = line?.flags;

      final startCol = (y == a.row) ? a.col.clamp(0, screen.cols - 1) : 0;
      final endCol = (y == b.row)
          ? b.col.clamp(0, screen.cols - 1)
          : screen.cols - 1;

      bool isWrapped = false;
      if (y < b.row && flags != null && flags.isNotEmpty) {
        isWrapped = (flags[flags.length - 1] & 128) != 0; // bit 7: WRAPLINE
      }

      for (int x = startCol; x <= endCol; x++) {
        if (x < chars.length) {
          final flag = flags != null && x < flags.length ? flags[x] : 0;
          final isSpacer = (flag & 512) != 0; // bit 9: WIDE_CHAR_SPACER
          if (!isSpacer) {
            buffer.write(chars[x]);
          }
        }
      }

      if (y < b.row && !isWrapped) {
        buffer.write('\n');
      }
    }

    // Trim trailing spaces on each line, like a real terminal.
    return buffer.toString().split('\n').map((l) => l.trimRight()).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final fontSize = widget.settings.fontSize;
    final fontFamily = widget.settings.fontFamily ?? fontFamilies[0];

    // Compute char metrics once here with fixed strut/height so pointer handlers and painter agree.
    final measureStyle = ui.TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: const ['monospace'],
      fontSize: fontSize,
      height: 1.0,
    );
    final measureParaStyle = ui.ParagraphStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      height: 1.0,
    );
    final measurePb = ui.ParagraphBuilder(measureParaStyle)
      ..pushStyle(measureStyle)
      ..addText('X');
    final charMeasure = measurePb.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final double charWidth = charMeasure.maxIntrinsicWidth;
    final double charHeight = charMeasure.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;

        final cols = (availableWidth / charWidth).floor().clamp(10, 500);
        final rows = (availableHeight / charHeight).floor().clamp(5, 200);

        final gridWidth = cols * charWidth;
        final gridHeight = rows * charHeight;

        final horizontalPadding = ((availableWidth - gridWidth) / 2.0).clamp(
          0.0,
          double.infinity,
        );
        final verticalPadding = ((availableHeight - gridHeight) / 2.0).clamp(
          0.0,
          double.infinity,
        );

        if (_screen.isEmpty || _screen.rows != rows || _screen.cols != cols) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              resizeTerminal(id: widget.terminalId, rows: rows, cols: cols);
            }
          });
        }

        final activeTheme = terminalThemes.firstWhere(
          (t) =>
              _parseHexColor(widget.settings.colorBackground)?.toARGB32() ==
                  (0xFF000000 | t.bg) ||
              _parseHexColor(widget.settings.colorForeground)?.toARGB32() ==
                  (0xFF000000 | t.fg),
          orElse: () => terminalThemes[0],
        );

        final backgroundColor =
            _parseHexColor(widget.settings.colorBackground) ??
            Theme.of(context).scaffoldBackgroundColor;
        final paintStyle = TerminalPaintStyle(
          fontSize: fontSize,
          cellWidth: charWidth,
          cellHeight: charHeight,
          textColor:
              _parseHexColor(widget.settings.colorForeground) ??
              Theme.of(context).textTheme.bodyMedium?.color ??
              Colors.white,
          backgroundColor: backgroundColor,
          cursorColor:
              _parseHexColor(widget.settings.colorCursor) ?? Colors.white70,
          fontFamily: fontFamily,
          terminalId: widget.terminalId,
          colorPalette: activeTheme.palette,
        );

        return Listener(
          behavior: HitTestBehavior.opaque,
          // ── Mouse-wheel scrolling ──────────────────────────────────────────────
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent) {
              // Negate the dy to match Alacritty's scroll direction:
              // Flutter: dy < 0 is wheel UP, dy > 0 is wheel DOWN
              // Alacritty: positive delta scrolls UP (into history), negative delta scrolls DOWN
              final int lines = (-pointerSignal.scrollDelta.dy / charHeight)
                  .round();
              if (lines != 0) {
                scrollTerminal(id: widget.terminalId, lines: lines);
              }
            }
          },
          // ── Left-button down: start selection ─────────────────────────────────
          onPointerDown: (event) {
            final isPrimary =
                event.buttons == kPrimaryMouseButton ||
                event.kind == PointerDeviceKind.touch;
            if (isPrimary) {
              if (!_focusNode.hasFocus) {
                _focusNode.requestFocus();
              }
              final cell = _pixelToCell(
                event.localPosition,
                charWidth,
                charHeight,
                padLeft: horizontalPadding,
                padTop: verticalPadding,
              );
              setState(() {
                _isSelecting = true;
                _selectionStart = cell;
                _selectionEnd = cell;
              });
            }
          },
          // ── Left-button drag: extend selection ────────────────────────────────
          onPointerMove: (event) {
            final isPrimary =
                event.buttons == kPrimaryMouseButton ||
                event.kind == PointerDeviceKind.touch;
            if (_isSelecting && isPrimary) {
              final cell = _pixelToCell(
                event.localPosition,
                charWidth,
                charHeight,
                padLeft: horizontalPadding,
                padTop: verticalPadding,
              );
              setState(() {
                _selectionEnd = cell;
              });
            }
          },
          // ── Left-button up: finish & copy ─────────────────────────────────────
          onPointerUp: (event) {
            if (_isSelecting) {
              final isSingleTap =
                  _selectionStart != null &&
                  _selectionEnd != null &&
                  _selectionStart!.col == _selectionEnd!.col &&
                  _selectionStart!.row == _selectionEnd!.row;

              setState(() {
                _isSelecting = false;
                if (isSingleTap) {
                  _selectionStart = null;
                  _selectionEnd = null;
                }
              });

              if (!isSingleTap) {
                if (!_screen.isEmpty) {
                  final text = _extractSelection(_screen);
                  if (text.trim().isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: text));
                  }
                }
              }
            }
          },
          child: Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.tab): const _TabIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _TabIntent: CallbackAction<_TabIntent>(
                  onInvoke: (intent) {
                    sendInput(id: widget.terminalId, input: '\t');
                    return null;
                  },
                ),
              },
              child: Focus(
                focusNode: _focusNode,
                autofocus: true,
                onKeyEvent: (FocusNode node, KeyEvent event) {
                  final key = event.logicalKey;
                  if (event is KeyDownEvent || event is KeyRepeatEvent) {
                    final isAlt = HardwareKeyboard.instance.isAltPressed;
                    final isCtrl = HardwareKeyboard.instance.isControlPressed;
                    final isShift = HardwareKeyboard.instance.isShiftPressed;
                    final isMeta = HardwareKeyboard.instance.isMetaPressed;

                    final isKeyC =
                        key == LogicalKeyboardKey.keyC ||
                        event.physicalKey == PhysicalKeyboardKey.keyC ||
                        key.keyLabel.toLowerCase() == 'c';
                    final isKeyV =
                        key == LogicalKeyboardKey.keyV ||
                        event.physicalKey == PhysicalKeyboardKey.keyV ||
                        key.keyLabel.toLowerCase() == 'v';

                    final isCopy =
                        (isCtrl && isShift && isKeyC) || (isMeta && isKeyC);
                    final isPaste =
                        (isCtrl && isShift && isKeyV) || (isMeta && isKeyV);

                    final isModifier =
                        key == LogicalKeyboardKey.controlLeft ||
                        key == LogicalKeyboardKey.controlRight ||
                        key == LogicalKeyboardKey.shiftLeft ||
                        key == LogicalKeyboardKey.shiftRight ||
                        key == LogicalKeyboardKey.altLeft ||
                        key == LogicalKeyboardKey.altRight ||
                        key == LogicalKeyboardKey.metaLeft ||
                        key == LogicalKeyboardKey.metaRight;

                    // Clear selection on any key except modifiers and Copy/Paste shortcuts
                    if (!isCopy && !isPaste && !isModifier) {
                      if (_selectionStart != null) {
                        setState(() {
                          _selectionStart = null;
                          _selectionEnd = null;
                        });
                      }
                    }

                    // Copy selection to clipboard
                    if (isCopy) {
                      if (!_screen.isEmpty) {
                        final text = _extractSelection(_screen);
                        if (text.trim().isNotEmpty) {
                          Clipboard.setData(ClipboardData(text: text));
                        }
                      }
                      return KeyEventResult.handled;
                    }

                    // Paste clipboard into terminal
                    if (isPaste) {
                      Clipboard.getData(Clipboard.kTextPlain).then((data) {
                        final text = data?.text;
                        if (text != null && text.isNotEmpty) {
                          pasteTerminal(id: widget.terminalId, input: text);
                        }
                      });
                      return KeyEventResult.handled;
                    }

                    // Only switch tabs with Alt+digit if multiple tabs exist
                    if (isAlt && !isCtrl && !isShift) {
                      final int? targetIndex = switch (key) {
                        LogicalKeyboardKey.digit1 => 0,
                        LogicalKeyboardKey.digit2 => 1,
                        LogicalKeyboardKey.digit3 => 2,
                        LogicalKeyboardKey.digit4 => 3,
                        LogicalKeyboardKey.digit5 => 4,
                        LogicalKeyboardKey.digit6 => 5,
                        LogicalKeyboardKey.digit7 => 6,
                        LogicalKeyboardKey.digit8 => 7,
                        LogicalKeyboardKey.digit9 => 8,
                        LogicalKeyboardKey.digit0 => 9,
                        _ => null,
                      };

                      if (targetIndex != null &&
                          widget.tabController.length > 1 &&
                          targetIndex < widget.tabController.length) {
                        widget.tabController.animateTo(targetIndex);
                        return KeyEventResult.handled;
                      }
                    }

                    final inputResult = resolveTerminalInput(event);
                    if (inputResult is TerminalAppCursorInput) {
                      sendKey(
                        id: widget.terminalId,
                        normalSeq: inputResult.normalSeq,
                        appSeq: inputResult.appSeq,
                      );
                      return KeyEventResult.handled;
                    } else if (inputResult is TerminalNormalInput) {
                      sendInput(id: widget.terminalId, input: inputResult.text);
                      return KeyEventResult.handled;
                    }
                  } else if (event is KeyUpEvent) {
                    if (key == LogicalKeyboardKey.tab) {
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: Container(
                  color: backgroundColor,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: horizontalPadding,
                      top: verticalPadding,
                    ),
                    // Flutter tracks damage per layer, so the grid is split into one layer
                    // per row plus small selection and cursor layers. A change then damages
                    // only the rows or cells it touches instead of the whole terminal.
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (int y = 0; y < _screen.rows; y++)
                          Positioned(
                            left: 0,
                            top: y * charHeight,
                            width: gridWidth,
                            height: charHeight,
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: TerminalRowPainter(
                                  _screen.lines[y],
                                  paintStyle,
                                ),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: TerminalSelectionPainter(
                                selectionStart: _selectionStart,
                                selectionEnd: _selectionEnd,
                                rows: _screen.rows,
                                cols: _screen.cols,
                                cellWidth: charWidth,
                                cellHeight: charHeight,
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: TerminalCursorPainter.fromScreen(
                                _screen,
                                isFocused: _focusNode.hasFocus,
                                style: paintStyle,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Color? _parseHexColor(String? hexString) {
    if (hexString == null) return null;
    final buffer = StringBuffer();
    if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
    buffer.write(hexString.replaceFirst('#', ''));
    final parsed = int.tryParse(buffer.toString(), radix: 16);
    if (parsed == null) return null;
    return Color(parsed);
  }
}

class _TabIntent extends Intent {
  const _TabIntent();
}
