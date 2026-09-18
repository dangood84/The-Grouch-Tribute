unit uhostwin;

{$mode objfpc}{$H+}

{ Windows tray icon + small layered overlay. Same TGrouchController as
  macOS; this unit presents BGRA pixels, polls the Recycle Bin, and
  plays original WAV stings. }

interface

procedure HostRun;

implementation

{$IFDEF WINDOWS}

uses
  Windows, Messages, ShellAPI, SysUtils, MMSystem, ugrouchconfig,
  ugrouchapp, ugrouchaudio, ugrouchrender, ugrouchtrash;

const
  AppName = 'TheGrouchWnd';
  WmTray = WM_APP + 42;
  IdTray = 1;
  CmdComeOut = 1001;
  CmdMute = 1002;
  CmdWidget = 1003;
  CmdAbout = 1004;
  CmdQuit = 1005;
  OverlayW = 160;
  OverlayH = 220;
  BarW = 32;
  BarH = 32;
  WidgetW = 120;
  WidgetH = 160;
  TickId = 1;
  TickMs = 33;

type
  TSHQueryRBInfo = record
    cbSize: DWORD;
    i64Size: Int64;
    i64NumItems: Int64;
  end;

function SHQueryRecycleBinA(pszRootPath: PAnsiChar; var Info: TSHQueryRBInfo): HRESULT;
  stdcall; external 'shell32.dll' name 'SHQueryRecycleBinA';

var
  Controller: TGrouchController;
  OverlayWnd: HWND;
  WidgetWnd: HWND;
  TrayIcon: NOTIFYICONDATA;
  Bgra: array of Byte;
  SfxWav: array[sfxLid..sfxSong] of TBytes;
  SfxHold: array[0..3] of TBytes;
  SfxSlot: Integer;
  LastTrash: Integer;
  PollAcc: Integer;
  LastTriggerMs: QWord;
  AtWidget: Boolean;

function RecycleCount: Integer;
var
  Info: TSHQueryRBInfo;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  if SHQueryRecycleBinA(nil, Info) = 0 then
    Result := Integer(Info.i64NumItems)
  else
    Result := 0;
end;

procedure PlaySfx(Kind: TSfxKind);
begin
  if (Kind < sfxLid) or (Kind > sfxSong) then
    Exit;
  if Length(SfxWav[Kind]) < 44 then
    Exit;
  SfxHold[SfxSlot] := SfxWav[Kind];
  PlaySound(PChar(@SfxHold[SfxSlot][0]), 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT);
  SfxSlot := (SfxSlot + 1) mod Length(SfxHold);
end;

procedure DrainAudio;
var
  Kind: TSfxKind;
begin
  if Controller = nil then
    Exit;
  if Controller.Model.Config.Muted then
  begin
    while Controller.Model.DrainSfx(Kind) do
      ;
    Exit;
  end;
  while Controller.Model.DrainSfx(Kind) do
    PlaySfx(Kind);
end;

procedure PresentLayered(Wnd: HWND; Buf: TPixelBuffer);
var
  ScreenDC, MemDC: HDC;
  Info: BITMAPINFO;
  Bits: Pointer;
  Dib, Old: HBITMAP;
  Blend: BLENDFUNCTION;
  Size: SIZE;
  SrcPt, DstPt: TPoint;
  R: TRect;
begin
  SetLength(Bgra, Buf.Width * Buf.Height * 4);
  CopyBGRA(Buf, @Bgra[0]);

  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  Info.bmiHeader.biWidth := Buf.Width;
  Info.bmiHeader.biHeight := -Buf.Height;
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 32;
  Info.bmiHeader.biCompression := BI_RGB;

  ScreenDC := GetDC(0);
  MemDC := CreateCompatibleDC(ScreenDC);
  Bits := nil;
  Dib := CreateDIBSection(ScreenDC, Info, DIB_RGB_COLORS, Bits, 0, 0);
  Old := SelectObject(MemDC, Dib);
  if (Bits <> nil) and (Length(Bgra) > 0) then
    Move(Bgra[0], Bits^, Length(Bgra));

  GetWindowRect(Wnd, R);
  Size.cx := Buf.Width;
  Size.cy := Buf.Height;
  SrcPt.X := 0;
  SrcPt.Y := 0;
  DstPt.X := R.Left;
  DstPt.Y := R.Top;
  FillChar(Blend, SizeOf(Blend), 0);
  Blend.BlendOp := AC_SRC_OVER;
  Blend.SourceConstantAlpha := 255;
  Blend.AlphaFormat := AC_SRC_ALPHA;
  UpdateLayeredWindow(Wnd, ScreenDC, @DstPt, @Size, MemDC, @SrcPt, 0, @Blend, ULW_ALPHA);

  SelectObject(MemDC, Old);
  if Dib <> 0 then
    DeleteObject(Dib);
  DeleteDC(MemDC);
  ReleaseDC(0, ScreenDC);
end;

procedure PlaceOverlay;
var
  Mi: TMonitorInfo;
  Mon: HMONITOR;
  X, Y: Integer;
  Wr: TRect;
begin
  if AtWidget and (WidgetWnd <> 0) then
  begin
    GetWindowRect(WidgetWnd, Wr);
    SetWindowPos(OverlayWnd, HWND_TOPMOST,
      Wr.Left + (Wr.Right - Wr.Left - OverlayW) div 2, Wr.Top,
      OverlayW, OverlayH, SWP_SHOWWINDOW);
    Exit;
  end;
  FillChar(Mi, SizeOf(Mi), 0);
  Mi.cbSize := SizeOf(Mi);
  Mon := MonitorFromWindow(OverlayWnd, MONITOR_DEFAULTTOPRIMARY);
  GetMonitorInfo(Mon, @Mi);
  X := Mi.rcWork.Right - OverlayW - 24;
  Y := Mi.rcWork.Bottom - OverlayH - 8;
  SetWindowPos(OverlayWnd, HWND_TOPMOST, X, Y, OverlayW, OverlayH, SWP_SHOWWINDOW);
end;

procedure FireIfAllowed(FromWidget: Boolean);
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if Now - LastTriggerMs < 1500 then
    Exit;
  if (Controller <> nil) and Controller.Model.Busy then
    Exit;
  AtWidget := FromWidget;
  LastTriggerMs := Now;
  Controller.Trigger;
end;

procedure WatchTrash;
var
  NowCount: Integer;
begin
  Inc(PollAcc);
  if PollAcc < 15 then
    Exit;
  PollAcc := 0;
  NowCount := RecycleCount;
  if TrashWasEmptied(LastTrash, NowCount) then
    FireIfAllowed(False);
  LastTrash := NowCount;
end;

procedure ShowAbout(Wnd: HWND);
begin
  MessageBox(Wnd, PChar(GrouchAboutText), GrouchAboutTitle, MB_OK or MB_ICONINFORMATION);
end;

procedure PopupMenuAtCursor(Wnd: HWND);
var
  Menu: HMENU;
  Pt: TPoint;
begin
  Menu := CreatePopupMenu;
  AppendMenu(Menu, MF_STRING, CmdComeOut, '&Come Out!');
  AppendMenu(Menu, MF_STRING, CmdMute, '&Mute Sounds');
  AppendMenu(Menu, MF_STRING, CmdWidget, 'Show Desktop &Bin');
  AppendMenu(Menu, MF_SEPARATOR, 0, nil);
  AppendMenu(Menu, MF_STRING, CmdAbout, '&About...');
  AppendMenu(Menu, MF_STRING, CmdQuit, 'E&xit');
  GetCursorPos(Pt);
  SetForegroundWindow(Wnd);
  TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.X, Pt.Y, 0, Wnd, nil);
  DestroyMenu(Menu);
end;

function OverlayProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case Msg of
    WM_TIMER:
      if WParam = TickId then
      begin
        WatchTrash;
        Controller.Tick;
        DrainAudio;
        if Controller.Model.Busy then
        begin
          PlaceOverlay;
          if Controller.NeedsPresent then
          begin
            Controller.Render;
            PresentLayered(OverlayWnd, Controller.Overlay);
            Controller.ConsumePresent;
          end;
        end
        else
          ShowWindow(OverlayWnd, SW_HIDE);
        if Controller.ShowWidget then
        begin
          ShowWindow(WidgetWnd, SW_SHOW);
          Controller.Render;
          PresentLayered(WidgetWnd, Controller.Widget);
        end
        else
          ShowWindow(WidgetWnd, SW_HIDE);
      end;
    WM_COMMAND:
      case LOWORD(WParam) of
        CmdComeOut: begin AtWidget := False; Controller.Trigger; end;
        CmdMute: Controller.ApplyChar('M');
        CmdWidget: Controller.ApplyChar('W');
        CmdAbout: ShowAbout(Wnd);
        CmdQuit: PostQuitMessage(0);
      end;
    WmTray:
      if (LParam = WM_RBUTTONUP) or (LParam = WM_LBUTTONUP) then
        PopupMenuAtCursor(Wnd);
    WM_DESTROY:
      begin
        KillTimer(Wnd, TickId);
        Shell_NotifyIcon(NIM_DELETE, @TrayIcon);
        PlaySound(nil, 0, 0);
        PostQuitMessage(0);
      end;
    else
      Result := DefWindowProc(Wnd, Msg, WParam, LParam);
  end;
end;

function WidgetProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case Msg of
    WM_LBUTTONUP:
      FireIfAllowed(True);
    WM_NCHITTEST:
      begin
        Result := DefWindowProc(Wnd, Msg, WParam, LParam);
        if Result = HTCLIENT then
          Result := HTCAPTION; { drag the desktop bin }
      end;
    else
      Result := DefWindowProc(Wnd, Msg, WParam, LParam);
  end;
end;

procedure HostRun;
var
  WC: WNDCLASS;
  Msg: TMsg;
  Kind: TSfxKind;
  Ex: DWORD;
begin
  SfxSlot := 0;
  PollAcc := 0;
  LastTriggerMs := 0;
  AtWidget := False;
  for Kind := sfxLid to sfxSong do
    SfxWav[Kind] := BuildSfxWav(Kind);

  Controller := TGrouchController.Create(OverlayW, OverlayH, BarW, BarH,
    WidgetW, WidgetH, LoadConfig);
  LastTrash := RecycleCount;

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @OverlayProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.lpszClassName := AppName;
  WC.hbrBackground := 0;
  RegisterClass(WC);

  WC.lpfnWndProc := @WidgetProc;
  WC.lpszClassName := 'TheGrouchWidget';
  RegisterClass(WC);

  Ex := WS_EX_LAYERED or WS_EX_TOOLWINDOW or WS_EX_TOPMOST;
  OverlayWnd := CreateWindowEx(Ex, AppName, 'The Grouch Tribute',
    WS_POPUP, 0, 0, OverlayW, OverlayH, 0, 0, HInstance, nil);
  WidgetWnd := CreateWindowEx(WS_EX_LAYERED or WS_EX_TOOLWINDOW,
    'TheGrouchWidget', 'Grouch Bin', WS_POPUP, 80, 80, WidgetW, WidgetH,
    0, 0, HInstance, nil);

  FillChar(TrayIcon, SizeOf(TrayIcon), 0);
  TrayIcon.cbSize := SizeOf(TrayIcon);
  TrayIcon.Wnd := OverlayWnd;
  TrayIcon.uID := IdTray;
  TrayIcon.uFlags := NIF_MESSAGE or NIF_TIP or NIF_ICON;
  TrayIcon.uCallbackMessage := WmTray;
  TrayIcon.hIcon := LoadIcon(0, IDI_APPLICATION);
  StrPCopy(TrayIcon.szTip, 'The Grouch Tribute');
  Shell_NotifyIcon(NIM_ADD, @TrayIcon);

  SetTimer(OverlayWnd, TickId, TickMs, nil);
  ShowWindow(OverlayWnd, SW_HIDE);

  while GetMessage(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
