{ ============================================================================
  SCShell.Ctrl ??TRataShell VCL component (TWinControl).
  ============================================================================ }
unit SCShell.Ctrl;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.Imm,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.UITypes,
  Vcl.Controls,
  Vcl.Graphics,
  Vcl.Forms,
  SCShell,
  SCShell.Painter;

const
  WM_RATA_RENDER = WM_APP + 1;
  WM_RATA_EXIT   = WM_APP + 2;
  WM_RATA_TITLE  = WM_APP + 3;
  WM_RATA_BELL   = WM_APP + 4;

type
  TRataCursorStyle = (csBlock, csUnderline, csBar);

  TRataExitEvent = procedure(Sender: TObject; AExitCode: Integer) of object;
  TRataTitleEvent = procedure(Sender: TObject; const ATitle: string) of object;

  TSCRataShell = class(TWinControl)
  private
    FSession: TRataSession;
    FPainter: TRataPainter;
    FShellPath: string;
    FShellArgs: string;
    FWorkingDir: string;
    FEnvironment: TStrings;
    FAutoStart: Boolean;
    FActive: Boolean;
    FScrollbackLines: Integer;
    FCursorStyle: TRataCursorStyle;
    FCursorBlink: Boolean;
    FReadOnly: Boolean;
    FTitle: string;
    FExitCode: Integer;
    FLastCursorX: Integer;
    FLastCursorY: Integer;
    FComposing: Boolean;
    FPendingTitle: string;
    FTitleLock: TRTLCriticalSection;
    FRenderLock: TRTLCriticalSection;
    FPendingEvent: PRataRenderEvent;
    FPendingBuf: TBytes;
    FOnStarted: TNotifyEvent;
    FOnExit: TRataExitEvent;
    FOnTitleChange: TRataTitleEvent;
    FOnBell: TNotifyEvent;
    procedure SetActive(AValue: Boolean);
    procedure SetEnvironment(AValue: TStrings);
    procedure UpdateCellSize;
    function CalcCols: Integer;
    function CalcRows: Integer;
    procedure ApplyResize;
    procedure HandleRenderMessage;
    procedure ConsumePendingEvent(out AEvent: TRataRenderEvent;
      out ACells: TBytes; out AHasEvent: Boolean);
    procedure StoreRenderEvent(const AEvent: PRataRenderEvent);
    procedure WMPaint(var AMessage: TWMPaint); message WM_PAINT;
    procedure WMSize(var AMessage: TWMSize); message WM_SIZE;
    procedure WMEraseBkgnd(var AMessage: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure WMKeyDown(var AMessage: TWMKeyDown); message WM_KEYDOWN;
    procedure WMSysKeyDown(var AMessage: TWMKeyDown); message WM_SYSKEYDOWN;
    procedure WMChar(var AMessage: TWMChar); message WM_CHAR;
    procedure WMImeChar(var AMessage: TMessage); message WM_IME_CHAR;
    procedure WMImeStartComposition(var AMessage: TMessage); message WM_IME_STARTCOMPOSITION;
    procedure WMImeEndComposition(var AMessage: TMessage); message WM_IME_ENDCOMPOSITION;
    procedure WMImeComposition(var AMessage: TMessage); message WM_IME_COMPOSITION;
    procedure UpdateImeWindow;
    procedure WMSetFocus(var AMessage: TWMSetFocus); message WM_SETFOCUS;
    procedure WMGetDlgCode(var AMessage: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure WMRataRender(var AMessage: TMessage); message WM_RATA_RENDER;
    procedure WMRataExit(var AMessage: TMessage); message WM_RATA_EXIT;
    procedure WMRataTitle(var AMessage: TMessage); message WM_RATA_TITLE;
    procedure WMRataBell(var AMessage: TMessage); message WM_RATA_BELL;
  protected
    procedure CreateParams(var AParams: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DestroyWindowHandle; override;
    procedure Loaded; override;
    procedure Paint; virtual;
    procedure CMFontChanged(var AMessage: TMessage); message CM_FONTCHANGED;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start;
    procedure Stop(ATimeoutMs: Cardinal = 2000);
    procedure Restart;
    procedure SendText(const AText: string);
    procedure SendKey(AVk: Word; AMods: Word);
    function GetCols: Integer;
    function GetRows: Integer;
    function IsAlive: Boolean;
    property Title: string read FTitle;
    property ExitCode: Integer read FExitCode;
  published
    property ShellPath: string read FShellPath write FShellPath;
    property ShellArgs: string read FShellArgs write FShellArgs;
    property WorkingDir: string read FWorkingDir write FWorkingDir;
    property Environment: TStrings read FEnvironment write SetEnvironment;
    property AutoStart: Boolean read FAutoStart write FAutoStart default False;
    property Active: Boolean read FActive write SetActive default False;
    property ScrollbackLines: Integer read FScrollbackLines write FScrollbackLines default 10000;
    property CursorStyle: TRataCursorStyle read FCursorStyle write FCursorStyle default csBlock;
    property CursorBlink: Boolean read FCursorBlink write FCursorBlink default True;
    property ReadOnly: Boolean read FReadOnly write FReadOnly default False;

    property Align;
    property Anchors;
    property TabOrder;
    property TabStop default True;
    property Visible;
    property Font;
    property PopupMenu;

    property OnStarted: TNotifyEvent read FOnStarted write FOnStarted;
    property OnExit: TRataExitEvent read FOnExit write FOnExit;
    property OnTitleChange: TRataTitleEvent read FOnTitleChange write FOnTitleChange;
    property OnBell: TNotifyEvent read FOnBell write FOnBell;
  end;

  TRataShell = TSCRataShell;

implementation

uses
  System.Math,
  System.AnsiStrings;

{ ---- module-level callbacks (cdecl) ----------------------------------- }

procedure RataRenderProc(AUser: Pointer; const AEvent: PRataRenderEvent); cdecl;
var
  LCtrl: TSCRataShell;
begin
  if AUser = nil then
    Exit;
  LCtrl := TSCRataShell(AUser);
  LCtrl.StoreRenderEvent(AEvent);
  if LCtrl.HandleAllocated then
    PostMessage(LCtrl.Handle, WM_RATA_RENDER, 0, 0);
end;

procedure RataExitProc(AUser: Pointer; AExitCode: Integer); cdecl;
var
  LCtrl: TSCRataShell;
begin
  if AUser = nil then
    Exit;
  LCtrl := TSCRataShell(AUser);
  if LCtrl.HandleAllocated then
    PostMessage(LCtrl.Handle, WM_RATA_EXIT, 0, AExitCode);
end;

procedure RataBellProc(AUser: Pointer); cdecl;
var
  LCtrl: TSCRataShell;
begin
  if AUser = nil then
    Exit;
  LCtrl := TSCRataShell(AUser);
  if LCtrl.HandleAllocated then
    PostMessage(LCtrl.Handle, WM_RATA_BELL, 0, 0);
end;

procedure RataTitleProc(AUser: Pointer; AUtf8: PByte; ALen: NativeUInt); cdecl;
var
  LCtrl: TSCRataShell;
  LBuf: TBytes;
  LTitle: string;
begin
  if (AUser = nil) or (AUtf8 = nil) or (ALen = 0) then
    Exit;
  LCtrl := TSCRataShell(AUser);
  SetLength(LBuf, ALen);
  Move(AUtf8^, LBuf[0], ALen);
  LTitle := TEncoding.UTF8.GetString(LBuf);

  EnterCriticalSection(LCtrl.FTitleLock);
  try
    LCtrl.FPendingTitle := LTitle;
  finally
    LeaveCriticalSection(LCtrl.FTitleLock);
  end;

  if LCtrl.HandleAllocated then
    PostMessage(LCtrl.Handle, WM_RATA_TITLE, 0, 0);
end;

{ TSCRataShell }

constructor TSCRataShell.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls, csOpaque, csCaptureMouse,
    csClickEvents, csDoubleClicks];
  Width := 640;
  Height := 384;
  TabStop := True;
  FEnvironment := TStringList.Create;
  FScrollbackLines := 10000;
  FCursorStyle := csBlock;
  FCursorBlink := True;
  FShellPath := '';
  FPainter := TRataPainter.Create;
  InitializeCriticalSection(FRenderLock);
  InitializeCriticalSection(FTitleLock);

  Font.Name := 'Consolas';
  Font.Size := 10;
  Font.Color := $CCCCCC;
  // Force monospace pitch so GDI substitutes a fixed-pitch face if the named
  // font is missing ??without this a proportional fallback can produce
  // visible inter-character gaps even though we force advances via lpDx.
  Font.Pitch := fpFixed;
end;

destructor TSCRataShell.Destroy;
begin
  Stop(0);
  DeleteCriticalSection(FTitleLock);
  DeleteCriticalSection(FRenderLock);
  FPainter.Free;
  FEnvironment.Free;
  inherited;
end;

procedure TSCRataShell.CreateParams(var AParams: TCreateParams);
begin
  inherited CreateParams(AParams);
  AParams.Style := AParams.Style or WS_CLIPCHILDREN;
  AParams.WindowClass.style := AParams.WindowClass.style or CS_OWNDC;
end;

procedure TSCRataShell.CreateWnd;
begin
  inherited;
  UpdateCellSize;
end;

procedure TSCRataShell.DestroyWindowHandle;
begin
  Stop(0);
  inherited;
end;

procedure TSCRataShell.Loaded;
begin
  inherited;
  if FAutoStart and not (csDesigning in ComponentState) then
    Start;
end;

procedure TSCRataShell.SetActive(AValue: Boolean);
begin
  if AValue = FActive then
    Exit;
  if AValue then
    Start
  else
    Stop;
end;

procedure TSCRataShell.SetEnvironment(AValue: TStrings);
begin
  FEnvironment.Assign(AValue);
end;

procedure TSCRataShell.UpdateCellSize;
begin
  FPainter.SetFont(Font);
  ApplyResize;
end;

function TSCRataShell.CalcCols: Integer;
begin
  Result := Max(1, ClientWidth div FPainter.CellW);
end;

function TSCRataShell.CalcRows: Integer;
begin
  Result := Max(1, ClientHeight div FPainter.CellH);
end;

procedure TSCRataShell.ApplyResize;
var
  LCols, LRows: Integer;
begin
  if not HandleAllocated then
    Exit;
  LCols := CalcCols;
  LRows := CalcRows;
  FPainter.Resize(LCols, LRows);
  if (FSession <> nil) and Assigned(rata_session_resize) then
    rata_session_resize(FSession, LCols, LRows);
end;

procedure TSCRataShell.CMFontChanged(var AMessage: TMessage);
begin
  inherited;
  UpdateCellSize;
  Invalidate;
end;

procedure TSCRataShell.WMSize(var AMessage: TWMSize);
begin
  inherited;
  ApplyResize;
end;

procedure TSCRataShell.WMEraseBkgnd(var AMessage: TWMEraseBkgnd);
begin
  AMessage.Result := 1;
end;

procedure TSCRataShell.WMSetFocus(var AMessage: TWMSetFocus);
begin
  inherited;
  // future: cursor blink timer / focus indicator
end;

procedure TSCRataShell.WMPaint(var AMessage: TWMPaint);
begin
  Paint;
end;

procedure TSCRataShell.Paint;
var
  LPS: TPaintStruct;
  LDC: HDC;
  LRect: TRect;
begin
  if not HandleAllocated then
    Exit;

  LDC := BeginPaint(Handle, LPS);
  try
    LRect := ClientRect;
    if (FPainter.BackBuffer.Width = 0) or (FPainter.BackBuffer.Height = 0) then
    begin
      var LBrush := CreateSolidBrush(ColorToRGB(FPainter.Colors.DefaultBg));
      try
        FillRect(LDC, LRect, LBrush);
      finally
        DeleteObject(LBrush);
      end;
    end
    else
    begin
      FPainter.BlitTo(LDC, LRect);
      // Fill any leftover area not covered by cell grid
      var LBufW := FPainter.BackBuffer.Width;
      var LBufH := FPainter.BackBuffer.Height;
      if (LRect.Right > LBufW) or (LRect.Bottom > LBufH) then
      begin
        var LBrush := CreateSolidBrush(ColorToRGB(FPainter.Colors.DefaultBg));
        try
          if LRect.Right > LBufW then
            FillRect(LDC, Rect(LBufW, 0, LRect.Right, LRect.Bottom), LBrush);
          if LRect.Bottom > LBufH then
            FillRect(LDC, Rect(0, LBufH, LRect.Right, LRect.Bottom), LBrush);
        finally
          DeleteObject(LBrush);
        end;
      end;
    end;
  finally
    EndPaint(Handle, LPS);
  end;
end;

procedure TSCRataShell.StoreRenderEvent(const AEvent: PRataRenderEvent);
var
  LCellsBytes: NativeUInt;
  LRectsBytes: NativeUInt;
  LTotal: NativeUInt;
  LBuf: TBytes;
  LDest: PByte;
  LEvCopy: TRataRenderEvent;
begin
  if AEvent = nil then
    Exit;

  LCellsBytes := AEvent.CellsLen * SizeOf(TRataCell);
  LRectsBytes := AEvent.DirtyCount * SizeOf(TRataRect);
  LTotal := SizeOf(TRataRenderEvent) + LCellsBytes + LRectsBytes;

  SetLength(LBuf, LTotal);
  LDest := PByte(@LBuf[0]);
  LEvCopy := AEvent^;

  // Copy cells immediately after the event header.
  if LCellsBytes > 0 then
    Move(AEvent.Cells^, (LDest + SizeOf(TRataRenderEvent))^, LCellsBytes);
  if LRectsBytes > 0 then
    Move(AEvent.DirtyRects^,
      (LDest + SizeOf(TRataRenderEvent) + LCellsBytes)^, LRectsBytes);

  LEvCopy.Cells := PRataCell(LDest + SizeOf(TRataRenderEvent));
  LEvCopy.DirtyRects := PRataRect(LDest + SizeOf(TRataRenderEvent) + LCellsBytes);
  PRataRenderEvent(LDest)^ := LEvCopy;

  EnterCriticalSection(FRenderLock);
  try
    FPendingBuf := LBuf;
    FPendingEvent := PRataRenderEvent(LDest);
  finally
    LeaveCriticalSection(FRenderLock);
  end;
end;

procedure TSCRataShell.ConsumePendingEvent(out AEvent: TRataRenderEvent;
  out ACells: TBytes; out AHasEvent: Boolean);
begin
  AHasEvent := False;
  EnterCriticalSection(FRenderLock);
  try
    if FPendingEvent <> nil then
    begin
      ACells := FPendingBuf;
      AEvent := FPendingEvent^;
      // Adjust pointers to the local copy
      AEvent.Cells := PRataCell(@ACells[SizeOf(TRataRenderEvent)]);
      AEvent.DirtyRects := PRataRect(
        @ACells[SizeOf(TRataRenderEvent) + AEvent.CellsLen * SizeOf(TRataCell)]);
      AHasEvent := True;
      FPendingEvent := nil;
      FPendingBuf := nil;
    end;
  finally
    LeaveCriticalSection(FRenderLock);
  end;
end;

procedure TSCRataShell.HandleRenderMessage;
var
  LEvent: TRataRenderEvent;
  LBuf: TBytes;
  LHas: Boolean;
begin
  ConsumePendingEvent(LEvent, LBuf, LHas);
  if not LHas then
    Exit;

  FPainter.DrawEvent(@LEvent);
  FLastCursorX := LEvent.CursorX;
  FLastCursorY := LEvent.CursorY;
  Invalidate;
end;

procedure TSCRataShell.WMGetDlgCode(var AMessage: TWMGetDlgCode);
begin
  AMessage.Result := DLGC_WANTALLKEYS or DLGC_WANTARROWS or
    DLGC_WANTCHARS or DLGC_WANTTAB;
end;

procedure TSCRataShell.WMRataRender(var AMessage: TMessage);
begin
  HandleRenderMessage;
end;

procedure TSCRataShell.WMRataExit(var AMessage: TMessage);
begin
  FActive := False;
  FExitCode := AMessage.LParam;
  if Assigned(FOnExit) then
    FOnExit(Self, FExitCode);
end;

procedure TSCRataShell.WMRataTitle(var AMessage: TMessage);
begin
  EnterCriticalSection(FTitleLock);
  try
    FTitle := FPendingTitle;
  finally
    LeaveCriticalSection(FTitleLock);
  end;
  if Assigned(FOnTitleChange) then
    FOnTitleChange(Self, FTitle);
end;

procedure TSCRataShell.WMRataBell(var AMessage: TMessage);
begin
  if Assigned(FOnBell) then
    FOnBell(Self);
end;

{ ---- Input ---- }

procedure TSCRataShell.WMKeyDown(var AMessage: TWMKeyDown);
var
  LMods: UInt32;
begin
  if FReadOnly or (FSession = nil) then
    Exit;

  // While IME composition is active, never steal keys: the IME needs Backspace
  // to delete a Jamo, Enter to commit, Escape to cancel, etc.
  if FComposing then
  begin
    inherited;
    Exit;
  end;

  LMods := 0;
  if GetKeyState(VK_SHIFT) and $8000 <> 0 then LMods := LMods or RATA_MOD_SHIFT;
  if GetKeyState(VK_CONTROL) and $8000 <> 0 then LMods := LMods or RATA_MOD_CTRL;
  if GetKeyState(VK_MENU) and $8000 <> 0 then LMods := LMods or RATA_MOD_ALT;

  // Only forward special / combo keys here; printable chars come via WM_CHAR.
  case AMessage.CharCode of
    VK_BACK, VK_TAB, VK_RETURN, VK_ESCAPE,
    VK_PRIOR, VK_NEXT, VK_END, VK_HOME,
    VK_LEFT, VK_UP, VK_RIGHT, VK_DOWN,
    VK_INSERT, VK_DELETE,
    VK_F1..VK_F12:
      begin
        if Assigned(rata_session_send_key) then
          rata_session_send_key(FSession, AMessage.CharCode, LMods);
        AMessage.Result := 0;
        Exit;
      end;
  else
    if (LMods and RATA_MOD_CTRL <> 0)
       and (AMessage.CharCode >= Ord('A')) and (AMessage.CharCode <= Ord('Z')) then
    begin
      if Assigned(rata_session_send_key) then
        rata_session_send_key(FSession, AMessage.CharCode, LMods);
      AMessage.Result := 0;
      Exit;
    end;
  end;

  inherited;
end;

procedure TSCRataShell.WMSysKeyDown(var AMessage: TWMKeyDown);
begin
  WMKeyDown(AMessage);
end;

procedure TSCRataShell.WMChar(var AMessage: TWMChar);
var
  LText: string;
begin
  if FReadOnly or (FSession = nil) then
    Exit;
  // Filter control codes that arrive via WM_CHAR (we already handled them in WM_KEYDOWN).
  if AMessage.CharCode < $20 then
    Exit;

  LText := Char(AMessage.CharCode);
  SendText(LText);
end;

procedure TSCRataShell.WMImeChar(var AMessage: TMessage);
begin
  // Result strings are read explicitly in WMImeComposition (GCS_RESULTSTR);
  // swallow WM_IME_CHAR to avoid double-input. This message is generated by
  // DefWindowProc when our handler doesn't strip GCS_RESULTSTR ??we strip,
  // so this should rarely fire, but we still neutralise it defensively.
  AMessage.Result := 0;
end;

procedure TSCRataShell.UpdateImeWindow;
var
  LImc: HIMC;
  LForm: TCompositionForm;
  LFont: TLogFont;
begin
  if FPainter = nil then
    Exit;
  LImc := ImmGetContext(Handle);
  if LImc = 0 then
    Exit;
  try
    FillChar(LForm, SizeOf(LForm), 0);
    LForm.dwStyle := CFS_FORCE_POSITION;
    LForm.ptCurrentPos.X := FLastCursorX * FPainter.CellW;
    LForm.ptCurrentPos.Y := FLastCursorY * FPainter.CellH;
    ImmSetCompositionWindow(LImc, @LForm);

    // Match composition font to terminal font. Without this the IME draws
    // the half-composed character with its default UI font (typically 12pt
    // Segoe UI), which is visibly larger than the surrounding cells.
    if GetObject(Font.Handle, SizeOf(LFont), @LFont) <> 0 then
      ImmSetCompositionFont(LImc, @LFont);
  finally
    ImmReleaseContext(Handle, LImc);
  end;
end;

function HangulCellWidth(const AText: string): Integer;
var
  LCh: Cardinal;
begin
  // East-Asian wide approximation. Sufficient for IME placement; the next
  // render snapshot from the shell will correct any drift.
  Result := 0;
  for var I := 1 to Length(AText) do
  begin
    LCh := Ord(AText[I]);
    if ((LCh >= $1100) and (LCh <= $115F)) or
       ((LCh >= $2E80) and (LCh <= $303E)) or
       ((LCh >= $3041) and (LCh <= $33FF)) or
       ((LCh >= $3400) and (LCh <= $4DBF)) or
       ((LCh >= $4E00) and (LCh <= $9FFF)) or
       ((LCh >= $A000) and (LCh <= $A4CF)) or
       ((LCh >= $A960) and (LCh <= $A97F)) or
       ((LCh >= $AC00) and (LCh <= $D7A3)) or
       ((LCh >= $F900) and (LCh <= $FAFF)) or
       ((LCh >= $FE30) and (LCh <= $FE4F)) or
       ((LCh >= $FF00) and (LCh <= $FF60)) or
       ((LCh >= $FFE0) and (LCh <= $FFE6)) then
      Inc(Result, 2)
    else
      Inc(Result, 1);
  end;
end;

procedure TSCRataShell.WMImeStartComposition(var AMessage: TMessage);
begin
  FComposing := True;
  UpdateImeWindow;
  inherited;
end;

procedure TSCRataShell.WMImeEndComposition(var AMessage: TMessage);
begin
  FComposing := False;
  inherited;
end;

procedure TSCRataShell.WMImeComposition(var AMessage: TMessage);
var
  LImc: HIMC;
  LBytes: Integer;
  LBuf: TBytes;
  LText: string;
begin
  // 1) Process the committed result first ??this advances FLastCursorX so
  //    the new composition window (set in step 2) lands on the correct cell.
  if (AMessage.LParam and GCS_RESULTSTR) <> 0 then
  begin
    LImc := ImmGetContext(Handle);
    if LImc <> 0 then
    try
      LBytes := ImmGetCompositionStringW(LImc, GCS_RESULTSTR, nil, 0);
      if LBytes > 0 then
      begin
        SetLength(LBuf, LBytes);
        ImmGetCompositionStringW(LImc, GCS_RESULTSTR, @LBuf[0], LBytes);
        SetString(LText, PChar(@LBuf[0]), LBytes div SizeOf(Char));
        if not FReadOnly and (FSession <> nil) then
        begin
          SendText(LText);
          // Predict cursor advance. TUI hosts (e.g. claude) consume input
          // without echoing, so the shell cursor would not advance and the
          // next composition would overlap. The next render snapshot will
          // correct FLastCursorX if the shell does echo.
          Inc(FLastCursorX, HangulCellWidth(LText));
          if (FPainter <> nil) and (FLastCursorX >= FPainter.Cols) then
          begin
            Inc(FLastCursorY);
            FLastCursorX := 0;
          end;
        end;
      end;
      // Strip GCS_RESULTSTR so DefWindowProc doesn't also dispatch WM_IME_CHAR
      // (would duplicate input).
      AMessage.LParam := AMessage.LParam and not GCS_RESULTSTR;
    finally
      ImmReleaseContext(Handle, LImc);
    end;
  end;

  // 2) Anchor the composition window for the (possibly new) composing string.
  if (AMessage.LParam and GCS_COMPSTR) <> 0 then
    UpdateImeWindow;

  inherited;
end;

{ ---- Operations ---- }

procedure TSCRataShell.Start;
var
  LOpts: TRataSpawnOptions;
  LShellPath, LShellArgs, LCwd: UTF8String;
  LEnvBlock: UTF8String;
  LRes: TRataResult;
begin
  if FActive then
    Exit;
  if not RataIsLoaded then
    if not RataLoadLibrary then
      raise Exception.Create('rata_shell.dll could not be loaded');

  FillChar(LOpts, SizeOf(LOpts), 0);
  LShellPath := UTF8Encode(FShellPath);
  LShellArgs := UTF8Encode(FShellArgs);
  LCwd := UTF8Encode(FWorkingDir);

  if Length(LShellPath) > 0 then
  begin
    LOpts.ShellPathUtf8 := PByte(@LShellPath[1]);
    LOpts.ShellPathLen := Length(LShellPath);
  end;
  if Length(LShellArgs) > 0 then
  begin
    LOpts.ShellArgsUtf8 := PByte(@LShellArgs[1]);
    LOpts.ShellArgsLen := Length(LShellArgs);
  end;
  if Length(LCwd) > 0 then
  begin
    LOpts.CwdUtf8 := PByte(@LCwd[1]);
    LOpts.CwdLen := Length(LCwd);
  end;
  if FEnvironment.Count > 0 then
  begin
    var LEnv := '';
    for var I := 0 to FEnvironment.Count - 1 do
      LEnv := LEnv + FEnvironment[I] + #0;
    LEnvBlock := UTF8Encode(LEnv);
    LOpts.EnvUtf8 := PByte(@LEnvBlock[1]);
    LOpts.EnvLen := Length(LEnvBlock);
  end;

  HandleNeeded;

  LOpts.Cols := CalcCols;
  LOpts.Rows := CalcRows;
  LOpts.Scrollback := UInt32(FScrollbackLines);
  FPainter.Resize(LOpts.Cols, LOpts.Rows);

  LRes := rata_session_create(@LOpts, FSession);
  if LRes <> RATA_OK then
    raise Exception.Create('rata_session_create: ' + RataResultText(LRes));

  rata_session_set_callbacks(FSession,
    @RataRenderProc, @RataExitProc, @RataBellProc, @RataTitleProc, Self);

  LRes := rata_session_start(FSession);
  if LRes <> RATA_OK then
  begin
    rata_session_destroy(FSession);
    FSession := nil;
    raise Exception.Create('rata_session_start: ' + RataResultText(LRes));
  end;

  FActive := True;
  if Assigned(FOnStarted) then
    FOnStarted(Self);
end;

procedure TSCRataShell.Stop(ATimeoutMs: Cardinal);
begin
  if FSession = nil then
  begin
    FActive := False;
    Exit;
  end;
  if Assigned(rata_session_terminate) then
    rata_session_terminate(FSession, ATimeoutMs);
  if Assigned(rata_session_destroy) then
    rata_session_destroy(FSession);
  FSession := nil;
  FActive := False;
end;

procedure TSCRataShell.Restart;
begin
  Stop;
  Start;
end;

procedure TSCRataShell.SendText(const AText: string);
var
  LBytes: UTF8String;
begin
  if (FSession = nil) or (AText = '') then
    Exit;
  LBytes := UTF8Encode(AText);
  rata_session_send_text(FSession, PByte(@LBytes[1]), Length(LBytes));
end;

procedure TSCRataShell.SendKey(AVk, AMods: Word);
begin
  if FSession = nil then
    Exit;
  rata_session_send_key(FSession, AVk, AMods);
end;

function TSCRataShell.GetCols: Integer;
var
  LC, LR: UInt16;
begin
  if (FSession = nil) or not Assigned(rata_session_get_size) then
    Exit(0);
  rata_session_get_size(FSession, LC, LR);
  Result := LC;
end;

function TSCRataShell.GetRows: Integer;
var
  LC, LR: UInt16;
begin
  if (FSession = nil) or not Assigned(rata_session_get_size) then
    Exit(0);
  rata_session_get_size(FSession, LC, LR);
  Result := LR;
end;

function TSCRataShell.IsAlive: Boolean;
begin
  Result := (FSession <> nil)
    and Assigned(rata_session_is_alive)
    and (rata_session_is_alive(FSession) <> 0);
end;

end.

