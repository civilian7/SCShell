{ ============================================================================
  SCShell.pas — FFI bindings for sc_shell64.dll
  ============================================================================ }
unit SCShell;

interface

uses
  Winapi.Windows,
  System.SysUtils;

const
  RATA_OK         = 0;
  RATA_ERR_INVALID = -1;
  RATA_ERR_ARG    = -2;
  RATA_ERR_STATE  = -3;
  RATA_ERR_OS     = -4;
  RATA_ERR_IO     = -5;
  RATA_ERR_PANIC  = -99;

  RATA_INIT_LOG_FILE  = $01;
  RATA_INIT_LOG_DEBUG = $02;

  RATA_MOD_SHIFT = $01;
  RATA_MOD_CTRL  = $02;
  RATA_MOD_ALT   = $04;
  RATA_MOD_WIN   = $08;

  RATA_ATTR_BOLD      = $0001;
  RATA_ATTR_DIM       = $0002;
  RATA_ATTR_ITALIC    = $0004;
  RATA_ATTR_UNDERLINE = $0008;
  RATA_ATTR_BLINK     = $0010;
  RATA_ATTR_REVERSE   = $0020;
  RATA_ATTR_HIDDEN    = $0040;
  RATA_ATTR_STRIKE    = $0080;

  RATA_DEFAULT_FLAG = $80000000;

  {$IFDEF WIN64}
  RATA_DLL = 'sc_shell64.dll';
  {$ELSE}
  RATA_DLL = 'sc_shell32.dll';
  {$ENDIF}

type
  TRataResult = Integer;
  TRataSession = Pointer;

  TRataSpawnOptions = record
    ShellPathUtf8: PByte;
    ShellPathLen: NativeUInt;
    ShellArgsUtf8: PByte;
    ShellArgsLen: NativeUInt;
    CwdUtf8: PByte;
    CwdLen: NativeUInt;
    EnvUtf8: PByte;
    EnvLen: NativeUInt;
    Cols: UInt16;
    Rows: UInt16;
    Scrollback: UInt32;
    Flags: UInt32;
  end;
  PRataSpawnOptions = ^TRataSpawnOptions;

  TRataRect = record
    X, Y, W, H: UInt16;
  end;
  PRataRect = ^TRataRect;

  TRataCell = record
    Ch: UInt32;
    Fg: UInt32;
    Bg: UInt32;
    Attrs: UInt16;
    Width: Byte;
    Pad: Byte;
  end;
  PRataCell = ^TRataCell;

  TRataRenderEvent = record
    Cols: UInt16;
    Rows: UInt16;
    CursorX: UInt16;
    CursorY: UInt16;
    CursorVisible: Byte;
    CursorStyle: Byte;
    Pad: array[0..1] of Byte;
    DirtyRects: PRataRect;
    DirtyCount: NativeUInt;
    Cells: PRataCell;
    CellsLen: NativeUInt;
  end;
  PRataRenderEvent = ^TRataRenderEvent;

  TRataRenderCb = procedure(AUser: Pointer; const AEvent: PRataRenderEvent); cdecl;
  TRataExitCb   = procedure(AUser: Pointer; AExitCode: Integer); cdecl;
  TRataBellCb   = procedure(AUser: Pointer); cdecl;
  TRataTitleCb  = procedure(AUser: Pointer; AUtf8: PByte; ALen: NativeUInt); cdecl;

var
  rata_init: function(AFlags: UInt32): TRataResult; cdecl;
  rata_shutdown: procedure; cdecl;
  rata_version: function: PAnsiChar; cdecl;
  rata_last_error_message: function(ABuf: PByte; ACap: NativeUInt): NativeUInt; cdecl;

  rata_session_create: function(const AOpts: PRataSpawnOptions;
    out AHandle: TRataSession): TRataResult; cdecl;
  rata_session_destroy: function(AHandle: TRataSession): TRataResult; cdecl;
  rata_session_set_callbacks: function(AHandle: TRataSession;
    AOnRender: TRataRenderCb; AOnExit: TRataExitCb;
    AOnBell: TRataBellCb; AOnTitle: TRataTitleCb;
    AUser: Pointer): TRataResult; cdecl;
  rata_session_start: function(AHandle: TRataSession): TRataResult; cdecl;
  rata_session_resize: function(AHandle: TRataSession; ACols, ARows: UInt16): TRataResult; cdecl;
  rata_session_send_text: function(AHandle: TRataSession;
    AUtf8: PByte; ALen: NativeUInt): TRataResult; cdecl;
  rata_session_send_key: function(AHandle: TRataSession;
    AVk, AMods: UInt32): TRataResult; cdecl;
  rata_session_request_render: function(AHandle: TRataSession): TRataResult; cdecl;
  rata_session_terminate: function(AHandle: TRataSession; ATimeoutMs: UInt32): TRataResult; cdecl;
  rata_session_is_alive: function(AHandle: TRataSession): Integer; cdecl;
  rata_session_get_size: function(AHandle: TRataSession;
    out ACols, ARows: UInt16): TRataResult; cdecl;
  rata_session_get_title: function(AHandle: TRataSession;
    ABuf: PByte; ACap: NativeUInt): NativeUInt; cdecl;

/// <summary>DLL을 명시적 경로(또는 기본 검색 경로)로 로드합니다.</summary>
/// <param name="ADllPath">DLL 경로. 빈 문자열이면 표준 검색 경로 사용</param>
/// <returns>True면 성공</returns>
function RataLoadLibrary(const ADllPath: string = ''): Boolean;

/// <summary>로드된 DLL을 언로드합니다.</summary>
procedure RataUnloadLibrary;

/// <summary>DLL이 로드되어 있는지 확인합니다.</summary>
function RataIsLoaded: Boolean;

/// <summary>마지막 에러 메시지를 UTF-8 → string으로 반환합니다.</summary>
function RataLastError: string;

/// <summary>RataResult를 사람이 읽을 수 있는 문자열로 변환합니다.</summary>
function RataResultText(ACode: TRataResult): string;

implementation

var
  GModule: HMODULE = 0;

function GetProcRequired(const AName: AnsiString): Pointer;
begin
  Result := GetProcAddress(GModule, PAnsiChar(AName));
  if Result = nil then
    raise Exception.CreateFmt('sc_shell: missing export %s', [string(AName)]);
end;

function RataLoadLibrary(const ADllPath: string): Boolean;
var
  LPath: string;
begin
  if GModule <> 0 then
    Exit(True);

  if ADllPath = '' then
    LPath := RATA_DLL
  else
    LPath := ADllPath;

  GModule := LoadLibrary(PChar(LPath));
  if GModule = 0 then
    Exit(False);

  @rata_init                  := GetProcRequired('rata_init');
  @rata_shutdown              := GetProcRequired('rata_shutdown');
  @rata_version               := GetProcRequired('rata_version');
  @rata_last_error_message    := GetProcRequired('rata_last_error_message');
  @rata_session_create        := GetProcRequired('rata_session_create');
  @rata_session_destroy       := GetProcRequired('rata_session_destroy');
  @rata_session_set_callbacks := GetProcRequired('rata_session_set_callbacks');
  @rata_session_start         := GetProcRequired('rata_session_start');
  @rata_session_resize        := GetProcRequired('rata_session_resize');
  @rata_session_send_text     := GetProcRequired('rata_session_send_text');
  @rata_session_send_key      := GetProcRequired('rata_session_send_key');
  @rata_session_request_render:= GetProcRequired('rata_session_request_render');
  @rata_session_terminate     := GetProcRequired('rata_session_terminate');
  @rata_session_is_alive      := GetProcRequired('rata_session_is_alive');
  @rata_session_get_size      := GetProcRequired('rata_session_get_size');
  @rata_session_get_title     := GetProcRequired('rata_session_get_title');

  // Enable file logging by default during development. Log goes next to the
  // DLL (or %TEMP% as fallback).
  rata_init(RATA_INIT_LOG_FILE or RATA_INIT_LOG_DEBUG);
  Result := True;
end;

procedure RataUnloadLibrary;
begin
  if GModule = 0 then
    Exit;

  if Assigned(rata_shutdown) then
    rata_shutdown;

  FreeLibrary(GModule);
  GModule := 0;
end;

function RataIsLoaded: Boolean;
begin
  Result := GModule <> 0;
end;

function RataLastError: string;
var
  LLen: NativeUInt;
  LBuf: TBytes;
begin
  if not Assigned(rata_last_error_message) then
    Exit('');

  LLen := rata_last_error_message(nil, 0);
  if LLen = 0 then
    Exit('');

  SetLength(LBuf, LLen + 1);
  rata_last_error_message(@LBuf[0], Length(LBuf));
  Result := UTF8ToString(@LBuf[0]);
end;

function RataResultText(ACode: TRataResult): string;
begin
  case ACode of
    RATA_OK:          Result := 'OK';
    RATA_ERR_INVALID: Result := 'invalid handle';
    RATA_ERR_ARG:     Result := 'invalid argument';
    RATA_ERR_STATE:   Result := 'invalid state';
    RATA_ERR_OS:      Result := 'OS error';
    RATA_ERR_IO:      Result := 'I/O error';
    RATA_ERR_PANIC:   Result := 'panic';
  else
    Result := Format('error %d', [ACode]);
  end;

  if ACode <> RATA_OK then
  begin
    var LMsg := RataLastError;
    if LMsg <> '' then
      Result := Result + ': ' + LMsg;
  end;
end;

initialization

finalization
  RataUnloadLibrary;

end.
