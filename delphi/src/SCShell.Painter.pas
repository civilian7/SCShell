{ ============================================================================
  SCShell.Painter — Cell-grid GDI painter (back buffer based).
  ============================================================================ }
unit SCShell.Painter;

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  Vcl.Graphics,
  SCShell;

type
  TRataColors = class(TPersistent)
  strict private
    FAnsi: array[0..15] of TColor;
    FDefaultFg: TColor;
    FDefaultBg: TColor;
    FSelection: TColor;
    function GetAnsi(AIndex: Integer): TColor;
    procedure SetAnsi(AIndex: Integer; AValue: TColor);
  public
    constructor Create;
    procedure Assign(ASource: TPersistent); override;
    property Ansi[AIndex: Integer]: TColor read GetAnsi write SetAnsi;
  published
    property DefaultFg: TColor read FDefaultFg write FDefaultFg default $CCCCCC;
    property DefaultBg: TColor read FDefaultBg write FDefaultBg default $000000;
    property Selection: TColor read FSelection write FSelection default $664433;
  end;

  TRataPainter = class
  strict private
    FFont: TFont;
    FColors: TRataColors;
    FCellW: Integer;
    FCellH: Integer;
    FBackBuffer: TBitmap;
    FCols: Integer;
    FRows: Integer;
    procedure RecreateBuffer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetFont(AFont: TFont);
    procedure MeasureCell;
    procedure Resize(ACols, ARows: Integer);
    procedure DrawEvent(const AEvent: PRataRenderEvent);
    procedure BlitTo(ATargetDC: HDC; const ARect: TRect);
    property CellW: Integer read FCellW;
    property CellH: Integer read FCellH;
    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property Colors: TRataColors read FColors;
    property BackBuffer: TBitmap read FBackBuffer;
  end;

implementation

uses
  System.Math;

const
  ANSI_DEFAULT: array[0..15] of TColor = (
    $000000, $0000CD, $00CD00, $00CDCD, $CD0000, $CD00CD, $CDCD00, $E5E5E5,
    $7F7F7F, $0000FF, $00FF00, $00FFFF, $FF0000, $FF00FF, $FFFF00, $FFFFFF
  );

{ TRataColors }

constructor TRataColors.Create;
begin
  inherited;
  for var I := 0 to 15 do
    FAnsi[I] := ANSI_DEFAULT[I];
  FDefaultFg := $CCCCCC;
  FDefaultBg := $000000;
  FSelection := $664433;
end;

procedure TRataColors.Assign(ASource: TPersistent);
begin
  if ASource is TRataColors then
  begin
    var LSrc := TRataColors(ASource);
    for var I := 0 to 15 do
      FAnsi[I] := LSrc.FAnsi[I];
    FDefaultFg := LSrc.FDefaultFg;
    FDefaultBg := LSrc.FDefaultBg;
    FSelection := LSrc.FSelection;
  end
  else
    inherited Assign(ASource);
end;

function TRataColors.GetAnsi(AIndex: Integer): TColor;
begin
  if (AIndex >= 0) and (AIndex < 16) then
    Result := FAnsi[AIndex]
  else
    Result := clNone;
end;

procedure TRataColors.SetAnsi(AIndex: Integer; AValue: TColor);
begin
  if (AIndex >= 0) and (AIndex < 16) then
    FAnsi[AIndex] := AValue;
end;

{ TRataPainter }

constructor TRataPainter.Create;
begin
  inherited;
  FFont := TFont.Create;
  FFont.Name := 'Consolas';
  FFont.Size := 10;
  FFont.Color := $CCCCCC;
  FColors := TRataColors.Create;
  FBackBuffer := TBitmap.Create;
  FBackBuffer.PixelFormat := pf32bit;
  MeasureCell;
end;

destructor TRataPainter.Destroy;
begin
  FBackBuffer.Free;
  FColors.Free;
  FFont.Free;
  inherited;
end;

procedure TRataPainter.SetFont(AFont: TFont);
begin
  FFont.Assign(AFont);
  MeasureCell;
end;

procedure TRataPainter.MeasureCell;
var
  LDC: HDC;
  LOld: HFONT;
  LMetrics: TTextMetric;
  LSize: TSize;
begin
  LDC := GetDC(0);
  try
    LOld := SelectObject(LDC, FFont.Handle);
    try
      GetTextMetrics(LDC, LMetrics);
      FCellH := LMetrics.tmHeight + LMetrics.tmExternalLeading;
      // Measure an actual glyph rather than relying on tmAveCharWidth: when a
      // requested monospace face falls back to a proportional substitute, the
      // average is misleading and characters land with visible gaps.
      if GetTextExtentPoint32(LDC, 'M', 1, LSize) then
        FCellW := LSize.cx
      else
        FCellW := LMetrics.tmAveCharWidth;
      if FCellW < 1 then FCellW := 8;
      if FCellH < 1 then FCellH := 16;
    finally
      SelectObject(LDC, LOld);
    end;
  finally
    ReleaseDC(0, LDC);
  end;
end;

procedure TRataPainter.RecreateBuffer;
var
  LW, LH: Integer;
begin
  LW := Max(1, FCols * FCellW);
  LH := Max(1, FRows * FCellH);

  if (FBackBuffer.Width <> LW) or (FBackBuffer.Height <> LH) then
  begin
    FBackBuffer.SetSize(LW, LH);
    FBackBuffer.Canvas.Brush.Color := FColors.DefaultBg;
    FBackBuffer.Canvas.FillRect(Rect(0, 0, LW, LH));
  end;
end;

procedure TRataPainter.Resize(ACols, ARows: Integer);
begin
  FCols := Max(1, ACols);
  FRows := Max(1, ARows);
  RecreateBuffer;
end;

function ResolveColor(AValue: UInt32; ADefault: TColor): TColor;
var
  LR, LG, LB: Byte;
begin
  if (AValue and RATA_DEFAULT_FLAG) <> 0 then
    Exit(ADefault);

  // Stored as 0x00RRGGBB; TColor is 0x00BBGGRR.
  LR := (AValue shr 16) and $FF;
  LG := (AValue shr 8) and $FF;
  LB := AValue and $FF;
  Result := RGB(LR, LG, LB);
end;

procedure TRataPainter.DrawEvent(const AEvent: PRataRenderEvent);
var
  LCanvas: TCanvas;
  LDC: HDC;
  LCell, LRunStart: PRataCell;
  LX, LY: Integer;
  LCols, LRows: Integer;
  LFg, LBg: TColor;
  LFgPrev, LBgPrev: TColor;
  LAttrsPrev: UInt16;
  LRect, LRunRect: TRect;
  LRunText: string;
  LRunDx: array of Integer;
  LRunCells: Integer;
  LRunCols: Integer;
  LRunStartX: Integer;
  procedure FlushRun;
  begin
    if LRunCols = 0 then Exit;
    LRunRect := Rect(
      LRunStartX * FCellW,
      LY * FCellH,
      (LRunStartX + LRunCols) * FCellW,
      (LY + 1) * FCellH);

    if (LAttrsPrev and RATA_ATTR_BOLD) <> 0 then
      LCanvas.Font.Style := [fsBold]
    else
      LCanvas.Font.Style := [];
    // VCL TCanvas does not re-select the font onto its DC until the next
    // canvas-level operation. Because we call ExtTextOut directly on LDC,
    // we must explicitly select the canvas's current HFONT — otherwise
    // bold/regular runs render with whatever font GDI happened to have
    // selected, causing misaligned glyph widths between adjacent cells.
    SelectObject(LDC, LCanvas.Font.Handle);

    if Length(LRunText) > 0 then
    begin
      SetTextColor(LDC, ColorToRGB(LFgPrev));
      SetBkColor(LDC, ColorToRGB(LBgPrev));
      // ETO_OPAQUE paints the rect background in BkColor in the same call,
      // so we no longer need a separate FillRect (which would also dirty the
      // canvas state).
      ExtTextOut(LDC, LRunStartX * FCellW, LY * FCellH,
        ETO_CLIPPED or ETO_OPAQUE, @LRunRect,
        PChar(LRunText), Length(LRunText), @LRunDx[0]);
    end
    else
    begin
      LCanvas.Brush.Color := LBgPrev;
      LCanvas.Brush.Style := bsSolid;
      LCanvas.FillRect(LRunRect);
    end;

    LRunText := '';
    LRunCells := 0;
    LRunCols := 0;
  end;
begin
  if (AEvent = nil) or (AEvent.Cells = nil) then
    Exit;

  LCols := AEvent.Cols;
  LRows := AEvent.Rows;
  if (LCols <> FCols) or (LRows <> FRows) then
  begin
    FCols := LCols;
    FRows := LRows;
    RecreateBuffer;
  end;

  LCanvas := FBackBuffer.Canvas;
  LCanvas.Font.Assign(FFont);
  LDC := LCanvas.Handle;
  SetBkMode(LDC, OPAQUE);
  SetLength(LRunDx, LCols + 4);

  LCell := AEvent.Cells;
  LFgPrev := 0; LBgPrev := 0; LAttrsPrev := $FFFF;
  for LY := 0 to LRows - 1 do
  begin
    LRunText := '';
    LRunCells := 0;
    LRunCols := 0;
    LRunStartX := 0;
    for LX := 0 to LCols - 1 do
    begin
      // Resolve effective fg/bg for this cell, applying REVERSE.
      LFg := ResolveColor(LCell.Fg, FColors.DefaultFg);
      LBg := ResolveColor(LCell.Bg, FColors.DefaultBg);
      if (LCell.Attrs and RATA_ATTR_REVERSE) <> 0 then
      begin
        var LTmp := LFg;
        LFg := LBg;
        LBg := LTmp;
      end;

      // Wide-char trailer: already covered by the previous glyph's advance.
      if LCell.Width = 0 then
      begin
        Inc(LCell);
        Continue;
      end;

      // Start a new run when style differs (or first cell of the row).
      if (LRunCols = 0) or (LFgPrev <> LFg) or (LBgPrev <> LBg)
         or (LAttrsPrev <> LCell.Attrs) then
      begin
        FlushRun;
        LRunStartX := LX;
        LFgPrev := LFg;
        LBgPrev := LBg;
        LAttrsPrev := LCell.Attrs;
      end;

      if (LCell.Ch <> 0) and (LCell.Ch <> Ord(' ')) then
        LRunText := LRunText + Char(LCell.Ch)
      else
        LRunText := LRunText + ' ';
      // Force this glyph's advance to the full cell width (2*FCellW for wide
      // chars). This makes proportional/fallback fonts position chars exactly
      // at cell boundaries.
      LRunDx[LRunCells] := LCell.Width * FCellW;
      Inc(LRunCells);
      Inc(LRunCols, LCell.Width);
      Inc(LCell);
    end;
    FlushRun;
  end;

  // Cursor — style 별 분기. 0=block(default), 2/3=underline, 5/6=bar.
  // 짝수=steady, 홀수=blinking (blinking 은 호스트 타이머가 visibility 토글).
  if (AEvent.CursorVisible <> 0)
     and (AEvent.CursorX < FCols)
     and (AEvent.CursorY < FRows) then
  begin
    var LCx := AEvent.CursorX * FCellW;
    var LCy := AEvent.CursorY * FCellH;
    case AEvent.CursorStyle of
      2, 3: { underline — 하단 1px 두께 */
        begin
          LRect := Rect(LCx, LCy + FCellH - 2, LCx + FCellW, LCy + FCellH);
          InvertRect(LDC, LRect);
        end;
      5, 6: { bar — 좌측 2px 두께 }
        begin
          LRect := Rect(LCx, LCy, LCx + 2, LCy + FCellH);
          InvertRect(LDC, LRect);
        end;
    else
      { 0/1 (block / blinking block) — 기본 블록 invert }
      LRect := Rect(LCx, LCy, LCx + FCellW, LCy + FCellH);
      InvertRect(LDC, LRect);
    end;
  end;
end;

procedure TRataPainter.BlitTo(ATargetDC: HDC; const ARect: TRect);
begin
  BitBlt(ATargetDC, ARect.Left, ARect.Top,
    ARect.Width, ARect.Height,
    FBackBuffer.Canvas.Handle, 0, 0, SRCCOPY);
end;

end.
