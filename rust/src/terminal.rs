use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Scroll;
use alacritty_terminal::grid::{Dimensions, GridCell};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term};
use parking_lot::RwLock;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::io::{Read, Write};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use vte::ansi;

use std::sync::atomic::{AtomicBool, Ordering};

pub struct TerminalFrame {
    pub rows: u16,
    pub cols: u16,
    pub content: String,
    pub attributes: Vec<u32>, // Packed: 24 bits for FG/BG, 8 bits for flags
    pub cursor_x: u16,
    pub cursor_y: u16,
}

pub struct TerminalCell {
    pub content: String,
    pub fg: u32,
    pub bg: u32,
    pub bold: bool,
}

struct SyncMasterPty(Box<dyn MasterPty + Send>);
unsafe impl Sync for SyncMasterPty {}

pub struct FlutterTerminal {
    term: Arc<RwLock<Term<VoidListener>>>,
    master_pty: Arc<RwLock<SyncMasterPty>>,
    writer: Arc<RwLock<SyncWriter>>,
    pub dirty: Arc<AtomicBool>,
    child_pid: Option<i32>,
}

struct SyncWriter(Box<dyn Write + Send>);
unsafe impl Sync for SyncWriter {}

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

impl FlutterTerminal {
    pub fn new(rows: u16, cols: u16, cwd: Option<String>) -> Self {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();

        let dims = SimpleDimensions {
            cols: cols as usize,
            rows: rows as usize,
        };
        let term = Term::new(Config::default(), &dims, VoidListener);
        let term = Arc::new(RwLock::new(term));
        let dirty = Arc::new(AtomicBool::new(true));

        let mut cmd = CommandBuilder::new("bash");
        cmd.env("TERM", "xterm-256color");
        if let Some(dir) = cwd {
            cmd.cwd(dir);
        }
        let mut _child = pair.slave.spawn_command(cmd).unwrap();
        let child_pid = pair.master.process_group_leader();

        let reader = pair.master.try_clone_reader().unwrap();
        let writer = pair.master.take_writer().unwrap();
        let term_clone = Arc::clone(&term);
        let dirty_clone = Arc::clone(&dirty);

        thread::spawn(move || {
            let mut processor: ansi::Processor<NoopTimeout> = ansi::Processor::new();
            let mut reader = reader;
            let mut buf = [0u8; 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let mut term_lock = term_clone.write();
                        processor.advance(&mut *term_lock, &buf[..n]);
                        dirty_clone.store(true, Ordering::SeqCst);
                    }
                    Err(_) => break,
                }
            }
        });

        Self {
            term,
            master_pty: Arc::new(RwLock::new(SyncMasterPty(pair.master))),
            writer: Arc::new(RwLock::new(SyncWriter(writer))),
            dirty,
            child_pid,
        }
    }

    pub fn write(&self, input: String) {
        let mut writer = self.writer.write();
        writer.0.write_all(input.as_bytes()).unwrap();
        writer.0.flush().unwrap();
    }

    pub fn paste(&self, mut input: String) {
        let is_bracketed = {
            let term = self.term.read();
            term.mode()
                .contains(alacritty_terminal::term::TermMode::BRACKETED_PASTE)
        };

        let mut writer = self.writer.write();
        if is_bracketed {
            // Remove any literal escape characters to avoid escaping bracketed paste
            input = input.replace('\x1b', "");
            writer.0.write_all(b"\x1b[200~").unwrap();
            writer.0.write_all(input.as_bytes()).unwrap();
            writer.0.write_all(b"\x1b[201~").unwrap();
        } else {
            // Standard terminal behavior: send carriage return instead of newline
            input = input.replace('\n', "\r");
            writer.0.write_all(input.as_bytes()).unwrap();
        }
        writer.0.flush().unwrap();
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        {
            let mut term = self.term.write();
            term.resize(SimpleDimensions {
                cols: cols as usize,
                rows: rows as usize,
            });
        }
        {
            let master = self.master_pty.write();
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
        if !self.dirty.swap(false, Ordering::SeqCst) {
            return None;
        }

        let term = self.term.read();
        let grid = term.grid();
        let display_offset = grid.display_offset(); // How many lines we are scrolled up

        let mut content = String::new();
        let rows = term.screen_lines();
        let cols = term.columns();
        let mut attributes = Vec::with_capacity(rows * cols);

        for y in 0..rows {
            // Map screen row 'y' to grid line accounting for scrollback
            let line_idx = Line(y as i32 - display_offset as i32);
            for col in 0..cols {
                let cell = &grid[line_idx][Column(col)];
                content.push(cell.c);

                let mut attr = 0u32;
                if cell.flags().contains(Flags::BOLD) {
                    attr |= 1;
                }
                if cell.flags().contains(Flags::WRAPLINE) {
                    attr |= 2;
                }
                attributes.push(attr);
            }
        }

        // Adjust cursor_y to be relative to the scrolled viewport
        // If the cursor is on the screen, its position is original_y + display_offset
        let raw_cursor_y = term.grid().cursor.point.line.0 as i32;
        let adjusted_cursor_y = raw_cursor_y + display_offset as i32;

        Some(TerminalFrame {
            rows: rows as u16,
            cols: cols as u16,
            content,
            attributes,
            cursor_x: term.grid().cursor.point.column.0 as u16,
            // Hide cursor (move off-screen) if it's not in the current viewport
            cursor_y: if (0..rows as i32).contains(&adjusted_cursor_y) {
                adjusted_cursor_y as u16
            } else {
                65535
            },
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
        let mut writer = self.writer.write();
        writer.0.write_all(seq.as_bytes()).unwrap();
        writer.0.flush().unwrap();
    }

    pub fn cwd(&self) -> Option<String> {
        let pid = self.child_pid?;
        std::fs::read_link(format!("/proc/{}/cwd", pid))
            .ok()
            .and_then(|path| path.to_str().map(|s| s.to_string()))
    }
}
