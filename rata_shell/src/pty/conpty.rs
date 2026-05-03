//! ConPTY-based pseudo-console host.

use super::job::JobHandle;
use crate::error::RataError;
use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::ptr::null_mut;
use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::Console::{
    ClosePseudoConsole, CreatePseudoConsole, ResizePseudoConsole, COORD, HPCON,
};
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::Threading::{
    CreateProcessW, DeleteProcThreadAttributeList, GetExitCodeProcess,
    InitializeProcThreadAttributeList, TerminateProcess, UpdateProcThreadAttribute,
    CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, LPPROC_THREAD_ATTRIBUTE_LIST,
    PROCESS_INFORMATION, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, STARTUPINFOEXW, STARTUPINFOW,
};

const STILL_ACTIVE: u32 = 259;

pub struct PipeHandle(pub HANDLE);

impl PipeHandle {
    pub fn raw(&self) -> HANDLE {
        self.0
    }
}

impl Drop for PipeHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

unsafe impl Send for PipeHandle {}
unsafe impl Sync for PipeHandle {}

pub struct PtyHost {
    pub hpcon: HPCON,
    pub input_write: PipeHandle,
    pub output_read: PipeHandle,
    pub process: PROCESS_INFORMATION,
    pub _job: JobHandle,
    attr_buf: Vec<u8>,
}

unsafe impl Send for PtyHost {}
unsafe impl Sync for PtyHost {}

impl PtyHost {
    pub fn spawn(
        cmdline: &str,
        cwd: Option<&str>,
        env_block: Option<&[u16]>,
        cols: u16,
        rows: u16,
    ) -> Result<Self, RataError> {
        unsafe {
            let mut input_read = HANDLE::default();
            let mut input_write = HANDLE::default();
            CreatePipe(&mut input_read, &mut input_write, None, 0)?;
            let mut output_read = HANDLE::default();
            let mut output_write = HANDLE::default();
            CreatePipe(&mut output_read, &mut output_write, None, 0)?;

            let size = COORD {
                X: cols.max(1) as i16,
                Y: rows.max(1) as i16,
            };
            let hpcon: HPCON =
                CreatePseudoConsole(size, input_read, output_write, 0)
                    .map_err(RataError::from)?;

            // The pty owns these ends; close our copies.
            let _ = CloseHandle(input_read);
            let _ = CloseHandle(output_write);

            let mut size_needed: usize = 0;
            let _ = InitializeProcThreadAttributeList(
                None,
                1,
                Some(0),
                &mut size_needed,
            );
            let mut attr_buf = vec![0u8; size_needed];
            let attr_list =
                LPPROC_THREAD_ATTRIBUTE_LIST(attr_buf.as_mut_ptr() as *mut c_void);
            InitializeProcThreadAttributeList(
                Some(attr_list),
                1,
                Some(0),
                &mut size_needed,
            )?;
            UpdateProcThreadAttribute(
                attr_list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                Some(hpcon.0 as *const _),
                size_of::<HPCON>(),
                None,
                None,
            )?;

            let mut si: STARTUPINFOEXW = zeroed();
            si.StartupInfo = STARTUPINFOW {
                cb: size_of::<STARTUPINFOEXW>() as u32,
                ..zeroed()
            };
            si.lpAttributeList = attr_list;

            let mut wide_cmd: Vec<u16> =
                cmdline.encode_utf16().chain(std::iter::once(0)).collect();
            let wide_cwd: Option<Vec<u16>> = cwd
                .filter(|s| !s.is_empty())
                .map(|s| s.encode_utf16().chain(std::iter::once(0)).collect());

            let mut pi = PROCESS_INFORMATION::default();

            let cwd_ptr = wide_cwd
                .as_deref()
                .map(|v| windows::core::PCWSTR(v.as_ptr()))
                .unwrap_or(windows::core::PCWSTR::null());

            let env_ptr: *const c_void = env_block
                .map(|b| b.as_ptr() as *const c_void)
                .unwrap_or(null_mut());

            let creation_flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;

            let job = JobHandle::create()?;

            let res = CreateProcessW(
                windows::core::PCWSTR::null(),
                Some(PWSTR(wide_cmd.as_mut_ptr())),
                None,
                None,
                false,
                creation_flags,
                if env_ptr.is_null() { None } else { Some(env_ptr) },
                cwd_ptr,
                &si.StartupInfo,
                &mut pi,
            );
            if let Err(e) = res {
                DeleteProcThreadAttributeList(attr_list);
                let _ = ClosePseudoConsole(hpcon);
                let _ = CloseHandle(input_write);
                let _ = CloseHandle(output_read);
                return Err(RataError::from(e));
            }

            job.assign(&pi)?;

            Ok(PtyHost {
                hpcon,
                input_write: PipeHandle(input_write),
                output_read: PipeHandle(output_read),
                process: pi,
                _job: job,
                attr_buf,
            })
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), RataError> {
        let size = COORD {
            X: cols.max(1) as i16,
            Y: rows.max(1) as i16,
        };
        unsafe { ResizePseudoConsole(self.hpcon, size).map_err(RataError::from) }
    }

    pub fn try_exit_code(&self) -> Option<i32> {
        unsafe {
            let mut code: u32 = 0;
            if GetExitCodeProcess(self.process.hProcess, &mut code).is_ok() {
                if code == STILL_ACTIVE {
                    None
                } else {
                    Some(code as i32)
                }
            } else {
                None
            }
        }
    }

    pub fn terminate(&self, code: u32) {
        unsafe {
            let _ = TerminateProcess(self.process.hProcess, code);
        }
    }
}

impl Drop for PtyHost {
    fn drop(&mut self) {
        unsafe {
            let _ = ClosePseudoConsole(self.hpcon);
            if !self.process.hProcess.is_invalid() {
                let _ = CloseHandle(self.process.hProcess);
            }
            if !self.process.hThread.is_invalid() {
                let _ = CloseHandle(self.process.hThread);
            }
            if !self.attr_buf.is_empty() {
                let attr_list =
                    LPPROC_THREAD_ATTRIBUTE_LIST(self.attr_buf.as_mut_ptr() as *mut c_void);
                DeleteProcThreadAttributeList(attr_list);
            }
        }
    }
}
