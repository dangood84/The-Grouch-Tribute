program grouchtest;

{$mode objfpc}{$H+}

{ Headless checks for the dormant → lid → rise → sing/wave toggle,
  trash-empty detector, and original WAV headers. No window. }

uses
  SysUtils, ugrouchconfig, ugrouchtrash, ugrouchaudio, ugrouchmodel, ugrouchapp;

procedure ExpectNear(const LabelText: string; Got, Want, Eps: Double);
begin
  if Abs(Got - Want) > Eps then
  begin
    WriteLn('FAIL ', LabelText, ': got ', Got:0:6, ' want ', Want:0:6);
    Halt(1);
  end;
  WriteLn('ok   ', LabelText);
end;

procedure ExpectEq(const LabelText: string; Got, Want: Integer);
begin
  if Got <> Want then
  begin
    WriteLn('FAIL ', LabelText, ': got ', Got, ' want ', Want);
    Halt(1);
  end;
  WriteLn('ok   ', LabelText);
end;

procedure ExpectTrue(const LabelText: string; Ok: Boolean);
begin
  if not Ok then
  begin
    WriteLn('FAIL ', LabelText);
    Halt(1);
  end;
  WriteLn('ok   ', LabelText);
end;

procedure RunUntil(M: TGrouchModel; Ph: TGrouchPhase; MaxSteps: Integer);
var
  I: Integer;
begin
  for I := 1 to MaxSteps do
  begin
    if M.Phase = Ph then
      Exit;
    M.Update(1 / 30);
  end;
end;

var
  M: TGrouchModel;
  C: TGrouchController;
  Cfg: TGrouchConfig;
  Wav: TBytes;
  Kind: TSfxKind;
  Dir, Junk: string;
  F: TextFile;
  SawLid, SawSong: Boolean;
  P: TGrouchPose;
begin
  ExpectTrue('phase dormant name', PhaseName(gpDormant) = 'dormant');
  ExpectTrue('action sing name', ActionName(gaSingAndWave) = 'sing');
  ExpectTrue('action wave name', ActionName(gaJustWave) = 'wave');
  ExpectTrue('sfx song name', SfxName(sfxSong) = 'song');
  ExpectTrue('empty-bin title', IsEmptyTrashTitle('Empty Bin'));
  ExpectTrue('empty-bin ellipsis', IsEmptyTrashTitle('Empty Bin…'));
  ExpectTrue('empty-trash dots', IsEmptyTrashTitle('Empty Trash...'));
  ExpectTrue('wastebasket title', IsEmptyTrashTitle('Empty Wastebasket'));
  ExpectTrue('not empty-trash', not IsEmptyTrashTitle('Get Info'));
  ExpectTrue('emptied 3 to 0', TrashWasEmptied(3, 0));
  ExpectTrue('not emptied 0 to 0', not TrashWasEmptied(0, 0));
  ExpectTrue('not emptied 3 to 2', not TrashWasEmptied(3, 2));

  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'grouch-trash-test';
  ForceDirectories(Dir);
  Junk := IncludeTrailingPathDelimiter(Dir) + 'can.txt';
  AssignFile(F, Junk);
  Rewrite(F);
  WriteLn(F, 'junk');
  CloseFile(F);
  ExpectEq('count one junk file', CountTrashItems(Dir), 1);
  DeleteFile(Junk);
  ExpectEq('count after empty', CountTrashItems(Dir), 0);
  RmDir(Dir);

  Wav := BuildSfxWav(sfxLid);
  ExpectTrue('lid wav header', (Length(Wav) > 44) and (Chr(Wav[0]) = 'R'));
  Wav := BuildSfxWav(sfxSong);
  ExpectTrue('song wav size', Length(Wav) > 1000);
  ExpectTrue('song duration', SongDuration > 3.5);
  ExpectTrue('song has notes', SongNoteCount >= 8);
  ExpectTrue('mouth opens on a note', SongMouthAt(1.2) > 0.3);
  ExpectTrue('mouth rests between notes', SongMouthAt(1.72) < 0.2);

  M := TGrouchModel.Create;
  try
    Cfg := DefaultConfig;
    Cfg.NextAction := gaSingAndWave;
    M.SetConfig(Cfg);
    ExpectTrue('starts dormant', not M.Busy);
    ExpectEq('starts dormant phase', Ord(M.Phase), Ord(gpDormant));

    M.Trigger;
    ExpectEq('trigger opens lid', Ord(M.Phase), Ord(gpLidOpen));
    SawLid := False;
    SawSong := False;
    while M.DrainSfx(Kind) do
      if Kind = sfxLid then
        SawLid := True;
    ExpectTrue('lid sfx on popup', SawLid);

    { A second Empty Trash while he is out is ignored. }
    M.Trigger;
    ExpectEq('busy ignores retrigger', Ord(M.Phase), Ord(gpLidOpen));

    RunUntil(M, gpRise, 40);
    ExpectEq('reached rise', Ord(M.Phase), Ord(gpRise));
    P := M.Pose;
    ExpectTrue('lid fully open on rise', P.LidAngle > 0.99);

    RunUntil(M, gpAction, 40);
    ExpectEq('reached action', Ord(M.Phase), Ord(gpAction));
    ExpectEq('first action is sing', Ord(M.CurrentAction), Ord(gaSingAndWave));
    while M.DrainSfx(Kind) do
      if Kind = sfxSong then
        SawSong := True;
    ExpectTrue('song sfx on sing action', SawSong);
    P := M.Pose;
    ExpectTrue('caption during sing', P.ShowCaption);
    ExpectTrue('fully risen', P.Rise > 0.99);

    RunUntil(M, gpDormant, 400);
    ExpectTrue('returns to dormant', not M.Busy);
    ExpectEq('toggle to wave next', Ord(M.Config.NextAction), Ord(gaJustWave));

    M.Trigger;
    RunUntil(M, gpAction, 80);
    ExpectEq('second action is wave', Ord(M.CurrentAction), Ord(gaJustWave));
    P := M.Pose;
    ExpectTrue('no caption on wave', not P.ShowCaption);
    SawSong := False;
    while M.DrainSfx(Kind) do
      if Kind = sfxSong then
        SawSong := True;
    ExpectTrue('wave does not sing', not SawSong);

    RunUntil(M, gpDormant, 200);
    ExpectEq('toggle back to sing', Ord(M.Config.NextAction), Ord(gaSingAndWave));

    M.ForcePose(gpAction, gaSingAndWave, 0.5);
    ExpectEq('force pose action', Ord(M.Phase), Ord(gpAction));
    P := M.Pose;
    ExpectTrue('forced rise', P.Rise > 0.99);
  finally
    M.Free;
  end;

  C := TGrouchController.Create(160, 220, 22, 22, 120, 160, DefaultConfig, False);
  try
    C.ApplyChar('M');
    ExpectTrue('muted', C.Model.Config.Muted);
    C.ApplyChar('W');
    ExpectTrue('widget on', C.ShowWidget);
    C.ApplyChar(' ');
    ExpectTrue('space triggers', C.Model.Busy);
    C.Tick;
    C.Render;
    ExpectEq('overlay width', C.Overlay.Width, 160);
    C.ConsumePresent;
  finally
    C.Free;
  end;

  WriteLn('all tests passed');
end.
