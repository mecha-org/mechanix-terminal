import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mechanix_terminal/core/utils/constants.dart';
import 'package:mechanix_terminal/features/data/terminal_screen.dart';
import 'package:mechanix_terminal/src/rust/terminal.dart';

const List<String> _defaultFontFamilyFallback = ['monospace'];

class _CachedRun {
  final ui.Paragraph paragraph;
  final double x;

  const _CachedRun(this.paragraph, this.x);
}

class _CachedRow {
  final List<_CachedRun> runs;

  const _CachedRow(this.runs);
}

/// Font, cell metrics and colors shared by every terminal layer.
class TerminalPaintStyle {
  final double fontSize;
  final double cellWidth;
  final double cellHeight;
  final Color textColor;
  final Color backgroundColor;
  final Color cursorColor;
  final String fontFamily;
  final int terminalId;
  final Uint32List? colorPalette;

  TerminalPaintStyle({
    required this.fontSize,
    required this.cellWidth,
    required this.cellHeight,
    required this.textColor,
    required this.backgroundColor,
    required this.cursorColor,
    required this.fontFamily,
    required this.terminalId,
    this.colorPalette,
  });

  /// The 16-color ANSI palette, resolved once per style to avoid allocation churn on every paint.
  late final List<Color> palette = List<Color>.generate(16, (idx) {
    if (colorPalette != null && idx < colorPalette!.length) {
      return Color(0xFF000000 | colorPalette![idx]);
    }
    return Color(0xFF000000 | defaultDarkThemePalette[idx]);
  });

  /// Fast color resolution reusing the pre-resolved 16-color ANSI palette.
  Color resolveCellColor(int colorCode, Color defaultColor) {
    if (colorCode == 0) {
      return defaultColor;
    }
    if ((colorCode & 0xFF000000) == 0x01000000) {
      return palette[colorCode & 0x0F];
    }
    return Color(colorCode);
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalPaintStyle &&
      other.fontSize == fontSize &&
      other.cellWidth == cellWidth &&
      other.cellHeight == cellHeight &&
      other.textColor == textColor &&
      other.backgroundColor == backgroundColor &&
      other.cursorColor == cursorColor &&
      other.fontFamily == fontFamily &&
      other.terminalId == terminalId &&
      other.colorPalette == colorPalette;

  @override
  int get hashCode => Object.hash(
    fontSize,
    cellWidth,
    cellHeight,
    textColor,
    backgroundColor,
    cursorColor,
    fontFamily,
    terminalId,
    colorPalette,
  );
}

/// Paints one terminal row: non-default cell backgrounds and styled text runs.
///
/// Each row sits behind its own RepaintBoundary, so a row whose [TerminalRow]
/// instance is unchanged keeps its retained layer and adds no frame damage.
class TerminalRowPainter extends CustomPainter {
  final TerminalRow? row;
  final TerminalPaintStyle style;

  static const int _maxCachedRows = 512;
  static final Map<String, _CachedRow> _rowCache = {};

  /// Clears the static row cache. Useful for testing or when disposing terminal instances.
  static void clearCache() {
    _rowCache.clear();
  }

  /// Current number of rows cached in memory (for testing and metrics).
  @visibleForTesting
  static int get cachedRowCount => _rowCache.length;

  TerminalRowPainter(this.row, this.style);

  /// Fast row attributes hash to detect changes in colors or formatting flags.
  static int _computeRowAttrHash(TerminalRow row) {
    int hash = 17;
    for (int i = 0; i < row.flags.length; i++) {
      hash = 31 * hash + row.flags[i];
      hash = 31 * hash + row.fgColors[i];
      hash = 31 * hash + row.bgColors[i];
    }
    return hash;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final row = this.row;
    if (row == null) return;
    _paintBackgrounds(canvas, row);
    _paintText(canvas, row);
  }

  void _paintBackgrounds(Canvas canvas, TerminalRow row) {
    final cellWidth = style.cellWidth;
    final cellHeight = style.cellHeight;
    final cols = row.flags.length;
    final defaultBgValue = style.backgroundColor.toARGB32();

    Color? currentBg;
    int spanStartCol = 0;

    for (int col = 0; col < cols; col++) {
      final flag = row.flags[col];
      final isInverse = (flag & 16) != 0; // bit 4: INVERSE (swap fg and bg)
      final resolvedFg = style.resolveCellColor(
        row.fgColors[col],
        style.textColor,
      );
      final resolvedBg = style.resolveCellColor(
        row.bgColors[col],
        style.backgroundColor,
      );
      final effectiveBg = isInverse ? resolvedFg : resolvedBg;

      final isCustomBg = effectiveBg.toARGB32() != defaultBgValue;

      if (isCustomBg) {
        if (currentBg == null) {
          currentBg = effectiveBg;
          spanStartCol = col;
        } else if (currentBg != effectiveBg) {
          // Flush previous background span
          canvas.drawRect(
            Rect.fromLTWH(
              spanStartCol * cellWidth,
              0,
              (col - spanStartCol) * cellWidth,
              cellHeight,
            ),
            Paint()..color = currentBg,
          );
          currentBg = effectiveBg;
          spanStartCol = col;
        }
      } else if (currentBg != null) {
        // Flush open span when hitting default background
        canvas.drawRect(
          Rect.fromLTWH(
            spanStartCol * cellWidth,
            0,
            (col - spanStartCol) * cellWidth,
            cellHeight,
          ),
          Paint()..color = currentBg,
        );
        currentBg = null;
      }
    }

    // Flush trailing background span at end of row
    if (currentBg != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          spanStartCol * cellWidth,
          0,
          (cols - spanStartCol) * cellWidth,
          cellHeight,
        ),
        Paint()..color = currentBg,
      );
    }
  }

  void _paintText(Canvas canvas, TerminalRow row) {
    if (row.text.isEmpty) return;

    final cellWidth = style.cellWidth;
    final cols = row.flags.length;
    final paletteHash = style.colorPalette?.hashCode ?? 0;

    final attrHash = _computeRowAttrHash(row);
    final cacheKey =
        "${style.terminalId}_${style.fontSize}_${cellWidth}_${style.textColor.toARGB32()}_${style.backgroundColor.toARGB32()}_${style.fontFamily}_${paletteHash}_${row.text.hashCode}_$attrHash";

    final cachedRow = _rowCache[cacheKey];
    if (cachedRow != null) {
      for (final run in cachedRow.runs) {
        canvas.drawParagraph(run.paragraph, Offset(run.x, 0));
      }
      return;
    }

    final chars = row.text.characters.toList();
    int col = 0;
    int charIdx = 0;
    final rowRuns = <_CachedRun>[];

    while (col < cols && charIdx < chars.length) {
      final flag = row.flags[col];

      // Skip wide char spacer
      if ((flag & 512) != 0) {
        // bit 9: WIDE_CHAR_SPACER
        col++;
        continue;
      }

      final isBold = (flag & 1) != 0; // bit 0: BOLD
      final isItalic = (flag & 2) != 0; // bit 1: ITALIC
      final isUnderline = (flag & 4) != 0; // bit 2: UNDERLINE
      final isDim = (flag & 8) != 0; // bit 3: DIM
      final isInverse = (flag & 16) != 0; // bit 4: INVERSE
      final isStrikethrough = (flag & 32) != 0; // bit 5: STRIKEOUT
      final isHidden = (flag & 64) != 0; // bit 6: HIDDEN

      final resolvedFg = style.resolveCellColor(
        row.fgColors[col],
        style.textColor,
      );
      final resolvedBg = style.resolveCellColor(
        row.bgColors[col],
        style.backgroundColor,
      );
      final effectiveFg = isInverse ? resolvedBg : resolvedFg;

      final startCol = col;
      final runBuffer = StringBuffer();

      while (col < cols && charIdx < chars.length) {
        final cFlag = row.flags[col];

        if ((cFlag & 512) != 0) {
          break;
        }

        final cBold = (cFlag & 1) != 0;
        final cItalic = (cFlag & 2) != 0;
        final cUnderline = (cFlag & 4) != 0;
        final cDim = (cFlag & 8) != 0;
        final cInverse = (cFlag & 16) != 0;
        final cStrike = (cFlag & 32) != 0;
        final cHidden = (cFlag & 64) != 0;

        final cResolvedFg = style.resolveCellColor(
          row.fgColors[col],
          style.textColor,
        );
        final cResolvedBg = style.resolveCellColor(
          row.bgColors[col],
          style.backgroundColor,
        );
        final cEffectiveFg = cInverse ? cResolvedBg : cResolvedFg;

        if (cEffectiveFg == effectiveFg &&
            cBold == isBold &&
            cDim == isDim &&
            cItalic == isItalic &&
            cUnderline == isUnderline &&
            cStrike == isStrikethrough &&
            cHidden == isHidden) {
          runBuffer.write(chars[charIdx]);
          charIdx++;
          col++;
        } else {
          break;
        }
      }

      if (!isHidden && runBuffer.isNotEmpty) {
        final runText = runBuffer.toString();
        if (runText.trim().isNotEmpty || isUnderline || isStrikethrough) {
          final runColor = isDim
              ? effectiveFg.withValues(alpha: 0.6)
              : effectiveFg;

          final textStyle = ui.TextStyle(
            color: runColor,
            fontFamily: style.fontFamily,
            fontFamilyFallback: _defaultFontFamilyFallback,
            fontSize: style.fontSize,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
            decoration: isUnderline
                ? TextDecoration.underline
                : (isStrikethrough
                      ? TextDecoration.lineThrough
                      : TextDecoration.none),
            height: 1.0,
          );

          final paragraphStyle = ui.ParagraphStyle(
            textAlign: TextAlign.left,
            fontSize: style.fontSize,
            fontFamily: style.fontFamily,
            height: 1.0,
          );

          final pb = ui.ParagraphBuilder(paragraphStyle)
            ..pushStyle(textStyle)
            ..addText(runText);

          final paragraph = pb.build()
            ..layout(
              ui.ParagraphConstraints(
                width: (col - startCol) * cellWidth + 4.0,
              ),
            );

          final runX = startCol * cellWidth;
          rowRuns.add(_CachedRun(paragraph, runX));
          canvas.drawParagraph(paragraph, Offset(runX, 0));
        }
      }
    }

    assert(
      () {
        int nonSpacerCols = 0;
        for (int c = 0; c < cols; c++) {
          if ((row.flags[c] & 512) == 0) {
            nonSpacerCols++;
          }
        }
        return charIdx == chars.length && charIdx == nonSpacerCols;
      }(),
      'Contract violation with Rust backend at row ${row.index}: parsed $charIdx graphemes for ${chars.length} characters in line "${row.text}".',
    );

    if (_rowCache.length >= _maxCachedRows) {
      _rowCache.remove(_rowCache.keys.first);
    }
    _rowCache[cacheKey] = _CachedRow(rowRuns);
  }

  @override
  bool shouldRepaint(covariant TerminalRowPainter oldDelegate) {
    return !identical(oldDelegate.row, row) || oldDelegate.style != style;
  }
}

/// Paints the selection highlight over the text rows.
class TerminalSelectionPainter extends CustomPainter {
  final ({int col, int row})? selectionStart;
  final ({int col, int row})? selectionEnd;
  final int rows;
  final int cols;
  final double cellWidth;
  final double cellHeight;

  TerminalSelectionPainter({
    required this.selectionStart,
    required this.selectionEnd,
    required this.rows,
    required this.cols,
    required this.cellWidth,
    required this.cellHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ss = selectionStart;
    final se = selectionEnd;
    if (ss == null || se == null) return;

    final ({int col, int row}) a;
    final ({int col, int row}) b;
    if (ss.row < se.row || (ss.row == se.row && ss.col <= se.col)) {
      a = ss;
      b = se;
    } else {
      a = se;
      b = ss;
    }

    final selPaint = Paint()..color = const Color(0x557CB9F5);

    for (int y = a.row; y <= b.row; y++) {
      if (y < 0 || y >= rows) continue;
      final startCol = (y == a.row) ? a.col.clamp(0, cols - 1) : 0;
      final endCol = (y == b.row) ? b.col.clamp(0, cols - 1) : cols - 1;
      canvas.drawRect(
        Rect.fromLTWH(
          startCol * cellWidth,
          y * cellHeight,
          (endCol - startCol + 1) * cellWidth,
          cellHeight,
        ),
        selPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerminalSelectionPainter oldDelegate) {
    return oldDelegate.selectionStart != selectionStart ||
        oldDelegate.selectionEnd != selectionEnd ||
        oldDelegate.rows != rows ||
        oldDelegate.cols != cols ||
        oldDelegate.cellWidth != cellWidth ||
        oldDelegate.cellHeight != cellHeight;
  }
}

/// Paints the cursor. It only draws one cell, so moving it damages just the old and new cells.
class TerminalCursorPainter extends CustomPainter {
  final TerminalRow? row;
  final int cursorX;
  final int cursorY;
  final int rows;
  final int cols;
  final bool visible;
  final bool isFocused;
  final TerminalPaintStyle style;

  TerminalCursorPainter({
    required this.row,
    required this.cursorX,
    required this.cursorY,
    required this.rows,
    required this.cols,
    required this.visible,
    required this.isFocused,
    required this.style,
  });

  factory TerminalCursorPainter.fromScreen(
    TerminalScreen screen, {
    required bool isFocused,
    required TerminalPaintStyle style,
  }) {
    return TerminalCursorPainter(
      row: screen.cursorY < screen.rows ? screen.lines[screen.cursorY] : null,
      cursorX: screen.cursorX,
      cursorY: screen.cursorY,
      rows: screen.rows,
      cols: screen.cols,
      visible: screen.cursorVisible,
      isFocused: isFocused,
      style: style,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible || cursorY >= rows || cursorX >= cols) return;

    final cellWidth = style.cellWidth;
    final cellHeight = style.cellHeight;
    final cursorRect = Rect.fromLTWH(
      cursorX * cellWidth,
      cursorY * cellHeight,
      cellWidth,
      cellHeight,
    );

    if (!isFocused) {
      // Hollow rectangular outline when unfocused (matching native Alacritty);
      // the character under it is already drawn by its row layer.
      final cursorPaint = Paint()
        ..color = style.cursorColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRect(cursorRect.deflate(0.5), cursorPaint);
      return;
    }

    canvas.drawRect(cursorRect, Paint()..color = style.cursorColor);

    // Render character under cursor using backgroundColor for maximum legibility
    final row = this.row;
    if (row == null || row.text.isEmpty || cursorX >= row.flags.length) return;

    // Each non-spacer cell consumes exactly 1 character from row.text.characters.
    if ((row.flags[cursorX] & 512) != 0) return; // bit 9: WIDE_CHAR_SPACER
    int charIdx = 0;
    for (int c = 0; c < cursorX; c++) {
      if ((row.flags[c] & 512) == 0) {
        charIdx++;
      }
    }

    final chars = row.text.characters.toList();
    if (charIdx >= chars.length) return;
    final charUnderCursor = chars[charIdx];
    if (charUnderCursor.trim().isEmpty) return;

    final cursorPb =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontSize: style.fontSize,
              fontFamily: style.fontFamily,
              height: 1.0,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: style.backgroundColor,
              fontFamily: style.fontFamily,
              fontFamilyFallback: _defaultFontFamilyFallback,
              fontSize: style.fontSize,
              height: 1.0,
            ),
          )
          ..addText(charUnderCursor);

    final cursorParagraph = cursorPb.build()
      ..layout(ui.ParagraphConstraints(width: cellWidth * 2));

    canvas.drawParagraph(cursorParagraph, cursorRect.topLeft);
  }

  @override
  bool shouldRepaint(covariant TerminalCursorPainter oldDelegate) {
    return !identical(oldDelegate.row, row) ||
        oldDelegate.cursorX != cursorX ||
        oldDelegate.cursorY != cursorY ||
        oldDelegate.rows != rows ||
        oldDelegate.cols != cols ||
        oldDelegate.visible != visible ||
        oldDelegate.isFocused != isFocused ||
        oldDelegate.style != style;
  }
}
