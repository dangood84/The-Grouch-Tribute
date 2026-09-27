unit uhostgtk;

{$mode objfpc}{$H+}

{ Linux GTK 2 panel icon + small overlay. Same TGrouchController as
  macOS; this unit presents a GdkPixbuf, polls the user Trash folder,
  and plays original WAV stings via paplay/aplay.

  Raspberry Pi OS has no compositor for the gdk rgba colormap — that
  path is an opaque white sheet (same as Lemmings Overlay). These
  windows stay on a normal visual and punch a 1-bit X shape from the
  sprite alpha. }

interface

procedure HostRun;

implementation

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}

uses
  SysUtils, Classes, ctypes, gtk2, gdk2, gdk2pixbuf, glib2, Unix,
  ugrouchconfig, ugrouchapp, ugrouchaudio, ugrouchrender, ugrouchtrash;

type
  PGtkStatusIcon = Pointer;

function gtk_status_icon_new: PGtkStatusIcon; cdecl; external;
procedure gtk_status_icon_set_from_pixbuf(icon: PGtkStatusIcon; pixbuf: PGdkPixbuf); cdecl; external;
procedure gtk_status_icon_set_visible(icon: PGtkStatusIcon; visible: gboolean); cdecl; external;
procedure gtk_status_icon_set_tooltip(icon: PGtkStatusIcon; text: Pgchar); cdecl; external;
function gtk_widget_get_window(widget: PGtkWidget): PGdkWindow; cdecl; external;

const
  OverlayW = 160;
  OverlayH = 220;
  BarW = 24;
  BarH = 24;
  WidgetW = 120;
  WidgetH = 160;
  TickMs = 33;
  { Pixels below this stay out of the 1-bit mask. AA fringe is ~0.35. }
  ShapeAlpha = 48;

var
  Controller: TGrouchController;
  Overlay: PGtkWidget;
  Widget: PGtkWidget;
  StatusIcon: PGtkStatusIcon;
  OverlayPix, BarPix, WidgetPix: PGdkPixbuf;
  SfxWav: array[sfxLid..sfxSong] of TBytes;
  SfxPath: array[sfxLid..sfxSong] of string;
  Popup: PGtkWidget;
  LastTrash: Integer;
  PollAcc: Integer;
  LastTriggerMs: QWord;
  AtWidget: Boolean;

procedure DestroyPix(var Pix: PGdkPixbuf);
begin
  if Pix <> nil then
  begin
    g_object_unref(Pix);
    Pix := nil;
  end;
end;

procedure EnsurePix(var Pix: PGdkPixbuf; W, H: Integer);
begin
  if (W < 1) or (H < 1) then
    Exit;
  if (Pix <> nil) and (gdk_pixbuf_get_width(Pix) = W) and
     (gdk_pixbuf_get_height(Pix) = H) then
    Exit;
  DestroyPix(Pix);
  Pix := gdk_pixbuf_new(GDK_COLORSPACE_RGB, True, 8, W, H);
end;

procedure PixbufFromBuffer(Pix: PGdkPixbuf; Buf: TPixelBuffer);
var
  Pixels: PByte;
  Row: Integer;
  Src, Dst: PByte;
  BufW: Integer;
begin
  if Pix = nil then
    Exit;
  BufW := Buf.Width;
  Pixels := PByte(gdk_pixbuf_get_pixels(Pix));
  for Row := 0 to Buf.Height - 1 do
  begin
    Src := Buf.Ptr + Row * BufW * 4;
    Dst := Pixels + Row * gdk_pixbuf_get_rowstride(Pix);
    Move(Src^, Dst^, BufW * 4);
  end;
end;

procedure WriteSfxFiles;
var
  Kind: TSfxKind;
  Path: string;
  F: File;
begin
  for Kind := sfxLid to sfxSong do
  begin
    SfxWav[Kind] := BuildSfxWav(Kind);
    Path := IncludeTrailingPathDelimiter(GetTempDir) + 'grouch-' + SfxName(Kind) + '.wav';
    SfxPath[Kind] := Path;
    AssignFile(F, Path);
    Rewrite(F, 1);
    if Length(SfxWav[Kind]) > 0 then
      BlockWrite(F, SfxWav[Kind][0], Length(SfxWav[Kind]));
    CloseFile(F);
  end;
end;

procedure PlaySfx(Kind: TSfxKind);
var
  Cmd: string;
begin
  if (Kind < sfxLid) or (Kind > sfxSong) then
    Exit;
  Cmd := '(paplay ' + SfxPath[Kind] + ' || aplay -q ' + SfxPath[Kind] +
    ') >/dev/null 2>&1 &';
  fpSystem(Cmd);
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
  NowCount := CountTrashItems(DefaultTrashDir);
  if TrashWasEmptied(LastTrash, NowCount) then
    FireIfAllowed(False);
  LastTrash := NowCount;
end;

procedure PlaceOverlay;
var
  Screen: PGdkScreen;
  W, H: Integer;
  Wx, Wy, Ww, Wh: gint;
begin
  if AtWidget and (Widget <> nil) then
  begin
    gtk_window_get_position(PGtkWindow(Widget), @Wx, @Wy);
    gtk_window_get_size(PGtkWindow(Widget), @Ww, @Wh);
    gtk_window_move(PGtkWindow(Overlay), Wx + (Ww - OverlayW) div 2, Wy);
    Exit;
  end;
  Screen := gdk_screen_get_default;
  W := gdk_screen_get_width(Screen);
  H := gdk_screen_get_height(Screen);
  gtk_window_move(PGtkWindow(Overlay), W - OverlayW - 24, H - OverlayH - 48);
end;

function GdkWinOf(Win: PGtkWidget): PGdkWindow;
begin
  Result := nil;
  if Win = nil then
    Exit;
  Result := gtk_widget_get_window(Win);
  if Result = nil then
    Result := Win^.window;
end;

procedure ApplyShaped(Win: PGtkWidget; Pix: PGdkPixbuf);
var
  GdkWin: PGdkWindow;
  Mask, Colour: PGdkPixmap;
  Gc: PGdkGC;
  W, H: Integer;
begin
  { Install RGB as the X background, then punch a 1-bit hole for alpha 0.
    Expose then copies that pixmap instead of filling the GTK theme white. }
  if (Win = nil) or (Pix = nil) then
    Exit;
  gtk_widget_realize(Win);
  GdkWin := GdkWinOf(Win);
  if GdkWin = nil then
    Exit;
  W := gdk_pixbuf_get_width(Pix);
  H := gdk_pixbuf_get_height(Pix);
  if (W < 1) or (H < 1) then
    Exit;

  Colour := gdk_pixmap_new(GdkWin, W, H, -1);
  if Colour <> nil then
  begin
    Gc := gdk_gc_new(Colour);
    if Gc <> nil then
    begin
      gdk_draw_rgb_32_image(Colour, Gc, 0, 0, W, H, GDK_RGB_DITHER_NONE,
        gdk_pixbuf_get_pixels(Pix), gdk_pixbuf_get_rowstride(Pix));
      g_object_unref(Gc);
    end;
    gdk_window_set_back_pixmap(GdkWin, Colour, False);
    g_object_unref(Colour);
  end;

  Mask := gdk_pixmap_new(GdkWin, W, H, 1);
  if Mask <> nil then
  begin
    gdk_pixbuf_render_threshold_alpha(Pix, Mask, 0, 0, 0, 0, W, H, ShapeAlpha);
    gdk_window_shape_combine_mask(GdkWin, Mask, 0, 0);
    g_object_unref(Mask);
  end;
  gdk_window_clear(GdkWin);
end;

procedure Present;
begin
  Controller.Render;
  EnsurePix(OverlayPix, Controller.Overlay.Width, Controller.Overlay.Height);
  EnsurePix(BarPix, Controller.Bar.Width, Controller.Bar.Height);
  EnsurePix(WidgetPix, Controller.Widget.Width, Controller.Widget.Height);
  PixbufFromBuffer(OverlayPix, Controller.Overlay);
  PixbufFromBuffer(BarPix, Controller.Bar);
  PixbufFromBuffer(WidgetPix, Controller.Widget);
  Controller.ConsumePresent;
  if (Overlay <> nil) and GTK_WIDGET_VISIBLE(Overlay) then
    ApplyShaped(Overlay, OverlayPix);
  if (Widget <> nil) and GTK_WIDGET_VISIBLE(Widget) then
    ApplyShaped(Widget, WidgetPix);
  if (StatusIcon <> nil) and (BarPix <> nil) then
    gtk_status_icon_set_from_pixbuf(StatusIcon, BarPix);
end;

procedure OnQuit(WidgetObj: PGtkWidget; Data: gpointer); cdecl;
begin
  gtk_main_quit;
end;

procedure OnAbout(WidgetObj: PGtkWidget; Data: gpointer); cdecl;
var
  Dlg: PGtkWidget;
begin
  Dlg := gtk_message_dialog_new(nil, GTK_DIALOG_MODAL, GTK_MESSAGE_INFO,
    GTK_BUTTONS_OK, PChar(GrouchAboutText));
  gtk_window_set_title(PGtkWindow(Dlg), PChar(GrouchAboutTitle));
  gtk_dialog_run(PGtkDialog(Dlg));
  gtk_widget_destroy(Dlg);
end;

procedure OnComeOut(WidgetObj: PGtkWidget; Data: gpointer); cdecl;
begin
  AtWidget := False;
  Controller.Trigger;
end;

procedure OnMute(WidgetObj: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar('M');
end;

procedure OnWidget(WidgetObj: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar('W');
end;

function BuildPopup: PGtkWidget;
var
  Menu, Item: PGtkWidget;
begin
  Menu := gtk_menu_new;
  Item := gtk_menu_item_new_with_label('Come Out!');
  { Linux FPC gtk2 has TGCallback (glib GCallback), not TG_SIGNAL_FUNC. }
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnComeOut), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Mute Sounds');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnMute), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Show Desktop Bin');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnWidget), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_separator_menu_item_new;
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('About The Grouch Tribute');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnAbout), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Quit');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnQuit), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  gtk_widget_show_all(Menu);
  Result := Menu;
end;

procedure OnStatusPopup(Icon: PGtkStatusIcon; Button: guint; ActivateTime: guint32;
  Data: gpointer); cdecl;
begin
  if Popup = nil then
    Popup := BuildPopup;
  gtk_menu_popup(PGtkMenu(Popup), nil, nil, nil, nil, Button, ActivateTime);
end;

function OnMapOverlay(W: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  if OverlayPix <> nil then
    ApplyShaped(W, OverlayPix);
  Result := False;
end;

function OnMapWidget(W: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  if WidgetPix <> nil then
    ApplyShaped(W, WidgetPix);
  Result := False;
end;

function OnExposeOverlay(W: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  if OverlayPix <> nil then
    ApplyShaped(W, OverlayPix);
  Result := True;
end;

function OnExposeWidget(W: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  if WidgetPix <> nil then
    ApplyShaped(W, WidgetPix);
  Result := True;
end;

function OnTick(Data: gpointer): gboolean; cdecl;
begin
  WatchTrash;
  Controller.Tick;
  DrainAudio;
  if Controller.Model.Busy then
  begin
    PlaceOverlay;
    gtk_widget_show(Overlay);
  end
  else
    gtk_widget_hide(Overlay);
  if Controller.ShowWidget then
    gtk_widget_show(Widget)
  else
    gtk_widget_hide(Widget);
  if Controller.NeedsPresent then
    Present;
  Result := True;
end;

function OnWidgetClick(W: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  FireIfAllowed(True);
  Result := True;
end;

procedure DecorateOverlay(Win: PGtkWidget; W, H: Integer);
begin
  gtk_window_set_decorated(PGtkWindow(Win), False);
  gtk_window_set_keep_above(PGtkWindow(Win), True);
  gtk_window_set_skip_taskbar_hint(PGtkWindow(Win), True);
  gtk_window_set_skip_pager_hint(PGtkWindow(Win), True);
  gtk_window_set_accept_focus(PGtkWindow(Win), False);
  gtk_widget_set_app_paintable(Win, True);
  gtk_widget_set_double_buffered(Win, False);
  gtk_window_resize(PGtkWindow(Win), W, H);
end;

procedure HostRun;
var
  Screen: PGdkScreen;
begin
  gtk_init(@argc, @argv);
  OverlayPix := nil;
  BarPix := nil;
  WidgetPix := nil;
  Popup := nil;
  PollAcc := 0;
  LastTriggerMs := 0;
  AtWidget := False;
  WriteSfxFiles;

  Controller := TGrouchController.Create(OverlayW, OverlayH, BarW, BarH,
    WidgetW, WidgetH, LoadConfig);
  LastTrash := CountTrashItems(DefaultTrashDir);

  Screen := gdk_screen_get_default;
  Overlay := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(Overlay), 'The Grouch Tribute');
  DecorateOverlay(Overlay, OverlayW, OverlayH);
  { No rgba colormap — on the Pi that visual exists but paints white. }
  g_signal_connect(G_OBJECT(Overlay), 'delete-event', TGCallback(@OnQuit), nil);
  g_signal_connect(G_OBJECT(Overlay), 'map-event', TGCallback(@OnMapOverlay), nil);
  g_signal_connect(G_OBJECT(Overlay), 'expose-event', TGCallback(@OnExposeOverlay), nil);

  Widget := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(Widget), 'Grouch Bin');
  DecorateOverlay(Widget, WidgetW, WidgetH);
  gtk_window_move(PGtkWindow(Widget), 40, gdk_screen_get_height(Screen) - WidgetH - 80);
  gtk_widget_add_events(Widget, GDK_BUTTON_PRESS_MASK);
  g_signal_connect(G_OBJECT(Widget), 'button-press-event', TGCallback(@OnWidgetClick), nil);
  g_signal_connect(G_OBJECT(Widget), 'map-event', TGCallback(@OnMapWidget), nil);
  g_signal_connect(G_OBJECT(Widget), 'expose-event', TGCallback(@OnExposeWidget), nil);

  StatusIcon := gtk_status_icon_new;
  gtk_status_icon_set_tooltip(StatusIcon, 'The Grouch Tribute');
  g_signal_connect(G_OBJECT(StatusIcon), 'popup-menu', TGCallback(@OnStatusPopup), nil);

  g_timeout_add(TickMs, TGSourceFunc(@OnTick), nil);
  Present;
  gtk_widget_hide(Overlay);
  gtk_widget_hide(Widget);
  gtk_main;
  DestroyPix(OverlayPix);
  DestroyPix(BarPix);
  DestroyPix(WidgetPix);
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
