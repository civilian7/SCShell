//! Snapshot the alacritty viewport into a flat cell array for the host,
//! and compute dirty rectangles by row diff against the previous snapshot.

use crate::term::{HostCell, SnapshotMeta, TermHost};

#[derive(Clone, Copy, Debug)]
pub struct RectU16 {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

pub struct RenderSnapshot {
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub cursor_style: u8,
    pub cells: Vec<HostCell>,
    pub dirty: Vec<RectU16>,
}

pub struct HostBackend {
    prev: Option<Vec<HostCell>>,
    prev_cols: u16,
    prev_rows: u16,
    cell_buf: Vec<HostCell>,
}

impl HostBackend {
    pub fn new() -> Self {
        HostBackend {
            prev: None,
            prev_cols: 0,
            prev_rows: 0,
            cell_buf: Vec::new(),
        }
    }

    pub fn snapshot(&mut self, term: &TermHost) -> RenderSnapshot {
        let meta: SnapshotMeta = term.snapshot(&mut self.cell_buf);
        let cols = meta.cols;
        let rows = meta.rows;
        let cells_now: Vec<HostCell> = self.cell_buf.clone();

        let mut dirty: Vec<RectU16> = Vec::new();
        let same_size = self.prev.is_some()
            && self.prev_cols == cols
            && self.prev_rows == rows;
        if !same_size {
            dirty.push(RectU16 { x: 0, y: 0, w: cols, h: rows });
        } else if let Some(prev) = &self.prev {
            for y in 0..rows as usize {
                let off = y * cols as usize;
                let new_slice = &cells_now[off..off + cols as usize];
                let old_slice = &prev[off..off + cols as usize];
                if !cells_eq(new_slice, old_slice) {
                    dirty.push(RectU16 { x: 0, y: y as u16, w: cols, h: 1 });
                }
            }
            dirty = coalesce(dirty);
        }

        self.prev = Some(cells_now.clone());
        self.prev_cols = cols;
        self.prev_rows = rows;

        RenderSnapshot {
            cols,
            rows,
            cursor_x: meta.cursor_x,
            cursor_y: meta.cursor_y,
            cursor_visible: meta.cursor_visible,
            cursor_style: 0,
            cells: cells_now,
            dirty,
        }
    }
}

fn cells_eq(a: &[HostCell], b: &[HostCell]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b.iter()).all(|(x, y)| {
        x.ch == y.ch && x.fg == y.fg && x.bg == y.bg && x.attrs == y.attrs && x.width == y.width
    })
}

fn coalesce(mut rects: Vec<RectU16>) -> Vec<RectU16> {
    rects.sort_by_key(|r| r.y);
    let mut out: Vec<RectU16> = Vec::with_capacity(rects.len());
    for r in rects {
        if let Some(last) = out.last_mut() {
            if last.x == r.x && last.w == r.w && last.y + last.h == r.y {
                last.h += r.h;
                continue;
            }
        }
        out.push(r);
    }
    out
}
