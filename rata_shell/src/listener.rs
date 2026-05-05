//! Custom EventListener — alacritty Term events 를 Session 콜백으로 전달.
//! VoidListener 대신 사용해 Title/Bell/ClipboardStore 등을 호스트가 받게 함.

use alacritty_terminal::event::{Event, EventListener};
use parking_lot::Mutex;
use std::sync::Arc;

/// Sink Session 이 가지는 콜백 핸들. 게으른 fire — Term 이 lock 되어 있는 동안
/// 콜백을 직접 호출하면 재진입 위험이 있어 큐에 넣어 호출자가 drain.
pub struct EventSink {
    pub queue: Mutex<Vec<Event>>,
}

impl EventSink {
    pub fn new() -> Self {
        Self { queue: Mutex::new(Vec::new()) }
    }

    pub fn drain(&self) -> Vec<Event> {
        let mut q = self.queue.lock();
        std::mem::take(&mut *q)
    }
}

#[derive(Clone)]
pub struct HostListener {
    pub sink: Arc<EventSink>,
}

impl HostListener {
    pub fn new(sink: Arc<EventSink>) -> Self {
        Self { sink }
    }
}

impl EventListener for HostListener {
    fn send_event(&self, event: Event) {
        // Term::send_event 는 &self 기반이라 lock 안에서 호출됨 → 즉시 콜백
        // 호출 시 재진입 위험. 큐에 적재하고 호출자(advance/snapshot)가 drain.
        self.sink.queue.lock().push(event);
    }
}
