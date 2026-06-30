import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mechanix_terminal/src/rust/terminal.dart';

class TerminalPainter extends CustomPainter {
  final TerminalFrame frame;
  final double fontSize;
  final Color textColor;
  final Color backgroundColor;
  final Color cursorColor;
  final String fontFamily;
  final int terminalId;
  final ({int col, int row})? selectionStart;
  final ({int col, int row})? selectionEnd;

  static final Map<String, ui.Paragraph> _rowCache = {};

  TerminalPainter(
    this.frame,
    this.fontSize,
    this.textColor,
    this.backgroundColor,
    this.cursorColor,
    this.fontFamily,
    this.terminalId, {
    this.selectionStart,
    this.selectionEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final textStyle = ui.TextStyle(
      color: textColor,
      fontFamily: fontFamily,
      fontFamilyFallback: const ['monospace'],
      fontSize: fontSize,
    );

    final paragraphStyle = ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontSize: fontSize,
      fontFamily: fontFamily,
    );
    final pb = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(textStyle)
      ..addText('X');
    final charMeasure = pb.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final double charWidth = charMeasure.maxIntrinsicWidth;
    final double charHeight = charMeasure.height;

    for (int y = 0; y < frame.rows; y++) {
      final startIndex = y * frame.cols;
      final endIndex = (y + 1) * frame.cols;
      if (startIndex >= frame.content.length) break;

      final actualEnd = endIndex > frame.content.length
          ? frame.content.length
          : endIndex;
      final rowContent = frame.content.substring(startIndex, actualEnd);

      final cacheKey =
          "${terminalId}_${y}_${rowContent}_${fontSize}_${textColor.toARGB32()}_$fontFamily";

      ui.Paragraph? paragraph = _rowCache[cacheKey];
      if (paragraph == null) {
        final rowBuilder = ui.ParagraphBuilder(paragraphStyle);
        rowBuilder.pushStyle(textStyle);
        rowBuilder.addText(rowContent);
        paragraph = rowBuilder.build();
        paragraph.layout(
          ui.ParagraphConstraints(width: charWidth * frame.cols),
        );
        _rowCache[cacheKey] = paragraph;
      }

      canvas.drawParagraph(paragraph, Offset(0, y * charHeight));
    }

    // ── Draw selection highlight ───────────────────────────────────────────
    final ss = selectionStart;
    final se = selectionEnd;
    if (ss != null && se != null) {
      // Normalise order.
      final ({int col, int row}) a;
      final ({int col, int row}) b;
      if (ss.row < se.row || (ss.row == se.row && ss.col <= se.col)) {
        a = ss;
        b = se;
      } else {
        a = se;
        b = ss;
      }

      final selPaint = Paint()
        ..color = const Color(0x557CB9F5); // semi-transparent blue

      for (int y = a.row; y <= b.row; y++) {
        final startCol = (y == a.row) ? a.col : 0;
        final endCol = (y == b.row) ? b.col : frame.cols - 1;
        canvas.drawRect(
          Rect.fromLTWH(
            startCol * charWidth,
            y * charHeight,
            (endCol - startCol + 1) * charWidth,
            charHeight,
          ),
          selPaint,
        );
      }
    }

    // ── Draw cursor ───────────────────────────────────────────────────────────
    final cursorPaint = Paint()..color = cursorColor;
    canvas.drawRect(
      Rect.fromLTWH(
        frame.cursorX * charWidth,
        frame.cursorY * charHeight,
        charWidth,
        charHeight,
      ),
      cursorPaint,
    );

    if (_rowCache.length > 1000) {
      _rowCache.clear();
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.textColor != textColor ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.cursorColor != cursorColor ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.selectionStart != selectionStart ||
        oldDelegate.selectionEnd != selectionEnd;
  }
}
