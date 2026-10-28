use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Scroll;
use alacritty_terminal::grid::{Dimensions, GridCell};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi;
use parking_lot::{Mutex, RwLock};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
// use std::collections::hash_map::DefaultHasher;
// use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// One visible screen row. `fg_colors`, `bg_colors` and `flags` hold one entry per column.
pub struct TerminalRow {
    pub index: u16,
    pub text: String,
    pub fg_colors: Vec<u32>,
    pub bg_colors: Vec<u32>,
    pub flags: Vec<u16>,
}

/// Screen changes since the previous update for the same terminal.
pub struct TerminalUpdate {
    pub rows: u16,
    pub cols: u16,
    /// Every row is included; the receiver must drop the rows it holds.
    pub full: bool,
    pub changed_rows: Vec<TerminalRow>,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub is_closed: bool,
}

/// What the Dart side currently holds, so updates only carry rows that actually changed.
#[derive(Default)]
struct SentState {
    cols: usize,
    rows: usize,
    // row_hashes: Vec<u64>,
    cursor: Option<(u16, u16, bool)>,
}

pub struct TerminalCell {
    pub content: String,
    pub fg: u32,
    pub bg: u32,
    pub bold: bool,
}

struct SyncMasterPty(Box<dyn MasterPty + Send>);
unsafe impl Sync for SyncMasterPty {}

struct SyncWriter(Box<dyn Write + Send>);
unsafe impl Sync for SyncWriter {}

struct SyncChild(Box<dyn portable_pty::Child + Send>);
unsafe impl Sync for SyncChild {}

pub struct FlutterTerminal {
    term: Arc<RwLock<Term<VoidListener>>>,
    master_pty: Arc<RwLock<Option<SyncMasterPty>>>,
    writer: Arc<RwLock<Option<SyncWriter>>>,
    child: Arc<RwLock<Option<SyncChild>>>,
    pub dirty: Arc<AtomicBool>,
    pub is_closed: Arc<AtomicBool>,
    child_pid: Option<i32>,
    sent: Mutex<SentState>,
}

#[cfg(unix)]
extern "C" {
    // Standard POSIX kill(2) syscall provided by the system C runtime (already linked by Rust std).
    fn kill(pid: i32, sig: i32) -> i32;
}

#[cfg(unix)]
const SIGKILL: i32 = 9;

impl Drop for FlutterTerminal {
    fn drop(&mut self) {
        // Kill process group (-pid) so background jobs release slave PTY, unblocking reader thread.
        #[cfg(unix)]
        if let Some(pid) = self.child_pid {
            unsafe {
                kill(-pid, SIGKILL);
            }
        }

        // Close master PTY and writer to force immediate EOF/EIO on reader thread.
        let _ = self.master_pty.write().take();
        let _ = self.writer.write().take();

        // Reap direct child process to prevent zombie (<defunct>) processes.
        if let Some(mut child) = self.child.write().take() {
            let _ = child.0.kill();
            let _ = child.0.wait();
        }
    }
}

struct SimpleDimensions {
    cols: usize,
    rows: usize,
}

impl Dimensions for SimpleDimensions {
    fn columns(&self) -> usize {
        self.cols
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn total_lines(&self) -> usize {
        10000 // Enable 10,000 lines of scrollback history
    }
}

#[derive(Default)]
struct NoopTimeout {
    _dummy: bool,
}

impl ansi::Timeout for NoopTimeout {
    fn set_timeout(&mut self, _: Duration) {}
    fn clear_timeout(&mut self) {}
    fn pending_timeout(&self) -> bool {
        false
    }
}

fn resolve_color(color: ansi::Color) -> u32 {
    match color {
        ansi::Color::Named(named) => match named {
            ansi::NamedColor::Foreground | ansi::NamedColor::Background => 0,
            ansi::NamedColor::Black => 0x01000000,
            ansi::NamedColor::Red => 0x01000001,
            ansi::NamedColor::Green => 0x01000002,
            ansi::NamedColor::Yellow => 0x01000003,
            ansi::NamedColor::Blue => 0x01000004,
            ansi::NamedColor::Magenta => 0x01000005,
            ansi::NamedColor::Cyan => 0x01000006,
            ansi::NamedColor::White => 0x01000007,
            ansi::NamedColor::BrightBlack => 0x01000008,
            ansi::NamedColor::BrightRed => 0x01000009,
            ansi::NamedColor::BrightGreen => 0x0100000A,
            ansi::NamedColor::BrightYellow => 0x0100000B,
            ansi::NamedColor::BrightBlue => 0x0100000C,
            ansi::NamedColor::BrightMagenta => 0x0100000D,
            ansi::NamedColor::BrightCyan => 0x0100000E,
            ansi::NamedColor::BrightWhite => 0x0100000F,
            ansi::NamedColor::DimBlack => 0x01000000,
            ansi::NamedColor::DimRed => 0x01000001,
            ansi::NamedColor::DimGreen => 0x01000002,
            ansi::NamedColor::DimYellow => 0x01000003,
            ansi::NamedColor::DimBlue => 0x01000004,
            ansi::NamedColor::DimMagenta => 0x01000005,
            ansi::NamedColor::DimCyan => 0x01000006,
            ansi::NamedColor::DimWhite => 0x01000007,
            _ => 0,
        },
        ansi::Color::Spec(rgb) => {
            0xFF000000 | ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
        }
        ansi::Color::Indexed(idx) => {
            if idx < 16 {
                0x01000000 | (idx as u32)
            } else if idx < 232 {
                // 6x6x6 color cube (indices 16..231)
                let idx = idx - 16;
                let r = (idx / 36) % 6;
                let g = (idx / 6) % 6;
                let b = idx % 6;
                let r_val = if r == 0 { 0 } else { (r as u32) * 40 + 55 };
                let g_val = if g == 0 { 0 } else { (g as u32) * 40 + 55 };
                let b_val = if b == 0 { 0 } else { (b as u32) * 40 + 55 };
                0xFF000000 | (r_val << 16) | (g_val << 8) | b_val
            } else {
                // 24 grayscale steps (indices 232..255)
                let gray = (idx - 232) as u32 * 10 + 8;
                0xFF000000 | (gray << 16) | (gray << 8) | gray
            }
        }
    }
}

fn build_row(term: &Term<VoidListener>, y: usize, cols: usize) -> TerminalRow {
    let grid = term.grid();
    let line_idx = Line(y as i32 - grid.display_offset() as i32);

    let mut text = String::with_capacity(cols);
    let mut fg_colors = Vec::with_capacity(cols);
    let mut bg_colors = Vec::with_capacity(cols);
    let mut flags = Vec::with_capacity(cols);

    for col in 0..cols {
        let cell = &grid[line_idx][Column(col)];
        let is_spacer = cell.flags().contains(Flags::WIDE_CHAR_SPACER);
        if !is_spacer {
            text.push(cell.c);
            // Append zero-width characters (combining accents/diacritics) to preserve grapheme clusters.
            if let Some(zerowidth) = cell.zerowidth() {
                for &zw in zerowidth {
                    text.push(zw);
                }
            }
        }

        fg_colors.push(resolve_color(cell.fg));
        bg_colors.push(resolve_color(cell.bg));

        let mut attr = 0u16;
        let f = cell.flags();
        if f.contains(Flags::BOLD) {
            attr |= 1;
        }
        if f.contains(Flags::ITALIC) {
            attr |= 2;
        }
        if f.contains(Flags::UNDERLINE) {
            attr |= 4;
        }
        if f.contains(Flags::DIM) {
            attr |= 8;
        }
        if f.contains(Flags::INVERSE) {
            attr |= 16;
        }
        if f.contains(Flags::STRIKEOUT) {
            attr |= 32;
        }
        if f.contains(Flags::HIDDEN) {
            attr |= 64;
        }
        if f.contains(Flags::WRAPLINE) {
            attr |= 128;
        }
        if f.contains(Flags::WIDE_CHAR) {
            attr |= 256;
        }
        if is_spacer {
            attr |= 512;
        }

        flags.push(attr);
    }

    TerminalRow {
        index: y as u16,
        text,
        fg_colors,
        bg_colors,
        flags,
    }
}

// fn hash_row(row: &TerminalRow) -> u64 {
//     let mut hasher = DefaultHasher::new();
//     row.text.hash(&mut hasher);
//     row.fg_colors.hash(&mut hasher);
//     row.bg_colors.hash(&mut hasher);
//     row.flags.hash(&mut hasher);
//     hasher.finish()
// }

/// Drains alacritty's damage and returns the damaged rows.
///
/// Damage over-reports: alacritty always damages the cursor cells, so the cursor rows are
/// resent even when their text is unchanged. The commented-out hash filter drops those.
fn build_update(
    term: &mut Term<VoidListener>,
    sent: &mut SentState,
    force_full: bool,
    is_closed: bool,
) -> Option<TerminalUpdate> {
    let rows = term.screen_lines();
    let cols = term.columns();

    let mut damaged = vec![false; rows];
    let full_damage = match term.damage() {
        TermDamage::Full => true,
        TermDamage::Partial(lines) => {
            for bounds in lines {
                if bounds.line < rows {
                    damaged[bounds.line] = true;
                }
            }
            false
        }
    };
    term.reset_damage();

    let full = force_full || sent.cols != cols || sent.rows != rows;
    if full {
        sent.cols = cols;
        sent.rows = rows;
        // sent.row_hashes = vec![0; rows];
    }

    let mut changed_rows = Vec::new();
    for y in 0..rows {
        if !(full || full_damage || damaged[y]) {
            continue;
        }
        let row = build_row(term, y, cols);
        // let hash = hash_row(&row);
        // if !full && sent.row_hashes[y] == hash {
        //     continue;
        // }
        // sent.row_hashes[y] = hash;
        changed_rows.push(row);
    }

    let grid = term.grid();
    let cursor_y = grid.cursor.point.line.0 + grid.display_offset() as i32;
    let cursor_y = if (0..rows as i32).contains(&cursor_y) {
        cursor_y as u16
    } else {
        u16::MAX
    };
    let cursor_x = grid.cursor.point.column.0 as u16;
    let cursor_visible = term.mode().contains(TermMode::SHOW_CURSOR);

    let cursor = Some((cursor_x, cursor_y, cursor_visible));
    let cursor_changed = sent.cursor != cursor;
    sent.cursor = cursor;

    if !full && !is_closed && !cursor_changed && changed_rows.is_empty() {
        return None;
    }

    Some(TerminalUpdate {
        rows: rows as u16,
        cols: cols as u16,
        full,
        changed_rows,
        cursor_x,
        cursor_y,
        cursor_visible,
        is_closed,
    })
}

impl FlutterTerminal {
    pub fn new(rows: u16, cols: u16, cwd: Option<String>) -> Option<Self> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .ok()?;

        let dims = SimpleDimensions {
            cols: cols as usize,
            rows: rows as usize,
        };
        let term = Term::new(Config::default(), &dims, VoidListener);
        let term = Arc::new(RwLock::new(term));
        let dirty = Arc::new(AtomicBool::new(true));
        let is_closed = Arc::new(AtomicBool::new(false));

        let shell = std::env::var("SHELL").unwrap_or_else(|_| "bash".to_string());
        let mut cmd = CommandBuilder::new(&shell);
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        if let Some(dir) = cwd {
            cmd.cwd(dir);
        }
        let child = pair.slave.spawn_command(cmd).ok()?;
        // Track process group leader PID for process cleanup on tab drop.
        let child_pid = pair.master.process_group_leader();

        let reader = pair.master.try_clone_reader().ok()?;
        let writer = pair.master.take_writer().ok()?;
        let term_clone = Arc::clone(&term);
        let dirty_clone = Arc::clone(&dirty);
        let is_closed_clone = Arc::clone(&is_closed);

        thread::spawn(move || {
            let mut processor: ansi::Processor<NoopTimeout> = ansi::Processor::new();
            let mut reader = reader;
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        is_closed_clone.store(true, Ordering::SeqCst);
                        dirty_clone.store(true, Ordering::SeqCst);
                        break;
                    }
                    Ok(n) => {
                        let mut term_lock = term_clone.write();
                        processor.advance(&mut *term_lock, &buf[..n]);
                        dirty_clone.store(true, Ordering::SeqCst);
                    }
                    Err(_) => {
                        is_closed_clone.store(true, Ordering::SeqCst);
                        dirty_clone.store(true, Ordering::SeqCst);
                        break;
                    }
                }
            }
        });

        Some(Self {
            term,
            master_pty: Arc::new(RwLock::new(Some(SyncMasterPty(pair.master)))),
            writer: Arc::new(RwLock::new(Some(SyncWriter(writer)))),
            child: Arc::new(RwLock::new(Some(SyncChild(child)))),
            dirty,
            is_closed,
            child_pid,
            sent: Mutex::new(SentState::default()),
        })
    }

    pub fn write(&self, input: String) {
        if let Some(writer) = self.writer.write().as_mut() {
            let _ = writer.0.write_all(input.as_bytes());
            let _ = writer.0.flush();
        }
    }

    pub fn paste(&self, mut input: String) {
        let is_bracketed = {
            let term = self.term.read();
            term.mode()
                .contains(alacritty_terminal::term::TermMode::BRACKETED_PASTE)
        };

        if let Some(writer) = self.writer.write().as_mut() {
            if is_bracketed {
                input = input.replace('\x1b', "");
                let _ = writer.0.write_all(b"\x1b[200~");
                let _ = writer.0.write_all(input.as_bytes());
                let _ = writer.0.write_all(b"\x1b[201~");
            } else {
                input = input.replace('\n', "\r");
                let _ = writer.0.write_all(input.as_bytes());
            }
            let _ = writer.0.flush();
        }
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        {
            let mut term = self.term.write();
            term.resize(SimpleDimensions {
                cols: cols as usize,
                rows: rows as usize,
            });
        }
        if let Some(master) = self.master_pty.write().as_mut() {
            let _ = master.0.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
        }
        self.dirty.store(true, Ordering::SeqCst);
    }

    /// Returns the rows changed since the previous call, or `None` if nothing visible changed.
    /// `force_full` resends every row, for a receiver that holds no screen yet.
    pub fn get_update(&self, force_full: bool) -> Option<TerminalUpdate> {
        let is_closed = self.is_closed.load(Ordering::SeqCst);
        if !self.dirty.swap(false, Ordering::SeqCst) && !is_closed && !force_full {
            return None;
        }

        let mut term = self.term.write();
        let mut sent = self.sent.lock();
        build_update(&mut term, &mut sent, force_full, is_closed)
    }

    pub fn scroll(&self, lines: i32) {
        let mut term = self.term.write();
        term.scroll_display(Scroll::Delta(lines));
        self.dirty.store(true, Ordering::SeqCst);
    }

    pub fn send_key(&self, normal_seq: &str, app_seq: &str) {
        let is_app_mode = {
            let term = self.term.read();
            let mode = term.mode();
            mode.contains(alacritty_terminal::term::TermMode::APP_CURSOR)
                || mode.contains(alacritty_terminal::term::TermMode::APP_KEYPAD)
        };
        let seq = if is_app_mode && !app_seq.is_empty() {
            app_seq
        } else {
            normal_seq
        };
        if let Some(writer) = self.writer.write().as_mut() {
            let _ = writer.0.write_all(seq.as_bytes());
            let _ = writer.0.flush();
        }
    }

    pub fn is_app_cursor(&self) -> bool {
        self.term
            .read()
            .mode()
            .contains(alacritty_terminal::term::TermMode::APP_CURSOR)
    }

    pub fn is_alt_screen(&self) -> bool {
        self.term
            .read()
            .mode()
            .contains(alacritty_terminal::term::TermMode::ALT_SCREEN)
    }

    pub fn cwd(&self) -> Option<String> {
        let pid = self.child_pid?;
        std::fs::read_link(format!("/proc/{}/cwd", pid))
            .ok()
            .and_then(|path| path.to_str().map(|s| s.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};

    #[test]
    fn test_color_resolution_named() {
        assert_eq!(resolve_color(Color::Named(NamedColor::Foreground)), 0);
        assert_eq!(resolve_color(Color::Named(NamedColor::Background)), 0);
        assert_eq!(resolve_color(Color::Named(NamedColor::Black)), 0x01000000);
        assert_eq!(resolve_color(Color::Named(NamedColor::Red)), 0x01000001);
        assert_eq!(
            resolve_color(Color::Named(NamedColor::BrightWhite)),
            0x0100000F
        );
    }

    #[test]
    fn test_color_resolution_truecolor() {
        let rgb_color = Color::Spec(Rgb {
            r: 255,
            g: 128,
            b: 64,
        });
        assert_eq!(
            resolve_color(rgb_color),
            0xFF000000 | (255 << 16) | (128 << 8) | 64
        );
    }

    #[test]
    fn test_color_resolution_indexed() {
        assert_eq!(resolve_color(Color::Indexed(1)), 0x01000001);
        assert_eq!(resolve_color(Color::Indexed(15)), 0x0100000F);
        // Cube index 16 (0, 0, 0)
        assert_eq!(resolve_color(Color::Indexed(16)), 0xFF000000);
        // Grayscale index 232 (8, 8, 8)
        assert_eq!(resolve_color(Color::Indexed(232)), 0xFF080808);
    }

    #[test]
    fn test_terminal_lifecycle_and_reap() {
        let term = FlutterTerminal::new(24, 80, None);
        assert!(term.is_some());
        let term = term.unwrap();
        assert!(!term.is_closed.load(Ordering::SeqCst));
        assert!(term.child_pid.is_some());

        // Test panic-free write
        term.write("echo test\n".to_string());
        term.paste("pasted content\n".to_string());
        term.send_key("\x1b[A", "\x1bOA");

        // Dropping terminal automatically kills and reaps child process
        drop(term);
    }

    #[test]
    fn test_get_update_full_rows_and_attributes() {
        let term = FlutterTerminal::new(24, 80, None).expect("Terminal should create");
        std::thread::sleep(Duration::from_millis(50));
        let update = term.get_update(true).expect("Forced update should exist");
        assert!(update.full);
        assert_eq!(update.rows, 24);
        assert_eq!(update.cols, 80);
        assert_eq!(update.changed_rows.len(), 24);
        for (y, row) in update.changed_rows.iter().enumerate() {
            assert_eq!(row.index as usize, y);
            assert_eq!(row.fg_colors.len(), 80);
            assert_eq!(row.bg_colors.len(), 80);
            assert_eq!(row.flags.len(), 80);
        }
    }

    fn test_term(rows: usize, cols: usize) -> Term<VoidListener> {
        Term::new(Config::default(), &SimpleDimensions { cols, rows }, VoidListener)
    }

    fn indices(update: &TerminalUpdate) -> Vec<u16> {
        update.changed_rows.iter().map(|r| r.index).collect()
    }

    #[test]
    fn test_update_sends_damaged_rows() {
        let mut term = test_term(24, 80);
        let mut sent = SentState::default();
        let first = build_update(&mut term, &mut sent, false, false).expect("First update");
        assert!(first.full);
        assert_eq!(first.changed_rows.len(), 24);

        let mut processor = ansi::Processor::<NoopTimeout>::new();
        processor.advance(&mut term, b"\x1b[5;1Hhello");
        let update = build_update(&mut term, &mut sent, false, false).expect("Row 5 changed");
        assert!(!update.full);
        // Row 0 is resent because the cursor left it.
        assert_eq!(indices(&update), vec![0, 4]);
        assert!(update.changed_rows[1].text.starts_with("hello"));
        assert_eq!((update.cursor_x, update.cursor_y), (5, 4));
    }

    #[test]
    fn test_cursor_move_resends_old_and_new_cursor_rows() {
        let mut term = test_term(24, 80);
        let mut sent = SentState::default();
        build_update(&mut term, &mut sent, false, false);

        let mut processor = ansi::Processor::<NoopTimeout>::new();
        processor.advance(&mut term, b"\x1b[10;10H");
        let update = build_update(&mut term, &mut sent, false, false).expect("Cursor moved");
        assert_eq!(indices(&update), vec![0, 9]);
        assert_eq!((update.cursor_x, update.cursor_y), (9, 9));
    }

    #[test]
    fn test_no_change_resends_cursor_row() {
        let mut term = test_term(24, 80);
        let mut sent = SentState::default();
        build_update(&mut term, &mut sent, false, false);
        let update = build_update(&mut term, &mut sent, false, false).expect("Cursor row damaged");
        assert_eq!(indices(&update), vec![0]);
    }

    #[test]
    fn test_hidden_cursor_is_reported() {
        let mut term = test_term(24, 80);
        let mut sent = SentState::default();
        build_update(&mut term, &mut sent, false, false);

        let mut processor = ansi::Processor::<NoopTimeout>::new();
        processor.advance(&mut term, b"\x1b[?25l");
        let update = build_update(&mut term, &mut sent, false, false).expect("Cursor hidden");
        assert!(!update.cursor_visible);
    }

    #[test]
    fn test_resize_sends_full_update() {
        let mut term = test_term(24, 80);
        let mut sent = SentState::default();
        build_update(&mut term, &mut sent, false, false);

        term.resize(SimpleDimensions { cols: 100, rows: 30 });
        let update = build_update(&mut term, &mut sent, false, false).expect("Resized");
        assert!(update.full);
        assert_eq!((update.rows, update.cols), (30, 100));
        assert_eq!(update.changed_rows.len(), 30);
    }

    #[test]
    fn test_terminal_exit_command() {
        let term = FlutterTerminal::new(24, 80, None).expect("Terminal should create");
        assert!(!term.is_closed.load(Ordering::SeqCst));

        // Write exit command to the shell process
        term.write("exit\n".to_string());

        // Wait up to 1 second for the shell process to terminate and trigger EOF on reader
        let mut closed = false;
        for _ in 0..50 {
            std::thread::sleep(Duration::from_millis(20));
            if term.is_closed.load(Ordering::SeqCst) {
                closed = true;
                break;
            }
        }
        assert!(
            closed,
            "Terminal should be marked is_closed after shell exits"
        );

        // get_update should return an update with is_closed == true
        let update = term.get_update(false);
        assert!(update.is_some());
        assert!(update.unwrap().is_closed);
    }

    #[test]
    fn test_terminal_modes_and_send_key() {
        let term = FlutterTerminal::new(24, 80, None).expect("Terminal should create");
        assert!(!term.is_app_cursor());
        assert!(!term.is_alt_screen());

        // Simulate application turning on APP_CURSOR via DECCKM sequence \x1b[?1h
        {
            let mut term_lock = term.term.write();
            let mut processor = ansi::Processor::<NoopTimeout>::new();
            processor.advance(&mut *term_lock, b"\x1b[?1h");
        }
        assert!(term.is_app_cursor());

        // Simulate application turning off APP_CURSOR via DECCKM sequence \x1b[?1l
        {
            let mut term_lock = term.term.write();
            let mut processor = ansi::Processor::<NoopTimeout>::new();
            processor.advance(&mut *term_lock, b"\x1b[?1l");
        }
        assert!(!term.is_app_cursor());
    }

    #[test]
    fn test_combining_characters() {
        let term = FlutterTerminal::new(24, 80, None).expect("Terminal should create");
        {
            let mut term_lock = term.term.write();
            let mut processor = ansi::Processor::<NoopTimeout>::new();
            // "e" + combining acute accent U+0301 (UTF-8: 0xCC, 0x81)
            processor.advance(&mut *term_lock, "e\u{0301}".as_bytes());
        }
        let update = term.get_update(true).expect("Update should exist");
        let first_line = &update.changed_rows[0].text;
        assert!(
            first_line.starts_with("e\u{0301}"),
            "Line should contain combining acute accent, got: {:?}",
            first_line
        );
    }
}
