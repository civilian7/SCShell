//! ConPTY-based pseudo-console host.

use super::job::JobHandle;
use crate::error::RataError;
use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::ptr::null_mut;
use windows::core::PWSTR;
use windows::Win32::Foundation::{
    CloseHandle, DuplicateHandle, DUPLICATE_SAME_ACCESS, HANDLE,
};
use windows::Win32::System::Console::{
    ClosePseudoConsole, CreatePseudoConsole, ResizePseudoConsole, COORD, HPCON,
};
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::Threading::{
    CreateProcessW, DeleteProcThreadAttributeList, GetCurrentProcess, GetExitCodeProcess,
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

    /// 같은 파이프 끝을 가리키는 '자기 소유' 핸들 사본을 만든다.
    ///
    /// ★I/O 스레드가 PtyHost 소유의 raw HANDLE 을 그냥 복사해 쓰면, PtyHost 가 먼저 drop 될 때
    ///   (PipeHandle::drop → CloseHandle) 스레드는 닫힌 핸들에 ReadFile/WriteFile 을 건다. Win32
    ///   핸들 값은 즉시 재활용되므로 최악의 경우 남의 핸들에 I/O 를 거는 셈이 된다.
    ///   그렇다고 스레드가 Arc<PtyHost> 를 붙들면 정반대의 교착이 난다 — ClosePseudoConsole 이
    ///   리더 종료를 기다리고, 리더의 ReadFile 은 그 close 로만 EOF 를 받기 때문이다.
    ///   해법은 복제다: 스레드는 자기 사본을 소유하고, hpcon 은 제때 닫힌다(파이프 읽기 끝의
    ///   사본이 남아 있어도 쓰기 끝이 닫히면 EOF 는 정상적으로 온다).
    pub fn duplicate(&self) -> Result<PipeHandle, RataError> {
        unsafe {
            let mut dup = HANDLE::default();
            DuplicateHandle(
                GetCurrentProcess(),
                self.0,
                GetCurrentProcess(),
                &mut dup,
                0,
                false,
                DUPLICATE_SAME_ACCESS,
            )?;
            Ok(PipeHandle(dup))
        }
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

            // ★'?' 로 그냥 빠져나가면 이미 만든 hpcon/파이프가 샌다(CreatePseudoConsole 은
            //   위에서 성공했다). 실패 경로마다 되돌린다.
            if let Err(e) = InitializeProcThreadAttributeList(
                Some(attr_list),
                1,
                Some(0),
                &mut size_needed,
            ) {
                let _ = ClosePseudoConsole(hpcon);
                let _ = CloseHandle(input_write);
                let _ = CloseHandle(output_read);
                return Err(RataError::from(e));
            }

            if let Err(e) = UpdateProcThreadAttribute(
                attr_list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                Some(hpcon.0 as *const _),
                size_of::<HPCON>(),
                None,
                None,
            ) {
                DeleteProcThreadAttributeList(attr_list);
                let _ = ClosePseudoConsole(hpcon);
                let _ = CloseHandle(input_write);
                let _ = CloseHandle(output_read);
                return Err(RataError::from(e));
            }

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

            // ★job.assign 실패 시 '?' 로 빠져나가면 안 된다 — CreateProcessW 는 이미 성공했다.
            //   조기 반환하면 hpcon/파이프/프로세스 핸들이 새고, 무엇보다 자식 셸이 job 에 붙지
            //   않은 채 고아로 살아남는다(KILL_ON_JOB_CLOSE 도 안 걸린다).
            //   AssignProcessToJobObject 는 호스트가 nested job 을 허용하지 않는 job 안에서 돌 때
            //   (일부 CI/샌드박스/디버거 환경) 실제로 실패한다.
            if let Err(e) = job.assign(&pi) {
                let _ = TerminateProcess(pi.hProcess, 1);
                let _ = CloseHandle(pi.hThread);
                let _ = CloseHandle(pi.hProcess);
                DeleteProcThreadAttributeList(attr_list);
                let _ = ClosePseudoConsole(hpcon);
                let _ = CloseHandle(input_write);
                let _ = CloseHandle(output_read);
                return Err(e);
            }

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

    /// Win32 PID of the spawned child (0 if not running).
    pub fn child_pid(&self) -> u32 {
        self.process.dwProcessId
    }

    /// 자식이 끝났으면 종료 코드를, 아직 살아 있으면 None.
    ///
    /// ★생존 판정을 GetExitCodeProcess 의 STILL_ACTIVE(259) 로 하면 안 된다. 259 는 정당한
    ///   종료 코드이기도 해서, 셸이 실제로 259 로 끝나면 영원히 "아직 살아 있다"로 읽힌다 —
    ///   감시 스레드가 무한 폴링하고 on_exit 이 영영 발화하지 않는다.
    ///   프로세스 핸들이 시그널되었는지(WaitForSingleObject timeout=0)로 먼저 판정한다.
    pub fn try_exit_code(&self) -> Option<i32> {
        use windows::Win32::Foundation::WAIT_OBJECT_0;
        use windows::Win32::System::Threading::WaitForSingleObject;

        unsafe {
            if WaitForSingleObject(self.process.hProcess, 0) != WAIT_OBJECT_0 {
                return None; // 아직 실행 중(또는 대기 실패) — 종료하지 않았다.
            }

            let mut code: u32 = 0;
            if GetExitCodeProcess(self.process.hProcess, &mut code).is_ok() {
                Some(code as i32)
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
