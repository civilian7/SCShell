//! Ratatui integration: a custom `Backend` that captures cell output into a
//! flat buffer for the host, plus dirty-rect tracking.

mod backend;

pub use backend::{HostBackend, RenderSnapshot};
