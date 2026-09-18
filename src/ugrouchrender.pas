unit ugrouchrender;

{$mode objfpc}{$H+}

{ Software RGBA canvas. Hosts only upload the bytes. The grouch and the
  galvanised can are original geometry — not Sesame Workshop or classic
  Mac INIT bitmaps. Clear is RGBA (0,0,0,0) so the desktop shows through. }

interface

uses
  ugrouchmodel;

type
  TPixelBuffer = class
  private
    FWidth, FHeight: Integer;
    FData: array of Byte;
  public
    constructor Create(AWidth, AHeight: Integer);
    procedure Resize(AWidth, AHeight: Integer);
    procedure Clear(R, G, B, A: Byte);
    function Ptr: PByte;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

procedure RenderGrouch(Buf: TPixelBuffer; Model: TGrouchModel);
procedure RenderBarIcon(Buf: TPixelBuffer; Model: TGrouchModel);
procedure RenderWidget(Buf: TPixelBuffer; Model: TGrouchModel);
procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);

implementation

uses
  Math, SysUtils, ugrouchconfig;

type
  TColor = record
    R, G, B: Byte;
  end;

function C(R, G, B: Byte): TColor;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
end;

constructor TPixelBuffer.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  Resize(AWidth, AHeight);
end;

procedure TPixelBuffer.Resize(AWidth, AHeight: Integer);
begin
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FData, FWidth * FHeight * 4);
end;

procedure TPixelBuffer.Clear(R, G, B, A: Byte);
var
  I: Integer;
  P: PByte;
begin
  P := @FData[0];
  I := 0;
  while I < Length(FData) do
  begin
    P[I] := R;
    P[I + 1] := G;
    P[I + 2] := B;
    P[I + 3] := A;
    Inc(I, 4);
  end;
end;

function TPixelBuffer.Ptr: PByte;
begin
  Result := @FData[0];
end;

procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);
var
  I, N: Integer;
  S, D: PByte;
begin
  S := Buf.Ptr;
  D := Dest;
  N := Buf.Width * Buf.Height;
  for I := 0 to N - 1 do
  begin
    D[0] := S[2];
    D[1] := S[1];
    D[2] := S[0];
    D[3] := S[3];
    Inc(S, 4);
    Inc(D, 4);
  end;
end;

procedure BlendPixel(P: PByte; R, G, B: Byte; A: Double);
var
  SA, DA, OutA, Inv: Double;
begin
  if A <= 0.001 then
    Exit;
  if A > 1 then
    A := 1;
  SA := A;
  DA := P[3] / 255.0;
  Inv := 1.0 - SA;
  OutA := SA + DA * Inv;
  if OutA <= 0.001 then
    Exit;
  P[0] := Round((R * SA + P[0] * DA * Inv) / OutA);
  P[1] := Round((G * SA + P[1] * DA * Inv) / OutA);
  P[2] := Round((B * SA + P[2] * DA * Inv) / OutA);
  P[3] := Round(OutA * 255.0);
end;

procedure Plot(Buf: TPixelBuffer; X, Y: Integer; Col: TColor; A: Double);
var
  P: PByte;
begin
  if (X < 0) or (Y < 0) or (X >= Buf.Width) or (Y >= Buf.Height) then
    Exit;
  P := Buf.Ptr + (Y * Buf.Width + X) * 4;
  BlendPixel(P, Col.R, Col.G, Col.B, A);
end;

function CoverEllipse(PX, PY, CX, CY, RX, RY: Double): Double;
var
  NX, NY, D, Edge: Double;
begin
  if (RX <= 0.2) or (RY <= 0.2) then
    Exit(0);
  NX := (PX - CX) / RX;
  NY := (PY - CY) / RY;
  D := Sqrt(NX * NX + NY * NY);
  Edge := (D - 1.0) * Min(RX, RY);
  if Edge <= -0.6 then
    Result := 1
  else if Edge >= 0.6 then
    Result := 0
  else
    Result := 1.0 - (Edge + 0.6) / 1.2;
end;

procedure FillEllipse(Buf: TPixelBuffer; CX, CY, RX, RY: Double; Col: TColor; Alpha: Double);
var
  X0, Y0, X1, Y1, X, Y: Integer;
  Cov: Double;
  P: PByte;
begin
  if (Alpha <= 0) or (RX <= 0) or (RY <= 0) then
    Exit;
  X0 := Max(0, Floor(CX - RX - 1));
  Y0 := Max(0, Floor(CY - RY - 1));
  X1 := Min(Buf.Width - 1, Ceil(CX + RX + 1));
  Y1 := Min(Buf.Height - 1, Ceil(CY + RY + 1));
  for Y := Y0 to Y1 do
    for X := X0 to X1 do
    begin
      Cov := CoverEllipse(X + 0.5, Y + 0.5, CX, CY, RX, RY);
      if Cov > 0 then
      begin
        P := Buf.Ptr + (Y * Buf.Width + X) * 4;
        BlendPixel(P, Col.R, Col.G, Col.B, Alpha * Cov);
      end;
    end;
end;

procedure FillRect(Buf: TPixelBuffer; X0, Y0, X1, Y1: Double; Col: TColor; Alpha: Double);
var
  XA, XB, YA, YB, X, Y: Integer;
  P: PByte;
begin
  XA := Max(0, Floor(X0));
  YA := Max(0, Floor(Y0));
  XB := Min(Buf.Width - 1, Floor(X1));
  YB := Min(Buf.Height - 1, Floor(Y1));
  if (XB < XA) or (YB < YA) then
    Exit;
  for Y := YA to YB do
    for X := XA to XB do
    begin
      P := Buf.Ptr + (Y * Buf.Width + X) * 4;
      BlendPixel(P, Col.R, Col.G, Col.B, Alpha);
    end;
end;

procedure FillTrapezoid(Buf: TPixelBuffer; TopY, BotY, TopHalf, BotHalf, CX: Double;
  Col: TColor; Alpha: Double);
var
  Y, X, X0, X1: Integer;
  T, Half: Double;
  P: PByte;
begin
  if BotY <= TopY then
    Exit;
  for Y := Max(0, Floor(TopY)) to Min(Buf.Height - 1, Floor(BotY)) do
  begin
    T := (Y + 0.5 - TopY) / (BotY - TopY);
    Half := TopHalf + (BotHalf - TopHalf) * T;
    X0 := Max(0, Floor(CX - Half));
    X1 := Min(Buf.Width - 1, Floor(CX + Half));
    for X := X0 to X1 do
    begin
      P := Buf.Ptr + (Y * Buf.Width + X) * 4;
      BlendPixel(P, Col.R, Col.G, Col.B, Alpha);
    end;
  end;
end;

type
  TGlyph = array[0..6] of Byte;

function GlyphOf(Ch: Char): TGlyph;
begin
  { 5×7 bitmaps, bit 4 = left. Only the caption alphabet. }
  FillChar(Result, SizeOf(Result), 0);
  case UpCase(Ch) of
    'A': begin Result[0]:=$0E; Result[1]:=$11; Result[2]:=$11; Result[3]:=$1F; Result[4]:=$11; Result[5]:=$11; Result[6]:=$11; end;
    'E': begin Result[0]:=$1F; Result[1]:=$10; Result[2]:=$10; Result[3]:=$1E; Result[4]:=$10; Result[5]:=$10; Result[6]:=$1F; end;
    'H': begin Result[0]:=$11; Result[1]:=$11; Result[2]:=$11; Result[3]:=$1F; Result[4]:=$11; Result[5]:=$11; Result[6]:=$11; end;
    'I': begin Result[0]:=$1F; Result[1]:=$04; Result[2]:=$04; Result[3]:=$04; Result[4]:=$04; Result[5]:=$04; Result[6]:=$1F; end;
    'L': begin Result[0]:=$10; Result[1]:=$10; Result[2]:=$10; Result[3]:=$10; Result[4]:=$10; Result[5]:=$10; Result[6]:=$1F; end;
    'O': begin Result[0]:=$0E; Result[1]:=$11; Result[2]:=$11; Result[3]:=$11; Result[4]:=$11; Result[5]:=$11; Result[6]:=$0E; end;
    'R': begin Result[0]:=$1E; Result[1]:=$11; Result[2]:=$11; Result[3]:=$1E; Result[4]:=$14; Result[5]:=$12; Result[6]:=$11; end;
    'S': begin Result[0]:=$0F; Result[1]:=$10; Result[2]:=$10; Result[3]:=$0E; Result[4]:=$01; Result[5]:=$01; Result[6]:=$1E; end;
    'T': begin Result[0]:=$1F; Result[1]:=$04; Result[2]:=$04; Result[3]:=$04; Result[4]:=$04; Result[5]:=$04; Result[6]:=$04; end;
    'V': begin Result[0]:=$11; Result[1]:=$11; Result[2]:=$11; Result[3]:=$11; Result[4]:=$11; Result[5]:=$0A; Result[6]:=$04; end;
    '!': begin Result[0]:=$04; Result[1]:=$04; Result[2]:=$04; Result[3]:=$04; Result[4]:=$04; Result[5]:=$00; Result[6]:=$04; end;
  end;
end;

procedure DrawChar(Buf: TPixelBuffer; X, Y, Scale: Integer; Ch: Char; Col: TColor);
var
  G: TGlyph;
  Row, ColX, PX, PY, SX, SY: Integer;
begin
  G := GlyphOf(Ch);
  for Row := 0 to 6 do
    for ColX := 0 to 4 do
      if (G[Row] and (1 shl (4 - ColX))) <> 0 then
        for SY := 0 to Scale - 1 do
          for SX := 0 to Scale - 1 do
          begin
            PX := X + ColX * Scale + SX;
            PY := Y + Row * Scale + SY;
            Plot(Buf, PX, PY, Col, 1);
          end;
end;

procedure DrawCaption(Buf: TPixelBuffer; CX, Top: Double; S: Double);
const
  Text = 'I LOVE TRASH!';
var
  I, Scale, Cell, TotalW, X0, Y0, Pad: Integer;
  Cream, Ink, Rim: TColor;
begin
  Scale := Max(2, Round(S * 0.38));
  Cell := 5 * Scale + Scale;
  TotalW := Length(Text) * Cell;
  Pad := 4 * Scale;
  X0 := Round(CX - TotalW * 0.5);
  Y0 := Max(6, Round(Top) + Scale);
  Cream := C(255, 236, 170);
  Ink := C(28, 20, 16);
  Rim := C(40, 28, 18);
  FillEllipse(Buf, CX, Y0 + 3.6 * Scale, TotalW * 0.5 + Pad, 6.2 * Scale, Rim, 1);
  FillEllipse(Buf, CX, Y0 + 3.6 * Scale, TotalW * 0.48 + Pad, 5.5 * Scale, Cream, 1);
  for I := 1 to Length(Text) do
    DrawChar(Buf, X0 + (I - 1) * Cell, Y0 + Scale, Scale, Text[I], Ink);
end;

procedure DrawArm(Buf: TPixelBuffer; ShoulderX, ShoulderY, Angle, Len, Thick: Double; Col: TColor);
var
  I, N: Integer;
  T, X, Y: Double;
begin
  N := Max(4, Round(Len));
  for I := 0 to N do
  begin
    T := I / N;
    X := ShoulderX + Cos(Angle) * Len * T;
    Y := ShoulderY + Sin(Angle) * Len * T;
    FillEllipse(Buf, X, Y, Thick, Thick, Col, 1);
  end;
  { Hand }
  FillEllipse(Buf, ShoulderX + Cos(Angle) * Len, ShoulderY + Sin(Angle) * Len,
    Thick * 1.35, Thick * 1.2, Col, 1);
end;

procedure DrawLid(Buf: TPixelBuffer; CX, RimY, CanH, CanW, LidAngle: Double);
var
  LidCol, LidDark, Dark: TColor;
  TopHalf, LidX, LidY, LidRX, LidRY: Double;
begin
  LidCol := C(88, 168, 78);
  LidDark := C(48, 108, 52);
  Dark := C(92, 100, 112);
  TopHalf := CanW * 0.46;
  { Closed sits on the rim; open swings up and back so Oscar can appear. }
  LidX := CX - LidAngle * CanW * 0.18;
  LidY := RimY - LidAngle * CanH * 0.55;
  LidRX := TopHalf * (1.02 - LidAngle * 0.15);
  LidRY := CanW * (0.12 + LidAngle * 0.22);
  FillEllipse(Buf, LidX, LidY, LidRX, LidRY, LidDark, 1);
  FillEllipse(Buf, LidX, LidY - LidRY * 0.15, LidRX * 0.92, LidRY * 0.72, LidCol, 1);
  FillEllipse(Buf, LidX, LidY - LidRY * 0.7, CanW * 0.10, CanW * 0.05, Dark, 1);
end;

procedure DrawCanBody(Buf: TPixelBuffer; CX, RimY, CanH, CanW: Double);
var
  Steel, Dark, Hi, Inner, Rim: TColor;
  BotY, TopHalf, BotHalf: Double;
  I: Integer;
begin
  Steel := C(176, 184, 196);
  Dark := C(92, 100, 112);
  Hi := C(230, 236, 244);
  Inner := C(28, 32, 38);
  Rim := C(210, 216, 224);
  BotY := RimY + CanH;
  TopHalf := CanW * 0.46;
  BotHalf := CanW * 0.40;

  FillEllipse(Buf, CX, RimY, TopHalf, CanW * 0.14, Inner, 1);
  FillTrapezoid(Buf, RimY, BotY, TopHalf * 0.96, BotHalf, CX, Steel, 1);
  FillTrapezoid(Buf, RimY + 2, BotY - 2, TopHalf * 0.18, BotHalf * 0.16,
    CX - TopHalf * 0.55, Hi, 0.35);
  FillTrapezoid(Buf, RimY + 2, BotY - 2, TopHalf * 0.16, BotHalf * 0.14,
    CX + TopHalf * 0.62, Dark, 0.40);
  FillEllipse(Buf, CX, BotY, BotHalf, CanW * 0.10, Dark, 1);
  FillEllipse(Buf, CX, RimY, TopHalf, CanW * 0.13, Rim, 1);
  FillEllipse(Buf, CX, RimY, TopHalf * 0.82, CanW * 0.09, Inner, 1);
  for I := 0 to 3 do
    FillEllipse(Buf, CX - TopHalf * 0.7 + I * TopHalf * 0.46,
      RimY + CanH * 0.22, CanW * 0.035, CanW * 0.035, Dark, 0.8);
end;

procedure DrawOscar(Buf: TPixelBuffer; CX, RimY, Rise, Wave, Mouth, S: Double);
var
  Fur, FurDark, FurLite, Brow, Eye, Pupil, MouthC, Tongue: TColor;
  HeadCX, HeadCY, BodyCX, BodyCY: Double;
  EyeDX, Squint, Open: Double;
  ArmAng: Double;
begin
  Fur := C(52, 168, 58);
  FurDark := C(28, 108, 42);
  FurLite := C(98, 204, 86);
  Brow := C(24, 72, 30);
  Eye := C(255, 220, 70);
  Pupil := C(22, 18, 16);
  MouthC := C(42, 18, 20);
  Tongue := C(204, 72, 86);

  HeadCX := CX;
  HeadCY := RimY - Rise * S * 38;
  BodyCX := CX;
  BodyCY := HeadCY + S * 22;

  { Body in the can }
  FillEllipse(Buf, BodyCX, BodyCY, S * 20, S * 18, Fur, 1);
  FillEllipse(Buf, BodyCX - S * 8, BodyCY - S * 4, S * 7, S * 8, FurLite, 0.35);

  { Head }
  FillEllipse(Buf, HeadCX, HeadCY, S * 18, S * 16, Fur, 1);
  FillEllipse(Buf, HeadCX - S * 6, HeadCY - S * 4, S * 7, S * 6, FurLite, 0.4);
  { Messy tufts, not earmuffs }
  FillEllipse(Buf, HeadCX - S * 14, HeadCY - S * 10, S * 6, S * 5, FurDark, 1);
  FillEllipse(Buf, HeadCX + S * 13, HeadCY - S * 11, S * 5.5, S * 5, FurDark, 1);
  FillEllipse(Buf, HeadCX + S * 2, HeadCY - S * 15, S * 7, S * 5, FurDark, 1);

  { Unibrow sits on the eyes, grouchy and low }
  FillEllipse(Buf, HeadCX, HeadCY - S * 5.2, S * 14, S * 2.4, Brow, 1);
  FillRect(Buf, HeadCX - S * 13, HeadCY - S * 6.4, HeadCX + S * 13, HeadCY - S * 3.2, Brow, 1);

  Squint := 1 - Mouth * 0.15;
  EyeDX := S * 6.5;
  FillEllipse(Buf, HeadCX - EyeDX, HeadCY + S * 0.8, S * 5.2, S * 4.2 * Squint, Eye, 1);
  FillEllipse(Buf, HeadCX + EyeDX, HeadCY + S * 0.8, S * 5.2, S * 4.2 * Squint, Eye, 1);
  FillEllipse(Buf, HeadCX - EyeDX + S * 1.2, HeadCY + S * 1.2, S * 2.1, S * 2.3 * Squint, Pupil, 1);
  FillEllipse(Buf, HeadCX + EyeDX + S * 1.2, HeadCY + S * 1.2, S * 2.1, S * 2.3 * Squint, Pupil, 1);

  if Mouth < 0.22 then
  begin
    { Closed grouchy frown while waving. }
    FillEllipse(Buf, HeadCX, HeadCY + S * 9.5, S * 8, S * 2.1, MouthC, 1);
    FillEllipse(Buf, HeadCX, HeadCY + S * 8.6, S * 7, S * 1.2, Fur, 1);
  end
  else
  begin
    Open := 3 + Mouth * 9;
    FillEllipse(Buf, HeadCX, HeadCY + S * 8.5, S * (7 + Mouth * 3), S * Open * 0.55, MouthC, 1);
    if Mouth > 0.35 then
      FillEllipse(Buf, HeadCX, HeadCY + S * 10.5, S * 3.2, S * Open * 0.22, Tongue, 1);
  end;

  { Left arm tucked; right arm waves. Angle 0 is to the right. }
  DrawArm(Buf, CX - S * 16, BodyCY - S * 2, 2.4, S * 14, S * 3.4, Fur);
  ArmAng := -0.9 - Wave * 0.85;
  DrawArm(Buf, CX + S * 16, BodyCY - S * 4, ArmAng, S * 18, S * 3.6, Fur);

  { Pupils highlight }
  FillEllipse(Buf, HeadCX - EyeDX + S * 0.2, HeadCY - S * 0.2, S * 0.8, S * 0.8, C(255, 255, 240), 0.9);
  FillEllipse(Buf, HeadCX + EyeDX + S * 0.2, HeadCY - S * 0.2, S * 0.8, S * 0.8, C(255, 255, 240), 0.9);
end;

procedure PaintScene(Buf: TPixelBuffer; Model: TGrouchModel; AlwaysCan: Boolean);
var
  P: TGrouchPose;
  CX, RimY, CanH, CanW, S: Double;
begin
  Buf.Clear(0, 0, 0, 0);
  P := Model.Pose;
  if (not P.Visible) and (not AlwaysCan) then
    Exit;

  S := Min(Buf.Width, Buf.Height) / 110.0;
  if S < 1 then
    S := 1;
  CX := Buf.Width * 0.5;
  CanH := S * 42;
  CanW := S * 48;
  RimY := Buf.Height - CanH - S * 6;

  if P.ShowCaption and (P.Rise > 0.7) then
    DrawCaption(Buf, CX, S * 4, S);

  { Painter's algorithm: an open lid lives behind him; the can body
    then covers everything below the rim; a closed lid sits on top. }
  if P.LidAngle > 0.4 then
    DrawLid(Buf, CX, RimY, CanH, CanW, P.LidAngle);
  if P.Rise > 0.02 then
    DrawOscar(Buf, CX, RimY, P.Rise, P.Wave, P.Mouth, S);
  DrawCanBody(Buf, CX, RimY, CanH, CanW);
  if P.LidAngle <= 0.4 then
    DrawLid(Buf, CX, RimY, CanH, CanW, P.LidAngle);
end;

procedure RenderGrouch(Buf: TPixelBuffer; Model: TGrouchModel);
begin
  PaintScene(Buf, Model, False);
end;

procedure RenderWidget(Buf: TPixelBuffer; Model: TGrouchModel);
begin
  { Desktop bin always shows the can so there is something to click. }
  PaintScene(Buf, Model, True);
end;

procedure RenderBarIcon(Buf: TPixelBuffer; Model: TGrouchModel);
var
  P: TGrouchPose;
  CX, CY, S: Double;
  Steel, Inner, Fur, Lid: TColor;
begin
  Buf.Clear(0, 0, 0, 0);
  P := Model.Pose;
  S := Min(Buf.Width, Buf.Height) / 22.0;
  CX := Buf.Width * 0.5;
  CY := Buf.Height * 0.62;
  Steel := C(180, 188, 200);
  Inner := C(30, 34, 40);
  Fur := C(52, 168, 58);
  Lid := C(88, 168, 78);
  FillTrapezoid(Buf, CY - S * 6, CY + S * 8, S * 7, S * 6, CX, Steel, 1);
  FillEllipse(Buf, CX, CY - S * 6, S * 7, S * 2.4, Inner, 1);
  FillEllipse(Buf, CX, CY - S * 7.5, S * 7.2, S * 2.2, Lid, 1);
  if P.Visible then
    FillEllipse(Buf, CX, CY - S * 9, S * 5.5, S * 5, Fur, 1);
end;

end.
