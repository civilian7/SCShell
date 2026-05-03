//! Minimal direct-to-file logger that bypasses the tracing-subscriber stack.
//! tracing-subscriber's `try_init` silently fails in dynamic-library hosting
//! scenarios when a global subscriber is already set, leaving us with no
//! diagnostics. This module guarantees output as long as the file opened.

use parking_lot::Mutex;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;

static SINK: Mutex<Option<Sink>> = Mutex::new(None);

struct Sink {
    file: File,
    #[allow(dead_code)]
    path: PathBuf,
}

pub fn install(file: File, path: PathBuf) {
    *SINK.lock() = Some(Sink { file, path });
}

pub fn rlog(args: std::fmt::Arguments<'_>) {
    let mut guard = SINK.lock();
    if let Some(s) = guard.as_mut() {
        let now = chrono_ish();
        let _ = writeln!(s.file, "[{}] {}", now, args);
        let _ = s.file.flush();
    }
}

fn chrono_ish() -> String {
    // Avoid pulling in chrono — produce HH:MM:SS.mmm from SystemTime.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let millis = now.subsec_millis();
    let hh = (secs / 3600) % 24;
    let mm = (secs / 60) % 60;
    let ss = secs % 60;
    format!("{:02}:{:02}:{:02}.{:03}", hh, mm, ss, millis)
}

#[macro_export]
macro_rules! rlog {
    ($($arg:tt)*) => {
        $crate::log::rlog(format_args!($($arg)*))
    };
}
