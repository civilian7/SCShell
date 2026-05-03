//! Job Object that kills the child process tree when the host process exits
//! or when the session is dropped.

use crate::error::RataError;
use std::mem::{size_of, zeroed};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, SetInformationJobObject,
    JobObjectExtendedLimitInformation, JOBOBJECT_BASIC_LIMIT_INFORMATION,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows::Win32::System::Threading::PROCESS_INFORMATION;

pub struct JobHandle(pub HANDLE);

impl JobHandle {
    pub fn create() -> Result<Self, RataError> {
        unsafe {
            let h = CreateJobObjectW(None, None)?;
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = zeroed();
            info.BasicLimitInformation = JOBOBJECT_BASIC_LIMIT_INFORMATION {
                LimitFlags: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
                ..zeroed()
            };
            SetInformationJobObject(
                h,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )?;
            Ok(JobHandle(h))
        }
    }

    pub fn assign(&self, pi: &PROCESS_INFORMATION) -> Result<(), RataError> {
        unsafe {
            AssignProcessToJobObject(self.0, pi.hProcess)?;
        }
        Ok(())
    }
}

impl Drop for JobHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = windows::Win32::Foundation::CloseHandle(self.0);
            }
        }
    }
}
