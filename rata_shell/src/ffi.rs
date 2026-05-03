//! C ABI exports.
//!
//! Every public function:
//!   * is `extern "C"`,
//!   * is wrapped in `catch_unwind` to prevent panics from unwinding past the
//!     FFI boundary, and
//!   * validates handles with a magic-number check.

use crate::error::*;
use crate::session::{Callbacks, Session, SpawnOptions, SESSION_MAGIC};
use crate::term::HostCell;
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

// ---------- Init / shutdown / version ----------

pub const RATA_INIT_LOG_FILE: u32 = 0x01;
pub const RATA_INIT_LOG_DEBUG: u32 = 0x02;

use std::fs::OpenOptions;
use std::io::Write;
use std::sync::OnceLock;

static LOG_FILE: OnceLock<()> = OnceLock::new();

#[no_mangle]
pub extern "C" fn rata_init(flags: u32) -> RataResult {
    guard(|| {
        if flags & RATA_INIT_LOG_FILE != 0 {
            LOG_FILE.get_or_init(|| {
                init_logging(flags);
            });
        }
        crate::log::rlog(format_args!("rata_init flags=0x{:x}", flags));
        RATA_OK
    })
}

fn init_logging(_flags: u32) {
    // Try a list of candidate locations and use the first that opens. The
    // primary target is the directory containing rata_shell.dll itself, which
    // is always next to the EXE that loaded it and avoids any %TEMP% surprise.
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Some(dir) = dll_dir() {
        candidates.push(dir.join("rata_shell.log"));
    }
    for env_name in ["TEMP", "TMP", "USERPROFILE"] {
        if let Some(d) = std::env::var_os(env_name) {
            candidates.push(std::path::PathBuf::from(d).join("rata_shell.log"));
        }
    }
    candidates.push(std::path::PathBuf::from("C:\\rata_shell.log"));

    for path in candidates {
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        {
            let _ = writeln!(
                file,
                "==== rata_shell {} session start (pid={}) path={} ====",
                env!("CARGO_PKG_VERSION"),
                std::process::id(),
                path.display()
            );
            let _ = file.flush();
            crate::log::install(file, path);
            return;
        }
    }
}

fn dll_dir() -> Option<std::path::PathBuf> {
    use windows::Win32::Foundation::HMODULE;
    use windows::Win32::System::LibraryLoader::{
        GetModuleFileNameW, GetModuleHandleExW, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
        GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    };
    unsafe {
        let mut module = HMODULE::default();
        let probe = dll_dir as *const () as *const _;
        if GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            windows::core::PCWSTR(probe),
            &mut module,
        )
        .is_err()
        {
            return None;
        }
        let mut buf = [0u16; 1024];
        let n = GetModuleFileNameW(Some(module), &mut buf);
        if n == 0 {
            return None;
        }
        let s = String::from_utf16_lossy(&buf[..n as usize]);
        std::path::PathBuf::from(s).parent().map(|p| p.to_path_buf())
    }
}

#[no_mangle]
pub extern "C" fn rata_shutdown() {
    let _ = guard(|| RATA_OK);
}

#[no_mangle]
pub extern "C" fn rata_version() -> *const u8 {
    static VERSION: &[u8] = b"0.1.0\0";
    VERSION.as_ptr()
}

#[no_mangle]
pub extern "C" fn rata_last_error_message(buf: *mut u8, cap: usize) -> usize {
    let msg = last_error_copy();
    let bytes = msg.as_bytes();
    if buf.is_null() || cap == 0 {
        return bytes.len();
    }
    let n = bytes.len().min(cap.saturating_sub(1));
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, n);
        *buf.add(n) = 0;
    }
    n
}

// ---------- Spawn options ----------

#[repr(C)]
pub struct RataSpawnOptions {
    pub shell_path_utf8: *const u8,
    pub shell_path_len: usize,
    pub shell_args_utf8: *const u8,
    pub shell_args_len: usize,
    pub cwd_utf8: *const u8,
    pub cwd_len: usize,
    pub env_utf8: *const u8,
    pub env_len: usize,
    pub cols: u16,
    pub rows: u16,
    pub scrollback: u32,
    pub flags: u32,
}

// ---------- Session opaque handle ----------

pub type RataSession = *mut c_void;

fn session_from(handle: RataSession) -> Result<&'static Session, RataError> {
    if handle.is_null() {
        return Err(RataError::Invalid);
    }
    let s = unsafe { &*(handle as *const Session) };
    if s.magic != SESSION_MAGIC {
        return Err(RataError::Invalid);
    }
    Ok(s)
}

#[no_mangle]
pub extern "C" fn rata_session_create(
    opts: *const RataSpawnOptions,
    out_handle: *mut RataSession,
) -> RataResult {
    guard(|| {
        if opts.is_null() || out_handle.is_null() {
            return store(&RataError::Arg("null pointer"));
        }
        let opts = unsafe { &*opts };
        let shell_path = match read_utf8(opts.shell_path_utf8, opts.shell_path_len) {
            Some(s) if !s.is_empty() => s,
            _ => "C:\\Windows\\System32\\cmd.exe".to_string(),
        };
        let shell_args = read_utf8(opts.shell_args_utf8, opts.shell_args_len).unwrap_or_default();
        let cmdline = if shell_args.is_empty() {
            quote_path(&shell_path)
        } else {
            format!("{} {}", quote_path(&shell_path), shell_args)
        };
        let cwd = read_utf8(opts.cwd_utf8, opts.cwd_len).filter(|s| !s.is_empty());
        let env_block = if opts.env_utf8.is_null() || opts.env_len == 0 {
            None
        } else {
            Some(env_block_to_utf16(unsafe {
                slice::from_raw_parts(opts.env_utf8, opts.env_len)
            }))
        };

        let so = SpawnOptions {
            cmdline,
            cwd,
            env_block,
            cols: opts.cols.max(1),
            rows: opts.rows.max(1),
            scrollback: if opts.scrollback == 0 {
                10_000
            } else {
                opts.scrollback as usize
            },
        };

        let session = Box::new(Session::new(so));
        let raw = Box::into_raw(session) as RataSession;
        unsafe {
            *out_handle = raw;
        }
        RATA_OK
    })
}

#[no_mangle]
pub extern "C" fn rata_session_destroy(handle: RataSession) -> RataResult {
    guard(|| {
        if handle.is_null() {
            return RATA_OK;
        }
        let s = unsafe { &*(handle as *const Session) };
        if s.magic != SESSION_MAGIC {
            return store(&RataError::Invalid);
        }
        let _ = unsafe { Box::from_raw(handle as *mut Session) };
        RATA_OK
    })
}

// ---------- Callbacks ----------

#[repr(C)]
pub struct RataRect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

#[repr(C)]
pub struct RataCellC {
    pub ch: u32,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub width: u8,
    pub _pad: u8,
}

#[repr(C)]
pub struct RataRenderEvent {
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: u8,
    pub cursor_style: u8,
    pub _pad: [u8; 2],
    pub dirty_rects: *const RataRect,
    pub dirty_count: usize,
    pub cells: *const RataCellC,
    pub cells_len: usize,
}

pub type RataRenderCb =
    extern "C" fn(user: *mut c_void, ev: *const RataRenderEvent);
pub type RataExitCb = extern "C" fn(user: *mut c_void, exit_code: i32);
pub type RataBellCb = extern "C" fn(user: *mut c_void);
pub type RataTitleCb =
    extern "C" fn(user: *mut c_void, utf8: *const u8, len: usize);

#[no_mangle]
pub extern "C" fn rata_session_set_callbacks(
    handle: RataSession,
    on_render: Option<RataRenderCb>,
    on_exit: Option<RataExitCb>,
    on_bell: Option<RataBellCb>,
    on_title: Option<RataTitleCb>,
    user: *mut c_void,
) -> RataResult {
    guard(|| {
        let s = match session_from(handle) {
            Ok(s) => s,
            Err(e) => return store(&e),
        };
        // Convert raw pointer to usize so the captured value satisfies Send+Sync.
        let user_addr = user as usize;

        let render_cb = on_render.map(|cb| {
            Box::new(move |snap: &crate::render::RenderSnapshot, _title: &str| {
                let rects: Vec<RataRect> = snap
                    .dirty
                    .iter()
                    .map(|r| RataRect { x: r.x, y: r.y, w: r.w, h: r.h })
                    .collect();
                let cells: Vec<RataCellC> = snap.cells.iter().map(cell_to_c).collect();
                let ev = RataRenderEvent {
                    cols: snap.cols,
                    rows: snap.rows,
                    cursor_x: snap.cursor_x,
                    cursor_y: snap.cursor_y,
                    cursor_visible: snap.cursor_visible as u8,
                    cursor_style: snap.cursor_style,
                    _pad: [0; 2],
                    dirty_rects: rects.as_ptr(),
                    dirty_count: rects.len(),
                    cells: cells.as_ptr(),
                    cells_len: cells.len(),
                };
                let u = user_addr as *mut c_void;
                let _ = catch_unwind(AssertUnwindSafe(|| cb(u, &ev)));
            }) as crate::session::RenderCallback
        });

        let exit_cb = on_exit.map(|cb| {
            Box::new(move |code: i32| {
                let u = user_addr as *mut c_void;
                let _ = catch_unwind(AssertUnwindSafe(|| cb(u, code)));
            }) as crate::session::ExitCallback
        });

        let bell_cb = on_bell.map(|cb| {
            Box::new(move || {
                let u = user_addr as *mut c_void;
                let _ = catch_unwind(AssertUnwindSafe(|| cb(u)));
            }) as crate::session::BellCallback
        });

        let title_cb = on_title.map(|cb| {
            Box::new(move |t: &str| {
                let u = user_addr as *mut c_void;
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    cb(u, t.as_ptr(), t.len())
                }));
            }) as crate::session::TitleCallback
        });

        s.set_callbacks(Callbacks {
            on_render: render_cb,
            on_exit: exit_cb,
            on_bell: bell_cb,
            on_title: title_cb,
        });
        RATA_OK
    })
}

fn cell_to_c(c: &HostCell) -> RataCellC {
    RataCellC {
        ch: c.ch,
        fg: c.fg,
        bg: c.bg,
        attrs: c.attrs,
        width: c.width,
        _pad: 0,
    }
}

// ---------- Operations ----------

#[no_mangle]
pub extern "C" fn rata_session_start(handle: RataSession) -> RataResult {
    guard(|| match session_from(handle) {
        Ok(s) => match s.start() {
            Ok(()) => RATA_OK,
            Err(e) => store(&e),
        },
        Err(e) => store(&e),
    })
}

#[no_mangle]
pub extern "C" fn rata_session_resize(handle: RataSession, cols: u16, rows: u16) -> RataResult {
    guard(|| match session_from(handle) {
        Ok(s) => match s.resize(cols, rows) {
            Ok(()) => RATA_OK,
            Err(e) => store(&e),
        },
        Err(e) => store(&e),
    })
}

#[no_mangle]
pub extern "C" fn rata_session_send_text(
    handle: RataSession,
    utf8: *const u8,
    len: usize,
) -> RataResult {
    guard(|| {
        let s = match session_from(handle) {
            Ok(s) => s,
            Err(e) => return store(&e),
        };
        if utf8.is_null() || len == 0 {
            return RATA_OK;
        }
        let bytes = unsafe { slice::from_raw_parts(utf8, len) };
        match s.send_bytes(bytes) {
            Ok(()) => RATA_OK,
            Err(e) => store(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn rata_session_send_key(
    handle: RataSession,
    vk: u32,
    mods: u32,
) -> RataResult {
    guard(|| {
        let s = match session_from(handle) {
            Ok(s) => s,
            Err(e) => return store(&e),
        };
        match s.send_key(vk, mods) {
            Ok(()) => RATA_OK,
            Err(e) => store(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn rata_session_request_render(handle: RataSession) -> RataResult {
    guard(|| match session_from(handle) {
        Ok(s) => {
            s.request_render();
            RATA_OK
        }
        Err(e) => store(&e),
    })
}

#[no_mangle]
pub extern "C" fn rata_session_terminate(
    handle: RataSession,
    timeout_ms: u32,
) -> RataResult {
    guard(|| match session_from(handle) {
        Ok(s) => {
            s.terminate(timeout_ms);
            RATA_OK
        }
        Err(e) => store(&e),
    })
}

#[no_mangle]
pub extern "C" fn rata_session_is_alive(handle: RataSession) -> i32 {
    guard_with(0, || match session_from(handle) {
        Ok(s) => s.is_alive() as i32,
        Err(_) => 0,
    })
}

#[no_mangle]
pub extern "C" fn rata_session_get_size(
    handle: RataSession,
    out_cols: *mut u16,
    out_rows: *mut u16,
) -> RataResult {
    guard(|| match session_from(handle) {
        Ok(s) => {
            let (c, r) = s.cols_rows();
            unsafe {
                if !out_cols.is_null() {
                    *out_cols = c;
                }
                if !out_rows.is_null() {
                    *out_rows = r;
                }
            }
            RATA_OK
        }
        Err(e) => store(&e),
    })
}

#[no_mangle]
pub extern "C" fn rata_session_get_title(
    handle: RataSession,
    buf: *mut u8,
    cap: usize,
) -> usize {
    guard_with(0usize, || match session_from(handle) {
        Ok(s) => {
            let t = s.title();
            let bytes = t.as_bytes();
            if buf.is_null() || cap == 0 {
                return bytes.len();
            }
            let n = bytes.len().min(cap.saturating_sub(1));
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, n);
                *buf.add(n) = 0;
            }
            n
        }
        Err(_) => 0,
    })
}

// ---------- Helpers ----------

fn read_utf8(p: *const u8, len: usize) -> Option<String> {
    if p.is_null() || len == 0 {
        return None;
    }
    let bytes = unsafe { slice::from_raw_parts(p, len) };
    Some(String::from_utf8_lossy(bytes).into_owned())
}

fn quote_path(p: &str) -> String {
    if p.contains(' ') && !p.starts_with('"') {
        format!("\"{}\"", p)
    } else {
        p.to_string()
    }
}

fn env_block_to_utf16(bytes: &[u8]) -> Vec<u16> {
    let s = String::from_utf8_lossy(bytes);
    let mut out: Vec<u16> = Vec::with_capacity(bytes.len());
    for entry in s.split('\0') {
        if entry.is_empty() {
            continue;
        }
        out.extend(entry.encode_utf16());
        out.push(0);
    }
    out.push(0);
    out
}

fn guard<F: FnOnce() -> RataResult>(f: F) -> RataResult {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(RATA_ERR_PANIC)
}

fn guard_with<T: Copy, F: FnOnce() -> T>(default: T, f: F) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(default)
}

#[allow(unused_imports)]
use once_cell as _;
