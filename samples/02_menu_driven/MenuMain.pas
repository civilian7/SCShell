unit MenuMain;

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
  Vcl.Menus,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  Vcl.Dialogs,
  Vcl.Clipbrd,
  SCShell,
  SCShell.Ctrl;

type
  TFormMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FShell: TSCRataShell;
    FMenu: TMainMenu;
    FStatusBar: TPanel;
    FStatusPID: TLabel;
    FStatusCwd: TLabel;
    FStatusMode: TLabel;
    FStatusVI: TLabel;
    FStatusExit: TLabel;
    FPollTimer: TTimer;

    procedure BuildMenu;
    procedure BuildStatusBar;
    procedure CreateShell;

    // File
    procedure ChooseShellCmd(Sender: TObject);
    procedure ChooseShellPwsh(Sender: TObject);
    procedure ChooseShellWsl(Sender: TObject);
    procedure StartShell(Sender: TObject);
    procedure StopShell(Sender: TObject);
    procedure RestartShell(Sender: TObject);
    procedure ExitApp(Sender: TObject);

    // Edit
    procedure CopyClick(Sender: TObject);
    procedure PasteClick(Sender: TObject);
    procedure SelectAllClick(Sender: TObject);

    // View
    procedure ScrollTopClick(Sender: TObject);
    procedure ScrollBottomClick(Sender: TObject);
    procedure ClearScrollbackClick(Sender: TObject);
    procedure SoftResetClick(Sender: TObject);

    // VI / Search
    procedure ToggleVIClick(Sender: TObject);
    procedure SearchClick(Sender: TObject);
    procedure FindNextClick(Sender: TObject);
    procedure FindPrevClick(Sender: TObject);

    // Tools — bracketed paste demo, hyperlink demo
    procedure SendHyperlinkDemoClick(Sender: TObject);
    procedure SendCursorStyleDemoClick(Sender: TObject);
    procedure SendTitleDemoClick(Sender: TObject);
    procedure ShowChildPidClick(Sender: TObject);

    // Events
    procedure HandleStarted(ASender: TObject);
    procedure HandleExit(ASender: TObject; AExitCode: Integer);
    procedure HandleTitle(ASender: TObject; const ATitle: string);
    procedure HandleBell(ASender: TObject);

    procedure DoPollTick(ASender: TObject);
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  KeyPreview := True;
  BuildMenu;
  BuildStatusBar;
  CreateShell;

  FPollTimer := TTimer.Create(Self);
  FPollTimer.Interval := 500;
  FPollTimer.OnTimer := DoPollTick;
  FPollTimer.Enabled := True;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  if FShell <> nil then
    FShell.Stop(2000);  // 217 회피
end;

procedure TFormMain.BuildMenu;
var
  M: TMenuItem;
begin
  FMenu := TMainMenu.Create(Self);
  Self.Menu := FMenu;

  // File
  M := TMenuItem.Create(FMenu);
  M.Caption := '&File';
  FMenu.Items.Add(M);
  M.Add(NewItem('&cmd.exe',         0, False, True, ChooseShellCmd, 0, 'mi_cmd'));
  M.Add(NewItem('&PowerShell',      0, False, True, ChooseShellPwsh, 0, 'mi_pwsh'));
  M.Add(NewItem('&WSL',             0, False, True, ChooseShellWsl, 0, 'mi_wsl'));
  M.Add(NewLine);
  M.Add(NewItem('&Start',  TextToShortCut('F5'),       False, True, StartShell, 0, 'mi_start'));
  M.Add(NewItem('S&top',   TextToShortCut('Shift+F5'), False, True, StopShell, 0, 'mi_stop'));
  M.Add(NewItem('&Restart',TextToShortCut('Ctrl+R'),   False, True, RestartShell, 0, 'mi_restart'));
  M.Add(NewLine);
  M.Add(NewItem('E&xit',   TextToShortCut('Alt+F4'),   False, True, ExitApp, 0, 'mi_exit'));

  // Edit
  M := TMenuItem.Create(FMenu);
  M.Caption := '&Edit';
  FMenu.Items.Add(M);
  M.Add(NewItem('&Copy',       TextToShortCut('Ctrl+Shift+C'), False, True, CopyClick, 0, 'mi_copy'));
  M.Add(NewItem('&Paste',      TextToShortCut('Ctrl+Shift+V'), False, True, PasteClick, 0, 'mi_paste'));
  M.Add(NewItem('Select &All', TextToShortCut('Ctrl+Shift+A'), False, True, SelectAllClick, 0, 'mi_selall'));

  // View
  M := TMenuItem.Create(FMenu);
  M.Caption := '&View';
  FMenu.Items.Add(M);
  M.Add(NewItem('Scroll to &Top',    TextToShortCut('Ctrl+Home'), False, True, ScrollTopClick, 0, 'mi_top'));
  M.Add(NewItem('Scroll to &Bottom', TextToShortCut('Ctrl+End'),  False, True, ScrollBottomClick, 0, 'mi_bot'));
  M.Add(NewLine);
  M.Add(NewItem('&Clear Scrollback', TextToShortCut('Ctrl+L'),    False, True, ClearScrollbackClick, 0, 'mi_clear'));
  M.Add(NewItem('Soft &Reset',       0, False, True, SoftResetClick, 0, 'mi_reset'));

  // VI / Search
  M := TMenuItem.Create(FMenu);
  M.Caption := '&VI / Search';
  FMenu.Items.Add(M);
  M.Add(NewItem('Toggle &VI Mode', TextToShortCut('Ctrl+Shift+Space'), False, True, ToggleVIClick, 0, 'mi_vi'));
  M.Add(NewLine);
  M.Add(NewItem('&Find...',         TextToShortCut('Ctrl+Shift+F'),    False, True, SearchClick, 0, 'mi_find'));
  M.Add(NewItem('Find &Next',       TextToShortCut('F3'),              False, True, FindNextClick, 0, 'mi_next'));
  M.Add(NewItem('Find &Previous',   TextToShortCut('Shift+F3'),        False, True, FindPrevClick, 0, 'mi_prev'));

  // Tools
  M := TMenuItem.Create(FMenu);
  M.Caption := '&Tools';
  FMenu.Items.Add(M);
  M.Add(NewItem('Send &Hyperlink (OSC 8)', 0, False, True, SendHyperlinkDemoClick, 0, 'mi_hl'));
  M.Add(NewItem('Send &Cursor Style (steady bar)', 0, False, True, SendCursorStyleDemoClick, 0, 'mi_cs'));
  M.Add(NewItem('Send &Title (OSC 0)', 0, False, True, SendTitleDemoClick, 0, 'mi_title'));
  M.Add(NewLine);
  M.Add(NewItem('Show &Child PID', 0, False, True, ShowChildPidClick, 0, 'mi_pid'));
end;

procedure TFormMain.BuildStatusBar;

  function MakeLabel(AParent: TWinControl; ALeft, AWidth: Integer;
    const ATag: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := AParent;
    Result.Left := ALeft;
    Result.Top := 4;
    Result.Width := AWidth;
    Result.Caption := ATag + ': —';
    Result.Hint := ATag;
  end;

begin
  FStatusBar := TPanel.Create(Self);
  FStatusBar.Parent := Self;
  FStatusBar.Align := alBottom;
  FStatusBar.Height := 22;
  FStatusBar.BevelOuter := bvNone;
  FStatusBar.Color := RGB($28, $28, $28);
  FStatusBar.ParentBackground := False;
  FStatusBar.Font.Color := clWhite;

  FStatusPID  := MakeLabel(FStatusBar,   8, 100, 'PID');
  FStatusCwd  := MakeLabel(FStatusBar, 110, 360, 'CWD');
  FStatusMode := MakeLabel(FStatusBar, 470, 200, 'Mode');
  FStatusVI   := MakeLabel(FStatusBar, 670,  80, 'VI');
  FStatusExit := MakeLabel(FStatusBar, 750, 100, 'Exit');
end;

procedure TFormMain.CreateShell;
begin
  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.ShellPath := GetEnvironmentVariable('COMSPEC');
  if FShell.ShellPath = '' then FShell.ShellPath := 'cmd.exe';
  FShell.ShellArgs := '/K "chcp 65001 >nul"';
  FShell.ScrollbackLines := 10000;
  FShell.OnStarted := HandleStarted;
  FShell.OnExit := HandleExit;
  FShell.OnTitleChange := HandleTitle;
  FShell.OnBell := HandleBell;
  FShell.Start;
end;

// ---- File ------------------------------------------------------------

procedure TFormMain.ChooseShellCmd(Sender: TObject);
begin
  if FShell.IsAlive then FShell.Stop(2000);
  FShell.ShellPath := 'cmd.exe';
  FShell.ShellArgs := '/K "chcp 65001 >nul"';
  FShell.Start;
end;

procedure TFormMain.ChooseShellPwsh(Sender: TObject);
begin
  if FShell.IsAlive then FShell.Stop(2000);
  FShell.ShellPath := 'powershell.exe';
  FShell.ShellArgs := '';
  FShell.Start;
end;

procedure TFormMain.ChooseShellWsl(Sender: TObject);
begin
  if FShell.IsAlive then FShell.Stop(2000);
  FShell.ShellPath := 'wsl.exe';
  FShell.ShellArgs := '';
  FShell.Start;
end;

procedure TFormMain.StartShell(Sender: TObject);
begin
  if not FShell.IsAlive then FShell.Start;
end;

procedure TFormMain.StopShell(Sender: TObject);
begin
  if FShell.IsAlive then FShell.Stop;
end;

procedure TFormMain.RestartShell(Sender: TObject);
begin
  FShell.Restart;
end;

procedure TFormMain.ExitApp(Sender: TObject);
begin
  Close;
end;

// ---- Edit ------------------------------------------------------------

procedure TFormMain.CopyClick(Sender: TObject);
begin
  FShell.CopySelection;
end;

procedure TFormMain.PasteClick(Sender: TObject);
var
  LText: string;
begin
  LText := Clipboard.AsText;
  if LText <> '' then FShell.SendText(LText);
end;

procedure TFormMain.SelectAllClick(Sender: TObject);
begin
  // 전체 선택 — Lines 모드로 viewport 모든 행 + 컬럼 0..max 선택.
  FShell.SelectionStart(0, 0, 3);  // kind=Lines
  FShell.SelectionExtend(FShell.GetCols, FShell.GetRows);
end;

// ---- View ------------------------------------------------------------

procedure TFormMain.ScrollTopClick(Sender: TObject);
begin
  FShell.ScrollToTop;
end;

procedure TFormMain.ScrollBottomClick(Sender: TObject);
begin
  FShell.ScrollToBottom;
end;

procedure TFormMain.ClearScrollbackClick(Sender: TObject);
begin
  FShell.ClearHistory;
end;

procedure TFormMain.SoftResetClick(Sender: TObject);
begin
  FShell.SoftReset;
end;

// ---- VI / Search -----------------------------------------------------

procedure TFormMain.ToggleVIClick(Sender: TObject);
begin
  FShell.ToggleViMode;
end;

procedure TFormMain.SearchClick(Sender: TObject);
begin
  FShell.ShowSearchDialog;
end;

procedure TFormMain.FindNextClick(Sender: TObject);
begin
  FShell.SearchAgain(True);
end;

procedure TFormMain.FindPrevClick(Sender: TObject);
begin
  FShell.SearchAgain(False);
end;

// ---- Tools -----------------------------------------------------------

procedure TFormMain.SendHyperlinkDemoClick(Sender: TObject);
begin
  // OSC 8 hyperlink — Ctrl+Click 으로 열림.
  // ESC]8;;https://example.com\7 visible text ESC]8;;\7
  FShell.SendText(#27']8;;https://example.com'#7'click here'#27']8;;'#7#13);
end;

procedure TFormMain.SendCursorStyleDemoClick(Sender: TObject);
begin
  // CSI 6 SP q — steady bar cursor.
  FShell.SendText(#27'[6 q');
end;

procedure TFormMain.SendTitleDemoClick(Sender: TObject);
begin
  // OSC 0 ; title BEL → 폼 caption 갱신.
  FShell.SendText(#27']0;Hello from SCShell demo'#7);
end;

procedure TFormMain.ShowChildPidClick(Sender: TObject);
begin
  ShowMessage(Format('Child PID: %d, Exit code (last): %d',
    [FShell.ChildPid, FShell.CurrentExitCode]));
end;

// ---- Events ----------------------------------------------------------

procedure TFormMain.HandleStarted(ASender: TObject);
begin
  FStatusExit.Caption := 'Exit: —';
end;

procedure TFormMain.HandleExit(ASender: TObject; AExitCode: Integer);
begin
  FStatusExit.Caption := Format('Exit: %d', [AExitCode]);
end;

procedure TFormMain.HandleTitle(ASender: TObject; const ATitle: string);
begin
  if ATitle = '' then
    Caption := 'SCShell — Menu Driven Demo'
  else
    Caption := 'SCShell — ' + ATitle;
end;

procedure TFormMain.HandleBell(ASender: TObject);
begin
  MessageBeep(MB_ICONASTERISK);
end;

procedure TFormMain.DoPollTick(ASender: TObject);
var
  LFlags: UInt32;
  LMode: string;
begin
  if FShell = nil then Exit;
  FStatusPID.Caption := Format('PID: %d', [FShell.ChildPid]);
  var LCwd := FShell.CurrentCwd;
  if LCwd = '' then LCwd := '(unknown)';
  FStatusCwd.Caption := 'CWD: ' + LCwd;

  LFlags := FShell.ModeFlags;
  LMode := '';
  if (LFlags and RATA_MODE_ALT_SCREEN) <> 0          then LMode := LMode + 'ALT ';
  if (LFlags and RATA_MODE_BRACKETED_PASTE) <> 0     then LMode := LMode + 'BP ';
  if (LFlags and RATA_MODE_MOUSE_REPORT_CLICK) <> 0  then LMode := LMode + 'M ';
  if (LFlags and RATA_MODE_MOUSE_DRAG) <> 0          then LMode := LMode + 'Mdrag ';
  if (LFlags and RATA_MODE_MOUSE_MOTION) <> 0        then LMode := LMode + 'Mmotion ';
  if (LFlags and RATA_MODE_SGR_MOUSE) <> 0           then LMode := LMode + 'SGR ';
  if LMode = '' then LMode := '—';
  FStatusMode.Caption := 'Mode: ' + LMode;

  if FShell.ViModeActive then
    FStatusVI.Caption := 'VI: ON'
  else
    FStatusVI.Caption := 'VI: —';
end;

end.
