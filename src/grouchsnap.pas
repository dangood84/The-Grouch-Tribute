program grouchsnap;

{$mode objfpc}{$H+}

{ Writes PPM frames of the software canvas (no window).
  Usage: grouchsnap out-dir }

uses
  SysUtils, ugrouchconfig, ugrouchapp, ugrouchmodel;

procedure WritePPM(const Path: string; BufW, BufH: Integer; Ptr: PByte);
var
  F: File;
  X, Y: Integer;
  P: PByte;
  RGB: array[0..2] of Byte;
  Header: string;
  A: Byte;
begin
  Header := Format('P6'#10'%d %d'#10'255'#10, [BufW, BufH]);
  AssignFile(F, Path);
  Rewrite(F, 1);
  BlockWrite(F, Header[1], Length(Header));
  for Y := 0 to BufH - 1 do
  begin
    P := Ptr + Y * BufW * 4;
    for X := 0 to BufW - 1 do
    begin
      { Composite onto a dim desktop-grey so transparent pixels are visible. }
      A := P[3];
      RGB[0] := (P[0] * A + 36 * (255 - A)) div 255;
      RGB[1] := (P[1] * A + 40 * (255 - A)) div 255;
      RGB[2] := (P[2] * A + 48 * (255 - A)) div 255;
      BlockWrite(F, RGB[0], 3);
      Inc(P, 4);
    end;
  end;
  CloseFile(F);
end;

procedure Snap(C: TGrouchController; const Path: string);
begin
  C.Render;
  WritePPM(Path, C.Overlay.Width, C.Overlay.Height, C.Overlay.Ptr);
end;

var
  Dir: string;
  C: TGrouchController;
begin
  if ParamCount >= 1 then
    Dir := ParamStr(1)
  else
    Dir := 'build';
  ForceDirectories(Dir);
  C := TGrouchController.Create(320, 440, 44, 44, 240, 320, DefaultConfig, False);
  try
    C.Model.ForcePose(gpDormant, gaJustWave, 0);
    C.Render;
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-bar.ppm',
      C.Bar.Width, C.Bar.Height, C.Bar.Ptr);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-widget.ppm',
      C.Widget.Width, C.Widget.Height, C.Widget.Ptr);

    { Overlay is empty while dormant; widget still shows the closed can. }
    C.Model.ForcePose(gpLidOpen, gaSingAndWave, 0.85);
    Snap(C, IncludeTrailingPathDelimiter(Dir) + 'snap-lid.ppm');

    C.Model.ForcePose(gpRise, gaSingAndWave, 1.0);
    Snap(C, IncludeTrailingPathDelimiter(Dir) + 'snap-rise.ppm');

    C.Model.ForcePose(gpAction, gaJustWave, 0.4);
    Snap(C, IncludeTrailingPathDelimiter(Dir) + 'snap-wave.ppm');

    C.Model.ForcePose(gpAction, gaSingAndWave, 0.35);
    Snap(C, IncludeTrailingPathDelimiter(Dir) + 'snap-sing.ppm');
  finally
    C.Free;
  end;
end.
