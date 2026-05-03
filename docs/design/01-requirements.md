# 요구사항 정의서

## 1. 기능 요구사항 (Functional Requirements)

### FR-001: 쉘 프로세스 실행
- **설명**: ConPTY를 사용하여 임의의 쉘(`cmd.exe`, `powershell.exe`, `pwsh.exe`, `wsl.exe`, `bash.exe` 등)을 자식 프로세스로 실행한다.
- **우선순위**: 필수
- **사용자 스토리**: 델파이 개발자는 자신의 애플리케이션 폼에 터미널을 배치하고, 임의의 쉘을 실행시킬 수 있다.
- **인수 조건**:
  - [ ] 쉘 실행 파일 경로와 인자, 작업 디렉터리, 환경변수를 지정할 수 있다
  - [ ] 자식 프로세스 종료 시 호스트에 이벤트로 통지된다 (종료 코드 포함)
  - [ ] 호스트 종료 시 자식 프로세스가 누수 없이 정리된다 (Job Object)

### FR-002: 터미널 입출력
- **설명**: 사용자 키 입력을 ConPTY 입력 스트림에 전달하고, 쉘의 VT 출력을 화면에 렌더링한다.
- **우선순위**: 필수
- **인수 조건**:
  - [ ] ASCII / 한글(UTF-8) / 특수 키(화살표, F1~F12, Ctrl+조합, Alt+조합) 모두 지원
  - [ ] ANSI/VT100 이스케이프 시퀀스 — 색상(SGR), 커서 이동, 화면 지움, 스크롤 영역 등 지원
  - [ ] 24-bit truecolor (`ESC[38;2;R;G;Bm`) 지원

### FR-003: Ratatui 기반 렌더링
- **설명**: VT 파서가 만든 가상 스크린 버퍼를 Ratatui로 렌더링한다. Ratatui의 위젯 시스템을 활용해 향후 상태 바, 보더, 탭 등 부가 UI를 추가할 수 있도록 한다.
- **우선순위**: 필수
- **인수 조건**:
  - [ ] Ratatui의 `Backend` 트레이트를 구현한 커스텀 백엔드(`HostBackend`)가 셀 그리드를 호스트에 전달
  - [ ] 프레임당 변경된 셀만 dirty rect로 호스트에 알림 (성능)

### FR-004: 델파이 컴포넌트 임베드
- **설명**: `TRataShell`은 `TWinControl` 자손으로, 폼에 드롭하여 사용 가능하다.
- **우선순위**: 필수
- **인수 조건**:
  - [ ] 디자인타임 컴포넌트 등록 (`Register` 프로시저)
  - [ ] 런타임 동적 생성 가능
  - [ ] `Align`, `Anchors`, `Visible` 등 표준 `TWinControl` 동작 지원

### FR-005: 폰트/색상/테마
- **설명**: 모노스페이스 폰트와 컬러 팔레트(16색 + 기본 전경/배경)를 호스트에서 지정한다.
- **우선순위**: 필수
- **인수 조건**:
  - [ ] `Font.Name`, `Font.Size` 변경 시 셀 크기 재계산 → DLL에 resize 통보
  - [ ] 16색 팔레트 + 기본 fg/bg를 프로퍼티로 노출
  - [ ] 256색 / truecolor는 VT 코드를 그대로 RGB로 매핑

### FR-006: 리사이즈
- **설명**: 컴포넌트 크기 변경 시 셀(rows × cols) 단위로 PTY 크기를 재조정한다.
- **인수 조건**:
  - [ ] `WM_SIZE` 처리 시 `ResizePseudoConsole` 호출
  - [ ] 자식 쉘이 `SIGWINCH`에 해당하는 신호를 받음

### FR-007: 클립보드 / 선택
- **설명**: 마우스 드래그로 텍스트 선택, `Ctrl+C` (선택 영역이 있을 때) 또는 `Ctrl+Shift+C` 복사, `Ctrl+Shift+V` 붙여넣기.
- **우선순위**: 선택
- **인수 조건**:
  - [ ] 선택 영역 하이라이트 렌더링
  - [ ] 더블클릭 단어 선택, 트리플클릭 줄 선택

### FR-008: 스크롤백
- **설명**: 화면 밖으로 밀려난 줄을 일정 크기(예: 10,000줄)까지 보관하고 휠/스크롤바로 조회.
- **우선순위**: 선택

### FR-009: 종료 / 재시작
- **설명**: 호스트 측에서 세션을 강제 종료하거나 동일 설정으로 재시작할 수 있다.
- **인수 조건**:
  - [ ] `Terminate` 메서드 — 자식 프로세스 트리 전체 종료
  - [ ] `Restart` 메서드 — 종료 후 새 PTY로 재시작

## 2. 비기능 요구사항 (Non-Functional Requirements)

### NFR-001: 성능
- 80×25 화면 기준 60 FPS 렌더링 가능
- 대량 출력(`type bigfile.txt`) 시 입력 latency 100 ms 이하
- 프레임당 변경 셀만 호스트로 전달 (full-redraw 회피)

### NFR-002: 안전성
- DLL 경계에서 panic이 호스트로 unwind되지 않음 (`catch_unwind`)
- 모든 export 함수는 `extern "C"` + `#[no_mangle]` + null 체크
- 핸들 누수 0 — 정상/비정상 종료 모두에서 PTY/Process/Pipe 핸들 정리

### NFR-003: 호환성
- Windows 10 1903+ (ConPTY 안정 버전)
- Windows 11 권장
- 64-bit only (Win64) — 델파이 측 표준에 맞춤
- 델파이 13+ (Studio 37.0)

### NFR-004: 배포
- 단일 DLL (`rata_shell.dll`) + 델파이 유닛 (`RataShell.pas`, `RataShell.dcr`) 만 있으면 사용 가능
- DLL은 정적 링크된 Rust 의존성으로 의존 DLL 없음 (CRT는 `+crt-static`)

### NFR-005: 확장성
- VT 파서/렌더러/PTY 호스트가 분리되어 향후 mux(여러 세션), 탭, split-pane을 추가 가능

## 3. 제약 조건

| 구분 | 내용 |
|------|------|
| 기술 | Windows ConPTY API 사용 → Linux/macOS 미지원 |
| 언어 | Rust (1.80+), Delphi 13+ |
| 아키텍처 | x86_64 only |
| 라이선스 | Ratatui(MIT), 본 프로젝트는 사용처 라이선스에 따름 |

## 4. 용어 정의

| 용어 | 정의 |
|------|------|
| ConPTY | Windows의 Pseudo Console API. `CreatePseudoConsole`, `ResizePseudoConsole`, `ClosePseudoConsole` 제공 |
| VT 시퀀스 | DEC VT100/xterm 호환 이스케이프 시퀀스 (`ESC[...m` 등) |
| 셀 그리드 | (행, 열) 위치마다 (글자, 전경색, 배경색, 속성)를 가진 2차원 배열 |
| Backend (Ratatui) | Ratatui가 출력을 위임하는 trait. 본 프로젝트에서는 호스트 버퍼에 쓰는 커스텀 구현 |
| 호스트 | DLL을 로드하여 사용하는 측. 본 설계에서는 델파이 애플리케이션 |
