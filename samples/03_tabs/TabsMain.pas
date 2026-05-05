unit TabsMain;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.Menus,
  SCShell.Ctrl;

type
  TFormMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FPageCtrl: TPageControl;
    FToolbar: TPanel;
    FBtnNewCmd: TButton;
    FBtnNewPwsh: TButton;
    FBtnNewWsl: TButton;
    FBtnCloseTab: TButton;

    function NewTab(const AShellPath, AShellArgs, ATabCaption: string): TTabSheet;
    procedure CloseCurrentTab;

    procedure DoNewCmd(ASender: TObject);
    procedure DoNewPwsh(ASender: TObject);
    procedure DoNewWsl(ASender: TObject);
    procedure DoCloseTab(ASender: TObject);
    procedure DoTabTitleChange(ASender: TObject; const ATitle: string);
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 36;
  FToolbar.BevelOuter := bvNone;
  FToolbar.Color := RGB($30, $30, $30);
  FToolbar.ParentBackground := False;

  FBtnNewCmd := TButton.Create(Self);
  FBtnNewCmd.Parent := FToolbar;
  FBtnNewCmd.SetBounds(8, 6, 90, 24);
  FBtnNewCmd.Caption := '+ cmd';
  FBtnNewCmd.OnClick := DoNewCmd;

  FBtnNewPwsh := TButton.Create(Self);
  FBtnNewPwsh.Parent := FToolbar;
  FBtnNewPwsh.SetBounds(102, 6, 110, 24);
  FBtnNewPwsh.Caption := '+ powershell';
  FBtnNewPwsh.OnClick := DoNewPwsh;

  FBtnNewWsl := TButton.Create(Self);
  FBtnNewWsl.Parent := FToolbar;
  FBtnNewWsl.SetBounds(216, 6, 80, 24);
  FBtnNewWsl.Caption := '+ wsl';
  FBtnNewWsl.OnClick := DoNewWsl;

  FBtnCloseTab := TButton.Create(Self);
  FBtnCloseTab.Parent := FToolbar;
  FBtnCloseTab.SetBounds(310, 6, 100, 24);
  FBtnCloseTab.Caption := 'Close Tab (X)';
  FBtnCloseTab.OnClick := DoCloseTab;

  FPageCtrl := TPageControl.Create(Self);
  FPageCtrl.Parent := Self;
  FPageCtrl.Align := alClient;

  // 첫 탭 — cmd.exe
  NewTab('cmd.exe', '/K "chcp 65001 >nul"', 'cmd');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
var
  I: Integer;
  LShell: TSCRataShell;
begin
  // 모든 탭의 셸 명시적 정리 — Stop(2000) 으로 217 회피.
  if FPageCtrl <> nil then
    for I := 0 to FPageCtrl.PageCount - 1 do
    begin
      LShell := FPageCtrl.Pages[I].FindComponent('shell') as TSCRataShell;
      if (LShell <> nil) and LShell.IsAlive then LShell.Stop(2000);
    end;
end;

function TFormMain.NewTab(const AShellPath, AShellArgs, ATabCaption: string): TTabSheet;
var
  LSheet: TTabSheet;
  LShell: TSCRataShell;
begin
  LSheet := TTabSheet.Create(FPageCtrl);
  LSheet.PageControl := FPageCtrl;
  LSheet.Caption := ATabCaption;

  LShell := TSCRataShell.Create(LSheet);
  LShell.Name := 'shell';  // CloseTab 에서 FindComponent 하기 위함.
  LShell.Parent := LSheet;
  LShell.Align := alClient;
  LShell.ShellPath := AShellPath;
  LShell.ShellArgs := AShellArgs;
  LShell.ScrollbackLines := 10000;
  LShell.OnTitleChange := DoTabTitleChange;
  LShell.Tag := NativeInt(LSheet);  // 이벤트에서 탭 식별
  LShell.Start;

  FPageCtrl.ActivePage := LSheet;
  Result := LSheet;
end;

procedure TFormMain.CloseCurrentTab;
var
  LSheet: TTabSheet;
  LShell: TSCRataShell;
begin
  LSheet := FPageCtrl.ActivePage;
  if LSheet = nil then Exit;
  LShell := LSheet.FindComponent('shell') as TSCRataShell;
  if (LShell <> nil) and LShell.IsAlive then
    LShell.Stop(2000);
  LSheet.Free;
end;

procedure TFormMain.DoNewCmd(ASender: TObject);
begin
  NewTab('cmd.exe', '/K "chcp 65001 >nul"', 'cmd');
end;

procedure TFormMain.DoNewPwsh(ASender: TObject);
begin
  NewTab('powershell.exe', '', 'pwsh');
end;

procedure TFormMain.DoNewWsl(ASender: TObject);
begin
  NewTab('wsl.exe', '', 'wsl');
end;

procedure TFormMain.DoCloseTab(ASender: TObject);
begin
  CloseCurrentTab;
end;

procedure TFormMain.DoTabTitleChange(ASender: TObject; const ATitle: string);
var
  LShell: TSCRataShell;
  LSheet: TTabSheet;
begin
  LShell := TSCRataShell(ASender);
  LSheet := TTabSheet(Pointer(LShell.Tag));
  if (LSheet <> nil) and (LSheet.PageControl = FPageCtrl) then
  begin
    if ATitle = '' then
      LSheet.Caption := LShell.ShellPath
    else
      LSheet.Caption := ATitle;
  end;
end;

end.
