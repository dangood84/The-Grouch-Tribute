unit ugrouchmodel;

{$mode objfpc}{$H+}

{ Linear animation: dormant until Trigger, then lid → rise → action →
  sink → lid close, and the sing/wave bit flips. Hosts only call
  Trigger / Update / DrainSfx; they never advance phases themselves. }

interface

uses
  ugrouchconfig, ugrouchaudio;

type
  TGrouchPhase = (
    gpDormant,
    gpLidOpen,
    gpRise,
    gpAction,
    gpSink,
    gpLidClose
  );

  TGrouchPose = record
    Phase: TGrouchPhase;
    Action: TGrouchAction;
    Progress: Double;     { 0..1 inside the current phase }
    LidAngle: Double;     { 0 closed .. 1 flipped fully open }
    Rise: Double;         { 0 hidden in the can .. 1 popped out }
    Wave: Double;         { -1 .. 1 arm swing }
    Mouth: Double;        { 0 frown .. 1 sung O }
    ShowCaption: Boolean;
    Visible: Boolean;     { overlay should be on screen }
  end;

  TGrouchModel = class
  private
    FConfig: TGrouchConfig;
    FPhase: TGrouchPhase;
    FAction: TGrouchAction;
    FPhaseT: Double;
    FAnimT: Double;
    FSfx: array[0..7] of TSfxKind;
    FSfxCount: Integer;
    procedure PushSfx(Kind: TSfxKind);
    procedure EnterPhase(Next: TGrouchPhase);
    function PhaseDuration(Ph: TGrouchPhase): Double;
  public
    constructor Create;
    procedure SetConfig(const Cfg: TGrouchConfig);
    procedure Trigger;
    procedure Update(Dt: Double);
    procedure ForcePose(Phase: TGrouchPhase; Action: TGrouchAction; Progress: Double);
    function DrainSfx(out Kind: TSfxKind): Boolean;
    function Pose: TGrouchPose;
    function Busy: Boolean;
    property Config: TGrouchConfig read FConfig;
    property Phase: TGrouchPhase read FPhase;
    property CurrentAction: TGrouchAction read FAction;
  end;

function PhaseName(Ph: TGrouchPhase): string;
function LidOpenDuration: Double;
function RiseDuration: Double;
function WaveDuration: Double;
function SinkDuration: Double;
function LidCloseDuration: Double;

implementation

uses
  Math;

const
  kLidOpen = 0.38;
  kRise = 0.55;
  kWave = 1.65;
  kSink = 0.48;
  kLidClose = 0.32;

function LidOpenDuration: Double;
begin
  Result := kLidOpen;
end;

function RiseDuration: Double;
begin
  Result := kRise;
end;

function WaveDuration: Double;
begin
  Result := kWave;
end;

function SinkDuration: Double;
begin
  Result := kSink;
end;

function LidCloseDuration: Double;
begin
  Result := kLidClose;
end;

function PhaseName(Ph: TGrouchPhase): string;
begin
  case Ph of
    gpDormant: Result := 'dormant';
    gpLidOpen: Result := 'lid-open';
    gpRise: Result := 'rise';
    gpAction: Result := 'action';
    gpSink: Result := 'sink';
    gpLidClose: Result := 'lid-close';
    else Result := 'unknown';
  end;
end;

function Clamp01(V: Double): Double;
begin
  if V < 0 then
    Result := 0
  else if V > 1 then
    Result := 1
  else
    Result := V;
end;

function EaseOutCubic(T: Double): Double;
begin
  T := Clamp01(T);
  Result := 1 - Power(1 - T, 3);
end;

function EaseOutBack(T: Double): Double;
var
  C: Double;
begin
  T := Clamp01(T);
  C := 1.70158;
  Result := 1 + (C + 1) * Power(T - 1, 3) + C * Power(T - 1, 2);
  if Result > 1.12 then
    Result := 1.12;
end;

constructor TGrouchModel.Create;
begin
  inherited Create;
  FConfig := DefaultConfig;
  FPhase := gpDormant;
  FAction := gaSingAndWave;
  FPhaseT := 0;
  FAnimT := 0;
  FSfxCount := 0;
end;

procedure TGrouchModel.SetConfig(const Cfg: TGrouchConfig);
begin
  FConfig := Cfg;
end;

procedure TGrouchModel.PushSfx(Kind: TSfxKind);
begin
  if Kind = sfxNone then
    Exit;
  if FSfxCount >= Length(FSfx) then
    Exit;
  FSfx[FSfxCount] := Kind;
  Inc(FSfxCount);
end;

function TGrouchModel.PhaseDuration(Ph: TGrouchPhase): Double;
begin
  case Ph of
    gpLidOpen: Result := kLidOpen;
    gpRise: Result := kRise;
    gpAction:
      if FAction = gaSingAndWave then
        Result := SongDuration
      else
        Result := kWave;
    gpSink: Result := kSink;
    gpLidClose: Result := kLidClose;
    else Result := 0;
  end;
end;

procedure TGrouchModel.EnterPhase(Next: TGrouchPhase);
begin
  { State change: leave one linear step, enter the next. Audio is
    queued here so the renderer never starts a sound. }
  FPhase := Next;
  FPhaseT := 0;
  case Next of
    gpDormant:
      begin
        FAnimT := 0;
        { Performance finished — flip so the *next* Empty Trash does
          the other routine, and remember it across launches. }
        ToggleNextAction(FConfig);
      end;
    gpLidOpen:
      begin
        FAnimT := 0;
        PushSfx(sfxLid);
      end;
    gpRise: ;
    gpAction:
      begin
        FAnimT := 0;
        if FAction = gaSingAndWave then
          PushSfx(sfxSong);
      end;
    gpSink: ;
    gpLidClose: ;
  end;
end;

procedure TGrouchModel.Trigger;
begin
  if FPhase <> gpDormant then
    Exit; { already performing; Empty Trash during a song is ignored }
  { State change: DORMANT → POP UP. Latch the action *now* so a config
    edit mid-song cannot swap sing ↔ wave halfway through. }
  FAction := FConfig.NextAction;
  EnterPhase(gpLidOpen);
end;

procedure TGrouchModel.Update(Dt: Double);
var
  Dur: Double;
begin
  if Dt < 0 then
    Dt := 0;
  if Dt > 0.05 then
    Dt := 0.05; { hitch guard — same cap as Lemmings / Toasters }
  if FPhase = gpDormant then
    Exit;
  FPhaseT := FPhaseT + Dt;
  FAnimT := FAnimT + Dt;
  Dur := PhaseDuration(FPhase);
  if (Dur > 0) and (FPhaseT >= Dur) then
  begin
    { State change: this step's clock ran out. }
    case FPhase of
      gpLidOpen: EnterPhase(gpRise);
      gpRise: EnterPhase(gpAction);
      gpAction: EnterPhase(gpSink);
      gpSink: EnterPhase(gpLidClose);
      gpLidClose: EnterPhase(gpDormant);
    end;
  end;
end;

procedure TGrouchModel.ForcePose(Phase: TGrouchPhase; Action: TGrouchAction; Progress: Double);
begin
  { Tests and snapshots jump straight to a frame. No sfx, no toggle. }
  FPhase := Phase;
  FAction := Action;
  FPhaseT := Clamp01(Progress) * PhaseDuration(Phase);
  FAnimT := FPhaseT;
  FSfxCount := 0;
end;

function TGrouchModel.DrainSfx(out Kind: TSfxKind): Boolean;
var
  I: Integer;
begin
  Result := FSfxCount > 0;
  if not Result then
  begin
    Kind := sfxNone;
    Exit;
  end;
  Kind := FSfx[0];
  for I := 1 to FSfxCount - 1 do
    FSfx[I - 1] := FSfx[I];
  Dec(FSfxCount);
end;

function TGrouchModel.Pose: TGrouchPose;
var
  Dur, T: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Phase := FPhase;
  Result.Action := FAction;
  Dur := PhaseDuration(FPhase);
  if Dur > 0 then
    T := Clamp01(FPhaseT / Dur)
  else
    T := 0;
  Result.Progress := T;
  Result.Visible := FPhase <> gpDormant;
  Result.LidAngle := 0;
  Result.Rise := 0;
  Result.Wave := 0;
  Result.Mouth := 0.12;
  Result.ShowCaption := False;

  case FPhase of
    gpDormant:
      begin
        Result.LidAngle := 0;
        Result.Rise := 0;
      end;
    gpLidOpen:
      begin
        Result.LidAngle := EaseOutCubic(T);
        Result.Rise := 0;
      end;
    gpRise:
      begin
        Result.LidAngle := 1;
        Result.Rise := EaseOutBack(T);
      end;
    gpAction:
      begin
        Result.LidAngle := 1;
        Result.Rise := 1;
        Result.Wave := Sin(FAnimT * 8.2);
        if FAction = gaSingAndWave then
        begin
          Result.Mouth := SongMouthAt(FAnimT);
          Result.ShowCaption := True;
        end
        else
        begin
          Result.Mouth := 0.10;
          Result.Wave := Sin(FAnimT * 9.5);
        end;
      end;
    gpSink:
      begin
        Result.LidAngle := 1;
        Result.Rise := 1 - EaseOutCubic(T);
        Result.Wave := Sin(FAnimT * 6) * (1 - T);
        Result.Mouth := 0.10;
      end;
    gpLidClose:
      begin
        Result.LidAngle := 1 - EaseOutCubic(T);
        Result.Rise := 0;
      end;
  end;
end;

function TGrouchModel.Busy: Boolean;
begin
  Result := FPhase <> gpDormant;
end;

end.
