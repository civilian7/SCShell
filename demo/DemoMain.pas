unit DemoMain;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  SCShell.Ctrl;

type
  TFormMain = class(TForm)
    PanelTop: TPanel;
    BtnStart: TButton;
    BtnStop: TButton;
    ComboShell: TComboBox;
    StatusBar: TPanel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure BtnStartClick(Sender: TObject);
    procedure BtnStopClick(Sender: TObject);
  private
    FShell: TSCRataShell;
    procedure HandleStarted(Sender: TObject);
    procedure HandleExit(Sender: TObject; AExitCode: Integer);
    procedure HandleTitle(Sender: TObject; const ATitle: string);
    procedure UpdateStatus;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  Caption := 'RataShell Demo';

  PanelTop := TPanel.Create(Self);
  PanelTop.Parent := Self;
  PanelTop.Align := alTop;
  PanelTop.Height := 36;
  PanelTop.BevelOuter := bvNone;

  BtnStart := TButton.Create(Self);
  BtnStart.Parent := PanelTop;
  BtnStart.Caption := 'Start';
  BtnStart.Left := 8;
  BtnStart.Top := 6;
  BtnStart.Width := 75;
  BtnStart.OnClick := BtnStartClick;

  BtnStop := TButton.Create(Self);
  BtnStop.Parent := PanelTop;
  BtnStop.Caption := 'Stop';
  BtnStop.Left := 90;
  BtnStop.Top := 6;
  BtnStop.Width := 75;
  BtnStop.OnClick := BtnStopClick;

  ComboShell := TComboBox.Create(Self);
  ComboShell.Parent := PanelTop;
  ComboShell.Left := 180;
  ComboShell.Top := 8;
  ComboShell.Width := 280;
  ComboShell.Style := csDropDown;
  ComboShell.Items.Add('C:\Windows\System32\cmd.exe');
  ComboShell.Items.Add('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
  ComboShell.Items.Add('pwsh.exe');
  ComboShell.ItemIndex := 0;

  StatusBar := TPanel.Create(Self);
  StatusBar.Parent := Self;
  StatusBar.Align := alBottom;
  StatusBar.Height := 22;
  StatusBar.BevelOuter := bvNone;
  StatusBar.Caption := 'Idle';
  StatusBar.Alignment := taLeftJustify;

  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.OnStarted := HandleStarted;
  FShell.OnExit := HandleExit;
  FShell.OnTitleChange := HandleTitle;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  if Assigned(FShell) then
    FShell.Stop(0);
end;

procedure TFormMain.BtnStartClick(Sender: TObject);
begin
  FShell.ShellPath := ComboShell.Text;
  FShell.Start;
  FShell.SetFocus;
end;

procedure TFormMain.BtnStopClick(Sender: TObject);
begin
  FShell.Stop;
end;

procedure TFormMain.HandleStarted(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TFormMain.HandleExit(Sender: TObject; AExitCode: Integer);
begin
  StatusBar.Caption := Format('Exited (code=%d)', [AExitCode]);
end;

procedure TFormMain.HandleTitle(Sender: TObject; const ATitle: string);
begin
  Caption := 'RataShell Demo — ' + ATitle;
end;

procedure TFormMain.UpdateStatus;
begin
  StatusBar.Caption := Format('Running  %dx%d', [FShell.GetCols, FShell.GetRows]);
end;

end.
