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

/// Custom painter that renders a terminal frame to the canvas with batched drawing optimizations.
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
  });

  /// Resolves an encoded color integer to a concrete Flutter Color.
  Color _resolveCellColor(int colorCode, Color defaultColor) {
    if (colorCode == 0) {
      return defaultColor;
    }
    if ((colorCode & 0xFF000000) == 0x01000000) {
      final idx = colorCode & 0x0F;
      if (colorPalette != null && idx < colorPalette!.length) {
        return Color(0xFF000000 | colorPalette![idx]);
      }
      return Color(0xFF000000 | _defaultColorPalette[idx]);
    }
    return Color(colorCode);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final defaultBgValue = backgroundColor.toARGB32();

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
        final resolvedFg = _resolveCellColor(rawFg, textColor);
        final resolvedBg = _resolveCellColor(rawBg, backgroundColor);
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

    // ── 3. Draw Text Runs (Per-Cell Styled) ──────────────────────────────────
    for (int y = 0; y < frame.rows; y++) {
      if (y >= frame.lines.length) break;
      final line = frame.lines[y];
      if (line.isEmpty) continue;

      final chars = line.characters.toList();
      int col = 0;
      int charIdx = 0;

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

        final resolvedFg = _resolveCellColor(rawFg, textColor);
        final resolvedBg = _resolveCellColor(rawBg, backgroundColor);
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

          final cResolvedFg = _resolveCellColor(cRawFg, textColor);
          final cResolvedBg = _resolveCellColor(cRawBg, backgroundColor);
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
              fontFamilyFallback: const ['monospace'],
              fontSize: fontSize,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
              decoration: isUnderline
                  ? TextDecoration.underline
                  : (isStrikethrough
                        ? TextDecoration.lineThrough
                        : TextDecoration.none),
              height: 1.2,
            );

            final paragraphStyle = ui.ParagraphStyle(
              textAlign: TextAlign.left,
              fontSize: fontSize,
              fontFamily: fontFamily,
              height: 1.2,
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

            canvas.drawParagraph(
              paragraph,
              Offset(startCol * cellWidth, y * cellHeight),
            );
          }
        }
      }
    }

    // ── 4. Draw Cursor ───────────────────────────────────────────────────────
    if (frame.cursorY < frame.rows && frame.cursorX < frame.cols) {
      final cursorRect = Rect.fromLTWH(
        frame.cursorX * cellWidth,
        frame.cursorY * cellHeight,
        cellWidth,
        cellHeight,
      );

      final cursorPaint = Paint()..color = cursorColor;
      canvas.drawRect(cursorRect, cursorPaint);

      // Render character under cursor using backgroundColor for maximum legibility
      if (frame.cursorY < frame.lines.length) {
        final line = frame.lines[frame.cursorY];
        final chars = line.characters.toList();
        if (frame.cursorX < chars.length) {
          final charUnderCursor = chars[frame.cursorX];
          if (charUnderCursor.trim().isNotEmpty) {
            final cursorCharStyle = ui.TextStyle(
              color: backgroundColor,
              fontFamily: fontFamily,
              fontFamilyFallback: const ['monospace'],
              fontSize: fontSize,
              height: 1.2,
            );

            final cursorPb =
                ui.ParagraphBuilder(
                    ui.ParagraphStyle(
                      fontSize: fontSize,
                      fontFamily: fontFamily,
                      height: 1.2,
                    ),
                  )
                  ..pushStyle(cursorCharStyle)
                  ..addText(charUnderCursor);

            final cursorParagraph = cursorPb.build()
              ..layout(ui.ParagraphConstraints(width: cellWidth * 2));

            canvas.drawParagraph(
              cursorParagraph,
              Offset(frame.cursorX * cellWidth, frame.cursorY * cellHeight),
            );
          }
        }
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
        oldDelegate.selectionEnd != selectionEnd;
  }
}
