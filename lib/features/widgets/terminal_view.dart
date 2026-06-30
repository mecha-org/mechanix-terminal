import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mechanix_terminal/core/utils/constants.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/features/widgets/terminal_painter.dart';
import 'package:mechanix_terminal/src/rust/api/simple.dart';
import 'package:mechanix_terminal/src/rust/terminal.dart';

class TerminalView extends StatefulWidget {
  final int terminalId;
  final AppSettings settings;
  final TabController tabController;
  final int index;
  final Stream<int>? terminalStream;

  const TerminalView({
    super.key,
    required this.terminalId,
    required this.settings,
    required this.tabController,
    required this.index,
    this.terminalStream,
  });

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView>
    with AutomaticKeepAliveClientMixin {
  TerminalFrame? _frame;
  StreamSubscription? _subscription;
  final FocusNode _focusNode = FocusNode();

  // Estimate height per line dynamically based on font size
  double get _lineHeight => widget.settings.fontSize * 1.3;

  // ── TEXT SELECTION STATE ───────────────────────────────────────────────────
  // Cell coordinates (col, row) for selection anchor and active end.
  ({int col, int row})? _selectionStart;
  ({int col, int row})? _selectionEnd;
  bool _isSelecting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.tabController.addListener(_handleTabChange);

    if (widget.tabController.index == widget.index) {
      _activateTerminal();
    }

    _subscription = widget.terminalStream?.listen((id) {
      if (id == widget.terminalId && mounted) {
        final newFrame = getTerminalFrame(id: widget.terminalId);
        if (newFrame != null) {
          setState(() {
            _frame = newFrame;
          });
        }
      }
    });
    _frame = getTerminalFrame(id: widget.terminalId);
  }

  @override
  void didUpdateWidget(covariant TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabController != widget.tabController) {
      oldWidget.tabController.removeListener(_handleTabChange);
      widget.tabController.addListener(_handleTabChange);

      if (widget.tabController.index == widget.index) {
        _activateTerminal();
      }
    }
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_handleTabChange);
    _subscription?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (widget.tabController.index == widget.index) {
      _activateTerminal();
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

  /// Converts a Flutter KeyEvent into terminal strings or history sequences.
  String? _keyEventToTerminalInput(KeyEvent event) {
    final key = event.logicalKey;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // ── Ctrl shortcuts ────────────────────────────────────────────────────────
    if (isCtrl && !isAlt) {
      final value = ctrlMappings[key];
      if (value != null) return value;
    }

    // ── Alt (Meta) shortcuts ──────────────────────────────────────────────────
    if (isAlt && !isCtrl) {
      if (key == LogicalKeyboardKey.digit0) {
        return '\x1b0';
      }

      final digit1 = LogicalKeyboardKey.digit1.keyId;
      final digit9 = LogicalKeyboardKey.digit9.keyId;

      if (key.keyId >= digit1 && key.keyId <= digit9) {
        return '\x1b${key.keyId - digit1 + 1}';
      }

      final value = altMappings[key];
      if (value != null) return value;
    }

    // ── Shift shortcuts ───────────────────────────────────────────────────────
    if (isShift) {
      final shiftValue = shiftMappings[key];
      if (shiftValue != null) {
        return shiftValue;
      }
    }

    final defaultValue = defaultMappings[key];
    if (defaultValue != null) {
      return defaultValue;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final character = event.character;
      if (character != null && character.isNotEmpty) {
        return character;
      }
    }

    return null;
  }

  // ── SELECTION HELPERS ──────────────────────────────────────────────────────

  /// Convert a pixel offset to a terminal cell coordinate.
  ({int col, int row}) _pixelToCell(
    Offset position,
    double charWidth,
    double charHeight,
  ) {
    final frame = _frame;
    int col = (position.dx / charWidth).floor();
    int row = (position.dy / charHeight).floor();
    if (frame != null) {
      col = col.clamp(0, frame.cols - 1);
      row = row.clamp(0, frame.rows - 1);
    } else {
      col = col.clamp(0, 9999);
      row = row.clamp(0, 9999);
    }
    return (col: col, row: row);
  }

  /// Extract the plain-text content of the current selection from [frame].
  String _extractSelection(TerminalFrame frame) {
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
      final startCol = (y == a.row) ? a.col : 0;
      final endCol = (y == b.row) ? b.col : frame.cols - 1;
      final rowStart = y * frame.cols;

      bool isWrapped = false;
      if (y < b.row) {
        final lastColIdx = rowStart + (frame.cols - 1);
        if (lastColIdx < frame.attributes.length) {
          isWrapped = (frame.attributes[lastColIdx] & 2) != 0;
        }
      }

      for (int x = startCol; x <= endCol; x++) {
        final idx = rowStart + x;
        if (idx < frame.content.length) {
          buffer.write(frame.content[idx]);
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
    final fontFamily = widget.settings.fontFamily ?? 'monospace';

    // Compute char metrics once here so pointer handlers and painter agree.
    final measureStyle = ui.TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: const ['monospace'],
      fontSize: fontSize,
    );
    final measureParaStyle = ui.ParagraphStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
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
        final cols = (constraints.maxWidth / charWidth).floor().clamp(10, 500);
        final rows = (constraints.maxHeight / charHeight).floor().clamp(5, 200);

        final currentFrame = _frame;
        if (currentFrame == null ||
            currentFrame.rows != rows ||
            currentFrame.cols != cols) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              resizeTerminal(id: widget.terminalId, rows: rows, cols: cols);
            }
          });
        }

        return Listener(
          // ── Mouse-wheel scrolling ──────────────────────────────────────────────
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent) {
              // Negate the dy to match Alacritty's scroll direction:
              // Flutter: dy < 0 is wheel UP, dy > 0 is wheel DOWN
              // Alacritty: positive delta scrolls UP (into history), negative delta scrolls DOWN
              final int lines = (-pointerSignal.scrollDelta.dy / _lineHeight)
                  .round();
              if (lines != 0) {
                scrollTerminal(id: widget.terminalId, lines: lines);
              }
            }
          },
          // ── Left-button down: start selection ─────────────────────────────────
          onPointerDown: (event) {
            if (event.buttons == kPrimaryMouseButton) {
              _focusNode.requestFocus();
              final cell = _pixelToCell(
                event.localPosition,
                charWidth,
                charHeight,
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
            if (_isSelecting && event.buttons == kPrimaryMouseButton) {
              final cell = _pixelToCell(
                event.localPosition,
                charWidth,
                charHeight,
              );
              setState(() {
                _selectionEnd = cell;
              });
            }
          },
          // ── Left-button up: finish & copy ─────────────────────────────────────
          onPointerUp: (event) {
            if (_isSelecting) {
              setState(() {
                _isSelecting = false;
              });
              final frame = _frame;
              if (frame != null) {
                final text = _extractSelection(frame);
                if (text.trim().isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: text));
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
                  if (event is KeyDownEvent || event is KeyRepeatEvent) {
                    final key = event.logicalKey;
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
                      final frame = _frame;
                      if (frame != null) {
                        final text = _extractSelection(frame);
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
                          targetIndex < widget.tabController.length) {
                        widget.tabController.animateTo(targetIndex);
                        return KeyEventResult.handled;
                      }
                    }

                    final input = _keyEventToTerminalInput(event);
                    if (input != null) {
                      sendInput(id: widget.terminalId, input: input);
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: Container(
                  color:
                      _parseHexColor(widget.settings.colorBackground) ??
                      Theme.of(context).scaffoldBackgroundColor,
                  child: CustomPaint(
                    painter: _frame != null
                        ? TerminalPainter(
                            _frame!,
                            fontSize,
                            _parseHexColor(widget.settings.colorForeground) ??
                                Theme.of(context).textTheme.bodyMedium?.color ??
                                Colors.white,
                            _parseHexColor(widget.settings.colorBackground) ??
                                Theme.of(context).scaffoldBackgroundColor,
                            _parseHexColor(widget.settings.colorCursor) ??
                                Colors.white70,
                            fontFamily,
                            widget.terminalId,
                            selectionStart: _selectionStart,
                            selectionEnd: _selectionEnd,
                          )
                        : null,
                    child: Container(),
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
