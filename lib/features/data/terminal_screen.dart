import 'package:mechanix_terminal/src/rust/terminal.dart';

/// Client-side copy of the visible grid, patched by [TerminalUpdate]s from Rust.
///
/// Rows missing from an update keep the same [TerminalRow] instance, so row
/// painters detect changes with `identical` and unchanged rows are not repainted.
class TerminalScreen {
  int rows = 0;
  int cols = 0;
  List<TerminalRow?> lines = const [];
  int cursorX = 0;
  int cursorY = 0;
  bool cursorVisible = true;

  bool get isEmpty => rows == 0;

  void apply(TerminalUpdate update) {
    if (update.full || update.rows != rows || update.cols != cols) {
      rows = update.rows;
      cols = update.cols;
      lines = List<TerminalRow?>.filled(rows, null);
    }
    for (final row in update.changedRows) {
      if (row.index < rows) {
        lines[row.index] = row;
      }
    }
    cursorX = update.cursorX;
    cursorY = update.cursorY;
    cursorVisible = update.cursorVisible;
  }
}
