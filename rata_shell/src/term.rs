//! Wraps alacritty's `Term` so the rest of the crate sees a single, simple
//! object that processes bytes and exposes a viewport snapshot.

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Column;
use alacritty_terminal::term::{cell::Cell as ATCell, cell::Flags as ATFlags, Config, TermMode};
use alacritty_terminal::vte::ansi::{Color as ATColor, NamedColor, Processor};
use alacritty_terminal::Term;
use crate::listener::{EventSink, HostListener};
use std::collections::HashMap;
use std::sync::Arc;

/// 안정적 32-bit hash for hyperlink URIs (FNV-1a). 같은 URI 는 같은 id.
fn hash_uri(uri: &str) -> u32 {
    let mut h: u32 = 0x811C9DC5;
    for &b in uri.as_bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    // 0 은 sentinel (no link) 로 예약.
    if h == 0 { 1 } else { h }
}

/// 단순 RFC 3986 percent-decode (UTF-8 string 가정). 잘못된 시퀀스는 그대로 보존.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push(((h << 4) | l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

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
    term: Term<HostListener>,
    parser: Processor,
    size: Size,
    pub sink: Arc<EventSink>,
    /// 마지막으로 captured 한 윈도우 타이틀 (Event::Title 누적).
    pub current_title: String,
    /// 마지막으로 알려진 작업 디렉터리 (OSC 7 from shell).
    pub current_cwd: String,
    /// OSC 7 byte-stream 스캐너 상태.
    osc7_state: u8,
    osc7_buf: Vec<u8>,
    /// OSC 8 hyperlinks — id → URI. snapshot 시 cell 의 hyperlink 를 hash → 등록.
    pub hyperlinks: HashMap<u32, String>,

    /// 검색 커서 — 마지막 매치. 다음 search_next 는 여기서 '한 칸 앞'부터 찾는다.
    /// 이게 없으면 매번 grid 커서에서 다시 찾아 같은 매치만 무한 반복된다(F3 이 안 먹는다).
    search_pattern: String,
    search_origin: Option<alacritty_terminal::index::Point>,
}

impl TermHost {
    pub fn new(cols: u16, rows: u16, scrollback: usize) -> Self {
        let size = Size::new(cols as usize, rows as usize);
        let mut config = Config::default();
        config.scrolling_history = scrollback;
        let sink = Arc::new(EventSink::new());
        let listener = HostListener::new(sink.clone());
        let term = Term::new(config, &size, listener);
        Self {
            term,
            parser: Processor::new(),
            size,
            sink,
            current_title: String::new(),
            current_cwd: String::new(),
            osc7_state: 0,
            osc7_buf: Vec::new(),
            hyperlinks: HashMap::new(),
            search_pattern: String::new(),
            search_origin: None,
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
        // OSC 7 byte-stream 스캐너 (alacritty 가 OSC 7 를 처리하지 않으므로 호스트 측 capture).
        // 패턴: ESC ] 7 ; <url> (BEL | ST=ESC\)
        for &b in bytes {
            self.scan_osc7(b);
        }
        self.parser.advance(&mut self.term, bytes);
    }

    fn scan_osc7(&mut self, b: u8) {
        match self.osc7_state {
            0 => if b == 0x1b { self.osc7_state = 1; },
            1 => self.osc7_state = if b == b']' { 2 } else if b == 0x1b { 1 } else { 0 },
            2 => self.osc7_state = if b == b'7' { 3 } else { 0 },
            3 => {
                if b == b';' { self.osc7_state = 4; self.osc7_buf.clear(); }
                else { self.osc7_state = 0; }
            }
            4 => {
                // 종료: BEL 또는 ST(ESC\)
                if b == 0x07 || b == 0x1b {
                    let url_owned = String::from_utf8_lossy(&self.osc7_buf).into_owned();
                    self.osc7_buf.clear();
                    self.osc7_state = if b == 0x1b { 1 } else { 0 };
                    self.handle_osc7_url(&url_owned);
                } else {
                    self.osc7_buf.push(b);
                    if self.osc7_buf.len() > 4096 {
                        self.osc7_buf.clear();
                        self.osc7_state = 0;
                    }
                }
            }
            _ => self.osc7_state = 0,
        }
    }

    fn handle_osc7_url(&mut self, url: &str) {
        // 형식: file://hostname/absolute_path  또는  file:///path
        let path = if let Some(rest) = url.strip_prefix("file://") {
            // 첫 슬래시까지가 hostname (Windows 경로의 경우 / 하나만 있을 수도)
            match rest.find('/') {
                Some(idx) => &rest[idx..],
                None => rest,
            }
        } else { url };
        // 단순 percent-decode (%XX 시퀀스)
        let decoded = percent_decode(path);
        // Windows 경로 정규화: /C:/foo → C:/foo
        let normalized = if decoded.len() >= 3
            && decoded.starts_with('/')
            && decoded.as_bytes()[2] == b':'
        {
            decoded[1..].to_string()
        } else {
            decoded
        };
        self.current_cwd = normalized;
    }

    pub fn alt_active(&self) -> bool {
        self.term.mode().contains(TermMode::ALT_SCREEN)
    }

    /// Scroll display by `lines` (positive=up into history, negative=down toward live).
    pub fn scroll_display(&mut self, lines: i32) {
        self.term.scroll_display(alacritty_terminal::grid::Scroll::Delta(lines));
    }

    /// Jump to top of scrollback (oldest content).
    pub fn scroll_to_top(&mut self) {
        self.term.scroll_display(alacritty_terminal::grid::Scroll::Top);
    }

    /// Jump to bottom (live edge — display_offset becomes 0).
    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_display(alacritty_terminal::grid::Scroll::Bottom);
    }

    /// Current scroll offset from bottom (0 = at live edge, positive = scrolled up).
    pub fn display_offset(&self) -> usize {
        self.term.grid().display_offset()
    }

    /// Lines actually held in the scrollback right now — i.e. how far up we can scroll.
    ///
    /// This is NOT the configured scrollback limit. The host draws its scrollbar thumb from
    /// this, so reporting the limit (e.g. 10000) while only 100 lines exist makes the thumb
    /// tiny and its position meaningless.
    pub fn history_size(&self) -> usize {
        use alacritty_terminal::grid::Dimensions;
        self.term.grid().history_size()
    }

    /// Clear scrollback (history) but keep current viewport.
    pub fn clear_history(&mut self) {
        use alacritty_terminal::vte::ansi::ClearMode;
        use alacritty_terminal::vte::ansi::Handler;
        Handler::clear_screen(&mut self.term, ClearMode::Saved);
    }

    /// Soft reset terminal to initial state (RIS / ESC c).
    pub fn reset_state(&mut self) {
        // Term::clear_history + reinitialize via parser RIS escape.
        self.parser.advance(&mut self.term, b"\x1bc");
    }

    /// VI navigation mode 토글.
    pub fn toggle_vi_mode(&mut self) {
        self.term.toggle_vi_mode();
    }

    pub fn vi_mode_active(&self) -> bool {
        self.term.mode().contains(TermMode::VI)
    }

    /// VI motion 실행. AKind: 0=Up 1=Down 2=Left 3=Right 4=First 5=Last
    /// 6=FirstOccupied 7=High 8=Middle 9=Low
    /// 10=WordLeft 11=WordRight 12=WordLeftEnd 13=WordRightEnd
    /// 14=SemanticLeft 15=SemanticRight 16=SemanticLeftEnd 17=SemanticRightEnd
    /// 18=Bracket 19=ParagraphUp 20=ParagraphDown
    pub fn vi_motion(&mut self, kind: u8) {
        use alacritty_terminal::vi_mode::ViMotion as M;
        let m = match kind {
            0 => M::Up,
            1 => M::Down,
            2 => M::Left,
            3 => M::Right,
            4 => M::First,
            5 => M::Last,
            6 => M::FirstOccupied,
            7 => M::High,
            8 => M::Middle,
            9 => M::Low,
            10 => M::WordLeft,
            11 => M::WordRight,
            12 => M::WordLeftEnd,
            13 => M::WordRightEnd,
            14 => M::SemanticLeft,
            15 => M::SemanticRight,
            16 => M::SemanticLeftEnd,
            17 => M::SemanticRightEnd,
            18 => M::Bracket,
            19 => M::ParagraphUp,
            20 => M::ParagraphDown,
            _ => return,
        };
        self.term.vi_motion(m);
    }

    /// Regex 검색. 매치 시작 좌표 (viewport 0-based) + 길이 반환.
    /// 매치 없으면 (0, 0, 0).
    ///
    /// ★반복 호출하면 '다음' 매치로 넘어간다. 검색 커서(search_origin)를 유지하지 않으면
    ///   매번 grid 커서에서 다시 찾게 되어 언제나 같은 매치만 나온다(F3/Shift+F3 이 무의미해진다).
    ///   패턴이 바뀌면 커서를 리셋한다.
    ///
    /// ★매치가 화면 밖(히스토리)이면 좌표를 clamp 하지 않는다 — clamp 는 엉뚱한 행을 가리키는
    ///   거짓 좌표를 만든다. 대신 그 매치가 보이도록 뷰포트를 스크롤한 뒤 좌표를 계산한다.
    pub fn search_next(&mut self, pattern: &str, forward: bool) -> (u16, u16, u16) {
        use alacritty_terminal::grid::Scroll;
        use alacritty_terminal::index::{Boundary, Column, Direction, Line, Point};
        use alacritty_terminal::term::search::RegexSearch;

        if pattern.is_empty() {
            return (0, 0, 0);
        }

        let mut regex = match RegexSearch::new(pattern) {
            Ok(r) => r,
            Err(_) => return (0, 0, 0),
        };

        // 패턴이 바뀌면 처음부터 — 이전 패턴의 매치 위치에서 이어가면 안 된다.
        if self.search_pattern != pattern {
            self.search_pattern = pattern.to_string();
            self.search_origin = None;
        }

        let dir = if forward { Direction::Right } else { Direction::Left };

        // 시작점: 직전 매치가 있으면 그 한 칸 옆, 없으면 현재 커서.
        // 한 칸 옮기지 않으면 같은 매치를 다시 집어 제자리걸음한다.
        let origin = match self.search_origin {
            Some(p) => match dir {
                Direction::Right => p.add(self.term.grid(), Boundary::Grid, 1),
                Direction::Left => p.sub(self.term.grid(), Boundary::Grid, 1),
            },
            None => self.term.grid().cursor.point,
        };

        // 검색 경계 — 스크롤백 전체를 훑는다(뷰포트만 보면 히스토리의 매치를 놓친다).
        let history = self.term.grid().history_size() as i32;
        let result = match dir {
            Direction::Right => self.term.regex_search_right(
                &mut regex,
                origin,
                Point::new(Line(self.size.lines as i32 - 1), Column(self.size.cols - 1)),
            ),
            Direction::Left => self.term.regex_search_left(
                &mut regex,
                origin,
                Point::new(Line(-history), Column(0)),
            ),
        };

        let range = match result {
            Some(r) => r,
            None => {
                // 끝까지 못 찾았다 — 다음 호출은 처음부터 다시 돌도록 커서를 푼다(wrap-around).
                self.search_origin = None;
                return (0, 0, 0);
            }
        };

        let start = *range.start();
        let end = *range.end();
        self.search_origin = Some(start);

        // 매치가 뷰포트 밖이면 보이도록 스크롤한다.
        // grid Line 은 0..lines-1 이 화면, 음수가 히스토리다. display_offset(off) 이면
        // 화면에 보이는 grid Line 은 -off .. lines-1-off 구간이다.
        let mut off = self.term.grid().display_offset() as i32;
        if start.line.0 < -off {
            // 매치가 화면 위(더 오래된 히스토리) — 위로 스크롤.
            self.term.scroll_display(Scroll::Delta(-off - start.line.0));
            off = self.term.grid().display_offset() as i32;
        } else if start.line.0 > self.size.lines as i32 - 1 - off {
            // 매치가 화면 아래 — 아래로 스크롤.
            self.term
                .scroll_display(Scroll::Delta(self.size.lines as i32 - 1 - off - start.line.0));
            off = self.term.grid().display_offset() as i32;
        }

        let row = start.line.0 + off;
        if row < 0 || row >= self.size.lines as i32 {
            return (0, 0, 0); // 스크롤로도 못 담았다 — 거짓 좌표를 주느니 '없음'을 준다.
        }

        // 길이 — 매치가 여러 줄에 걸치면 시작 줄의 끝까지로 자른다(호출자는 한 줄 하이라이트).
        let len = if end.line == start.line {
            (end.column.0 + 1).saturating_sub(start.column.0)
        } else {
            self.size.cols.saturating_sub(start.column.0)
        };

        (start.column.0 as u16, row as u16, len as u16)
    }

    /// 선택 영역 시작. (col, row) 는 viewport 0-based 셀 좌표.
    /// AKind: 0=Simple(드래그), 1=Block(블록), 2=Semantic(단어), 3=Lines(라인).
    pub fn selection_start(&mut self, col: u16, row: u16, kind: u8) {
        use alacritty_terminal::index::{Column, Line, Point, Side};
        use alacritty_terminal::selection::{Selection, SelectionType};
        let st = match kind {
            1 => SelectionType::Block,
            2 => SelectionType::Semantic,
            3 => SelectionType::Lines,
            _ => SelectionType::Simple,
        };
        // viewport (col, row) → grid Point. row 는 viewport 기준 — display_offset 보정.
        let off = self.term.grid().display_offset() as i32;
        let line = Line(row as i32 - off);
        let pt = Point { line, column: Column(col as usize) };
        self.term.selection = Some(Selection::new(st, pt, Side::Left));
    }

    pub fn selection_extend(&mut self, col: u16, row: u16) {
        use alacritty_terminal::index::{Column, Line, Point, Side};
        let off = self.term.grid().display_offset() as i32;
        if let Some(sel) = self.term.selection.as_mut() {
            let line = Line(row as i32 - off);
            let pt = Point { line, column: Column(col as usize) };
            sel.update(pt, Side::Right);
        }
    }

    pub fn selection_clear(&mut self) {
        self.term.selection = None;
    }

    pub fn selection_to_string(&self) -> Option<String> {
        self.term.selection_to_string()
    }

    /// Bit-flags for current TermMode (subset of interest).
    /// bit 0 = ALT_SCREEN, 1 = APP_CURSOR, 2 = APP_KEYPAD,
    /// 3 = BRACKETED_PASTE, 4 = MOUSE_REPORT_CLICK, 5 = MOUSE_DRAG,
    /// 6 = MOUSE_MOTION, 7 = SGR_MOUSE, 8 = UTF8_MOUSE.
    pub fn mode_flags(&self) -> u32 {
        let m = self.term.mode();
        let mut f: u32 = 0;
        if m.contains(TermMode::ALT_SCREEN)        { f |= 1 << 0; }
        if m.contains(TermMode::APP_CURSOR)        { f |= 1 << 1; }
        if m.contains(TermMode::APP_KEYPAD)        { f |= 1 << 2; }
        if m.contains(TermMode::BRACKETED_PASTE)   { f |= 1 << 3; }
        if m.contains(TermMode::MOUSE_REPORT_CLICK){ f |= 1 << 4; }
        if m.contains(TermMode::MOUSE_DRAG)        { f |= 1 << 5; }
        if m.contains(TermMode::MOUSE_MOTION)      { f |= 1 << 6; }
        if m.contains(TermMode::SGR_MOUSE)         { f |= 1 << 7; }
        if m.contains(TermMode::UTF8_MOUSE)        { f |= 1 << 8; }
        f
    }

    /// 마지막으로 알려진 윈도우 타이틀 (HostListener 가 Event::Title 수신 시 갱신).
    pub fn title(&self) -> String {
        self.current_title.clone()
    }

    /// Event 큐에서 제목 변경/벨 등 alacritty 이벤트를 가져와 caller 에게 전달.
    /// 현재는 title 만 내부 업데이트, 나머지는 그대로 반환.
    pub fn drain_events(&mut self) -> Vec<alacritty_terminal::event::Event> {
        let evs = self.sink.drain();
        for ev in &evs {
            match ev {
                alacritty_terminal::event::Event::Title(t) => {
                    self.current_title = t.clone();
                }
                alacritty_terminal::event::Event::ResetTitle => {
                    self.current_title.clear();
                }
                _ => {}
            }
        }
        evs
    }

    /// Build a flat, host-friendly cell view of the current viewport.
    /// `&mut` 필요 — hyperlinks HashMap 등록 (cell 의 OSC 8 URI → id 매핑).
    pub fn snapshot(&mut self, cells: &mut Vec<HostCell>) -> SnapshotMeta {
        use alacritty_terminal::vte::ansi::CursorShape;
        cells.clear();
        let cols = self.size.cols;
        let rows = self.size.lines;
        cells.reserve(cols * rows);
        // alacritty grid + hyperlinks 동시 borrow 회피 — 일단 셀 정보를 모두 수집한 후
        // hyperlink id 등록은 별도 패스.
        let mut hl_uris: Vec<Option<String>> = Vec::with_capacity(cols * rows);
        {
            let grid = self.term.grid();
            // ★viewport row → grid Line 은 display_offset 보정이 필요하다.
            //   이 보정이 없으면 스크롤(scroll_display)로 display_offset 이 바뀌어도 snapshot 이
            //   늘 활성 영역(라이브 화면)만 읽어, 호스트에는 스크롤해도 같은 화면이 전달된다.
            //   (selection_start/extend 등 다른 좌표 변환은 이미 같은 보정을 한다.)
            let off = grid.display_offset() as i32;
            for line_idx in 0..rows as i32 {
                let line = alacritty_terminal::index::Line(line_idx - off);
                for col in 0..cols {
                    let cell = &grid[line][Column(col)];
                    cells.push(convert_cell(cell));
                    hl_uris.push(cell.hyperlink().map(|h| h.uri().to_string()));
                }
            }
        }
        // 각 셀의 hyperlink_id 등록 + 매핑.
        for (i, opt_uri) in hl_uris.iter().enumerate() {
            if let Some(uri) = opt_uri {
                let id = hash_uri(uri);
                self.hyperlinks.entry(id).or_insert_with(|| uri.clone());
                cells[i].hyperlink_id = id;
            }
        }
        let grid = self.term.grid();
        let cursor_pos = grid.cursor.point;
        let cursor_x = (cursor_pos.column.0 as i32).clamp(0, cols as i32 - 1) as u16;
        // ★grid Line → viewport row 도 display_offset 보정이 필요하다(셀과 같은 좌표계).
        //   보정이 없으면 스크롤해도 커서가 원래 자리에 그대로 남는다.
        let cursor_off = grid.display_offset() as i32;
        let cursor_line_vp = cursor_pos.line.0 + cursor_off;
        // 스크롤로 커서가 화면 밖으로 나가면 숨긴다 — clamp 만 하면 가장자리에 눌러붙는다.
        let cursor_in_view = cursor_line_vp >= 0 && cursor_line_vp < rows as i32;
        let cursor_y = cursor_line_vp.clamp(0, rows as i32 - 1) as u16;
        // VT 표준 매핑: 0=block default, 2=steady block, 3=blink underline,
        // 4=steady underline, 5=blink bar, 6=steady bar.
        let style = self.term.cursor_style();
        let cursor_style: u8 = match (style.shape, style.blinking) {
            (CursorShape::Underline, true) => 3,
            (CursorShape::Underline, false) => 4,
            (CursorShape::Beam, true) => 5,
            (CursorShape::Beam, false) => 6,
            (CursorShape::Hidden, _) => 0, // visibility 가 false 처리됨
            _ => if style.blinking { 1 } else { 2 }, // Block / HollowBlock
        };
        SnapshotMeta {
            cols: cols as u16,
            rows: rows as u16,
            cursor_x,
            cursor_y,
            cursor_visible: self.term.mode().contains(TermMode::SHOW_CURSOR)
                && style.shape != CursorShape::Hidden
                && cursor_in_view,
            alt_active: self.alt_active(),
            app_cursor_keys: self.term.mode().contains(TermMode::APP_CURSOR),
            cursor_style,
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
    /// OSC 8 hyperlink id (0 = no link). 호스트가 get_hyperlink(id) 로 URI 조회.
    pub hyperlink_id: u32,
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
    /// VT cursor style 0/1=block(blink/steady), 3/4=underline, 5/6=bar.
    pub cursor_style: u8,
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
        hyperlink_id: 0,
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
