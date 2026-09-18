unit ugrouchconfig;

{$mode objfpc}{$H+}

{ Mute, desktop-bin visibility, and the sing/wave toggle. The live
  animation phase lives on TGrouchModel so a saved INI cannot freeze
  Oscar mid-rise. NextAction is the one piece of performance memory
  that *should* survive a relaunch — that is how the classic utility
  alternated "I love trash" with a silent wave. }

interface

type
  TGrouchAction = (gaSingAndWave, gaJustWave);

  TGrouchConfig = record
    Muted: Boolean;
    ShowWidget: Boolean;
    NextAction: TGrouchAction;
  end;

function DefaultConfig: TGrouchConfig;
function LoadConfig: TGrouchConfig;
procedure SaveConfig(const Cfg: TGrouchConfig);
procedure ToggleNextAction(var Cfg: TGrouchConfig);
function ActionName(Action: TGrouchAction): string;

implementation

uses
  IniFiles, SysUtils;

const
  Section = 'grouch';

function ConfigPath: string;
var
  Dir: string;
begin
  { Per-user OS config dir, not the repo, so relaunch keeps the toggle. }
  Dir := GetAppConfigDir(False);
  ForceDirectories(Dir);
  Result := IncludeTrailingPathDelimiter(Dir) + 'thegrouch.ini';
end;

function DefaultConfig: TGrouchConfig;
begin
  Result.Muted := False;
  Result.ShowWidget := False;
  Result.NextAction := gaSingAndWave; { first Empty Trash sings, next one waves }
end;

function LoadConfig: TGrouchConfig;
var
  Ini: TIniFile;
  Sing: Boolean;
begin
  Result := DefaultConfig;
  if not FileExists(ConfigPath) then
    Exit;
  Ini := TIniFile.Create(ConfigPath);
  try
    Result.Muted := Ini.ReadBool(Section, 'muted', Result.Muted);
    Result.ShowWidget := Ini.ReadBool(Section, 'widget', Result.ShowWidget);
    Sing := Ini.ReadBool(Section, 'nextsing', True);
    if Sing then
      Result.NextAction := gaSingAndWave
    else
      Result.NextAction := gaJustWave;
  finally
    Ini.Free;
  end;
end;

procedure SaveConfig(const Cfg: TGrouchConfig);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(ConfigPath);
  try
    Ini.WriteBool(Section, 'muted', Cfg.Muted);
    Ini.WriteBool(Section, 'widget', Cfg.ShowWidget);
    Ini.WriteBool(Section, 'nextsing', Cfg.NextAction = gaSingAndWave);
  finally
    Ini.Free;
  end;
end;

procedure ToggleNextAction(var Cfg: TGrouchConfig);
begin
  { State change: the just-finished performance decides the other one
    is next. Classic Grouch INIT flipped this bit after every Empty Trash. }
  if Cfg.NextAction = gaSingAndWave then
    Cfg.NextAction := gaJustWave
  else
    Cfg.NextAction := gaSingAndWave;
end;

function ActionName(Action: TGrouchAction): string;
begin
  if Action = gaSingAndWave then
    Result := 'sing'
  else
    Result := 'wave';
end;

end.
