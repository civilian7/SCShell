//! Reader/writer threads for the ConPTY pipes.

use crate::pty::PtyHost;
use crossbeam_channel::{Receiver, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::Storage::FileSystem::{ReadFile, WriteFile};

pub enum IoEvent {
    Bytes(Vec<u8>),
    Eof,
}

pub struct ReaderThread {
    pub rx: Receiver<IoEvent>,
    pub tx: Sender<IoEvent>,
    pub join: Option<JoinHandle<()>>,
}

pub struct WriterThread {
    pub tx: Sender<Vec<u8>>,
    pub join: Option<JoinHandle<()>>,
}

struct SendableHandle(HANDLE);
unsafe impl Send for SendableHandle {}

impl ReaderThread {
    pub fn spawn(pty: &Arc<PtyHost>) -> Self {
        let (tx, rx) = crossbeam_channel::bounded::<IoEvent>(64);
        let tx_for_thread = tx.clone();
        let h = SendableHandle(pty.output_read.raw());
        let join = std::thread::Builder::new()
            .name("rata-reader".into())
            .spawn(move || {
                let h = h;
                let mut buf = vec![0u8; 8192];
                loop {
                    let mut read: u32 = 0;
                    let ok = unsafe {
                        ReadFile(h.0, Some(&mut buf[..]), Some(&mut read), None)
                    };
                    if ok.is_err() || read == 0 {
                        let _ = tx_for_thread.send(IoEvent::Eof);
                        break;
                    }
                    if tx_for_thread
                        .send(IoEvent::Bytes(buf[..read as usize].to_vec()))
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .expect("spawn reader");
        ReaderThread { rx, tx, join: Some(join) }
    }
}

impl WriterThread {
    pub fn spawn(pty: &Arc<PtyHost>) -> Self {
        let (tx, rx) = crossbeam_channel::unbounded::<Vec<u8>>();
        let h = SendableHandle(pty.input_write.raw());
        let join = std::thread::Builder::new()
            .name("rata-writer".into())
            .spawn(move || {
                let h = h;
                while let Ok(buf) = rx.recv() {
                    if buf.is_empty() {
                        break;
                    }
                    let mut written: u32 = 0;
                    let _ = unsafe {
                        WriteFile(h.0, Some(&buf[..]), Some(&mut written), None)
                    };
                }
            })
            .expect("spawn writer");
        WriterThread { tx, join: Some(join) }
    }
}

impl Drop for ReaderThread {
    fn drop(&mut self) {
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

impl Drop for WriterThread {
    fn drop(&mut self) {
        let _ = self.tx.send(Vec::new()); // sentinel
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}
