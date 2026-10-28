use crate::terminal::{FlutterTerminal, TerminalUpdate};
use parking_lot::RwLock;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};

// Re-export needed types for FRB
pub use crate::terminal::TerminalCell;

use std::sync::OnceLock;

use std::thread;
use std::time::Duration;

static NEXT_ID: AtomicU32 = AtomicU32::new(1);

fn terminals() -> &'static RwLock<HashMap<u32, FlutterTerminal>> {
    static INSTANCE: OnceLock<RwLock<HashMap<u32, FlutterTerminal>>> = OnceLock::new();
    INSTANCE.get_or_init(|| RwLock::new(HashMap::new()))
}

fn active_id() -> &'static RwLock<u32> {
    static INSTANCE: OnceLock<RwLock<u32>> = OnceLock::new();
    INSTANCE.get_or_init(|| RwLock::new(0))
}

#[flutter_rust_bridge::frb(sync)]
pub fn add_terminal(rows: u16, cols: u16, cwd: Option<String>) -> u32 {
    let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);

    // Inherit active tab's CWD if not provided; filter invalid/deleted dirs so shell spawn won't fail.
    let resolved_cwd = cwd.or_else(|| {
        let active = *active_id().read();
        if active != 0 {
            let lock = terminals().read();
            lock.get(&active).and_then(|t| t.cwd())
        } else {
            None
        }
    }).filter(|dir| std::path::Path::new(dir).is_dir());

    if let Some(terminal) = FlutterTerminal::new(rows, cols, resolved_cwd) {
        let mut lock = terminals().write();
        lock.insert(id, terminal);

        let mut active_lock = active_id().write();
        if *active_lock == 0 {
            *active_lock = id;
        }

        id
    } else {
        0
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_terminal_cwd(id: u32) -> Option<String> {
    let lock = terminals().read();
    lock.get(&id).and_then(|t| t.cwd())
}

#[flutter_rust_bridge::frb(sync)]
pub fn remove_terminal(id: u32) {
    // Release write-lock before dropping terminal to avoid blocking concurrent tab operations.
    let terminal = {
        let mut lock = terminals().write();
        let term = lock.remove(&id);

        let mut active_lock = active_id().write();
        if *active_lock == id {
            // Clear active_id so Flutter's tab controller explicitly sets the new active tab.
            *active_lock = 0;
        }
        term
    };

    // Reap child process asynchronously so blocking waitpid() doesn't stall the Flutter UI thread.
    if let Some(term) = terminal {
        thread::spawn(move || {
            drop(term);
        });
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_active_terminal(id: u32) {
    let mut active_lock = active_id().write();
    *active_lock = id;
}

use crate::frb_generated::StreamSink;

pub fn create_terminal_stream(sink: StreamSink<u32>) {
    thread::spawn(move || loop {
        {
            let lock = terminals().read();
            let active = *active_id().read();
            for (&id, terminal) in lock.iter() {
                let is_closed = terminal.is_closed.load(Ordering::SeqCst);
                // Stream dirty updates only for the active tab; broadcast closure for all tabs.
                let is_dirty = terminal.dirty.load(Ordering::SeqCst);
                if (id == active && is_dirty) || is_closed {
                    let _ = sink.add(id);
                }
            }
        }
        thread::sleep(Duration::from_millis(16));
    });
}

/// Rows changed since the previous call for `id`; `force_full` resends the whole screen.
#[flutter_rust_bridge::frb(sync)]
pub fn get_terminal_update(id: u32, force_full: bool) -> Option<TerminalUpdate> {
    let lock = terminals().read();
    lock.get(&id).and_then(|t| t.get_update(force_full))
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_terminal_closed(id: u32) -> bool {
    let lock = terminals().read();
    lock.get(&id)
        .map(|t| t.is_closed.load(Ordering::SeqCst))
        .unwrap_or(true)
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_terminal_app_cursor(id: u32) -> bool {
    let lock = terminals().read();
    lock.get(&id).map(|t| t.is_app_cursor()).unwrap_or(false)
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_terminal_alt_screen(id: u32) -> bool {
    let lock = terminals().read();
    lock.get(&id).map(|t| t.is_alt_screen()).unwrap_or(false)
}

#[flutter_rust_bridge::frb(sync)]
pub fn send_input(id: u32, input: String) {
    let lock = terminals().read();
    if let Some(t) = lock.get(&id) {
        t.write(input);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn send_key(id: u32, normal_seq: String, app_seq: String) {
    let lock = terminals().read();
    if let Some(t) = lock.get(&id) {
        t.send_key(&normal_seq, &app_seq);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn paste_terminal(id: u32, input: String) {
    let lock = terminals().read();
    if let Some(t) = lock.get(&id) {
        t.paste(input);
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)]
pub fn scroll_terminal(id: u32, lines: i32) {
    let lock = terminals().read();
    if let Some(t) = lock.get(&id) {
        t.scroll(lines);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn resize_terminal(id: u32, rows: u16, cols: u16) {
    let lock = terminals().read();
    if let Some(t) = lock.get(&id) {
        t.resize(rows, cols);
    }
}
