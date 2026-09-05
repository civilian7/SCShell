# SCShell

> 델파이 애플리케이션에 임베드 가능한 Windows 터미널 컴포넌트

**Languages:** **한국어** | [English](README.en.md)

---

## 개요

**SCShell**은 델파이 애플리케이션에 통합 가능한 풀-기능 Windows 터미널 컴포넌트입니다. Rust로 작성된 DLL이 ConPTY를 통해 실제 셸(cmd, PowerShell, pwsh, WSL 등)을 호스팅하고, [alacritty_terminal](https://crates.io/crates/alacritty_terminal)을 사용해 검증된 VT100/xterm 처리를 수행합니다. 델파이 측에서는 `TWinControl` 자손인 `TSCRataShell` 컴포넌트로 폼에 드롭하여 사용할 수 있습니다.

## 특징

- **완전한 ConPTY 통합** — Windows 10 1903+ 의 `CreatePseudoConsole` API
- **alacritty 기반 VT 처리** — alt screen, 스크롤백, SGR(24-bit truecolor 포함), 커서 save/restore, insert/delete, scroll regions, bracketed paste 등
- **한글 IME 완전 지원** — 조합 창 위치 자동 정렬, 셀 단위 폰트 매칭, 자모 분리/조합 취소 정상 동작
- **TWinControl 표준 컴포넌트** — Align, Anchors, Font, TabOrder 등 VCL 표준 동작
- **자식 프로세스 자동 정리** — Job Object의 `KILL_ON_JOB_CLOSE`로 호스트 종료 시 셸 트리 누수 없음
- **Panic 격리** — `catch_unwind`로 FFI 경계에서 Rust panic이 호스트로 전파되지 않음
- **단일 DLL 배포** — 정적 CRT 링크로 의존 DLL 없음
- **32/64비트 모두 지원** — 이름은 `sc_shell.dll` 하나이고 폴더로 가른다(`bin/`, `bin/win32/`)

## 요구 사항

- **Rust** 1.80+ (DLL 빌드)
- **Delphi** 13 (Studio 37.0)
- **Windows** 10 1903+ (ConPTY 안정 버전)

## 디렉터리 구조

```
SHELL/
├── docs/design/             # 설계 문서
├── rata_shell/              # Rust DLL crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── ffi.rs           # C ABI export
│       ├── session.rs       # 세션 라이프사이클
│       ├── pty/             # ConPTY + Job Object
│       ├── io.rs            # Reader/Writer 스레드
│       ├── term.rs          # alacritty Term 래퍼
│       ├── render/          # 셀 그리드 스냅샷 + diff
│       ├── keymap.rs        # Win32 VK → VT 시퀀스
│       └── log.rs           # 직접 파일 로깅
├── delphi/
│   ├── src/
│   │   ├── SCShell.pas         # FFI 바인딩
│   │   ├── SCShell.Painter.pas # GDI 페인터
│   │   ├── SCShell.Ctrl.pas    # TSCRataShell 컴포넌트
│   │   └── SCShell.Reg.pas     # 디자인타임 등록
│   └── packages/
│       ├── SCShell_RT.dpk      # 런타임 패키지
│       └── SCShell_DT.dpk      # 디자인타임 패키지
├── demo/
│   ├── DemoShell.dpr           # 데모 EXE 프로젝트
│   ├── DemoMain.pas
│   └── DemoMain.dfm
├── tools/
│   └── build.ps1               # 통합 빌드 스크립트
└── bin/                        # 산출물 (.dll, .exe)
```

## 빌드

```powershell
# 전체 빌드 (Rust DLL 32+64 + Delphi 데모)
.\tools\build.ps1 -All

# Rust DLL만 (32+64)
.\tools\build.ps1 -Rust

# 특정 비트만
.\tools\build.ps1 -Rust64
.\tools\build.ps1 -Rust32

# Delphi 데모만
.\tools\build.ps1 -Delphi
```

산출물:
- `bin/sc_shell.dll` — Rust DLL (x86_64)
- `bin/win32/sc_shell.dll` — Rust DLL (i686, 같은 이름)
- `bin/DemoShell.exe` — 데모 애플리케이션

## 사용 예 (델파이)

```pascal
uses
  SCShell.Ctrl;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.ShellPath := 'C:\Windows\System32\cmd.exe';
  FShell.OnExit := HandleShellExit;
  FShell.Start;
end;

procedure TFormMain.HandleShellExit(Sender: TObject; AExitCode: Integer);
begin
  StatusBar.Caption := Format('Exited: %d', [AExitCode]);
end;
```

## 주요 프로퍼티 / 메서드

| 멤버 | 설명 |
|------|------|
| `ShellPath: string` | 실행할 셸 실행 파일 경로 |
| `ShellArgs: string` | 셸 인자 |
| `WorkingDir: string` | 자식 프로세스 작업 디렉터리 |
| `Environment: TStrings` | 환경 변수 (`KEY=VALUE` 항목) |
| `AutoStart: Boolean` | True면 `Loaded` 시 자동 시작 |
| `ScrollbackLines: Integer` | 스크롤백 줄 수 (기본 10000) |
| `Start` | 셸 프로세스 실행 |
| `Stop(timeout)` | 셸 종료 |
| `Restart` | 종료 후 재시작 |
| `SendText(text)` | UTF-16 → UTF-8 변환 후 PTY로 전송 |
| `OnExit` | 자식 프로세스 종료 이벤트 |
| `OnTitleChange` | 타이틀(`OSC 0/2`) 변경 이벤트 |
| `OnBell` | BEL 수신 이벤트 |

## 아키텍처

```
+----------------------------------------------------+
|              델파이 호스트 프로세스                 |
|  +---------------+    +----------------------+     |
|  | TSCRataShell  |---→| SCShell.pas (FFI)    |     |
|  | (TWinControl) |←---| 동적 DLL 바인딩       |     |
|  +---------------+    +----------▲-----------+     |
|                                  | C ABI           |
+----------------------------------|-----------------+
                                   ▼
+----------------------------------------------------+
|              sc_shell.dll (Rust)                   |
|  +-------+   +---------+   +----------+            |
|  | FFI   |←→ | Session |←→ | TermHost |            |
|  +-------+   +----┬────+   +----┬─────+            |
|                   ▼              ▼                  |
|              +-------+   +-----------------+        |
|              |  PTY  |   | alacritty Term  |        |
|              +---┬---+   |  + Processor    |        |
|                  |       +-----------------+        |
+------------------|---------------------------------+
                   ▼
            +-------------+
            | ConPTY API  |
            +------┬------+
                   ▼
          +-----------------+
          |  cmd / pwsh /   |
          |   wsl / ...     |
          +-----------------+
```

## 라이선스

MIT — `alacritty_terminal`(MIT) 등 의존성 라이선스 준수
