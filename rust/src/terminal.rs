use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Scroll;
use alacritty_terminal::grid::{Dimensions, GridCell};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi;
use parking_lot::RwLock;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub struct TerminalFrame {
    pub rows: u16,
    pub cols: u16,
    pub lines: Vec<String>,
    pub fg_colors: Vec<u32>,
    pub bg_colors: Vec<u32>,
    pub flags: Vec<u16>,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub is_closed: bool,
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
}

impl Drop for FlutterTerminal {
    fn drop(&mut self) {
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

    pub fn get_frame(&self) -> Option<TerminalFrame> {
        let is_closed = self.is_closed.load(Ordering::SeqCst);
        if !self.dirty.swap(false, Ordering::SeqCst) && !is_closed {
            return None;
        }

        let term = self.term.read();
        let grid = term.grid();
        let display_offset = grid.display_offset();

        let rows = term.screen_lines();
        let cols = term.columns();

        let mut lines = Vec::with_capacity(rows);
        let mut fg_colors = Vec::with_capacity(rows * cols);
        let mut bg_colors = Vec::with_capacity(rows * cols);
        let mut flags_vec = Vec::with_capacity(rows * cols);

        for y in 0..rows {
            let line_idx = Line(y as i32 - display_offset as i32);
            let mut line_str = String::with_capacity(cols);

            for col in 0..cols {
                let cell = &grid[line_idx][Column(col)];
                let is_spacer = cell.flags().contains(Flags::WIDE_CHAR_SPACER);
                if !is_spacer {
                    line_str.push(cell.c);
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

                flags_vec.push(attr);
            }
            lines.push(line_str);
        }

        let raw_cursor_y = term.grid().cursor.point.line.0 as i32;
        let adjusted_cursor_y = raw_cursor_y + display_offset as i32;

        Some(TerminalFrame {
            rows: rows as u16,
            cols: cols as u16,
            lines,
            fg_colors,
            bg_colors,
            flags: flags_vec,
            cursor_x: term.grid().cursor.point.column.0 as u16,
            cursor_y: if (0..rows as i32).contains(&adjusted_cursor_y) {
                adjusted_cursor_y as u16
            } else {
                65535
            },
            is_closed: self.is_closed.load(Ordering::SeqCst),
        })
    }

    pub fn scroll(&self, lines: i32) {
        let mut term = self.term.write();
        term.scroll_display(Scroll::Delta(lines));
        self.dirty.store(true, Ordering::SeqCst);
    }

    pub fn send_key(&self, normal_seq: &str, app_seq: &str) {
        let app_cursor = {
            let term = self.term.read();
            term.mode()
                .contains(alacritty_terminal::term::TermMode::APP_CURSOR)
        };
        let seq = if app_cursor { app_seq } else { normal_seq };
        if let Some(writer) = self.writer.write().as_mut() {
            let _ = writer.0.write_all(seq.as_bytes());
            let _ = writer.0.flush();
        }
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
    fn test_get_frame_lines_and_attributes() {
        let term = FlutterTerminal::new(24, 80, None).expect("Terminal should create");
        std::thread::sleep(Duration::from_millis(50));
        let frame = term.get_frame();
        if let Some(f) = frame {
            assert_eq!(f.rows, 24);
            assert_eq!(f.cols, 80);
            assert_eq!(f.lines.len(), 24);
            assert_eq!(f.fg_colors.len(), 24 * 80);
            assert_eq!(f.bg_colors.len(), 24 * 80);
            assert_eq!(f.flags.len(), 24 * 80);
        }
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

        // get_frame should return a frame with is_closed == true
        let frame = term.get_frame();
        assert!(frame.is_some());
        assert!(frame.unwrap().is_closed);
    }
}
