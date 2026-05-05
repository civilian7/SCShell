unit MinimalMain;

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  SCShell.Ctrl;

type
  TFormMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FShell: TSCRataShell;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.ShellPath := GetEnvironmentVariable('COMSPEC');
  if FShell.ShellPath = '' then FShell.ShellPath := 'cmd.exe';
  FShell.ShellArgs := '/K "chcp 65001 >nul"';
  FShell.ScrollbackLines := 10000;
  FShell.Start;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  if FShell <> nil then FShell.Stop(2000);
end;

end.
