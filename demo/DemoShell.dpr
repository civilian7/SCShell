program DemoShell;

uses
  Vcl.Forms,
  DemoMain in 'DemoMain.pas' {FormMain},
  SCShell in '..\delphi\src\SCShell.pas',
  SCShell.Painter in '..\delphi\src\SCShell.Painter.pas',
  SCShell.Ctrl in '..\delphi\src\SCShell.Ctrl.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
