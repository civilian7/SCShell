use parking_lot::Mutex;
use std::cell::RefCell;

pub type RataResult = i32;

pub const RATA_OK: RataResult = 0;
pub const RATA_ERR_INVALID: RataResult = -1;
pub const RATA_ERR_ARG: RataResult = -2;
pub const RATA_ERR_STATE: RataResult = -3;
pub const RATA_ERR_OS: RataResult = -4;
pub const RATA_ERR_IO: RataResult = -5;
pub const RATA_ERR_PANIC: RataResult = -99;

thread_local! {
    static LAST_ERR: RefCell<String> = const { RefCell::new(String::new()) };
}

static GLOBAL_ERR: Mutex<String> = Mutex::new(String::new());

pub fn set_last_error(msg: impl Into<String>) {
    let s = msg.into();
    LAST_ERR.with(|cell| {
        *cell.borrow_mut() = s.clone();
    });
    *GLOBAL_ERR.lock() = s;
}

pub fn last_error_copy() -> String {
    LAST_ERR.with(|cell| {
        let v = cell.borrow().clone();
        if v.is_empty() {
            GLOBAL_ERR.lock().clone()
        } else {
            v
        }
    })
}

#[derive(Debug)]
pub enum RataError {
    Invalid,
    Arg(&'static str),
    State(&'static str),
    Os(String),
    Io(std::io::Error),
}

impl RataError {
    pub fn code(&self) -> RataResult {
        match self {
            RataError::Invalid => RATA_ERR_INVALID,
            RataError::Arg(_) => RATA_ERR_ARG,
            RataError::State(_) => RATA_ERR_STATE,
            RataError::Os(_) => RATA_ERR_OS,
            RataError::Io(_) => RATA_ERR_IO,
        }
    }
}

impl std::fmt::Display for RataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RataError::Invalid => write!(f, "invalid handle or null pointer"),
            RataError::Arg(s) => write!(f, "invalid argument: {s}"),
            RataError::State(s) => write!(f, "invalid state: {s}"),
            RataError::Os(s) => write!(f, "os error: {s}"),
            RataError::Io(e) => write!(f, "io error: {e}"),
        }
    }
}

impl From<std::io::Error> for RataError {
    fn from(e: std::io::Error) -> Self {
        RataError::Io(e)
    }
}

impl From<windows::core::Error> for RataError {
    fn from(e: windows::core::Error) -> Self {
        RataError::Os(format!("HRESULT 0x{:08X}: {}", e.code().0, e.message()))
    }
}

pub fn store(err: &RataError) -> RataResult {
    set_last_error(err.to_string());
    err.code()
}
