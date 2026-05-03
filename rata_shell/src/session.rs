//! Top-level session: owns the PTY, IO threads, alacritty Term, and renderer.

use crate::error::RataError;
use crate::io::{IoEvent, ReaderThread, WriterThread};
use crate::pty::PtyHost;
use crate::render::{HostBackend, RenderSnapshot};
use crate::term::TermHost;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

pub struct SpawnOptions {
    pub cmdline: String,
    pub cwd: Option<String>,
    pub env_block: Option<Vec<u16>>,
    pub cols: u16,
    pub rows: u16,
    pub scrollback: usize,
}

pub type RenderCallback = Box<dyn Fn(&RenderSnapshot, &str) + Send + Sync>;
pub type ExitCallback = Box<dyn Fn(i32) + Send + Sync>;
pub type BellCallback = Box<dyn Fn() + Send + Sync>;
pub type TitleCallback = Box<dyn Fn(&str) + Send + Sync>;

pub struct Callbacks {
    pub on_render: Option<RenderCallback>,
    pub on_exit: Option<ExitCallback>,
    pub on_bell: Option<BellCallback>,
    pub on_title: Option<TitleCallback>,
}

impl Default for Callbacks {
    fn default() -> Self {
        Callbacks { on_render: None, on_exit: None, on_bell: None, on_title: None }
    }
}

pub struct Session {
    pub magic: u32,
    pty: Mutex<Option<Arc<PtyHost>>>,
    reader: Mutex<Option<ReaderThread>>,
    writer: Mutex<Option<WriterThread>>,
    term: Arc<Mutex<TermHost>>,
    backend: Arc<Mutex<HostBackend>>,
    callbacks: Arc<Mutex<Callbacks>>,
    pump: Mutex<Option<JoinHandle<()>>>,
    alive: Arc<AtomicBool>,
    exit_code: Arc<AtomicI32>,
    options: Mutex<SpawnOptions>,
}

pub const SESSION_MAGIC: u32 = 0x52415441; // 'RATA'

impl Session {
    pub fn new(options: SpawnOptions) -> Self {
        let term = TermHost::new(options.cols, options.rows, options.scrollback);
        Session {
            magic: SESSION_MAGIC,
            pty: Mutex::new(None),
            reader: Mutex::new(None),
            writer: Mutex::new(None),
            term: Arc::new(Mutex::new(term)),
            backend: Arc::new(Mutex::new(HostBackend::new())),
            callbacks: Arc::new(Mutex::new(Callbacks::default())),
            pump: Mutex::new(None),
            alive: Arc::new(AtomicBool::new(false)),
            exit_code: Arc::new(AtomicI32::new(0)),
            options: Mutex::new(options),
        }
    }

    pub fn set_callbacks(&self, cbs: Callbacks) {
        *self.callbacks.lock() = cbs;
    }

    pub fn start(&self) -> Result<(), RataError> {
        if self.alive.load(Ordering::SeqCst) {
            return Err(RataError::State("already running"));
        }
        let opts = self.options.lock();
        // Inject TERM/COLORTERM if caller didn't supply env_block — allows
        // claude / vim / etc. to use alt-screen + truecolor.
        let env_owned: Option<Vec<u16>>;
        let env_ref: Option<&[u16]> = match opts.env_block.as_deref() {
            Some(b) => {
                env_owned = None;
                Some(b)
            }
            None => {
                env_owned = Some(default_env_with_terminfo());
                env_owned.as_deref()
            }
        };
        crate::rlog!(
            "session.start cmdline={:?} cols={} rows={} env_injected={}",
            opts.cmdline, opts.cols, opts.rows, opts.env_block.is_none()
        );
        let pty = Arc::new(PtyHost::spawn(
            &opts.cmdline,
            opts.cwd.as_deref(),
            env_ref,
            opts.cols,
            opts.rows,
        )?);
        drop(opts);
        drop(env_owned);

        let reader = ReaderThread::spawn(&pty);
        let writer = WriterThread::spawn(&pty);

        let term = Arc::clone(&self.term);
        let backend = Arc::clone(&self.backend);
        let callbacks = Arc::clone(&self.callbacks);
        let alive = Arc::clone(&self.alive);
        let exit_code = Arc::clone(&self.exit_code);
        let pty_arc = Arc::clone(&pty);
        let rx = reader.rx.clone();

        alive.store(true, Ordering::SeqCst);

        let pump = std::thread::Builder::new()
            .name("rata-pump".into())
            .spawn(move || {
                while let Ok(ev) = rx.recv() {
                    match ev {
                        IoEvent::Bytes(buf) => {
                            {
                                let mut t = term.lock();
                                t.advance(&buf);
                            }
                            // Drain any extra buffered input within a small budget
                            // before snapshotting, to coalesce frames.
                            while let Ok(IoEvent::Bytes(more)) = rx.try_recv() {
                                let mut t = term.lock();
                                t.advance(&more);
                            }

                            let snap = {
                                let t = term.lock();
                                backend.lock().snapshot(&t)
                            };
                            {
                                crate::rlog!(
                                    "render cols={} rows={} cursor=({},{})",
                                    snap.cols, snap.rows, snap.cursor_x, snap.cursor_y
                                );
                            }
                            let cb = callbacks.lock();
                            if let Some(f) = cb.on_render.as_ref() {
                                f(&snap, "");
                            }
                        }
                        IoEvent::Eof => {
                            let snap = {
                                let t = term.lock();
                                backend.lock().snapshot(&t)
                            };
                            {
                                let cb = callbacks.lock();
                                if let Some(f) = cb.on_render.as_ref() {
                                    f(&snap, "");
                                }
                            }
                            let code = pty_arc.try_exit_code().unwrap_or(0);
                            exit_code.store(code, Ordering::SeqCst);
                            alive.store(false, Ordering::SeqCst);
                            let cb = callbacks.lock();
                            if let Some(f) = cb.on_exit.as_ref() {
                                f(code);
                            }
                            break;
                        }
                    }
                }
            })
            .expect("spawn pump");

        *self.pty.lock() = Some(pty);
        *self.reader.lock() = Some(reader);
        *self.writer.lock() = Some(writer);
        *self.pump.lock() = Some(pump);
        Ok(())
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), RataError> {
        self.term.lock().resize(cols, rows);
        if let Some(p) = self.pty.lock().as_ref() {
            p.resize(cols, rows)?;
        }
        Ok(())
    }

    pub fn send_bytes(&self, bytes: &[u8]) -> Result<(), RataError> {
        if bytes.is_empty() {
            return Ok(());
        }
        if let Some(w) = self.writer.lock().as_ref() {
            let _ = w.tx.send(bytes.to_vec());
            Ok(())
        } else {
            Err(RataError::State("not started"))
        }
    }

    pub fn send_key(&self, vk: u32, mods: u32) -> Result<(), RataError> {
        let app = {
            let t = self.term.lock();
            // Read app cursor mode via snapshot (cheap).
            let mut buf = Vec::new();
            t.snapshot(&mut buf).app_cursor_keys
        };
        let bytes = crate::keymap::encode(vk, mods, app);
        if bytes.is_empty() {
            return Ok(());
        }
        self.send_bytes(&bytes)
    }

    pub fn request_render(&self) {
        let snap = {
            let t = self.term.lock();
            self.backend.lock().snapshot(&t)
        };
        let cb = self.callbacks.lock();
        if let Some(f) = cb.on_render.as_ref() {
            f(&snap, "");
        }
    }

    pub fn terminate(&self, _timeout_ms: u32) {
        if let Some(p) = self.pty.lock().as_ref() {
            p.terminate(1);
        }
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn cols_rows(&self) -> (u16, u16) {
        let t = self.term.lock();
        (t.cols(), t.rows())
    }

    pub fn title(&self) -> String {
        self.term.lock().title()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.terminate(0);

        // Inject synthetic EOF so pump wakes up regardless of reader state.
        if let Some(reader) = self.reader.lock().as_ref() {
            let _ = reader.tx.send(crate::io::IoEvent::Eof);
        }

        let _ = self.writer.lock().take();
        let _ = self.pty.lock().take();
        if let Some(j) = self.pump.lock().take() {
            let _ = j.join();
        }
        let _ = self.reader.lock().take();
    }
}

fn default_env_with_terminfo() -> Vec<u16> {
    let mut entries: Vec<(String, String)> = std::env::vars().collect();
    upsert(&mut entries, "TERM", "xterm-256color");
    upsert(&mut entries, "COLORTERM", "truecolor");

    let mut out: Vec<u16> = Vec::with_capacity(entries.len() * 32);
    for (k, v) in entries {
        let line = format!("{}={}", k, v);
        out.extend(line.encode_utf16());
        out.push(0);
    }
    out.push(0);
    out
}

fn upsert(entries: &mut Vec<(String, String)>, key: &str, value: &str) {
    if let Some(slot) = entries
        .iter_mut()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
    {
        slot.1 = value.to_string();
    } else {
        entries.push((key.to_string(), value.to_string()));
    }
}
