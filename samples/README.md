# SCShell 샘플

점진적 복잡도로 정리된 4개 샘플. 각 폴더는 자체 `.dpr` 진입점 + 코드만 포함.

## 빌드

각 샘플 폴더에서 Delphi `dcc64.exe` 로 컴파일. 또는 `tools/build.ps1` 의 패턴으로
직접 빌드:

```powershell
$Dcc64 = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe'
$DelphiSrc = '..\..\delphi\src'
$Bin = '..\..\bin'

cd 01_minimal
& $Dcc64 -B `
    -U"$DelphiSrc" `
    -E"$Bin\samples" `
    -N"$Bin\samples\dcu" `
    Minimal.dpr
```

빌드 후 `sc_shell.dll` 이 EXE 와 같은 폴더 (`bin\samples`) 에 있어야 함 — `bin\sc_shell.dll`
복사 또는 PATH 설정.

## 샘플 목록

### 01_minimal — 30줄 최소 임베드
- 폼 1개 + 셸 1개 alClient
- cmd.exe 자동 실행
- 모든 단축키 즉시 동작 (Ctrl+Shift+C/V/F, F3, Ctrl+Click, Ctrl+Shift+Space 등)

> 이 샘플은 **최소 통합 패턴** — 셸을 폼에 끼우는 것 외에는 아무 코드도 없음.

### 02_menu_driven — 메뉴/상태바 풀 데모
- File: 셸 종류 (cmd/pwsh/wsl) 전환, Start/Stop/Restart
- Edit: Copy/Paste/Select All
- View: Scroll Top/Bottom, Clear Scrollback, Soft Reset
- VI/Search: VI mode 토글, Find / Next / Prev
- Tools: 호스트가 직접 OSC 8 hyperlink / cursor style / OSC 0 title 송신 데모
- 상태바: PID / CWD (OSC 7) / Mode flags / VI / Exit code 실시간 폴링

> **모든 기능을 GUI 로 호출** 하는 통합 데모. 코드를 보면 어떤 메서드가 어떤 기능을
> 담당하는지 즉시 파악 가능.

### 03_tabs — 멀티 탭 터미널
- TPageControl + 각 탭마다 TSCRataShell
- 툴바 + cmd / + powershell / + wsl 버튼으로 새 탭 추가
- OSC 0/2 타이틀 → 탭 캡션 자동 갱신
- 닫기 시 Stop(2000) 으로 217 회피

> Windows Terminal / VS Code 터미널 패널 같은 **여러 셸 동시 운용** 패턴.

### 04_scripted — 호스트 → 셸 명령 자동화
- 우측 컨트롤 패널: Run Demo Script / Send Custom / Inject Hyperlink / Set Title
- 좌측 셸 — `SendText` 로 cmd 일괄 실행
- 1초 폴링: PID / CWD / Mode flags / VI 상태 표시
- Hyperlink 인젝션 — Ctrl+Click 으로 외부 열림 검증

> 호스트 앱이 셸을 **자동화 채널**로 사용하는 패턴 — CI runner UI, 빌드 진행 표시,
> SSH 자동 로그인 등.

## 공통 단축키 치트시트

| 단축키 | 동작 |
|---|---|
| Ctrl+Shift+C | 선택 영역 → 클립보드 |
| Ctrl+Shift+V | 클립보드 → 셸 (bracketed paste 자동 wrap) |
| Ctrl+Shift+F | 인라인 검색바 |
| F3 / Shift+F3 | 다음 / 이전 매치 |
| Ctrl+Shift+Space | VI 모드 토글 |
| Esc (VI 활성) | VI 모드 종료 |
| h/j/k/l (VI) | Left/Down/Up/Right |
| 0 / ^ / $ (VI) | 행 처음 / 첫 비공백 / 행 끝 |
| w/b/e (VI) | Word right/left/right-end |
| % (VI) | 매칭 괄호 |
| y (VI) | 선택 → 클립보드 |
| Shift+드래그 | 텍스트 선택 |
| 더블클릭 | 단어 선택 |
| 트리플클릭 | 행 선택 |
| Alt+드래그 | 사각 블록 선택 |
| Ctrl+Click | 위 hyperlink 열기 |
| 휠 | 스크롤백 ±3 라인 |

## 트러블슈팅

`'sc_shell.dll' could not be loaded` — DLL 이 EXE 폴더 또는 PATH 에 없음.
```powershell
copy ..\..\bin\sc_shell.dll .
```

종료 시 217 — `Stop(0)` 대신 `Stop(2000)` 사용. 데모는 모두 적용됨.
