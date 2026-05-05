{ ============================================================================
  01_minimal/Minimal.dpr — TSCRataShell 최소 임베드 샘플.
  메인폼 (MinimalMain.pas / .dfm) 1개 + 셸 1개 alClient. cmd.exe 자동 실행.
  ============================================================================ }
program Minimal;

uses
  Vcl.Forms,
  MinimalMain in 'MinimalMain.pas' {FormMain};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'SCShell Minimal';
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
