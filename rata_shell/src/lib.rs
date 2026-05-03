//! rata_shell — Embeddable Windows shell component DLL.
//!
//! Combines a ConPTY-hosted shell with the alacritty terminal emulator core
//! (parsing, screen state, scrollback, alt-screen) and exposes a flat C ABI
//! for Delphi (or any host with C FFI) to render the terminal viewport.

#![cfg(windows)]

mod error;
mod ffi;
mod io;
mod keymap;
#[macro_use]
mod log;
mod pty;
mod render;
mod session;
mod term;

pub use ffi::*;
