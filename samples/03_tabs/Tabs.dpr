{ ============================================================================
  03_tabs/Tabs.dpr — 멀티 탭 터미널 (PageControl + 각 탭마다 TSCRataShell).
  - "+" 버튼으로 새 탭 추가 (cmd / pwsh / wsl 선택)
  - 탭 마다 OSC 0/2 타이틀 변경 → 탭 캡션 자동 갱신
  - "X" 버튼으로 탭 닫기 — 셸 깔끔히 종료 (Stop 2000ms timeout)
  ============================================================================ }
program Tabs;

uses
  Vcl.Forms,
  TabsMain in 'TabsMain.pas' {FormMain};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'SCShell — Tabs Demo';
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
