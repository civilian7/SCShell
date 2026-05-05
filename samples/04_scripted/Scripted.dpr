{ ============================================================================
  04_scripted/Scripted.dpr — 호스트가 셸 명령을 자동 실행 + 출력 가로채기.
  - "Run Script" 버튼: SendText 로 cmd 일괄 실행
  - 결과 텍스트는 좌측 메모에 셸 출력 미러링 (선택 영역 → 클립보드 복사)
  - Hyperlink 자동 인식 (셸이 OSC 8 출력 시) — Ctrl+Click 으로 외부 열기
  - 매 1초 폴링: CWD / Mode / PID 표시
  ============================================================================ }
program Scripted;

uses
  Vcl.Forms,
  ScriptedMain in 'ScriptedMain.pas' {FormMain};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'SCShell — Scripted Demo';
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
