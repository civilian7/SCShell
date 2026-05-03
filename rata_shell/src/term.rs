//! Wraps alacritty's `Term` so the rest of the crate sees a single, simple
//! object that processes bytes and exposes a viewport snapshot.

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Column;
use alacritty_terminal::term::{cell::Cell as ATCell, cell::Flags as ATFlags, Config, TermMode};
use alacritty_terminal::vte::ansi::{Color as ATColor, NamedColor, Processor};
use alacritty_terminal::Term;

#[derive(Debug, Clone, Copy)]
pub struct Size {
    pub cols: usize,
    pub lines: usize,
}

impl Size {
    pub fn new(cols: usize, lines: usize) -> Self {
        Self {
            cols: cols.max(2),
            lines: lines.max(1),
        }
    }
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.lines
    }
    fn screen_lines(&self) -> usize {
        self.lines
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

pub struct TermHost {
    term: Term<VoidListener>,
    parser: Processor,
    size: Size,
}

impl TermHost {
    pub fn new(cols: u16, rows: u16, scrollback: usize) -> Self {
        let size = Size::new(cols as usize, rows as usize);
        let mut config = Config::default();
        config.scrolling_history = scrollback;
        let term = Term::new(config, &size, VoidListener);
        Self {
            term,
            parser: Processor::new(),
            size,
        }
    }

    pub fn cols(&self) -> u16 {
        self.size.cols as u16
    }

    pub fn rows(&self) -> u16 {
        self.size.lines as u16
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        let size = Size::new(cols as usize, rows as usize);
        self.size = size;
        self.term.resize(size);
    }

    pub fn advance(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    pub fn alt_active(&self) -> bool {
        self.term.mode().contains(TermMode::ALT_SCREEN)
    }

    pub fn title(&self) -> String {
        // Alacritty stores title internally; expose via Handler API would
        // require listening. For now, return empty — extension point.
        String::new()
    }

    /// Build a flat, host-friendly cell view of the current viewport.
    pub fn snapshot(&self, cells: &mut Vec<HostCell>) -> SnapshotMeta {
        cells.clear();
        let cols = self.size.cols;
        let rows = self.size.lines;
        cells.reserve(cols * rows);
        let grid = self.term.grid();
        for line_idx in 0..rows as i32 {
            let line = alacritty_terminal::index::Line(line_idx);
            for col in 0..cols {
                let cell = &grid[line][Column(col)];
                cells.push(convert_cell(cell));
            }
        }
        let cursor_pos = grid.cursor.point;
        let cursor_x = (cursor_pos.column.0 as i32).clamp(0, cols as i32 - 1) as u16;
        let cursor_line = cursor_pos.line.0;
        let cursor_y = cursor_line.clamp(0, rows as i32 - 1) as u16;
        SnapshotMeta {
            cols: cols as u16,
            rows: rows as u16,
            cursor_x,
            cursor_y,
            cursor_visible: self.term.mode().contains(TermMode::SHOW_CURSOR),
            alt_active: self.alt_active(),
            app_cursor_keys: self.term.mode().contains(TermMode::APP_CURSOR),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct HostCell {
    pub ch: u32,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub width: u8,
}

#[derive(Clone, Copy, Debug)]
pub struct SnapshotMeta {
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub alt_active: bool,
    pub app_cursor_keys: bool,
}

// --- Attribute / color conversion -------------------------------------

pub const ATTR_BOLD: u16 = 0x0001;
pub const ATTR_DIM: u16 = 0x0002;
pub const ATTR_ITALIC: u16 = 0x0004;
pub const ATTR_UNDERLINE: u16 = 0x0008;
pub const ATTR_BLINK: u16 = 0x0010;
pub const ATTR_REVERSE: u16 = 0x0020;
pub const ATTR_HIDDEN: u16 = 0x0040;
pub const ATTR_STRIKE: u16 = 0x0080;

pub const DEFAULT_FLAG: u32 = 0x80000000;

fn convert_cell(c: &ATCell) -> HostCell {
    let mut attrs: u16 = 0;
    let f = c.flags;
    if f.contains(ATFlags::BOLD) {
        attrs |= ATTR_BOLD;
    }
    if f.contains(ATFlags::DIM) {
        attrs |= ATTR_DIM;
    }
    if f.contains(ATFlags::ITALIC) {
        attrs |= ATTR_ITALIC;
    }
    if f.intersects(ATFlags::ALL_UNDERLINES) {
        attrs |= ATTR_UNDERLINE;
    }
    if f.contains(ATFlags::INVERSE) {
        attrs |= ATTR_REVERSE;
    }
    if f.contains(ATFlags::HIDDEN) {
        attrs |= ATTR_HIDDEN;
    }
    if f.contains(ATFlags::STRIKEOUT) {
        attrs |= ATTR_STRIKE;
    }

    let width = if f.contains(ATFlags::WIDE_CHAR) {
        2
    } else if f.contains(ATFlags::WIDE_CHAR_SPACER) {
        0
    } else {
        1
    };

    let ch = c.c as u32;

    HostCell {
        ch,
        fg: convert_color(c.fg, true),
        bg: convert_color(c.bg, false),
        attrs,
        width,
    }
}

fn convert_color(c: ATColor, is_fg: bool) -> u32 {
    match c {
        ATColor::Spec(rgb) => {
            ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
        }
        ATColor::Indexed(i) => xterm256(i),
        ATColor::Named(n) => named_color(n, is_fg),
    }
}

fn named_color(n: NamedColor, is_fg: bool) -> u32 {
    use NamedColor::*;
    match n {
        Foreground | BrightForeground | DimForeground => DEFAULT_FLAG | 0xCCCCCC,
        Background => DEFAULT_FLAG | 0x000000,
        Cursor => DEFAULT_FLAG | (if is_fg { 0xCCCCCC } else { 0x000000 }),
        Black | DimBlack => 0x000000,
        Red | DimRed => 0xCD0000,
        Green | DimGreen => 0x00CD00,
        Yellow | DimYellow => 0xCDCD00,
        Blue | DimBlue => 0x0000EE,
        Magenta | DimMagenta => 0xCD00CD,
        Cyan | DimCyan => 0x00CDCD,
        White | DimWhite => 0xE5E5E5,
        BrightBlack => 0x7F7F7F,
        BrightRed => 0xFF0000,
        BrightGreen => 0x00FF00,
        BrightYellow => 0xFFFF00,
        BrightBlue => 0x5C5CFF,
        BrightMagenta => 0xFF00FF,
        BrightCyan => 0x00FFFF,
        BrightWhite => 0xFFFFFF,
    }
}

fn xterm256(idx: u8) -> u32 {
    if idx < 16 {
        let table: [u32; 16] = [
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD,
            0xE5E5E5, 0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF,
            0x00FFFF, 0xFFFFFF,
        ];
        return table[idx as usize];
    }
    if idx < 232 {
        let i = (idx - 16) as u32;
        let r = (i / 36) % 6;
        let g = (i / 6) % 6;
        let b = i % 6;
        let c = |v: u32| if v == 0 { 0 } else { 55 + v * 40 };
        return (c(r) << 16) | (c(g) << 8) | c(b);
    }
    let v = 8 + (idx - 232) as u32 * 10;
    (v << 16) | (v << 8) | v
}
