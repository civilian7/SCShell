# SCShell 개발자 가이드

Delphi 호스트에 임베드 가능한 Windows 터미널 컴포넌트. Rust DLL (`sc_shell.dll`) +
Delphi VCL 컨트롤 (`TSCRataShell`) 의 짝.

---

## 1. 빠른 시작

### 1.1 폼에 셸 한 줄 임베드

```pascal
uses
  Vcl.Controls, SCShell, SCShell.Ctrl;

procedure TForm1.FormCreate(Sender: TObject);
var
  LShell: TSCRataShell;
begin
  LShell := TSCRataShell.Create(Self);
  LShell.Parent := Self;
  LShell.Align := alClient;
  LShell.ShellPath := GetEnvironmentVariable('COMSPEC');  // cmd.exe
  LShell.ShellArgs := '/K "chcp 65001 >nul"';             // UTF-8 콘솔
  LShell.ScrollbackLines := 10000;
  LShell.Start;
end;
```

`TSCRataShell.Start` 가 `sc_shell.dll` 자동 로드 + `rata_init` + 자식 프로세스 spawn.

### 1.2 단축키 즉시 동작

별도 코드 없이 사용 가능한 단축키:

| 단축키 | 동작 |
|---|---|
| Ctrl+Shift+C | 선택 영역 복사 |
| Ctrl+Shift+V | 클립보드 paste (bracketed paste mode 자동 wrap) |
| Ctrl+Shift+F | 인라인 검색바 토글 |
| F3 / Shift+F3 | 다음 / 이전 매치 |
| Ctrl+Shift+Space | VI navigation mode 토글 |
| Ctrl+Click (hyperlink 위) | ShellExecute |
| 휠 | 스크롤백 ±3 라인 |
| Shift+Drag (캔버스 밖) | 자동 스크롤 |

---

## 2. 빌드

### 2.1 Rust DLL

```powershell
# 64비트 (배포용)
.\tools\build.ps1 -Rust64

# 32비트 (legacy 호환, 옵트인)
.\tools\build.ps1 -Rust32

# 모두 + Delphi 데모
.\tools\build.ps1
```

출력:
- `bin\sc_shell.dll` (64비트, 호스트 앱이 사용)
- `bin\win32\sc_shell.dll` (32비트, 옵트인 — **이름은 같고 폴더로 가른다**)

요구사항:
- Rust 1.80+
- `rustup target add x86_64-pc-windows-msvc`
- MSVC build tools (Visual Studio 2022 Community Workload "C++ build tools")

### 2.2 Delphi 임포트

호스트 프로젝트에서 직접 사용:

```pascal
// .dpr uses 절
uses
  SCShell in '경로\delphi\src\SCShell.pas',
  SCShell.Painter in '경로\delphi\src\SCShell.Painter.pas',
  SCShell.Ctrl in '경로\delphi\src\SCShell.Ctrl.pas';
```

또는 패키지 (`SCShell_RT.dpk` / `SCShell_DT.dpk`) 설치 후 폼 디자이너에서 드롭.

`sc_shell.dll` 은 EXE 와 동일 폴더에 배치.

---

## 3. TSCRataShell API 레퍼런스

### 3.1 Published 프로퍼티

| 프로퍼티 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `ShellPath` | string | '' | 실행 셸 경로 (cmd.exe / pwsh.exe / wsl.exe) |
| `ShellArgs` | string | '' | 셸 인자 |
| `WorkingDir` | string | '' | 시작 디렉터리 |
| `Environment` | TStrings | empty | 추가 환경 변수 (`KEY=VALUE` per line) |
| `AutoStart` | Boolean | False | 폼 Loaded 시 자동 Start |
| `Active` | Boolean | False | True 설정 시 Start, False 설정 시 Stop |
| `ScrollbackLines` | Integer | 10000 | 스크롤백 최대 라인 수 |
| `CursorStyle` | TRataCursorStyle | csBlock | 기본 cursor style (셸이 OSC 로 변경 가능) |
| `CursorBlink` | Boolean | True | cursor 깜박임 활성 |
| `ReadOnly` | Boolean | False | True 면 키 입력 무시 |

### 3.2 Public 메서드

```pascal
procedure Start;
procedure Stop(ATimeoutMs: Cardinal = 2000);
procedure Restart;
function IsAlive: Boolean;

procedure SendText(const AText: string);    // 자동: scroll-to-bottom + selection clear
                                              // bracketed paste mode 자동 wrap
procedure SendKey(AVk: Word; AMods: Word);  // RATA_MOD_* 비트마스크

// 스크롤
function GetCols: Integer;
function GetRows: Integer;

// 정리/리셋
procedure ClearHistory;     // 스크롤백만 비움
procedure SoftReset;        // RIS (ESC c) — 화면 + 속성 초기화

// 상태 조회
function ChildPid: UInt32;
function CurrentExitCode: Integer;
function ModeFlags: UInt32;       // RATA_MODE_* 비트
function AltActive: Boolean;
function CurrentCwd: string;       // OSC 7 보고된 경로
function ViModeActive: Boolean;

// 선택 / 복사
function SelectionText: string;
procedure SelectionStart(ACol, ARow: Word; AKind: Byte = 0);  // 0=Simple/1=Block/2=Semantic/3=Lines
procedure SelectionExtend(ACol, ARow: Word);
procedure SelectionClear;
procedure CopySelection;

// Hyperlinks
function HyperlinkAt(ACol, ARow: Integer): UInt32;  // 0=없음
function HyperlinkUri(AId: UInt32): string;

// 검색
procedure ShowSearchDialog;                          // 인라인 검색바 표시
procedure SearchAgain(AForward: Boolean);            // 마지막 패턴 재검색
function SearchNext(const APattern: string; AForward: Boolean;
  out ACol, ARow, ALen: Word): Boolean;              // 단발 검색

// VI mode
procedure ToggleViMode;
procedure ViMotion(AKind: Byte);  // RATA_VIM_*
```

### 3.3 이벤트

```pascal
property OnStarted: TNotifyEvent;                     // Start 성공 후 fire
property OnExit: TRataExitEvent;                      // 자식 프로세스 종료 (exit code)
property OnTitleChange: TRataTitleEvent;              // OSC 0/2 윈도우 타이틀
property OnBell: TNotifyEvent;                        // BEL 문자 (\\a)
```

호스트 클립보드(OSC 52) 는 `Vcl.Clipbrd.Clipboard.AsText` 로 자동 적재됨 — 이벤트 없음.

### 3.4 상수

```pascal
// Modifier (SendKey 인자)
RATA_MOD_SHIFT = $01;
RATA_MOD_CTRL  = $02;
RATA_MOD_ALT   = $04;
RATA_MOD_WIN   = $08;

// TermMode 비트 (ModeFlags 반환)
RATA_MODE_ALT_SCREEN          = 1 shl 0;  // alt-screen (vim/less)
RATA_MODE_APP_CURSOR          = 1 shl 1;  // ESC OA vs ESC[A
RATA_MODE_APP_KEYPAD          = 1 shl 2;
RATA_MODE_BRACKETED_PASTE     = 1 shl 3;  // SendText 가 자동 wrap
RATA_MODE_MOUSE_REPORT_CLICK  = 1 shl 4;  // 1000
RATA_MODE_MOUSE_DRAG          = 1 shl 5;  // 1002
RATA_MODE_MOUSE_MOTION        = 1 shl 6;  // 1003
RATA_MODE_SGR_MOUSE           = 1 shl 7;  // 1006
RATA_MODE_UTF8_MOUSE          = 1 shl 8;  // 1005

// VI motion (ViMotion 인자)
RATA_VIM_UP / DOWN / LEFT / RIGHT
RATA_VIM_FIRST / LAST / FIRST_OCCUPIED
RATA_VIM_HIGH / MIDDLE / LOW
RATA_VIM_WORD_LEFT / RIGHT / LEFT_END / RIGHT_END
RATA_VIM_SEMANTIC_LEFT / RIGHT / LEFT_END / RIGHT_END
RATA_VIM_BRACKET / PARAGRAPH_UP / DOWN
```

---

## 4. 통합 패턴

### 4.1 탭 컨테이너에 임베드

`TSCShellTabSheet` (delphi/lib/app) 가 표준 패턴:

```pascal
type
  TSCShellTabSheet = class(TSCPageTabSheet)
  private
    FBaseCaption: string;
    FShell: TSCRataShell;
    procedure DoShellTitle(ASender: TObject; const ATitle: string);
  public
    procedure InitTerminal;
    procedure FocusTerminal;
  end;

procedure TSCShellTabSheet.InitTerminal;
begin
  FBaseCaption := Caption;
  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.OnTitleChange := DoShellTitle;
  FShell.ShellPath := 'cmd.exe';
  FShell.Start;
  TSCAsync.Post(procedure begin FocusTerminal; end);  // 핸들 생성 후 1 단계 지연
end;
```

### 4.2 셸 명령 자동 실행

```pascal
LShell.SendText('ls -la' + #13);  // CR = Enter
```

`SendText` 가 자동:
- 스크롤백 위로 올라가 있으면 live edge 복귀
- 선택 영역 자동 해제
- bracketed paste mode 활성 시 wrap (단일 문자 입력은 wrap 안 함)

### 4.3 탭 캡션 동기화

```pascal
procedure TMyTab.DoShellTitle(Sender: TObject; const ATitle: string);
begin
  if ATitle = '' then
    Caption := FBaseCaption
  else
    Caption := ATitle;
end;
```

### 4.4 종료 시 정리

```pascal
destructor TMyForm.Destroy;
begin
  if FShell <> nil then
  begin
    FShell.Stop(2000);  // ⚠ Stop(0) 금지 — Rust 콜백 스레드 join 미보장 → 217 오류
    FreeAndNil(FShell);
  end;
  inherited;
end;
```

---

## 5. 마우스 트래킹 (셸이 요청 시 자동)

`mode_flags` 가 `MOUSE_REPORT_CLICK / DRAG / MOTION` 중 하나라도 set 이면
`TSCRataShell.MouseDown/Up/Move` 가 자동 VT 시퀀스 송신:

| 모드 | 활성 시퀀스 | 캡처 이벤트 |
|---|---|---|
| 1000 | SGR 또는 X10 | down/up |
| 1002 | + drag | down/up + 버튼 held 중 motion |
| 1003 | + motion | down/up + 모든 motion |
| 1006 | SGR encoding | 위 모드 인코딩 변경 |
| 1005 | UTF-8 encoding | X10 같지만 좌표 UTF-8 멀티바이트 |

호스트는 별도 코드 없이 vim/htop/tig 등 마우스 인식 앱이 동작.

---

## 6. 검색 / VI mode

### 6.1 인라인 검색바 (Ctrl+Shift+F)

```pascal
LShell.ShowSearchDialog;  // Ctrl+Shift+F 가 자동 호출
```

상단 28px 패널 표시:
- TEdit 에 정규식 입력 → 실시간 매치 강조 (노란 사각형)
- Enter / F3: 다음, Shift+Enter / Shift+F3: 이전
- Esc: 닫기 + 매치 해제 + 셸 포커스 복귀

직접 호출:

```pascal
var LCol, LRow, LLen: Word;
if LShell.SearchNext('error', True, LCol, LRow, LLen) then
  ShowMessage(Format('match at %d,%d (len=%d)', [LCol, LRow, LLen]));
```

### 6.2 VI navigation (Ctrl+Shift+Space)

토글 후 키:
| 키 | motion |
|---|---|
| h/j/k/l | Left/Down/Up/Right |
| 0 / ^ / $ | First / FirstOccupied / Last |
| w / b / e | Word Right/Left/RightEnd |
| W / B / E | Semantic 변형 |
| H / M / L | viewport High/Middle/Low |
| { / } | Paragraph Up/Down |
| % | 매칭 괄호 |
| y | 선택 → 클립보드 (yank) |
| Esc / i | VI 종료 (insert mode) |

키 입력은 셸로 송신되지 않음 (PTY 보호).

---

## 7. 한글 IME

기본 동작 — 별도 설정 없이:
- IME 컴포지션 창 위치 셀 정렬 자동 보정
- 자모 분리 / 조합 취소 정상 처리
- `WMImeStartComposition / Composition / EndComposition` 내부 처리

폰트:
- `Font.Pitch := fpFixed` 강제 — Consolas 미설치 환경에서 fallback 폰트가
  fixed pitch 가 되도록 보장
- 한글 문자는 `WIDE_CHAR` cell 로 width=2 처리 — painter 가 인접 셀
  (`WIDE_CHAR_SPACER`) 를 width=0 으로 skip

---

## 8. 트러블슈팅

### 8.1 빌드 실패

| 증상 | 원인 / 해결 |
|---|---|
| `cargo build` 가 LNK1181 dependent crate | MSVC linker 미설치 — Visual Studio C++ workload |
| `dcc64.exe not found` | `tools/build.ps1` 의 `$Dcc64` 경로 확인 (Studio 37.0 기본) |
| `'sc_shell.dll' not found` | DLL 을 EXE 폴더에 배치 또는 `RataLoadLibrary(절대경로)` 명시 |

### 8.2 런타임

| 증상 | 원인 / 해결 |
|---|---|
| 종료 시 217 | Stop(0) 사용 금지 → Stop(2000+) 권장. 콜백 자동 nil 처리됨 |
| 셸 클릭해도 포커스 안 감 | 자동 처리 (TSCRataShell.MouseDown 가 SetFocus). 부모 폼 활성 확인 |
| 한글 입력 시 깨짐 | 셸이 chcp 65001 를 받았는지 확인. cmd.exe 면 ShellArgs `/K "chcp 65001>nul"` |
| vim 종료 후 alt-screen 안 빠짐 | `mode_flags` 가 ALT_SCREEN 비트 유지 — 셸이 정상 종료 안 한 경우. SoftReset 호출 |
| 마우스 휠로 스크롤 안 됨 | mode_flags 가 MOUSE_*MOTION/DRAG 활성 → 셸 앱(htop 등)이 휠을 가로챔 |

### 8.3 디버깅

DLL 로그: `RATA_INIT_LOG_FILE | RATA_INIT_LOG_DEBUG` 플래그로 `rata_shell.log`
파일 생성 (DLL 폴더 또는 `%TEMP%`).

```pascal
// SCShell.pas RataLoadLibrary 가 자동:
rata_init(RATA_INIT_LOG_FILE or RATA_INIT_LOG_DEBUG);
```

---

## 9. 디렉터리 구조

```
SHELL/
├── docs/
│   ├── DEVELOPER_GUIDE.md       # 본 문서
│   └── design/                   # 설계서
│       ├── 00-overview.md
│       ├── 01-requirements.md
│       ├── 02-tech-stack.md
│       ├── 03-architecture.md
│       ├── 05-ffi.md
│       └── 06-ui.md
├── rata_shell/                   # Rust DLL crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── ffi.rs                # C ABI export
│       ├── session.rs            # 세션 lifecycle
│       ├── pty/                  # ConPTY + Job Object
│       ├── io.rs                 # Reader/Writer 스레드
│       ├── term.rs               # alacritty Term 래퍼
│       ├── render/               # 셀 그리드 스냅샷 + diff
│       ├── keymap.rs             # Win32 VK → VT 시퀀스
│       ├── listener.rs           # alacritty Event 캡처 (Title/Bell/Clipboard)
│       └── log.rs
├── delphi/
│   ├── src/
│   │   ├── SCShell.pas           # FFI 바인딩
│   │   ├── SCShell.Painter.pas   # GDI 페인터
│   │   ├── SCShell.Ctrl.pas      # TSCRataShell 컴포넌트
│   │   └── SCShell.Reg.pas       # 디자인타임 등록
│   └── packages/
│       ├── SCShell_RT.dpk        # 런타임 패키지
│       └── SCShell_DT.dpk        # 디자인타임 패키지
├── demo/
│   ├── DemoShell.dpr             # 데모 EXE
│   ├── DemoMain.pas
│   └── DemoMain.dfm
├── tools/
│   └── build.ps1                 # Rust + Delphi 빌드 통합
└── bin/                          # 빌드 출력
    ├── sc_shell.dll              # 64비트 메인
    ├── win32/
    │   └── sc_shell.dll          # 32비트 (옵트인, 같은 이름)
    └── DemoShell.exe
```

---

## 10. 기능 매트릭스

| 카테고리 | 기능 | 구현 위치 |
|---|---|---|
| 렌더링 | block / underline / bar / blinking 4종 cursor | `SCShell.Painter.pas` |
| | dirty rect diff | `render/backend.rs` |
| | DPI 변경 폰트 재계산 | `TSCRataShell.ChangeScale` |
| 스크롤백 | scroll / scroll_to_top/bottom | `term.rs` + `session.rs` |
| | UI 스크롤바 (휠/썸/페이지) | `TSCRataShell.Paint/MouseDown` |
| | 키 입력 시 자동 bottom 복귀 | `SendText / WMKeyDown` |
| | 선택 드래그 viewport 경계 자동 스크롤 | `MouseMove / DoAutoScrollTick` |
| | clear_history | `term.clear_history` |
| 선택/복사 | Simple/Block/Semantic/Lines | `term.selection_start kind=0..3` |
| | Ctrl+Shift+C / Ctrl+Shift+V | `WMKeyDown` |
| | OSC 52 시스템 클립보드 적재 | `RataClipboardProc` (HostListener) |
| 마우스 트래킹 | 1000/1002/1003/1006/1005 | `SendMouseSequence` |
| 이벤트 | OSC 0/2 Title | `HostListener` → `OnTitleChange` |
| | OSC 7 cwd | term.rs byte scanner |
| | OSC 8 hyperlinks | `cell.hyperlink` + `hash_uri` |
| | OSC 52 clipboard | listener.rs Event::ClipboardStore |
| | Bell | listener Event::Bell → `OnBell` |
| 입력 | bracketed paste 자동 wrap | `SendText` |
| | 한글 IME | `WMImeComposition` 등 |
| 검색 | regex 검색 | `term.search_next` |
| | 인라인 검색바 + F3 | `ShowSearchDialog / WMKeyDown VK_F3` |
| | 매치 하이라이트 | `Paint` overlay |
| Hyperlinks | underline overlay | `Paint` cells 순회 |
| | hover hand cursor + URI hint | `MouseMove / Hint` |
| | Ctrl+Click → ShellExecute | `MouseDown` |
| VI mode | toggle / hjkl/wbe/HML/{}/% / yi | `ViMotion FFI` + `WMKeyDown / WMChar` |
| | 시각 표시 | TabSheet 200ms 폴링 → `[VI]` prefix |

---

## 11. 변경 이력

| 버전 | 날짜 | 주요 변경 |
|---|---|---|
| v0.40 → v0.41 | 2026-05-06 | 본 문서 도입. xterm.js → rata_shell 호스트 통합, 모든 alacritty 능력 surface (스크롤백/마우스/선택/OSC 0/2/7/8/52/cursor styles/hyperlinks/검색/풀 VI mode/인라인 검색바). DLL 이름 `sc_shell64.dll → sc_shell.dll`. 217 종료 오류 수정. |
