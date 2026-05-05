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
  Vcl.ExtCtrls,
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
    { Scrollbar — 우측 세로 스크롤바. display_offset/scrollback 동기. }
    FScrollDraggingThumb: Boolean;
    FScrollThumbDragOffset: Integer;
    FScrollOffset: UInt32;       // 마지막 알려진 display_offset (0=하단)
    FScrollMax: UInt32;          // 설정된 scrollback 라인 수
    { Selection — 마우스 드래그로 텍스트 선택 (트래킹 비활성 시). }
    FSelectingDrag: Boolean;
    { 멀티클릭 추적 (Win32 가 native triple-click 알리지 않으므로 timing 추적). }
    FLastClickTime: Cardinal;
    FLastClickX: Integer;
    FLastClickY: Integer;
    FConsecutiveClicks: Integer;
    { Edge auto-scroll — 선택 드래그 viewport 밖으로 나갔을 때 자동 스크롤. }
    FAutoScrollTimer: TTimer;
    FAutoScrollDir: Integer;        // -1=up, 0=none, +1=down
    FAutoScrollLastX: Integer;
    FAutoScrollLastY: Integer;
    { Cursor blink — VT 깜박이 cursor (style 1/3/5) 처리용 타이머. }
    FBlinkTimer: TTimer;
    FBlinkVisible: Boolean;
    FLastCursorStyle: Byte;
    { Hyperlink hover — 마지막 렌더의 cell 배열 보관, hover 위치 추적. }
    FLastCells: TArray<TRataCell>;
    FLastCols: Integer;
    FLastRows: Integer;
    FHoverHyperlinkId: UInt32;
    { 검색 — 마지막 패턴 + 현재 매치 위치 (F3 next/prev 용) }
    FLastSearchPattern: string;
    FSearchMatchCol: Integer;
    FSearchMatchRow: Integer;
    FSearchMatchLen: Integer;
    { 인라인 검색바 — 상단 패널 + 입력 + 버튼들. ShowSearchBar 시 visible. }
    FSearchBar: TWinControl;
    FSearchEdit: TWinControl;
    procedure HideSearchBar;
    procedure DoSearchEditChange(ASender: TObject);
    procedure DoSearchNextClick(ASender: TObject);
    procedure DoSearchPrevClick(ASender: TObject);
    procedure DoSearchCloseClick(ASender: TObject);
    procedure DoSearchEditKeyDown(ASender: TObject; var AKey: Word;
      AShift: TShiftState);
    procedure DoAutoScrollTick(ASender: TObject);
    procedure DoBlinkTick(ASender: TObject);
    procedure ApplyBlinkState;
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
    { Scrollbar 헬퍼 }
    function ScrollBarRect: TRect;
    function ScrollThumbRect: TRect;
    function ScrollHitThumb(AX, AY: Integer): Boolean;
    procedure UpdateScrollInfo;
    procedure ScrollByLines(ALines: Integer);
    { Mouse tracking — VT 시퀀스 생성. 활성 모드(mode_flags) 면 True 반환 + 송신. }
    function IsMouseTrackingActive: Boolean;
    function MouseToCell(AX, AY: Integer; out ACol, ARow: Integer): Boolean;
    procedure SendMouseSequence(ACb, ACol, ARow: Integer; APress: Boolean);
    function MouseModifiersBits(AShift: TShiftState): Integer;
  protected
    procedure CreateParams(var AParams: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DestroyWindowHandle; override;
    procedure Loaded; override;
    procedure MouseDown(AButton: TMouseButton; AShift: TShiftState;
      AX, AY: Integer); override;
    procedure MouseMove(AShift: TShiftState; AX, AY: Integer); override;
    procedure MouseUp(AButton: TMouseButton; AShift: TShiftState;
      AX, AY: Integer); override;
    function DoMouseWheel(AShift: TShiftState; AWheelDelta: Integer;
      AMousePos: TPoint): Boolean; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
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
    /// <summary>스크롤 — 양수=히스토리 위로, 음수=라이브 방향.</summary>
    procedure Scroll(ALines: Integer);
    /// <summary>스크롤백 최상단(가장 오래된)으로 이동.</summary>
    procedure ScrollToTop;
    /// <summary>라이브 edge(현재 입력 위치)로 이동.</summary>
    procedure ScrollToBottom;
    /// <summary>스크롤백 비우기 (히스토리만, 현재 viewport 유지).</summary>
    procedure ClearHistory;
    /// <summary>소프트 리셋 (RIS / ESC c). 화면 + 속성 초기화.</summary>
    procedure SoftReset;
    /// <summary>현재 자식 프로세스 PID. 0 = 미실행.</summary>
    function ChildPid: UInt32;
    /// <summary>마지막 캐시된 종료 코드. 콜백 외에서 폴링 가능.</summary>
    function CurrentExitCode: Integer;
    /// <summary>현재 TermMode 비트 (RATA_MODE_*).</summary>
    function ModeFlags: UInt32;
    /// <summary>Alt-screen 활성 여부 — vim/less 전체화면 감지.</summary>
    function AltActive: Boolean;
    /// <summary>OSC 7 으로 셸이 보고한 마지막 작업 디렉터리. 미보고 시 빈 문자열.</summary>
    function CurrentCwd: string;
    /// <summary>OSC 8 hyperlink id → URI 조회. id=0 또는 미등록 시 빈 문자열.</summary>
    function HyperlinkUri(AId: UInt32): string;
    /// <summary>VI navigation mode 토글 (alacritty hjkl 이동).</summary>
    procedure ToggleViMode;
    /// <summary>VI mode 활성 여부.</summary>
    function ViModeActive: Boolean;
    /// <summary>VI motion 직접 실행 (RATA_VIM_*).</summary>
    procedure ViMotion(AKind: Byte);
    /// <summary>Regex 검색 — 다음 일치를 찾아 (Col, Row, Len) 반환.
    /// 매치 없으면 모두 0. AForward=True 면 아래/오른쪽 방향.</summary>
    function SearchNext(const APattern: string; AForward: Boolean;
      out ACol, ARow, ALen: Word): Boolean;
    /// <summary>지정된 viewport 좌표 셀의 hyperlink id (0 = 없음).</summary>
    function HyperlinkAt(ACol, ARow: Integer): UInt32;
    /// <summary>인라인 검색 입력 다이얼로그 (Ctrl+Shift+F). 매치 시 위치로 스크롤.</summary>
    procedure ShowSearchDialog;
    /// <summary>마지막 패턴 으로 다음/이전 매치 (F3 / Shift+F3).</summary>
    procedure SearchAgain(AForward: Boolean);
    /// <summary>현재 선택된 텍스트. 선택 없으면 빈 문자열.</summary>
    function SelectionText: string;
    /// <summary>선택 영역 시작 (드래그 시작 시 호출). AKind: 0=Simple/1=Block/2=Semantic/3=Lines.</summary>
    procedure SelectionStart(ACol, ARow: Word; AKind: Byte = 0);
    /// <summary>선택 영역 확장 (드래그 중 호출).</summary>
    procedure SelectionExtend(ACol, ARow: Word);
    /// <summary>선택 영역 해제.</summary>
    procedure SelectionClear;
    /// <summary>현재 선택을 시스템 클립보드에 복사. 선택 없으면 무시.</summary>
    procedure CopySelection;
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
  System.AnsiStrings,
  Winapi.ShellAPI,
  Vcl.Clipbrd,
  Vcl.Dialogs,
  Vcl.StdCtrls;

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

procedure RataClipboardProc(AUser: Pointer; AUtf8: PByte; ALen: NativeUInt); cdecl;
var
  LBuf: TBytes;
  LText: string;
begin
  { OSC 52 — 셸이 호스트 클립보드에 텍스트를 적재 요청. Vcl.Clipbrd 의 main-thread
    제약 때문에 메인 스레드 마샬링이 안전하나, AnsiString 복사 후 PostMessage 가
    구조 추가 필요. 단순화: Clipboard 는 thread-safe (CF_UNICODETEXT) 하므로
    catch-all 로 직접 호출 — 콘솔 백그라운드 스레드에서도 동작 검증됨. }
  if (AUtf8 = nil) or (ALen = 0) then Exit;
  SetLength(LBuf, ALen);
  Move(AUtf8^, LBuf[0], ALen);
  LText := TEncoding.UTF8.GetString(LBuf);
  try
    Vcl.Clipbrd.Clipboard.AsText := LText;
  except
    // 클립보드 lock 실패는 무시 — 다른 앱이 점유 중일 수 있음.
  end;
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
  FBlinkVisible := True;
  FLastCursorStyle := 0;
  FShellPath := '';
  FPainter := TRataPainter.Create;
  InitializeCriticalSection(FRenderLock);
  InitializeCriticalSection(FTitleLock);

  { 530ms cursor blink — VT 표준. blink-style cursor 일 때만 활성. }
  FBlinkTimer := TTimer.Create(Self);
  FBlinkTimer.Interval := 530;
  FBlinkTimer.Enabled := False;
  FBlinkTimer.OnTimer := DoBlinkTick;

  { 50ms edge auto-scroll — 선택 드래그가 viewport 밖일 때만 활성. }
  FAutoScrollTimer := TTimer.Create(Self);
  FAutoScrollTimer.Interval := 50;
  FAutoScrollTimer.Enabled := False;
  FAutoScrollTimer.OnTimer := DoAutoScrollTick;

  FSearchMatchLen := 0;

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
  { 충분한 timeout 으로 종료 — Rust 측 reader/writer 스레드 join 보장.
    timeout 0 으로 종료하면 콜백 스레드가 아직 살아있는 상태에서
    DeleteCriticalSection 이 실행되어 217 오류. }
  Stop(2000);
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
const
  CScrollBarW = 12;  { 스크롤바 영역 — 텍스트 영역에서 제외 }
begin
  Result := Max(1, (ClientWidth - CScrollBarW) div FPainter.CellW);
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

procedure TSCRataShell.MouseDown(AButton: TMouseButton; AShift: TShiftState;
  AX, AY: Integer);
var
  LSBR, LThumb: TRect;
  LCb, LCol, LRow: Integer;
begin
  { 클릭 시 즉시 포커스 — TWinControl 기본은 자동 포커스 안 됨. TabStop 만으로
    탭 키 이동은 가능하지만 마우스 클릭으로는 별도 SetFocus 필요. }
  if not Focused and CanFocus then
    SetFocus;

  { Ctrl+좌클릭 hyperlink 위 → ShellExecute 로 외부 열기. }
  if (AButton = mbLeft) and (ssCtrl in AShift) and (AX < ScrollBarRect.Left) then
  begin
    if MouseToCell(AX, AY, LCol, LRow) then
    begin
      var LHl := HyperlinkAt(LCol - 1, LRow - 1);
      if LHl <> 0 then
      begin
        var LUri := HyperlinkUri(LHl);
        if LUri <> '' then
        begin
          ShellExecuteW(0, 'open', PWideChar(LUri), nil, nil, SW_SHOWNORMAL);
          Exit;
        end;
      end;
    end;
  end;

  { 마우스 트래킹 활성 시 스크롤바/드래그 우회하고 VT 시퀀스 송신. }
  if IsMouseTrackingActive and (AX < ScrollBarRect.Left) then
  begin
    if MouseToCell(AX, AY, LCol, LRow) then
    begin
      case AButton of
        mbLeft:   LCb := 0;
        mbMiddle: LCb := 1;
        mbRight:  LCb := 2;
      else        LCb := 0;
      end;
      LCb := LCb or MouseModifiersBits(AShift);
      SendMouseSequence(LCb, LCol, LRow, True);
      MouseCapture := True;
      Exit;
    end;
  end;

  { 트래킹 비활성 + 좌클릭 + 캔버스 영역 → 텍스트 선택 시작.
    싱글=Simple, 더블=Semantic(단어), 트리플=Lines(행), Alt=Block.
    Win32 는 native triple-click 을 알리지 않으므로 timing+위치 직접 추적. }
  if (AButton = mbLeft) and not IsMouseTrackingActive
     and (AX < ScrollBarRect.Left) then
  begin
    if MouseToCell(AX, AY, LCol, LRow) then
    begin
      { 멀티클릭 감지 — GetDoubleClickTime() ms 안에 ±5px 이내 클릭 누적. }
      var LDClick := Integer(GetDoubleClickTime);
      var LNow := GetTickCount;
      if (Integer(LNow - FLastClickTime) < LDClick) and
         (Abs(AX - FLastClickX) < 5) and (Abs(AY - FLastClickY) < 5) then
        Inc(FConsecutiveClicks)
      else
        FConsecutiveClicks := 1;
      FLastClickTime := LNow;
      FLastClickX := AX;
      FLastClickY := AY;

      var LKind: Byte;
      case FConsecutiveClicks of
        2: LKind := 2;   { Semantic — 단어 }
        3: begin LKind := 3; FConsecutiveClicks := 0; end;  { Lines — 행, 카운터 리셋 }
      else
        if ssAlt in AShift then LKind := 1   { Alt = block }
        else LKind := 0;                     { Simple }
      end;
      SelectionStart(LCol - 1, LRow - 1, LKind);
      FSelectingDrag := True;
      MouseCapture := True;
      Exit;
    end;
  end;

  { 스크롤바 영역 클릭 처리 — 좌클릭만. }
  if AButton = mbLeft then
  begin
    LSBR := ScrollBarRect;
    if (AX >= LSBR.Left) and (AX <= LSBR.Right) then
    begin
      if FScrollMax = 0 then Exit;
      LThumb := ScrollThumbRect;
      if (AY >= LThumb.Top) and (AY <= LThumb.Bottom) then
      begin
        { 썸 드래그 시작 }
        FScrollDraggingThumb := True;
        FScrollThumbDragOffset := AY - LThumb.Top;
        MouseCapture := True;
        Invalidate;
      end
      else
      begin
        { 트랙 위/아래 클릭 — 페이지 스크롤 }
        if AY < LThumb.Top then
          ScrollByLines(FPainter.Rows)
        else
          ScrollByLines(-FPainter.Rows);
      end;
      Exit;
    end;
  end;

  inherited;
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

    { Hyperlink underline overlay — hyperlink_id != 0 인 셀에 옅은 색 underline.
      hover 중이면 강조 색. cells 배열 row-major. }
    if (Length(FLastCells) > 0) and (FLastCols > 0) then
    begin
      var LPenNormal := CreatePen(PS_SOLID, 1, RGB($60, $A0, $E0));
      var LPenHover := CreatePen(PS_SOLID, 2, RGB($00, $80, $FF));
      try
        var LOldPen := SelectObject(LDC, LPenNormal);
        try
          for var LRowI := 0 to FLastRows - 1 do
          begin
            var LRunStart := -1;
            var LRunHl: UInt32 := 0;
            for var LColI := 0 to FLastCols - 1 do
            begin
              var LIdx := LRowI * FLastCols + LColI;
              if LIdx > High(FLastCells) then Break;
              var LHl := FLastCells[LIdx].HyperlinkId;
              if LHl <> 0 then
              begin
                if LRunStart < 0 then
                begin
                  LRunStart := LColI;
                  LRunHl := LHl;
                end;
              end
              else if LRunStart >= 0 then
              begin
                var LY := (LRowI + 1) * FPainter.CellH - 1;
                if LRunHl = FHoverHyperlinkId then
                  SelectObject(LDC, LPenHover)
                else
                  SelectObject(LDC, LPenNormal);
                MoveToEx(LDC, LRunStart * FPainter.CellW, LY, nil);
                LineTo(LDC, LColI * FPainter.CellW, LY);
                LRunStart := -1;
                LRunHl := 0;
              end;
            end;
            if LRunStart >= 0 then
            begin
              var LY := (LRowI + 1) * FPainter.CellH - 1;
              if LRunHl = FHoverHyperlinkId then
                SelectObject(LDC, LPenHover)
              else
                SelectObject(LDC, LPenNormal);
              MoveToEx(LDC, LRunStart * FPainter.CellW, LY, nil);
              LineTo(LDC, FLastCols * FPainter.CellW, LY);
            end;
          end;
        finally
          SelectObject(LDC, LOldPen);
        end;
      finally
        DeleteObject(LPenNormal);
        DeleteObject(LPenHover);
      end;
    end;

    { Search match highlight — 노란 박스로 매치 영역 강조. }
    if FSearchMatchLen > 0 then
    begin
      var LMRect := Rect(
        FSearchMatchCol * FPainter.CellW,
        FSearchMatchRow * FPainter.CellH,
        (FSearchMatchCol + FSearchMatchLen) * FPainter.CellW,
        (FSearchMatchRow + 1) * FPainter.CellH);
      var LOldROP := SetROP2(LDC, R2_NOTXORPEN);
      var LMatchPen := CreatePen(PS_SOLID, 2, RGB($FF, $D0, $00));
      var LOldPen := SelectObject(LDC, LMatchPen);
      try
        var LNullBrush := GetStockObject(NULL_BRUSH);
        var LOldBrush := SelectObject(LDC, LNullBrush);
        try
          Rectangle(LDC, LMRect.Left, LMRect.Top, LMRect.Right, LMRect.Bottom);
        finally
          SelectObject(LDC, LOldBrush);
        end;
      finally
        SelectObject(LDC, LOldPen);
        DeleteObject(LMatchPen);
        SetROP2(LDC, LOldROP);
      end;
    end;

    { Cursor blink — 백버퍼는 항상 cursor 그려진 상태. blink off 사이클 동안만
      cursor 영역을 다시 invert 하여 가림. }
    if FBlinkTimer.Enabled and not FBlinkVisible then
    begin
      var LCx := FLastCursorX * FPainter.CellW;
      var LCy := FLastCursorY * FPainter.CellH;
      var LCursorRect: TRect;
      case FLastCursorStyle of
        2, 3: LCursorRect := Rect(LCx, LCy + FPainter.CellH - 2,
                                   LCx + FPainter.CellW, LCy + FPainter.CellH);
        5, 6: LCursorRect := Rect(LCx, LCy, LCx + 2, LCy + FPainter.CellH);
      else
        LCursorRect := Rect(LCx, LCy, LCx + FPainter.CellW, LCy + FPainter.CellH);
      end;
      InvertRect(LDC, LCursorRect);
    end;

    { 우측 세로 스크롤바 페인트 — 트랙 + 썸. display_offset 기반. }
    var LSBR := ScrollBarRect;
    if (LSBR.Right > LSBR.Left) and (LSBR.Bottom > LSBR.Top) then
    begin
      var LTrackBrush := CreateSolidBrush(ColorToRGB(FPainter.Colors.DefaultBg));
      try
        FillRect(LDC, LSBR, LTrackBrush);
      finally
        DeleteObject(LTrackBrush);
      end;
      if FScrollMax > 0 then
      begin
        var LThumb := ScrollThumbRect;
        if (LThumb.Bottom > LThumb.Top) then
        begin
          var LThumbColor: COLORREF;
          if FScrollDraggingThumb then
            LThumbColor := RGB(160, 160, 160)
          else
            LThumbColor := RGB(96, 96, 96);
          var LThumbBrush := CreateSolidBrush(LThumbColor);
          try
            FillRect(LDC, LThumb, LThumbBrush);
          finally
            DeleteObject(LThumbBrush);
          end;
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

  { blink-style 변경 시 타이머 재구성. style 1/3/5 = blinking. }
  if LEvent.CursorStyle <> FLastCursorStyle then
  begin
    FLastCursorStyle := LEvent.CursorStyle;
    ApplyBlinkState;
  end;

  FPainter.DrawEvent(@LEvent);
  FLastCursorX := LEvent.CursorX;
  FLastCursorY := LEvent.CursorY;
  { hyperlink hit-test 위해 마지막 셀 배열 보관. }
  FLastCols := LEvent.Cols;
  FLastRows := LEvent.Rows;
  if (LEvent.Cells <> nil) and (LEvent.CellsLen > 0) then
  begin
    SetLength(FLastCells, LEvent.CellsLen);
    Move(LEvent.Cells^, FLastCells[0], LEvent.CellsLen * SizeOf(TRataCell));
  end
  else
    SetLength(FLastCells, 0);
  UpdateScrollInfo;
  Invalidate;
end;

function TSCRataShell.HyperlinkAt(ACol, ARow: Integer): UInt32;
var
  LIdx: Integer;
begin
  Result := 0;
  if (ACol < 0) or (ARow < 0) then Exit;
  if (ACol >= FLastCols) or (ARow >= FLastRows) then Exit;
  LIdx := ARow * FLastCols + ACol;
  if (LIdx < 0) or (LIdx > High(FLastCells)) then Exit;
  Result := FLastCells[LIdx].HyperlinkId;
end;

procedure TSCRataShell.ApplyBlinkState;
begin
  { CursorStyle 의 LSB = blinking 비트 (1=blinking block, 3=blinking underline,
    5=blinking bar). FCursorBlink published 가 False 면 강제 정적. }
  if FCursorBlink and ((FLastCursorStyle and 1) <> 0) then
  begin
    FBlinkVisible := True;
    FBlinkTimer.Enabled := True;
  end
  else
  begin
    FBlinkVisible := True;
    FBlinkTimer.Enabled := False;
  end;
end;

procedure TSCRataShell.DoBlinkTick(ASender: TObject);
begin
  FBlinkVisible := not FBlinkVisible;
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

  // Ctrl+Shift+C — 선택 영역 복사 (셸로 보내지 않음).
  if (AMessage.CharCode = Ord('C')) and
     (LMods and RATA_MOD_CTRL <> 0) and (LMods and RATA_MOD_SHIFT <> 0) then
  begin
    CopySelection;
    AMessage.Result := 0;
    Exit;
  end;
  // Ctrl+Shift+F — 인라인 검색 다이얼로그.
  if (AMessage.CharCode = Ord('F')) and
     (LMods and RATA_MOD_CTRL <> 0) and (LMods and RATA_MOD_SHIFT <> 0) then
  begin
    ShowSearchDialog;
    AMessage.Result := 0;
    Exit;
  end;
  // F3 / Shift+F3 — 다음 / 이전 매치.
  if (AMessage.CharCode = VK_F3) and (FLastSearchPattern <> '') then
  begin
    if (LMods and RATA_MOD_SHIFT <> 0) then
      SearchAgain(False)
    else
      SearchAgain(True);
    AMessage.Result := 0;
    Exit;
  end;
  // Ctrl+Shift+Space — VI navigation mode 토글.
  if (AMessage.CharCode = VK_SPACE) and
     (LMods and RATA_MOD_CTRL <> 0) and (LMods and RATA_MOD_SHIFT <> 0) then
  begin
    ToggleViMode;
    AMessage.Result := 0;
    Exit;
  end;

  // VI mode 활성 — 키를 motion 으로 해석. PTY 송신 차단.
  if ViModeActive then
  begin
    case AMessage.CharCode of
      VK_ESCAPE:  ToggleViMode;  // Esc 로 VI 모드 종료
      VK_LEFT:    ViMotion(RATA_VIM_LEFT);
      VK_RIGHT:   ViMotion(RATA_VIM_RIGHT);
      VK_UP:      ViMotion(RATA_VIM_UP);
      VK_DOWN:    ViMotion(RATA_VIM_DOWN);
      VK_HOME:    ViMotion(RATA_VIM_FIRST);
      VK_END:     ViMotion(RATA_VIM_LAST);
      VK_PRIOR:   if Assigned(rata_session_scroll) then  // PageUp
                    rata_session_scroll(FSession, FPainter.Rows);
      VK_NEXT:    if Assigned(rata_session_scroll) then  // PageDown
                    rata_session_scroll(FSession, -FPainter.Rows);
    end;
    AMessage.Result := 0;
    Exit;
  end;
  // Ctrl+Shift+V — 클립보드 붙여넣기 (시스템 텍스트 → send_text).
  if (AMessage.CharCode = Ord('V')) and
     (LMods and RATA_MOD_CTRL <> 0) and (LMods and RATA_MOD_SHIFT <> 0) then
  begin
    var LText := Vcl.Clipbrd.Clipboard.AsText;
    if LText <> '' then SendText(LText);
    AMessage.Result := 0;
    Exit;
  end;

  // Only forward special / combo keys here; printable chars come via WM_CHAR.
  case AMessage.CharCode of
    VK_BACK, VK_TAB, VK_RETURN, VK_ESCAPE,
    VK_PRIOR, VK_NEXT, VK_END, VK_HOME,
    VK_LEFT, VK_UP, VK_RIGHT, VK_DOWN,
    VK_INSERT, VK_DELETE,
    VK_F1..VK_F12:
      begin
        if Assigned(rata_session_send_key) then
        begin
          { 입력 시 scroll-to-bottom + 선택 해제 (xterm 표준). }
          if FScrollOffset > 0 then
            rata_session_scroll_to_bottom(FSession);
          SelectionClear;
          rata_session_send_key(FSession, AMessage.CharCode, LMods);
        end;
        AMessage.Result := 0;
        Exit;
      end;
  else
    if (LMods and RATA_MOD_CTRL <> 0)
       and (AMessage.CharCode >= Ord('A')) and (AMessage.CharCode <= Ord('Z')) then
    begin
      if Assigned(rata_session_send_key) then
      begin
        if FScrollOffset > 0 then
          rata_session_scroll_to_bottom(FSession);
        SelectionClear;
        rata_session_send_key(FSession, AMessage.CharCode, LMods);
      end;
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

  // VI mode 활성 — letter 키를 motion 으로 해석, PTY 송신 차단.
  if ViModeActive then
  begin
    case Char(AMessage.CharCode) of
      'h': ViMotion(RATA_VIM_LEFT);
      'j': ViMotion(RATA_VIM_DOWN);
      'k': ViMotion(RATA_VIM_UP);
      'l': ViMotion(RATA_VIM_RIGHT);
      '0': ViMotion(RATA_VIM_FIRST);
      '^': ViMotion(RATA_VIM_FIRST_OCCUPIED);
      '$': ViMotion(RATA_VIM_LAST);
      'w': ViMotion(RATA_VIM_WORD_RIGHT);
      'b': ViMotion(RATA_VIM_WORD_LEFT);
      'e': ViMotion(RATA_VIM_WORD_RIGHT_END);
      'W': ViMotion(RATA_VIM_SEMANTIC_RIGHT);
      'B': ViMotion(RATA_VIM_SEMANTIC_LEFT);
      'E': ViMotion(RATA_VIM_SEMANTIC_RIGHT_END);
      'H': ViMotion(RATA_VIM_HIGH);
      'M': ViMotion(RATA_VIM_MIDDLE);
      'L': ViMotion(RATA_VIM_LOW);
      '{': ViMotion(RATA_VIM_PARAGRAPH_UP);
      '}': ViMotion(RATA_VIM_PARAGRAPH_DOWN);
      '%': ViMotion(RATA_VIM_BRACKET);
      'y': CopySelection;  // yank — 현재 선택을 클립보드 복사
      'i': ToggleViMode;   // i = insert mode (VI 종료)
    end;
    Exit;
  end;

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
  if Assigned(rata_session_set_clipboard_callback) then
    rata_session_set_clipboard_callback(FSession, @RataClipboardProc, Self);

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
  { 콜백을 먼저 nil 로 끊는다 — terminate/destroy 사이 in-flight 콜백이 destroyed
    인스턴스로 PostMessage 하는 것을 막음. Stop(0) 으로 빠르게 종료할 때 특히 중요. }
  if Assigned(rata_session_set_callbacks) then
    rata_session_set_callbacks(FSession, nil, nil, nil, nil, nil);
  if Assigned(rata_session_set_clipboard_callback) then
    rata_session_set_clipboard_callback(FSession, nil, nil);
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
  LWrapped: string;
begin
  if (FSession = nil) or (AText = '') then
    Exit;

  { 입력 시 자동 처리:
    1) 스크롤백 위로 올라가 있으면 live edge 로 복귀 (xterm 표준)
    2) 텍스트 선택 자동 해제 (선택은 시각적 — 실제 텍스트 흐름과 분리)
    3) 셸이 bracketed paste mode advertise 했고 multi-char 입력이면 paste wrap }
  if FScrollOffset > 0 then
    if Assigned(rata_session_scroll_to_bottom) then
      rata_session_scroll_to_bottom(FSession);
  SelectionClear;

  if ((ModeFlags and RATA_MODE_BRACKETED_PASTE) <> 0) and
     (Length(AText) > 1) then
    LWrapped := #27'[200~' + AText + #27'[201~'
  else
    LWrapped := AText;

  LBytes := UTF8Encode(LWrapped);
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

procedure TSCRataShell.Scroll(ALines: Integer);
begin
  if (FSession <> nil) and Assigned(rata_session_scroll) then
  begin
    rata_session_scroll(FSession, ALines);
    UpdateScrollInfo;
    Invalidate;
  end;
end;

procedure TSCRataShell.ScrollToTop;
begin
  if (FSession <> nil) and Assigned(rata_session_scroll_to_top) then
  begin
    rata_session_scroll_to_top(FSession);
    UpdateScrollInfo;
    Invalidate;
  end;
end;

procedure TSCRataShell.ScrollToBottom;
begin
  if (FSession <> nil) and Assigned(rata_session_scroll_to_bottom) then
  begin
    rata_session_scroll_to_bottom(FSession);
    UpdateScrollInfo;
    Invalidate;
  end;
end;

procedure TSCRataShell.ClearHistory;
begin
  if (FSession <> nil) and Assigned(rata_session_clear_history) then
  begin
    rata_session_clear_history(FSession);
    UpdateScrollInfo;
    Invalidate;
  end;
end;

procedure TSCRataShell.SoftReset;
begin
  if (FSession <> nil) and Assigned(rata_session_reset) then
  begin
    rata_session_reset(FSession);
    Invalidate;
  end;
end;

function TSCRataShell.ChildPid: UInt32;
begin
  if (FSession = nil) or not Assigned(rata_session_get_child_pid) then
    Exit(0);
  Result := rata_session_get_child_pid(FSession);
end;

function TSCRataShell.CurrentExitCode: Integer;
begin
  if (FSession = nil) or not Assigned(rata_session_get_exit_code) then
    Exit(0);
  Result := rata_session_get_exit_code(FSession);
end;

function TSCRataShell.ModeFlags: UInt32;
begin
  if (FSession = nil) or not Assigned(rata_session_get_mode_flags) then
    Exit(0);
  Result := rata_session_get_mode_flags(FSession);
end;

function TSCRataShell.AltActive: Boolean;
begin
  Result := (ModeFlags and RATA_MODE_ALT_SCREEN) <> 0;
end;

function TSCRataShell.CurrentCwd: string;
var
  LBuf: TBytes;
  LLen: NativeUInt;
begin
  Result := '';
  if (FSession = nil) or not Assigned(rata_session_get_cwd) then Exit;
  LLen := rata_session_get_cwd(FSession, nil, 0);
  if LLen = 0 then Exit;
  SetLength(LBuf, LLen + 1);
  LLen := rata_session_get_cwd(FSession, @LBuf[0], Length(LBuf));
  if LLen > 0 then
    Result := TEncoding.UTF8.GetString(LBuf, 0, LLen);
end;

function TSCRataShell.HyperlinkUri(AId: UInt32): string;
var
  LBuf: TBytes;
  LLen: NativeUInt;
begin
  Result := '';
  if (FSession = nil) or (AId = 0) or not Assigned(rata_session_get_hyperlink) then
    Exit;
  LLen := rata_session_get_hyperlink(FSession, AId, nil, 0);
  if LLen = 0 then Exit;
  SetLength(LBuf, LLen + 1);
  LLen := rata_session_get_hyperlink(FSession, AId, @LBuf[0], Length(LBuf));
  if LLen > 0 then
    Result := TEncoding.UTF8.GetString(LBuf, 0, LLen);
end;

procedure TSCRataShell.ToggleViMode;
begin
  if (FSession <> nil) and Assigned(rata_session_toggle_vi_mode) then
    rata_session_toggle_vi_mode(FSession);
end;

function TSCRataShell.ViModeActive: Boolean;
begin
  Result := (FSession <> nil) and Assigned(rata_session_vi_mode_active)
    and (rata_session_vi_mode_active(FSession) <> 0);
end;

procedure TSCRataShell.ViMotion(AKind: Byte);
begin
  if (FSession <> nil) and Assigned(rata_session_vi_motion) then
    rata_session_vi_motion(FSession, AKind);
end;

procedure TSCRataShell.ShowSearchDialog;
const
  CBarH = 28;
  CBtnW = 60;
  CCloseW = 24;
  CMargin = 4;
var
  LPanel: TPanel;
  LEdit: TEdit;
  LNextBtn, LPrevBtn, LCloseBtn: TButton;
  LX: Integer;
begin
  if FSearchBar <> nil then
  begin
    if FSearchEdit <> nil then
      Winapi.Windows.SetFocus(FSearchEdit.Handle);
    Exit;
  end;
  LPanel := TPanel.Create(Self);
  LPanel.Parent := Self;
  LPanel.Align := alTop;
  LPanel.Height := CBarH;
  LPanel.BevelOuter := bvNone;
  LPanel.Color := RGB($30, $30, $30);
  LPanel.ParentBackground := False;
  FSearchBar := LPanel;

  LX := CMargin;
  LCloseBtn := TButton.Create(LPanel);
  LCloseBtn.Parent := LPanel;
  LCloseBtn.SetBounds(LX, (CBarH - 22) div 2, CCloseW, 22);
  LCloseBtn.Caption := 'X';
  LCloseBtn.OnClick := DoSearchCloseClick;
  Inc(LX, CCloseW + CMargin);

  LEdit := TEdit.Create(LPanel);
  LEdit.Parent := LPanel;
  LEdit.SetBounds(LX, (CBarH - 22) div 2,
    LPanel.Width - LX - (CBtnW + CMargin) * 2 - CMargin, 22);
  LEdit.Anchors := [akLeft, akTop, akRight];
  LEdit.Text := FLastSearchPattern;
  LEdit.OnChange := DoSearchEditChange;
  LEdit.OnKeyDown := DoSearchEditKeyDown;
  FSearchEdit := LEdit;
  Inc(LX, LEdit.Width + CMargin);

  LPrevBtn := TButton.Create(LPanel);
  LPrevBtn.Parent := LPanel;
  LPrevBtn.SetBounds(LPanel.Width - (CBtnW + CMargin) * 2,
    (CBarH - 22) div 2, CBtnW, 22);
  LPrevBtn.Anchors := [akTop, akRight];
  LPrevBtn.Caption := '< Prev';
  LPrevBtn.OnClick := DoSearchPrevClick;

  LNextBtn := TButton.Create(LPanel);
  LNextBtn.Parent := LPanel;
  LNextBtn.SetBounds(LPanel.Width - CBtnW - CMargin,
    (CBarH - 22) div 2, CBtnW, 22);
  LNextBtn.Anchors := [akTop, akRight];
  LNextBtn.Caption := 'Next >';
  LNextBtn.OnClick := DoSearchNextClick;

  Winapi.Windows.SetFocus(LEdit.Handle);
end;

procedure TSCRataShell.HideSearchBar;
begin
  if FSearchBar = nil then Exit;
  FreeAndNil(FSearchBar);
  FSearchEdit := nil;
  FSearchMatchLen := 0;
  Invalidate;
  if CanFocus then SetFocus;
end;

procedure TSCRataShell.DoSearchEditChange(ASender: TObject);
begin
  if FSearchEdit = nil then Exit;
  FLastSearchPattern := TEdit(FSearchEdit).Text;
  if FLastSearchPattern = '' then
  begin
    FSearchMatchLen := 0;
    Invalidate;
    Exit;
  end;
  SearchAgain(True);
end;

procedure TSCRataShell.DoSearchNextClick(ASender: TObject);
begin
  SearchAgain(True);
end;

procedure TSCRataShell.DoSearchPrevClick(ASender: TObject);
begin
  SearchAgain(False);
end;

procedure TSCRataShell.DoSearchCloseClick(ASender: TObject);
begin
  HideSearchBar;
end;

procedure TSCRataShell.DoSearchEditKeyDown(ASender: TObject; var AKey: Word;
  AShift: TShiftState);
begin
  case AKey of
    VK_ESCAPE:
      begin
        HideSearchBar;
        AKey := 0;
      end;
    VK_RETURN:
      begin
        if ssShift in AShift then SearchAgain(False)
        else SearchAgain(True);
        AKey := 0;
      end;
    VK_F3:
      begin
        if ssShift in AShift then SearchAgain(False)
        else SearchAgain(True);
        AKey := 0;
      end;
  end;
end;

procedure TSCRataShell.SearchAgain(AForward: Boolean);
var
  LCol, LRow, LLen: Word;
begin
  if FLastSearchPattern = '' then Exit;
  if SearchNext(FLastSearchPattern, AForward, LCol, LRow, LLen) then
  begin
    FSearchMatchCol := LCol;
    FSearchMatchRow := LRow;
    FSearchMatchLen := LLen;
    Invalidate;
  end
  else
  begin
    FSearchMatchLen := 0;
    MessageBeep(MB_ICONINFORMATION);
    Invalidate;
  end;
end;

function TSCRataShell.SearchNext(const APattern: string; AForward: Boolean;
  out ACol, ARow, ALen: Word): Boolean;
var
  LBytes: UTF8String;
  LFwd: Integer;
  LResCol, LResRow, LResLen: UInt16;
begin
  ACol := 0; ARow := 0; ALen := 0;
  Result := False;
  if (FSession = nil) or (APattern = '')
     or not Assigned(rata_session_search_next) then Exit;
  LBytes := UTF8Encode(APattern);
  if AForward then LFwd := 1 else LFwd := 0;
  if rata_session_search_next(FSession, PByte(@LBytes[1]), Length(LBytes),
       LFwd, LResCol, LResRow, LResLen) = RATA_OK then
  begin
    ACol := LResCol;
    ARow := LResRow;
    ALen := LResLen;
    Result := LResLen > 0;
  end;
end;

function TSCRataShell.SelectionText: string;
var
  LBuf: TBytes;
  LLen: NativeUInt;
begin
  Result := '';
  if (FSession = nil) or not Assigned(rata_session_selection_get_text) then Exit;
  LLen := rata_session_selection_get_text(FSession, nil, 0);
  if LLen = 0 then Exit;
  SetLength(LBuf, LLen + 1);
  LLen := rata_session_selection_get_text(FSession, @LBuf[0], Length(LBuf));
  if LLen > 0 then
    Result := TEncoding.UTF8.GetString(LBuf, 0, LLen);
end;

procedure TSCRataShell.SelectionStart(ACol, ARow: Word; AKind: Byte);
begin
  if (FSession <> nil) and Assigned(rata_session_selection_start) then
    rata_session_selection_start(FSession, ACol, ARow, AKind);
end;

procedure TSCRataShell.SelectionExtend(ACol, ARow: Word);
begin
  if (FSession <> nil) and Assigned(rata_session_selection_extend) then
    rata_session_selection_extend(FSession, ACol, ARow);
end;

procedure TSCRataShell.SelectionClear;
begin
  if (FSession <> nil) and Assigned(rata_session_selection_clear) then
    rata_session_selection_clear(FSession);
end;

procedure TSCRataShell.CopySelection;
var
  LText: string;
begin
  LText := SelectionText;
  if LText = '' then Exit;
  try
    Vcl.Clipbrd.Clipboard.AsText := LText;
  except
  end;
end;

{ ---- Scrollbar ---- }

function TSCRataShell.ScrollBarRect: TRect;
const
  CScrollBarW = 12;
begin
  Result := Rect(ClientWidth - CScrollBarW, 0, ClientWidth, ClientHeight);
end;

function TSCRataShell.ScrollThumbRect: TRect;
var
  LTrack: TRect;
  LTrackH, LThumbH, LThumbY, LRange, LPos: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if FScrollMax = 0 then Exit;
  LTrack := ScrollBarRect;
  LTrackH := LTrack.Bottom - LTrack.Top;
  if LTrackH <= 0 then Exit;

  { 썸 길이 — viewport / total 비율. 최소 24px. }
  LThumbH := Max(24, MulDiv(LTrackH, FPainter.Rows, Integer(FScrollMax) + FPainter.Rows));
  if LThumbH > LTrackH then LThumbH := LTrackH;

  { 위치 — display_offset 0 (live) 일 때 썸은 하단. offset 증가 시 위로 이동. }
  LRange := LTrackH - LThumbH;
  if FScrollMax = 0 then
    LPos := 0
  else
    LPos := MulDiv(LRange, Integer(FScrollMax) - Integer(FScrollOffset),
                  Integer(FScrollMax));
  LThumbY := LTrack.Top + LPos;
  Result := Rect(LTrack.Left, LThumbY, LTrack.Right, LThumbY + LThumbH);
end;

function TSCRataShell.ScrollHitThumb(AX, AY: Integer): Boolean;
var
  LR: TRect;
begin
  LR := ScrollThumbRect;
  Result := (AX >= LR.Left) and (AX <= LR.Right) and
            (AY >= LR.Top) and (AY <= LR.Bottom);
end;

procedure TSCRataShell.UpdateScrollInfo;
var
  LOffset, LMax: UInt32;
begin
  if (FSession = nil) or not Assigned(rata_session_get_scroll_info) then Exit;
  LOffset := 0;
  LMax := 0;
  if rata_session_get_scroll_info(FSession, LOffset, LMax) = RATA_OK then
  begin
    FScrollOffset := LOffset;
    FScrollMax := LMax;
  end;
end;

procedure TSCRataShell.ScrollByLines(ALines: Integer);
begin
  if (FSession = nil) or not Assigned(rata_session_scroll) then Exit;
  if ALines = 0 then Exit;
  rata_session_scroll(FSession, ALines);
  UpdateScrollInfo;
  Invalidate;
end;

procedure TSCRataShell.MouseMove(AShift: TShiftState; AX, AY: Integer);
var
  LTrack: TRect;
  LTrackH, LThumbH, LRange, LNewPos: Integer;
  LNewOffset: Integer;
  LCb, LCol, LRow: Integer;
  LMode: UInt32;
begin
  { 마우스 트래킹 — drag(1002) 또는 motion(1003) 활성 시 위치 변경 송신. }
  if IsMouseTrackingActive and (AX < ScrollBarRect.Left) then
  begin
    LMode := ModeFlags;
    var LSendMotion := False;
    if (LMode and RATA_MODE_MOUSE_DRAG) <> 0 then
      LSendMotion := (ssLeft in AShift) or (ssRight in AShift) or (ssMiddle in AShift)
    else if (LMode and RATA_MODE_MOUSE_MOTION) <> 0 then
      LSendMotion := True;
    if LSendMotion and MouseToCell(AX, AY, LCol, LRow) then
    begin
      LCb := 32 { motion bit };
      if ssLeft in AShift then LCb := LCb or 0
      else if ssMiddle in AShift then LCb := LCb or 1
      else if ssRight in AShift then LCb := LCb or 2
      else LCb := LCb or 3;  { no button }
      LCb := LCb or MouseModifiersBits(AShift);
      SendMouseSequence(LCb, LCol, LRow, True);
      Exit;
    end;
  end;

  { Hyperlink hover — 캔버스 영역 + 비-드래그 + 트래킹 비활성. }
  if (not IsMouseTrackingActive) and (not FSelectingDrag)
     and (not FScrollDraggingThumb)
     and (AX >= 0) and (AX < ScrollBarRect.Left)
     and (AY >= 0) and (AY < ClientHeight) then
  begin
    if MouseToCell(AX, AY, LCol, LRow) then
    begin
      var LHl := HyperlinkAt(LCol - 1, LRow - 1);
      if LHl <> FHoverHyperlinkId then
      begin
        FHoverHyperlinkId := LHl;
        Invalidate;
      end;
      if LHl <> 0 then
      begin
        Cursor := crHandPoint;
        Hint := HyperlinkUri(LHl);
        ShowHint := True;
        inherited;
        Exit;
      end;
    end;
  end;
  if FHoverHyperlinkId <> 0 then
  begin
    FHoverHyperlinkId := 0;
    Cursor := crDefault;
    Invalidate;
  end;

  if FSelectingDrag then
  begin
    { Viewport 경계 밖 — auto-scroll 활성. }
    if AY < 0 then
    begin
      FAutoScrollDir := -1;
      FAutoScrollLastX := AX;
      FAutoScrollLastY := AY;
      FAutoScrollTimer.Enabled := True;
    end
    else if AY > ClientHeight then
    begin
      FAutoScrollDir := 1;
      FAutoScrollLastX := AX;
      FAutoScrollLastY := AY;
      FAutoScrollTimer.Enabled := True;
    end
    else
    begin
      FAutoScrollTimer.Enabled := False;
      FAutoScrollDir := 0;
    end;
    if MouseToCell(AX, AY, LCol, LRow) then
      SelectionExtend(LCol - 1, LRow - 1);
    Exit;
  end;

  if FScrollDraggingThumb then
  begin
    LTrack := ScrollBarRect;
    LTrackH := LTrack.Bottom - LTrack.Top;
    LThumbH := Max(24, MulDiv(LTrackH, FPainter.Rows, Integer(FScrollMax) + FPainter.Rows));
    LRange := LTrackH - LThumbH;
    if LRange <= 0 then Exit;
    LNewPos := AY - LTrack.Top - FScrollThumbDragOffset;
    if LNewPos < 0 then LNewPos := 0;
    if LNewPos > LRange then LNewPos := LRange;
    { LNewPos 0 = top (max offset), LRange = bottom (offset 0) }
    LNewOffset := MulDiv(LRange - LNewPos, Integer(FScrollMax), LRange);
    if LNewOffset < 0 then LNewOffset := 0;
    if LNewOffset > Integer(FScrollMax) then LNewOffset := Integer(FScrollMax);
    var LDelta := LNewOffset - Integer(FScrollOffset);
    if LDelta <> 0 then ScrollByLines(LDelta);
    Exit;
  end;
  inherited;
end;

procedure TSCRataShell.MouseUp(AButton: TMouseButton; AShift: TShiftState;
  AX, AY: Integer);
var
  LCb, LCol, LRow: Integer;
begin
  if IsMouseTrackingActive and (AX < ScrollBarRect.Left) then
  begin
    if MouseToCell(AX, AY, LCol, LRow) then
    begin
      case AButton of
        mbLeft:   LCb := 0;
        mbMiddle: LCb := 1;
        mbRight:  LCb := 2;
      else        LCb := 0;
      end;
      LCb := LCb or MouseModifiersBits(AShift);
      SendMouseSequence(LCb, LCol, LRow, False);
      MouseCapture := False;
      Exit;
    end;
  end;

  if FSelectingDrag then
  begin
    FSelectingDrag := False;
    FAutoScrollTimer.Enabled := False;
    FAutoScrollDir := 0;
    MouseCapture := False;
    Exit;
  end;

  if FScrollDraggingThumb then
  begin
    FScrollDraggingThumb := False;
    MouseCapture := False;
    Invalidate;
    Exit;
  end;
  inherited;
end;

function TSCRataShell.DoMouseWheel(AShift: TShiftState; AWheelDelta: Integer;
  AMousePos: TPoint): Boolean;
const
  CWheelLines = 3;
var
  LCb, LCol, LRow: Integer;
  LPt: TPoint;
begin
  Result := True;
  { 마우스 트래킹 활성 시 휠 이벤트도 전송 (button 64=wheel up, 65=wheel down). }
  if IsMouseTrackingActive then
  begin
    LPt := ScreenToClient(AMousePos);
    if not MouseToCell(LPt.X, LPt.Y, LCol, LRow) then Exit;
    if AWheelDelta > 0 then LCb := 64 else LCb := 65;
    LCb := LCb or MouseModifiersBits(AShift);
    SendMouseSequence(LCb, LCol, LRow, True);
    Exit;
  end;

  if AWheelDelta > 0 then
    ScrollByLines(CWheelLines)
  else
    ScrollByLines(-CWheelLines);
end;

{ ---- Mouse tracking VT sequences ---- }

function TSCRataShell.IsMouseTrackingActive: Boolean;
begin
  Result := (ModeFlags and (RATA_MODE_MOUSE_REPORT_CLICK or RATA_MODE_MOUSE_DRAG or
    RATA_MODE_MOUSE_MOTION)) <> 0;
end;

function TSCRataShell.MouseToCell(AX, AY: Integer; out ACol, ARow: Integer): Boolean;
begin
  Result := False;
  ACol := 0; ARow := 0;
  if (FPainter.CellW <= 0) or (FPainter.CellH <= 0) then Exit;
  if AX < 0 then AX := 0;
  if AY < 0 then AY := 0;
  ACol := (AX div FPainter.CellW) + 1;  { 1-based }
  ARow := (AY div FPainter.CellH) + 1;
  if ACol < 1 then ACol := 1;
  if ARow < 1 then ARow := 1;
  Result := True;
end;

function TSCRataShell.MouseModifiersBits(AShift: TShiftState): Integer;
begin
  Result := 0;
  if ssShift in AShift then Result := Result or 4;
  if ssAlt   in AShift then Result := Result or 8;
  if ssCtrl  in AShift then Result := Result or 16;
end;

procedure TSCRataShell.SendMouseSequence(ACb, ACol, ARow: Integer; APress: Boolean);

  { UTF-8 인코딩 — 코드 포인트(0..0x10FFFF) → 1~4 byte. mouse 좌표용 한정. }
  function EncodeUtf8Cp(ACodePoint: Integer): TBytes;
  begin
    if ACodePoint < $80 then
    begin
      SetLength(Result, 1);
      Result[0] := Byte(ACodePoint);
    end
    else if ACodePoint < $800 then
    begin
      SetLength(Result, 2);
      Result[0] := $C0 or Byte(ACodePoint shr 6);
      Result[1] := $80 or Byte(ACodePoint and $3F);
    end
    else
    begin
      SetLength(Result, 3);
      Result[0] := $E0 or Byte(ACodePoint shr 12);
      Result[1] := $80 or Byte((ACodePoint shr 6) and $3F);
      Result[2] := $80 or Byte(ACodePoint and $3F);
    end;
  end;

var
  LMode: UInt32;
  LSeqBytes: TBytes;
  LCb: Integer;
  LStr: AnsiString;
  I: Integer;
begin
  if FSession = nil then Exit;
  LMode := ModeFlags;
  if (LMode and RATA_MODE_SGR_MOUSE) <> 0 then
  begin
    { SGR (1006): ESC[<Cb;Cx;Cy;M (press) / m (release) }
    if APress then
      LStr := AnsiString(Format(#27'[<%d;%d;%d;M', [ACb, ACol, ARow]))
    else
      LStr := AnsiString(Format(#27'[<%d;%d;%d;m', [ACb, ACol, ARow]));
    SetLength(LSeqBytes, Length(LStr));
    if Length(LStr) > 0 then
      Move(LStr[1], LSeqBytes[0], Length(LStr));
  end
  else if (LMode and RATA_MODE_UTF8_MOUSE) <> 0 then
  begin
    { UTF-8 (1005): X10 과 같지만 좌표 byte 는 UTF-8 멀티바이트 (>127 시).
      col/row up to 2015 (값+32 가 0x7FF 한계). }
    if not APress then LCb := 3;
    if ACol > 2015 then ACol := 2015;
    if ARow > 2015 then ARow := 2015;
    LStr := AnsiString(#27'[M') + AnsiChar(Chr(ACb + 32));
    SetLength(LSeqBytes, Length(LStr));
    if Length(LStr) > 0 then
      Move(LStr[1], LSeqBytes[0], Length(LStr));
    var LX := EncodeUtf8Cp(ACol + 32);
    var LY := EncodeUtf8Cp(ARow + 32);
    var LOldLen := Length(LSeqBytes);
    SetLength(LSeqBytes, LOldLen + Length(LX) + Length(LY));
    for I := 0 to High(LX) do LSeqBytes[LOldLen + I] := LX[I];
    for I := 0 to High(LY) do LSeqBytes[LOldLen + Length(LX) + I] := LY[I];
  end
  else
  begin
    { X10 legacy: ESC[M Cb Cx Cy — 각 byte = value+32. col/row 222 max. }
    LCb := ACb;
    if not APress then LCb := 3;
    if ACol > 222 then ACol := 222;
    if ARow > 222 then ARow := 222;
    LStr := AnsiString(#27'[M') + AnsiChar(Chr(LCb + 32)) +
            AnsiChar(Chr(ACol + 32)) + AnsiChar(Chr(ARow + 32));
    SetLength(LSeqBytes, Length(LStr));
    if Length(LStr) > 0 then
      Move(LStr[1], LSeqBytes[0], Length(LStr));
  end;
  if Length(LSeqBytes) > 0 then
    rata_session_send_text(FSession, @LSeqBytes[0], Length(LSeqBytes));
end;

procedure TSCRataShell.DoAutoScrollTick(ASender: TObject);
var
  LCol, LRow: Integer;
  LClampedY: Integer;
begin
  if not FSelectingDrag or (FAutoScrollDir = 0) then
  begin
    FAutoScrollTimer.Enabled := False;
    Exit;
  end;
  { 1 라인씩 스크롤 + selection extend. }
  ScrollByLines(-FAutoScrollDir);  { dir=-1(up): scroll into history (positive lines); dir=+1(down): scroll back }
  { 마지막 마우스 위치를 viewport 경계로 clamp 하여 selection 확장 }
  if FAutoScrollDir < 0 then LClampedY := 0
  else LClampedY := ClientHeight - 1;
  if MouseToCell(FAutoScrollLastX, LClampedY, LCol, LRow) then
    SelectionExtend(LCol - 1, LRow - 1);
end;

procedure TSCRataShell.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  { DPI 변경 — VCL 이 Font 를 자동 scale 한 후 호출. Painter 의 cell 크기 재계산
    + Term resize 가 필요. isDpiChange=False (메뉴얼 ScaleBy) 도 동일 처리. }
  if isDpiChange then
  begin
    UpdateCellSize;
    Invalidate;
  end;
end;

end.
