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
pub type ClipboardCallback = Box<dyn Fn(&str) + Send + Sync>;

pub struct Callbacks {
    pub on_render: Option<RenderCallback>,
    pub on_exit: Option<ExitCallback>,
    pub on_bell: Option<BellCallback>,
    pub on_title: Option<TitleCallback>,
    pub on_clipboard: Option<ClipboardCallback>,
}

impl Default for Callbacks {
    fn default() -> Self {
        Callbacks {
            on_render: None,
            on_exit: None,
            on_bell: None,
            on_title: None,
            on_clipboard: None,
        }
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

    /// 4 메인 콜백을 한 번에 갱신 — on_clipboard 는 보존.
    pub fn set_callbacks(&self, cbs: Callbacks) {
        let mut cur = self.callbacks.lock();
        cur.on_render = cbs.on_render;
        cur.on_exit = cbs.on_exit;
        cur.on_bell = cbs.on_bell;
        cur.on_title = cbs.on_title;
        // on_clipboard 는 set_clipboard_callback 으로 별도 관리.
    }

    pub fn set_clipboard_callback(&self, cb: Option<ClipboardCallback>) {
        self.callbacks.lock().on_clipboard = cb;
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

                            // alacritty Event 큐 처리 (Title/Bell/ClipboardStore 등).
                            let events = {
                                let mut t = term.lock();
                                t.drain_events()
                            };
                            for ev in events {
                                match ev {
                                    alacritty_terminal::event::Event::Title(title) => {
                                        let cb = callbacks.lock();
                                        if let Some(f) = cb.on_title.as_ref() {
                                            f(&title);
                                        }
                                    }
                                    alacritty_terminal::event::Event::ResetTitle => {
                                        let cb = callbacks.lock();
                                        if let Some(f) = cb.on_title.as_ref() {
                                            f("");
                                        }
                                    }
                                    alacritty_terminal::event::Event::Bell => {
                                        let cb = callbacks.lock();
                                        if let Some(f) = cb.on_bell.as_ref() {
                                            f();
                                        }
                                    }
                                    alacritty_terminal::event::Event::ClipboardStore(_ty, text) => {
                                        let cb = callbacks.lock();
                                        if let Some(f) = cb.on_clipboard.as_ref() {
                                            f(&text);
                                        }
                                    }
                                    _ => {}
                                }
                            }

                            let snap = {
                                let mut t = term.lock();
                                backend.lock().snapshot(&mut *t)
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
                                let mut t = term.lock();
                                backend.lock().snapshot(&mut *t)
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
            let mut t = self.term.lock();
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
            let mut t = self.term.lock();
            self.backend.lock().snapshot(&mut *t)
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

    /// Scroll display by `lines` and re-render.
    pub fn scroll(&self, lines: i32) {
        self.term.lock().scroll_display(lines);
        self.request_render();
    }

    pub fn scroll_to_top(&self) {
        self.term.lock().scroll_to_top();
        self.request_render();
    }

    pub fn scroll_to_bottom(&self) {
        self.term.lock().scroll_to_bottom();
        self.request_render();
    }

    /// Returns (display_offset, configured_scrollback_max).
    pub fn scroll_info(&self) -> (usize, usize) {
        let off = self.term.lock().display_offset();
        let max = self.options.lock().scrollback;
        (off, max)
    }

    pub fn clear_history(&self) {
        self.term.lock().clear_history();
        self.request_render();
    }

    pub fn reset_state(&self) {
        self.term.lock().reset_state();
        self.request_render();
    }

    /// Current cached exit code (0 if still alive). Set by io pump on child exit.
    pub fn exit_code(&self) -> i32 {
        self.exit_code.load(Ordering::SeqCst)
    }

    /// PID of the spawned child (0 if not running).
    pub fn child_pid(&self) -> u32 {
        match self.pty.lock().as_ref() {
            Some(p) => p.child_pid(),
            None => 0,
        }
    }

    /// Bit-flags for current TermMode (see TermHost::mode_flags).
    pub fn mode_flags(&self) -> u32 {
        self.term.lock().mode_flags()
    }

    pub fn selection_start(&self, col: u16, row: u16, kind: u8) {
        self.term.lock().selection_start(col, row, kind);
        self.request_render();
    }

    pub fn selection_extend(&self, col: u16, row: u16) {
        self.term.lock().selection_extend(col, row);
        self.request_render();
    }

    pub fn selection_clear(&self) {
        self.term.lock().selection_clear();
        self.request_render();
    }

    pub fn selection_to_string(&self) -> Option<String> {
        self.term.lock().selection_to_string()
    }

    /// 현재 작업 디렉터리 (셸이 OSC 7 로 보고한 마지막 값).
    pub fn current_cwd(&self) -> String {
        self.term.lock().current_cwd.clone()
    }

    /// OSC 8 hyperlink id → URI 조회. id=0 이거나 없으면 빈 문자열.
    pub fn hyperlink_uri(&self, id: u32) -> String {
        if id == 0 { return String::new(); }
        self.term.lock().hyperlinks.get(&id).cloned().unwrap_or_default()
    }

    /// VI navigation mode 토글 (alacritty 표준 — hjkl 이동 등).
    pub fn toggle_vi_mode(&self) {
        self.term.lock().toggle_vi_mode();
        self.request_render();
    }

    /// VI mode 활성 여부.
    pub fn vi_mode_active(&self) -> bool {
        self.term.lock().vi_mode_active()
    }

    /// VI motion 실행 + 재렌더.
    pub fn vi_motion(&self, kind: u8) {
        self.term.lock().vi_motion(kind);
        self.request_render();
    }

    /// Regex 검색 — 지정된 방향으로 다음 일치를 viewport 좌표로 반환.
    /// 반환: (col, row, length_in_cells). 없으면 (0, 0, 0).
    /// AForward: true = 아래/오른쪽, false = 위/왼쪽
    pub fn search_next(&self, pattern: &str, forward: bool) -> (u16, u16, u16) {
        self.term.lock().search_next(pattern, forward)
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
