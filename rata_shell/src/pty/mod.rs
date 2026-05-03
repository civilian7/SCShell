//! ConPTY host: pseudo-console + child process + job object.

mod conpty;
mod job;

pub use conpty::PtyHost;
