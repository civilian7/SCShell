unit ScriptedMain;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  System.UITypes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  SCShell,
  SCShell.Ctrl;

type
  TFormMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FShell: TSCRataShell;
    FRightPanel: TPanel;
    FBtnRunScript: TButton;
    FBtnEcho: TButton;
    FBtnHyperlink: TButton;
    FBtnTitle: TButton;
    FMemoScript: TMemo;
    FStatus: TLabel;
    FPollTimer: TTimer;

    procedure DoRunScript(ASender: TObject);
    procedure DoEcho(ASender: TObject);
    procedure DoHyperlink(ASender: TObject);
    procedure DoTitleSet(ASender: TObject);
    procedure DoPollTick(ASender: TObject);
    procedure DoTitle(ASender: TObject; const ATitle: string);
    procedure DoShellExit(ASender: TObject; AExitCode: Integer);
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

const
  CDemoScript =
    '@echo off' + #13 +
    'echo === SCShell Scripted Demo ===' + #13 +
    'echo Current directory: %CD%' + #13 +
    'echo Date: %DATE%  Time: %TIME%' + #13 +
    'echo.' + #13 +
    'echo Files in current dir:' + #13 +
    'dir /b' + #13 +
    'echo.' + #13 +
    'echo === Done ===' + #13;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  // 우측 컨트롤 패널
  FRightPanel := TPanel.Create(Self);
  FRightPanel.Parent := Self;
  FRightPanel.Align := alRight;
  FRightPanel.Width := 380;
  FRightPanel.BevelOuter := bvNone;
  FRightPanel.Color := RGB($28, $28, $28);
  FRightPanel.ParentBackground := False;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FRightPanel;
  FStatus.SetBounds(8, 8, 360, 60);
  FStatus.Font.Color := clWhite;
  FStatus.Font.Name := 'Consolas';
  FStatus.Font.Size := 9;
  FStatus.WordWrap := True;
  FStatus.AutoSize := False;
  FStatus.Caption := '(starting...)';

  FBtnRunScript := TButton.Create(Self);
  FBtnRunScript.Parent := FRightPanel;
  FBtnRunScript.SetBounds(8, 80, 360, 30);
  FBtnRunScript.Caption := 'Run Demo Script';
  FBtnRunScript.OnClick := DoRunScript;

  FMemoScript := TMemo.Create(Self);
  FMemoScript.Parent := FRightPanel;
  FMemoScript.SetBounds(8, 118, 360, 200);
  FMemoScript.Anchors := [akLeft, akTop, akRight];
  FMemoScript.ScrollBars := ssBoth;
  FMemoScript.Font.Name := 'Consolas';
  FMemoScript.Font.Size := 9;
  FMemoScript.Text := CDemoScript;

  FBtnEcho := TButton.Create(Self);
  FBtnEcho.Parent := FRightPanel;
  FBtnEcho.SetBounds(8, 326, 360, 28);
  FBtnEcho.Caption := 'Send Custom (textarea above)';
  FBtnEcho.OnClick := DoEcho;

  FBtnHyperlink := TButton.Create(Self);
  FBtnHyperlink.Parent := FRightPanel;
  FBtnHyperlink.SetBounds(8, 362, 360, 28);
  FBtnHyperlink.Caption := 'Inject Hyperlink (OSC 8) — Ctrl+Click to open';
  FBtnHyperlink.OnClick := DoHyperlink;

  FBtnTitle := TButton.Create(Self);
  FBtnTitle.Parent := FRightPanel;
  FBtnTitle.SetBounds(8, 398, 360, 28);
  FBtnTitle.Caption := 'Set Window Title (OSC 0)';
  FBtnTitle.OnClick := DoTitleSet;

  // 좌측 셸
  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.ShellPath := GetEnvironmentVariable('COMSPEC');
  if FShell.ShellPath = '' then FShell.ShellPath := 'cmd.exe';
  FShell.ShellArgs := '/K "chcp 65001 >nul"';
  FShell.ScrollbackLines := 10000;
  FShell.OnTitleChange := DoTitle;
  FShell.OnExit := DoShellExit;
  FShell.Start;

  FPollTimer := TTimer.Create(Self);
  FPollTimer.Interval := 1000;
  FPollTimer.OnTimer := DoPollTick;
  FPollTimer.Enabled := True;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  if FShell <> nil then FShell.Stop(2000);
end;

procedure TFormMain.DoRunScript(ASender: TObject);
begin
  if FShell.IsAlive then FShell.SendText(CDemoScript);
end;

procedure TFormMain.DoEcho(ASender: TObject);
begin
  if FShell.IsAlive and (FMemoScript.Text <> '') then
    FShell.SendText(FMemoScript.Text);
end;

procedure TFormMain.DoHyperlink(ASender: TObject);
begin
  // OSC 8 ; ; <URI> BEL  <text>  OSC 8 ; ; BEL
  if FShell.IsAlive then
    FShell.SendText(
      'echo SCShell repo: '#27']8;;https://github.com/example/scshell'#7 +
      '[Click here]'#27']8;;'#7 + #13);
end;

procedure TFormMain.DoTitleSet(ASender: TObject);
begin
  if FShell.IsAlive then
    FShell.SendText(#27']0;Set by host @ ' + FormatDateTime('hh:nn:ss', Now) + #7);
end;

procedure TFormMain.DoTitle(ASender: TObject; const ATitle: string);
begin
  if ATitle = '' then
    Caption := 'SCShell — Scripted Demo'
  else
    Caption := 'SCShell — ' + ATitle;
end;

procedure TFormMain.DoShellExit(ASender: TObject; AExitCode: Integer);
begin
  FStatus.Caption := Format('(shell exited with code %d)', [AExitCode]);
end;

procedure TFormMain.DoPollTick(ASender: TObject);
var
  LCwd: string;
  LFlags: UInt32;
  LModes: string;
begin
  if FShell = nil then Exit;
  LCwd := FShell.CurrentCwd;
  if LCwd = '' then LCwd := '(unknown — use cd to update OSC 7)';

  LFlags := FShell.ModeFlags;
  LModes := '';
  if (LFlags and RATA_MODE_ALT_SCREEN) <> 0      then LModes := LModes + ' ALT';
  if (LFlags and RATA_MODE_BRACKETED_PASTE) <> 0 then LModes := LModes + ' BP';
  if (LFlags and RATA_MODE_MOUSE_DRAG) <> 0      then LModes := LModes + ' Mdrag';
  if (LFlags and RATA_MODE_MOUSE_MOTION) <> 0    then LModes := LModes + ' Mmotion';
  if (LFlags and RATA_MODE_SGR_MOUSE) <> 0       then LModes := LModes + ' SGR';
  if LModes = '' then LModes := ' —';

  FStatus.Caption := Format(
    'PID: %d  alive: %s'#13#10 +
    'CWD: %s'#13#10 +
    'Mode:%s  VI: %s',
    [FShell.ChildPid,
     BoolToStr(FShell.IsAlive, True),
     LCwd,
     LModes,
     BoolToStr(FShell.ViModeActive, True)]);
end;

end.
