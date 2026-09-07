import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mechanix_terminal/src/rust/terminal.dart';

const List<int> _defaultColorPalette = [
  0x000000, // 0: Black
  0xCC0000, // 1: Red
  0x4E9A06, // 2: Green
  0xC4A000, // 3: Yellow
  0x3465A4, // 4: Blue
  0x75507B, // 5: Magenta
  0x06989A, // 6: Cyan
  0xD3D7CF, // 7: White
  0x555753, // 8: Bright Black
  0xEF2929, // 9: Bright Red
  0x8AE234, // 10: Bright Green
  0xFCE94F, // 11: Bright Yellow
  0x729FCF, // 12: Bright Blue
  0xAD7FA8, // 13: Bright Magenta
  0x34E2E2, // 14: Bright Cyan
  0xEEEEEC, // 15: Bright White
];

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

/// Custom painter that renders a terminal frame to the canvas with batched drawing optimizations
/// and per-row paragraph caching.
class TerminalPainter extends CustomPainter {
  final TerminalFrame frame;
  final double fontSize;
  final double cellWidth;
  final double cellHeight;
  final Color textColor;
  final Color backgroundColor;
  final Color cursorColor;
  final String fontFamily;
  final int terminalId;
  final Uint32List? colorPalette;
  final ({int col, int row})? selectionStart;
  final ({int col, int row})? selectionEnd;
  final bool isFocused;

  static const int _maxCachedRows = 512;
  static final Map<String, _CachedRow> _rowCache = {};

  /// Clears the static row cache. Useful for testing or when disposing terminal instances.
  static void clearCache() {
    _rowCache.clear();
  }

  /// Current number of rows cached in memory (for testing and metrics).
  @visibleForTesting
  static int get cachedRowCount => _rowCache.length;

  TerminalPainter(
    this.frame,
    this.fontSize,
    this.cellWidth,
    this.cellHeight,
    this.textColor,
    this.backgroundColor,
    this.cursorColor,
    this.fontFamily,
    this.terminalId, {
    this.colorPalette,
    this.selectionStart,
    this.selectionEnd,
    this.isFocused = true,
  });

  /// Fast color resolution reusing the pre-resolved 16-color ANSI palette
  /// to eliminate object allocation churn on every frame.
  static Color _resolveCellColor(
    int colorCode,
    Color defaultColor,
    List<Color> palette,
  ) {
    if (colorCode == 0) {
      return defaultColor;
    }
    if ((colorCode & 0xFF000000) == 0x01000000) {
      final idx = colorCode & 0x0F;
      return palette[idx];
    }
    return Color(colorCode);
  }

  /// Fast row attributes hash to detect changes in colors or formatting flags.
  int _computeRowAttrHash(int y) {
    int hash = 17;
    final rowStart = y * frame.cols;
    final rowEnd = rowStart + frame.cols;
    for (int i = rowStart; i < rowEnd; i++) {
      final f = i < frame.flags.length ? frame.flags[i] : 0;
      final fg = i < frame.fgColors.length ? frame.fgColors[i] : 0;
      final bg = i < frame.bgColors.length ? frame.bgColors[i] : 0;
      hash = 31 * hash + f;
      hash = 31 * hash + fg;
      hash = 31 * hash + bg;
    }
    return hash;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final defaultBgValue = backgroundColor.toARGB32();

    // Pre-resolve the 16-color ANSI palette once per frame to eliminate object allocation churn
    final resolvedPalette = List<Color>.generate(16, (idx) {
      if (colorPalette != null && idx < colorPalette!.length) {
        return Color(0xFF000000 | colorPalette![idx]);
      }
      return Color(0xFF000000 | _defaultColorPalette[idx]);
    });

    // ── 1. Draw Cell Backgrounds ───────────────────────────────────────────
    for (int y = 0; y < frame.rows; y++) {
      Color? currentBg;
      int spanStartCol = 0;

      for (int col = 0; col < frame.cols; col++) {
        final cellIdx = y * frame.cols + col;
        final rawFg = cellIdx < frame.fgColors.length
            ? frame.fgColors[cellIdx]
            : 0;
        final rawBg = cellIdx < frame.bgColors.length
            ? frame.bgColors[cellIdx]
            : 0;
        final flag = cellIdx < frame.flags.length ? frame.flags[cellIdx] : 0;

        final isInverse = (flag & 16) != 0; // bit 4: INVERSE (swap fg and bg)
        final resolvedFg = _resolveCellColor(rawFg, textColor, resolvedPalette);
        final resolvedBg = _resolveCellColor(
          rawBg,
          backgroundColor,
          resolvedPalette,
        );
        final effectiveBg = isInverse ? resolvedFg : resolvedBg;

        final isCustomBg = effectiveBg.toARGB32() != defaultBgValue;

        if (isCustomBg) {
          if (currentBg == null) {
            currentBg = effectiveBg;
            spanStartCol = col;
          } else if (currentBg != effectiveBg) {
            // Flush previous background span
            final bgPaint = Paint()..color = currentBg;
            canvas.drawRect(
              Rect.fromLTWH(
                spanStartCol * cellWidth,
                y * cellHeight,
                (col - spanStartCol) * cellWidth,
                cellHeight,
              ),
              bgPaint,
            );
            currentBg = effectiveBg;
            spanStartCol = col;
          }
        } else {
          if (currentBg != null) {
            // Flush open span when hitting default background
            final bgPaint = Paint()..color = currentBg;
            canvas.drawRect(
              Rect.fromLTWH(
                spanStartCol * cellWidth,
                y * cellHeight,
                (col - spanStartCol) * cellWidth,
                cellHeight,
              ),
              bgPaint,
            );
            currentBg = null;
          }
        }
      }

      // Flush trailing background span at end of row
      if (currentBg != null) {
        final bgPaint = Paint()..color = currentBg;
        canvas.drawRect(
          Rect.fromLTWH(
            spanStartCol * cellWidth,
            y * cellHeight,
            (frame.cols - spanStartCol) * cellWidth,
            cellHeight,
          ),
          bgPaint,
        );
      }
    }

    // ── 2. Draw Selection Highlight ────────────────────────────────────────
    final ss = selectionStart;
    final se = selectionEnd;
    if (ss != null && se != null) {
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
        if (y < 0 || y >= frame.rows) continue;
        final startCol = (y == a.row) ? a.col.clamp(0, frame.cols - 1) : 0;
        final endCol = (y == b.row)
            ? b.col.clamp(0, frame.cols - 1)
            : frame.cols - 1;
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

    // ── 3. Draw Text Runs (Per-Cell Styled with Row Caching)
    final int paletteHash = colorPalette != null ? colorPalette.hashCode : 0;

    for (int y = 0; y < frame.rows; y++) {
      if (y >= frame.lines.length) break;
      final line = frame.lines[y];
      if (line.isEmpty) continue;

      final attrHash = _computeRowAttrHash(y);
      final cacheKey =
          "${terminalId}_${fontSize}_${cellWidth}_${textColor.toARGB32()}_${backgroundColor.toARGB32()}_${fontFamily}_${paletteHash}_${line.hashCode}_$attrHash";

      final cachedRow = _rowCache[cacheKey];
      if (cachedRow != null) {
        for (final run in cachedRow.runs) {
          canvas.drawParagraph(run.paragraph, Offset(run.x, y * cellHeight));
        }
        continue;
      }

      final chars = line.characters.toList();
      int col = 0;
      int charIdx = 0;
      final rowRuns = <_CachedRun>[];

      while (col < frame.cols && charIdx < chars.length) {
        final cellIdx = y * frame.cols + col;
        final flag = cellIdx < frame.flags.length ? frame.flags[cellIdx] : 0;
        final rawFg = cellIdx < frame.fgColors.length
            ? frame.fgColors[cellIdx]
            : 0;
        final rawBg = cellIdx < frame.bgColors.length
            ? frame.bgColors[cellIdx]
            : 0;

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

        final resolvedFg = _resolveCellColor(rawFg, textColor, resolvedPalette);
        final resolvedBg = _resolveCellColor(
          rawBg,
          backgroundColor,
          resolvedPalette,
        );
        final effectiveFg = isInverse ? resolvedBg : resolvedFg;

        final startCol = col;
        final runBuffer = StringBuffer();

        while (col < frame.cols && charIdx < chars.length) {
          final cIdx = y * frame.cols + col;
          final cFlag = cIdx < frame.flags.length ? frame.flags[cIdx] : 0;
          final cRawFg = cIdx < frame.fgColors.length
              ? frame.fgColors[cIdx]
              : 0;
          final cRawBg = cIdx < frame.bgColors.length
              ? frame.bgColors[cIdx]
              : 0;

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

          final cResolvedFg = _resolveCellColor(
            cRawFg,
            textColor,
            resolvedPalette,
          );
          final cResolvedBg = _resolveCellColor(
            cRawBg,
            backgroundColor,
            resolvedPalette,
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
              fontFamily: fontFamily,
              fontFamilyFallback: _defaultFontFamilyFallback,
              fontSize: fontSize,
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
              fontSize: fontSize,
              fontFamily: fontFamily,
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
            canvas.drawParagraph(paragraph, Offset(runX, y * cellHeight));
          }
        }
      }

      assert(
        () {
          int nonSpacerCols = 0;
          final rowStart = y * frame.cols;
          for (int c = 0; c < frame.cols; c++) {
            final f = (rowStart + c < frame.flags.length)
                ? frame.flags[rowStart + c]
                : 0;
            if ((f & 512) == 0) {
              nonSpacerCols++;
            }
          }
          return charIdx == chars.length && charIdx == nonSpacerCols;
        }(),
        'Contract violation with Rust backend at row $y: parsed $charIdx graphemes for ${chars.length} characters in line "${frame.lines[y]}".',
      );

      if (_rowCache.length >= _maxCachedRows) {
        _rowCache.remove(_rowCache.keys.first);
      }
      _rowCache[cacheKey] = _CachedRow(rowRuns);
    }

    // ── 4. Draw Cursor ───────────────────────────────────────────────────────
    if (frame.cursorY < frame.rows && frame.cursorX < frame.cols) {
      final cursorRect = Rect.fromLTWH(
        frame.cursorX * cellWidth,
        frame.cursorY * cellHeight,
        cellWidth,
        cellHeight,
      );

      if (isFocused) {
        final cursorPaint = Paint()..color = cursorColor;
        canvas.drawRect(cursorRect, cursorPaint);

        // Render character under cursor using backgroundColor for maximum legibility
        if (frame.cursorY < frame.lines.length) {
          final line = frame.lines[frame.cursorY];
          if (line.isNotEmpty) {
            // Map grid column (frame.cursorX) to character index in frame.lines[frame.cursorY].
            // Each non-spacer cell consumes exactly 1 character from line.characters.
            int charIdx = 0;
            final rowStart = frame.cursorY * frame.cols;
            for (int c = 0; c < frame.cursorX; c++) {
              final flag = (rowStart + c < frame.flags.length)
                  ? frame.flags[rowStart + c]
                  : 0;
              if ((flag & 512) == 0) {
                charIdx++;
              }
            }

            final cursorFlag = (rowStart + frame.cursorX < frame.flags.length)
                ? frame.flags[rowStart + frame.cursorX]
                : 0;
            final isCursorOnSpacer = (cursorFlag & 512) != 0;

            if (!isCursorOnSpacer) {
              final chars = line.characters.toList();
              if (charIdx < chars.length) {
                final charUnderCursor = chars[charIdx];
                if (charUnderCursor.trim().isNotEmpty) {
                  final cursorCharStyle = ui.TextStyle(
                    color: backgroundColor,
                    fontFamily: fontFamily,
                    fontFamilyFallback: _defaultFontFamilyFallback,
                    fontSize: fontSize,
                    height: 1.0,
                  );

                  final cursorPb =
                      ui.ParagraphBuilder(
                          ui.ParagraphStyle(
                            fontSize: fontSize,
                            fontFamily: fontFamily,
                            height: 1.0,
                          ),
                        )
                        ..pushStyle(cursorCharStyle)
                        ..addText(charUnderCursor);

                  final cursorParagraph = cursorPb.build()
                    ..layout(ui.ParagraphConstraints(width: cellWidth * 2));

                  canvas.drawParagraph(
                    cursorParagraph,
                    Offset(
                      frame.cursorX * cellWidth,
                      frame.cursorY * cellHeight,
                    ),
                  );
                }
              }
            }
          }
        }
      } else {
        // Hollow rectangular outline when unfocused (matching native Alacritty)
        final cursorPaint = Paint()
          ..color = cursorColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawRect(cursorRect.deflate(0.5), cursorPaint);
        // In unfocused state, character under cursor is already drawn in the text pass!
      }
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.cellWidth != cellWidth ||
        oldDelegate.cellHeight != cellHeight ||
        oldDelegate.textColor != textColor ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.cursorColor != cursorColor ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.colorPalette != colorPalette ||
        oldDelegate.selectionStart != selectionStart ||
        oldDelegate.selectionEnd != selectionEnd ||
        oldDelegate.isFocused != isFocused;
  }
}
