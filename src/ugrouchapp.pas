unit ugrouchapp;

{$mode objfpc}{$H+}

{ One model, three canvases (Dock overlay, menu-bar icon, optional
  desktop bin). Hosts call Trigger when Empty Trash happens or the user
  clicks Come Out!, Tick on a timer, and present when NeedsPresent. }

interface

uses
  ugrouchconfig, ugrouchmodel, ugrouchrender;

const
  GrouchAboutTitle = 'The Grouch Tribute';
  GrouchAboutText =
    'A tribute to the classic Mac OS utility that popped a grouch out of ' +
    'the Wastebasket when you chose Empty Trash from the Special menu.' + LineEnding + LineEnding +
    'On modern macOS that menu lives under Finder (Empty Bin / Empty Trash). ' +
    'This helper asks Finder for the Bin''s item count — macOS does not let ' +
    'ordinary apps read ~/.Trash. Allow Control of Finder when prompted so ' +
    'Empty Bin can wake him. Accessibility is optional and only used to sit ' +
    'exactly on the Dock Bin icon.' + LineEnding + LineEnding +
    'He alternates: one Empty Trash he sings an original 8-bit shout and ' +
    'waves; the next time he just waves. The toggle is saved across launches.' + LineEnding + LineEnding +
    'Original sprites and chip sounds. Not affiliated with Sesame Workshop, ' +
    'Apple, or the classic Grouch INIT.' + LineEnding + LineEnding +
    'From the menu extra:' + LineEnding +
    '  Come Out!     play the sequence now' + LineEnding +
    '  M             mute the lid and the song' + LineEnding +
    '  Show Desktop Bin   clickable can on the desktop' + LineEnding + LineEnding +
    'Quit from the menu extra (macOS / Linux) or the tray icon (Windows).';

type
  TGrouchController = class
  private
    FNeedsPresent: Boolean;
    FLastMs: QWord;
    FPersist: Boolean;
    FBarW, FBarH: Integer;
    FWidgetW, FWidgetH: Integer;
  public
    Model: TGrouchModel;
    Overlay: TPixelBuffer;
    Bar: TPixelBuffer;
    Widget: TPixelBuffer;
    constructor Create(PixelW, PixelH, BarW, BarH, WidgetW, WidgetH: Integer;
      const Cfg: TGrouchConfig; Persist: Boolean = True);
    destructor Destroy; override;
    procedure Resize(PixelW, PixelH: Integer);
    procedure Tick;
    procedure Render;
    procedure Trigger;
    procedure ApplyChar(Ch: Char);
    procedure ConsumePresent;
    procedure SaveIfNeeded;
    function ShowWidget: Boolean;
    property NeedsPresent: Boolean read FNeedsPresent;
  end;

implementation

uses
  SysUtils;

constructor TGrouchController.Create(PixelW, PixelH, BarW, BarH, WidgetW, WidgetH: Integer;
  const Cfg: TGrouchConfig; Persist: Boolean);
begin
  inherited Create;
  FPersist := Persist;
  FBarW := BarW;
  FBarH := BarH;
  FWidgetW := WidgetW;
  FWidgetH := WidgetH;
  Model := TGrouchModel.Create;
  Model.SetConfig(Cfg);
  Overlay := TPixelBuffer.Create(PixelW, PixelH);
  Bar := TPixelBuffer.Create(BarW, BarH);
  Widget := TPixelBuffer.Create(WidgetW, WidgetH);
  FNeedsPresent := True;
  FLastMs := 0;
end;

destructor TGrouchController.Destroy;
begin
  SaveIfNeeded;
  Widget.Free;
  Bar.Free;
  Overlay.Free;
  Model.Free;
  inherited Destroy;
end;

procedure TGrouchController.SaveIfNeeded;
begin
  if FPersist then
    SaveConfig(Model.Config);
end;

procedure TGrouchController.Resize(PixelW, PixelH: Integer);
begin
  if (PixelW = Overlay.Width) and (PixelH = Overlay.Height) then
    Exit;
  Overlay.Resize(PixelW, PixelH);
  FNeedsPresent := True;
end;

procedure TGrouchController.Tick;
var
  NowMs: QWord;
  Dt: Double;
  WasBusy: Boolean;
begin
  NowMs := GetTickCount64;
  if FLastMs = 0 then
  begin
    FLastMs := NowMs;
    FNeedsPresent := True;
    Exit;
  end;
  Dt := (NowMs - FLastMs) / 1000.0;
  FLastMs := NowMs;
  WasBusy := Model.Busy;
  Model.Update(Dt);
  { Keep presenting while he is out, and one extra frame when he hides
    so the overlay can go transparent / orderOut. }
  if Model.Busy or WasBusy then
    FNeedsPresent := True;
  if WasBusy and (not Model.Busy) then
    SaveIfNeeded; { persist the sing/wave flip as soon as he ducks back }
end;

procedure TGrouchController.Render;
begin
  RenderGrouch(Overlay, Model);
  RenderBarIcon(Bar, Model);
  RenderWidget(Widget, Model);
end;

procedure TGrouchController.Trigger;
begin
  Model.Trigger;
  FNeedsPresent := True;
end;

procedure TGrouchController.ApplyChar(Ch: Char);
var
  Cfg: TGrouchConfig;
begin
  Cfg := Model.Config;
  case UpCase(Ch) of
    'M':
      Cfg.Muted := not Cfg.Muted;
    'W':
      Cfg.ShowWidget := not Cfg.ShowWidget;
    ' ':
      Trigger;
  end;
  Model.SetConfig(Cfg);
  FNeedsPresent := True;
end;

procedure TGrouchController.ConsumePresent;
begin
  FNeedsPresent := False;
end;

function TGrouchController.ShowWidget: Boolean;
begin
  Result := Model.Config.ShowWidget;
end;

end.
