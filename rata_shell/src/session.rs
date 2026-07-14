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
    /// 자식 프로세스 감시 스레드. **반드시 보관해서 Drop 에서 join 해야 한다** —
    /// 버리면 세션이 해제된 뒤에도 살아남아 호스트 콜백(이미 해제된 인스턴스)을 호출한다.
    watcher: Mutex<Option<JoinHandle<()>>>,
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
            watcher: Mutex::new(None),
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
        let pty_watch = Arc::clone(&pty);   // 자식 감시 스레드용(아래) — pty 는 곧 self 로 move 된다.
        let rx = reader.rx.clone();

        alive.store(true, Ordering::SeqCst);

        let pump = std::thread::Builder::new()
            .name("rata-pump".into())
            .spawn(move || {
                loop {
                    let ev = match rx.recv() {
                        Ok(e) => e,
                        Err(_) => break, // 채널 단절 — reader 가 사라졌다.
                    };

                    // Eof 를 어느 경로에서 보든 아래 한 곳에서 처리한다.
                    let mut saw_eof = false;

                    match ev {
                        IoEvent::Bytes(buf) => {
                            {
                                let mut t = term.lock();
                                t.advance(&buf);
                            }

                            // 버퍼된 입력을 합쳐 프레임 수를 줄인다.
                            //
                            // ★try_recv 는 메시지를 채널에서 '꺼낸 뒤' 매칭한다. 종전 코드는
                            //   `while let Ok(IoEvent::Bytes(more)) = rx.try_recv()` 였는데, 여기서
                            //   Eof 를 꺼내면 패턴이 안 맞아 루프만 끝나고 그 Eof 는 그대로 버려졌다.
                            //   셸이 마지막 출력 직후 종료하는 정상 시퀀스가 정확히 이 모양이라,
                            //   대부분의 정상 종료에서 EOF 가 유실됐다(on_exit 미발화). 게다가 이후
                            //   rx.recv() 는 reader 가 tx 를 붙들고 있어 영원히 깨어나지 않았다.
                            loop {
                                match rx.try_recv() {
                                    Ok(IoEvent::Bytes(more)) => {
                                        let mut t = term.lock();
                                        t.advance(&more);
                                    }
                                    Ok(IoEvent::Eof) => {
                                        saw_eof = true;
                                        break;
                                    }
                                    Err(_) => break,
                                }
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
                            saw_eof = true;
                        }
                    }

                    if saw_eof {
                        // 마지막 화면을 한 번 더 내보낸 뒤 종료를 통지한다.
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

                        // 자식 감시 스레드와 경쟁한다 — swap 으로 먼저 온 쪽만 통지한다.
                        if alive.swap(false, Ordering::SeqCst) {
                            let cb = callbacks.lock();
                            if let Some(f) = cb.on_exit.as_ref() {
                                f(code);
                            }
                        }

                        break;
                    }
                }
            })
            .expect("spawn pump");

        *self.pty.lock() = Some(pty);
        // ★자식 프로세스 감시 — PTY 읽기 EOF 만으로는 셸 종료를 놓친다.
        //
        //   ConPTY 는 자식(powershell)이 죽어도 conhost 가 파이프의 쓰기 끝을 붙들고 있어 EOF 가
        //   오지 않는 경우가 있다. 실제로 터미널에 'exit' 를 쳐서 셸이 사라져도 io pump 는 계속
        //   기다렸고, on_exit 이 영영 발화하지 않아 호스트는 셸이 죽은 줄 몰랐다.
        //
        //   자식 핸들을 직접 폴링해 종료를 잡는다. EOF 경로와 경쟁하므로 alive 를 swap 해서
        //   먼저 온 쪽만 on_exit 을 부른다(중복 통지 금지).
        {
            let pty_w = pty_watch;
            let alive_w = Arc::clone(&self.alive);
            let code_w = Arc::clone(&self.exit_code);
            let cbs_w = Arc::clone(&self.callbacks);

            let watcher = std::thread::Builder::new()
                .name("rata-child-watch".into())
                .spawn(move || loop {
                    if !alive_w.load(Ordering::SeqCst) {
                        break; // EOF 경로가 이미 처리했거나 Drop 이 내렸다.
                    }

                    if let Some(code) = pty_w.try_exit_code() {
                        code_w.store(code, Ordering::SeqCst);
                        if alive_w.swap(false, Ordering::SeqCst) {
                            let cb = cbs_w.lock();
                            if let Some(f) = cb.on_exit.as_ref() {
                                f(code);
                            }
                        }
                        break;
                    }

                    // 폴링 주기를 잘게 나눠 재운다 — Drop 이 alive 를 내리면 최대 30ms 안에 빠진다.
                    // 한 번에 150ms 를 자면 destroy 가 그만큼 지연된다.
                    for _ in 0..5 {
                        if !alive_w.load(Ordering::SeqCst) {
                            return;
                        }

                        std::thread::sleep(std::time::Duration::from_millis(30));
                    }
                })
                .expect("spawn child watcher");

            *self.watcher.lock() = Some(watcher);
        }

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

    /// Returns (display_offset, history_size) — both in lines.
    pub fn scroll_info(&self) -> (usize, usize) {
        // ★max 는 '설정된 scrollback 한도'가 아니라 '지금 스크롤백에 실제로 쌓인 줄 수'다.
        //   한도(예: 10000)를 돌려주면 호스트 스크롤바의 thumb 이 늘 극단적으로 작고 위치도
        //   실제 내용과 어긋난다 — 100줄만 있어도 10000줄 기준으로 그리게 되기 때문이다.
        let t = self.term.lock();
        (t.display_offset(), t.history_size())
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
        // ① 콜백을 먼저 끊는다.
        //
        //    ★순서가 핵심이다. 이걸 하지 않으면 아래에서 자식을 죽이는 순간 감시 스레드가
        //    종료를 감지해 on_exit 을 호출하는데, 그 클로저가 캡처한 호스트 인스턴스는
        //    이미 소멸 중이다(호스트 측 use-after-free). alive 를 먼저 내려 감시 스레드가
        //    통지 없이 빠지게 하고, 콜백 테이블 자체도 비운다.
        self.alive.store(false, Ordering::SeqCst);
        {
            let mut cb = self.callbacks.lock();
            *cb = Callbacks::default();
        }

        // ② 자식과 PTY 를 내린다.
        self.terminate(0);

        // pump 가 reader 상태와 무관하게 깨어나도록 합성 EOF 를 넣는다.
        if let Some(reader) = self.reader.lock().as_ref() {
            let _ = reader.tx.try_send(crate::io::IoEvent::Eof);
        }

        let _ = self.writer.lock().take();
        let _ = self.pty.lock().take();

        // ③ 스레드를 전부 회수한다. 감시 스레드를 join 하지 않으면 세션이 사라진 뒤에도
        //    살아남아 Arc 로 붙든 자원을 만진다(그리고 DLL 이 언로드되면 실행 중 코드가 사라진다).
        if let Some(j) = self.pump.lock().take() {
            let _ = j.join();
        }

        if let Some(j) = self.watcher.lock().take() {
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
