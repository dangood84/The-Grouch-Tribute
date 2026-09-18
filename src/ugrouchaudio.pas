unit ugrouchaudio;

{$mode objfpc}{$H+}

{ Original 8-bit PCM stings. Not the Sesame Street recording — that
  performance is still theirs. The lid is a metal squeak; the song is a
  grouchy square-wave shout the model also uses to open Oscar's mouth. }

interface

uses
  SysUtils;

type
  TSfxKind = (sfxNone, sfxLid, sfxSong);

  TSongNote = record
    Start, Dur, Hz: Double;
  end;

function BuildSfxWav(Kind: TSfxKind): TBytes;
function SfxName(Kind: TSfxKind): string;
function SongDuration: Double;
function SongNoteCount: Integer;
function SongNote(Index: Integer): TSongNote;
function SongMouthAt(SongTime: Double): Double;

implementation

uses
  Math;

const
  Rate = 22050;

var
  Score: array of TSongNote;
  ScoreReady: Boolean = False;
  ScoreLen: Double = 0;

procedure AddNote(Start, Dur, Hz: Double);
var
  N: Integer;
begin
  N := Length(Score);
  SetLength(Score, N + 1);
  Score[N].Start := Start;
  Score[N].Dur := Dur;
  Score[N].Hz := Hz;
end;

procedure EnsureScore;
begin
  if ScoreReady then
    Exit;
  ScoreReady := True;
  SetLength(Score, 0);
  { Original tribute shout — low, bluesy, not the 1970 melody.
    Times are seconds from the start of gpAction. }
  AddNote(0.00, 0.22, 98.00);    { G2  — gravel pickup }
  AddNote(0.28, 0.36, 130.81);   { C3 }
  AddNote(0.72, 0.22, 155.56);   { Eb3 }
  AddNote(1.02, 0.58, 196.00);   { G3  — held yell }
  AddNote(1.78, 0.24, 174.61);   { F3 }
  AddNote(2.10, 0.24, 155.56);   { Eb3 }
  AddNote(2.42, 0.20, 146.83);   { D3 }
  AddNote(2.70, 0.42, 130.81);   { C3 }
  AddNote(3.22, 0.28, 98.00);    { G2 }
  AddNote(3.58, 0.90, 130.81);   { C3  — rumble out }
  ScoreLen := 3.58 + 0.90 + 0.12;
end;

function SongDuration: Double;
begin
  EnsureScore;
  Result := ScoreLen;
end;

function SongNoteCount: Integer;
begin
  EnsureScore;
  Result := Length(Score);
end;

function SongNote(Index: Integer): TSongNote;
begin
  EnsureScore;
  if (Index < 0) or (Index >= Length(Score)) then
  begin
    Result.Start := 0;
    Result.Dur := 0;
    Result.Hz := 0;
  end
  else
    Result := Score[Index];
end;

function SongMouthAt(SongTime: Double): Double;
var
  I: Integer;
  N: TSongNote;
  Local, Attack, Rel, Env: Double;
begin
  { Mouth openness 0..1 follows the sung notes so the face lip-syncs
    the WAV the host is playing. }
  EnsureScore;
  Result := 0.08;
  for I := 0 to High(Score) do
  begin
    N := Score[I];
    if (SongTime < N.Start) or (SongTime > N.Start + N.Dur) then
      Continue;
    Local := SongTime - N.Start;
    Attack := Min(0.05, N.Dur * 0.25);
    Rel := Min(0.08, N.Dur * 0.35);
    Env := 1;
    if Local < Attack then
      Env := Local / Attack
    else if Local > N.Dur - Rel then
      Env := (N.Dur - Local) / Rel;
    { Higher notes open wider — a yell vs a mutter. }
    Result := 0.22 + Env * (0.45 + Min(N.Hz, 220) / 400.0);
    Exit;
  end;
end;

procedure WriteWavHeader(var Bytes: TBytes; Samples: Integer);
var
  P: Integer;
begin
  SetLength(Bytes, 44 + Samples * 2);
  FillChar(Bytes[0], Length(Bytes), 0);
  Bytes[0] := Ord('R'); Bytes[1] := Ord('I'); Bytes[2] := Ord('F'); Bytes[3] := Ord('F');
  P := 36 + Samples * 2;
  Bytes[4] := Byte(P); Bytes[5] := Byte(P shr 8);
  Bytes[6] := Byte(P shr 16); Bytes[7] := Byte(P shr 24);
  Bytes[8] := Ord('W'); Bytes[9] := Ord('A'); Bytes[10] := Ord('V'); Bytes[11] := Ord('E');
  Bytes[12] := Ord('f'); Bytes[13] := Ord('m'); Bytes[14] := Ord('t'); Bytes[15] := Ord(' ');
  Bytes[16] := 16;
  Bytes[20] := 1;
  Bytes[22] := 1;
  Bytes[24] := 34; Bytes[25] := 86; { 22050 }
  Bytes[28] := 68; Bytes[29] := 172; { 44100 B/s }
  Bytes[32] := 2;
  Bytes[34] := 16;
  Bytes[36] := Ord('d'); Bytes[37] := Ord('a'); Bytes[38] := Ord('t'); Bytes[39] := Ord('a');
  P := Samples * 2;
  Bytes[40] := Byte(P); Bytes[41] := Byte(P shr 8);
  Bytes[42] := Byte(P shr 16); Bytes[43] := Byte(P shr 24);
end;

procedure PutSample(var Bytes: TBytes; Index: Integer; Amp: Double);
var
  V: SmallInt;
begin
  if Amp > 0.95 then
    Amp := 0.95;
  if Amp < -0.95 then
    Amp := -0.95;
  V := Round(Amp * 32767);
  Bytes[44 + Index * 2] := Byte(V);
  Bytes[45 + Index * 2] := Byte(V shr 8);
end;

function Square(Phase, Duty: Double): Double;
begin
  if Phase < Duty then
    Result := 1
  else
    Result := -1;
end;

function Noise(I: Integer): Double;
begin
  Result := (((I * 1103515245 + 12345) shr 16) and $7FFF) / 16384.0 - 1.0;
end;

function BuildLidWav: TBytes;
var
  Samples, I: Integer;
  T, Hz, Env, Acc: Double;
begin
  Samples := Round(Rate * 0.22);
  WriteWavHeader(Result, Samples);
  for I := 0 to Samples - 1 do
  begin
    T := I / Rate;
    Env := Exp(-T * 9) * 0.7;
    { Rising then falling metal scrape — the hinged lid. }
    if T < 0.09 then
      Hz := 420 + T * 2800
    else
      Hz := 670 - (T - 0.09) * 1800;
    Acc := Square(Frac(T * Hz), 0.18) * Env * 0.35 + Noise(I) * Env * 0.45;
    PutSample(Result, I, Acc);
  end;
end;

function BuildSongWav: TBytes;
var
  Samples, I, N: Integer;
  T, Hz, Env, Acc, Phase, Vib, Scoop, Local, Attack, Rel: Double;
  Note: TSongNote;
  OnNote: Boolean;
begin
  EnsureScore;
  Samples := Round(Rate * SongDuration);
  WriteWavHeader(Result, Samples);
  Phase := 0;
  for I := 0 to Samples - 1 do
  begin
    T := I / Rate;
    OnNote := False;
    Hz := 98;
    Env := 0;
    for N := 0 to High(Score) do
    begin
      Note := Score[N];
      if (T < Note.Start) or (T > Note.Start + Note.Dur) then
        Continue;
      OnNote := True;
      Local := T - Note.Start;
      Attack := Min(0.04, Note.Dur * 0.2);
      Rel := Min(0.10, Note.Dur * 0.4);
      Env := 0.72;
      if Local < Attack then
        Env := 0.72 * (Local / Attack)
      else if Local > Note.Dur - Rel then
        Env := 0.72 * ((Note.Dur - Local) / Rel);
      { Grouchy scoop onto the pitch, then a little vibrato. }
      Scoop := 1;
      if Local < 0.06 then
        Scoop := 0.92 + 0.08 * (Local / 0.06);
      Vib := 1 + 0.012 * Sin(2 * Pi * 5.4 * T);
      Hz := Note.Hz * Scoop * Vib;
      Break;
    end;
    if not OnNote then
    begin
      PutSample(Result, I, Noise(I) * 0.02);
      Continue;
    end;
    Phase := Phase + Hz / Rate;
    Phase := Frac(Phase);
    { Square + a slice of 2nd harmonic so it reads as a sung shout,
      not a clean chiptune beep. }
    Acc := Square(Phase, 0.42) * Env * 0.72 +
           Square(Frac(Phase * 2), 0.42) * Env * 0.18 +
           Noise(I) * Env * 0.06;
    PutSample(Result, I, Acc);
  end;
end;

function BuildSfxWav(Kind: TSfxKind): TBytes;
begin
  case Kind of
    sfxLid: Result := BuildLidWav;
    sfxSong: Result := BuildSongWav;
    else
      begin
        WriteWavHeader(Result, 64);
      end;
  end;
end;

function SfxName(Kind: TSfxKind): string;
begin
  case Kind of
    sfxLid: Result := 'lid';
    sfxSong: Result := 'song';
    else Result := 'none';
  end;
end;

end.
