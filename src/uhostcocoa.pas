unit uhostcocoa;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}
{$linkframework Cocoa}
{$linkframework CoreServices}
{$linkframework ApplicationServices}

{ macOS menu extra + overlay above the Dock Trash. Accessory policy +
  LSUIElement = no Dock icon. Same TGrouchController as Windows/Linux;
  this unit presents pixels, watches ~/.Trash, and optionally listens
  for Finder → Empty Trash via Accessibility. }

interface

procedure HostRun;

implementation

uses
  SysUtils, Math, CocoaAll, ugrouchconfig, ugrouchapp, ugrouchaudio,
  ugrouchtrash;

const
  OverlayPointsW = 160;
  OverlayPointsH = 220;
  BarPointsW = 22;
  BarPointsH = 22;
  WidgetPointsW = 120;
  WidgetPointsH = 160;
  TickInterval = 1.0 / 30.0;

type
  TOverlayView = objcclass;
  TOverlayWindow = objcclass;
  TWidgetView = objcclass;
  TWidgetWindow = objcclass;

  NSBitmapImageRepGrouch = objccategory external (NSBitmapImageRep)
    function initRGBA(planes: Pointer; aWidth: NSInteger; aHeight: NSInteger;
      aBits: NSInteger; aSamples: NSInteger; aAlpha: ObjCBOOL;
      aPlanar: ObjCBOOL; aSpace: NSString; aBpr: NSInteger;
      aBpp: NSInteger): id; message 'initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:';
  end;

  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol, NSWindowDelegateProtocol)
  public
    controller: TGrouchController;
    overlay: TOverlayWindow;
    view: TOverlayView;
    widget: TWidgetWindow;
    widgetView: TWidgetView;
    statusItem: NSStatusItem;
    frameImage: NSImage;
    barImage: NSImage;
    widgetImage: NSImage;
    animTimer: NSTimer;
    scale: Double;
    ready: ObjCBOOL;
    atWidget: ObjCBOOL;
    lastTrash: Integer;
    pollAcc: Integer;
    lastTriggerMs: QWord;
    sfxSlot: Integer;
    procedure applicationDidFinishLaunching(notification: NSNotification); message 'applicationDidFinishLaunching:';
    procedure tick(timer: NSTimer); message 'tick:';
    procedure quitAction(sender: id); message 'quitAction:';
    procedure aboutAction(sender: id); message 'aboutAction:';
    procedure comeOutAction(sender: id); message 'comeOutAction:';
    procedure muteAction(sender: id); message 'muteAction:';
    procedure widgetAction(sender: id); message 'widgetAction:';
    procedure accessAction(sender: id); message 'accessAction:';
    procedure redraw; message 'redraw';
    procedure syncOverlay; message 'syncOverlay';
    procedure syncWidget; message 'syncWidget';
    procedure placeOverlay; message 'placeOverlay';
    procedure drainAudio; message 'drainAudio';
    procedure watchTrash; message 'watchTrash';
    procedure setup; message 'setup';
    function windowShouldClose(sender: id): ObjCBOOL; message 'windowShouldClose:';
  end;

  TOverlayWindow = objcclass(NSWindow)
  public
    function canBecomeKeyWindow: ObjCBOOL; override;
    function canBecomeMainWindow: ObjCBOOL; override;
  end;

  TOverlayView = objcclass(NSView)
  public
    app: TAppDelegate;
    procedure drawRect(dirtyRect: NSRect); override;
    function isOpaque: ObjCBOOL; override;
  end;

  TWidgetWindow = objcclass(NSWindow)
  public
    app: TAppDelegate;
    function canBecomeKeyWindow: ObjCBOOL; override;
  end;

  TWidgetView = objcclass(NSView)
  public
    app: TAppDelegate;
    dragging: ObjCBOOL;
    dragStart: NSPoint;
    winStart: NSPoint;
    procedure drawRect(dirtyRect: NSRect); override;
    function isOpaque: ObjCBOOL; override;
    procedure mouseDown(event: NSEvent); override;
    procedure mouseDragged(event: NSEvent); override;
    procedure mouseUp(event: NSEvent); override;
  end;

var
  SharedApp: TAppDelegate;
  SfxWav: array[sfxLid..sfxSong] of TBytes;
  SfxRing: array[0..3] of NSSound;
  GTrashDirty: Boolean;
  GMenuEmpty: Boolean;
  GFSStream: Pointer;
  GAXObserver: Pointer;
  GAXFinder: Pointer;
  GTrashScript: NSAppleScript;

type
  FSEventStreamContext = record
    version: NativeInt;
    info: Pointer;
    retain: Pointer;
    release: Pointer;
    copyDescription: Pointer;
  end;

function FSEventStreamCreate(allocator: Pointer; callback: Pointer;
  context: Pointer; pathsToWatch: Pointer; sinceWhen: QWord;
  latency: Double; flags: Cardinal): Pointer; cdecl; external;
function FSEventStreamStart(stream: Pointer): Boolean; cdecl; external;
procedure FSEventStreamStop(stream: Pointer); cdecl; external;
procedure FSEventStreamInvalidate(stream: Pointer); cdecl; external;
procedure FSEventStreamRelease(stream: Pointer); cdecl; external;
procedure FSEventStreamScheduleWithRunLoop(stream: Pointer; runLoop: Pointer;
  mode: Pointer); cdecl; external;
function CFRunLoopGetCurrent: Pointer; cdecl; external;
procedure CFRelease(cf: Pointer); cdecl; external;
function CFRunLoopAddSource(rl: Pointer; source: Pointer; mode: Pointer): Pointer; cdecl; external;

function AXIsProcessTrusted: Boolean; cdecl; external;
function AXIsProcessTrustedWithOptions(options: Pointer): Boolean; cdecl; external;
function AXUIElementCreateApplication(pid: Integer): Pointer; cdecl; external;
function AXUIElementCopyAttributeValue(element: Pointer; attribute: Pointer;
  value: PPointer): Integer; cdecl; external;
function AXObserverCreate(pid: Integer; callback: Pointer; observer: PPointer): Integer; cdecl; external;
function AXObserverAddNotification(observer: Pointer; element: Pointer;
  notification: Pointer; refcon: Pointer): Integer; cdecl; external;
function AXObserverGetRunLoopSource(observer: Pointer): Pointer; cdecl; external;
function AXValueGetValue(value: Pointer; theType: LongInt; ptr: Pointer): Boolean; cdecl; external;

const
  kFSEventStreamEventIdSinceNow = QWord($FFFFFFFFFFFFFFFF);
  kFSEventStreamCreateFlagFileEvents = $00000010;
  kAXValueCGPointType = 1;
  kAXValueCGSizeType = 2;

function NSStr(const S: string): NSString; forward;

procedure TrashFSCallback(stream: Pointer; info: Pointer; numEvents: NativeUInt;
  eventPaths: Pointer; eventFlags: Pointer; eventIds: Pointer); cdecl;
begin
  { State change: something in ~/.Trash mutated. The timer recounts;
    we do not Trigger from this thread-ish callback itself. }
  GTrashDirty := True;
end;

procedure AXMenuCallback(observer: Pointer; element: Pointer; notification: Pointer;
  refcon: Pointer); cdecl;
var
  TitleRef: Pointer;
  Title: NSString;
  S: string;
begin
  TitleRef := nil;
  if AXUIElementCopyAttributeValue(element, NSStr('AXTitle'), @TitleRef) <> 0 then
    Exit;
  if TitleRef = nil then
    Exit;
  Title := NSString(TitleRef);
  S := string(Title.UTF8String);
  CFRelease(TitleRef);
  if IsEmptyTrashTitle(S) then
    { State change: Finder menu item Empty Trash was chosen. Debounced
      with the FSEvents path so we do not pop twice. }
    GMenuEmpty := True;
end;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function CountFinderTrash(out Ok: Boolean): Integer;
var
  Desc: NSAppleEventDescriptor;
  Err: Pointer;
begin
  { Finder's own Bin count — not ~/.Trash. macOS TCC blocks listing
    ~/.Trash ("Operation not permitted"), and iCloud / empty folders
    often never land there anyway. `count items of trash` is what
    Finder → Empty Bin actually empties. }
  Ok := False;
  Result := 0;
  if GTrashScript = nil then
  begin
    { Accessory extras have no key window; the Automation prompt is easy
      to miss unless we come forward once. }
    NSApplication.sharedApplication.activateIgnoringOtherApps(True);
    GTrashScript := NSAppleScript.alloc.initWithSource(
      NSStr('tell application "Finder" to count items of trash'));
  end;
  if GTrashScript = nil then
    Exit;
  Err := nil;
  Desc := GTrashScript.executeAndReturnError(@Err);
  if Desc = nil then
    Exit;
  Result := Integer(Desc.int32Value);
  if Result < 0 then
    Result := 0;
  Ok := True;
end;

function CurrentTrashCount: Integer;
var
  Ok: Boolean;
begin
  Result := CountFinderTrash(Ok);
  if not Ok then
    Result := CountTrashItems(DefaultTrashDir);
end;

function MakeImage(Pixels: PByte; PixelW, PixelH: Integer; PointW, PointH: Double): NSImage;
var
  Rep: NSBitmapImageRep;
  Dest: PByte;
  Bytes: Integer;
begin
  Rep := NSBitmapImageRep(NSBitmapImageRep.alloc.initRGBA(nil, PixelW, PixelH, 8, 4,
    True, False, NSCalibratedRGBColorSpace, PixelW * 4, 32));
  Result := NSImage.alloc.initWithSize(NSMakeSize(PointW, PointH));
  if Rep <> nil then
  begin
    Dest := PByte(Rep.bitmapData);
    Bytes := PixelW * PixelH * 4;
    if (Dest <> nil) and (Pixels <> nil) and (Bytes > 0) then
      Move(Pixels^, Dest^, Bytes);
    Result.addRepresentation(Rep);
    Rep.release;
  end;
  Result.setCacheMode(NSImageCacheNever);
end;

function FindBundlePid(const Bundle: string): Integer;
var
  Apps: NSArray;
  App: NSRunningApplication;
  Ident: NSString;
  I: Integer;
begin
  Result := 0;
  Apps := NSWorkspace.sharedWorkspace.runningApplications;
  if Apps = nil then
    Exit;
  for I := 0 to Integer(Apps.count) - 1 do
  begin
    App := NSRunningApplication(Apps.objectAtIndex(I));
    if App = nil then
      Continue;
    Ident := App.bundleIdentifier;
    if (Ident <> nil) and Ident.isEqualToString(NSStr(Bundle)) then
    begin
      Result := Integer(App.processIdentifier);
      Exit;
    end;
  end;
end;

function EstimateTrashRect: NSRect;
var
  Screen, Vis: NSRect;
  Tile, DockH, DockW: Double;
  Dock: NSUserDefaults;
  Ori: NSString;
  Bottom, Left, Right: Boolean;
begin
  Screen := NSScreen.mainScreen.frame;
  Vis := NSScreen.mainScreen.visibleFrame;
  Tile := 48;
  Dock := NSUserDefaults.alloc.initWithSuiteName(NSStr('com.apple.dock'));
  Ori := nil;
  if Dock <> nil then
  begin
    if Dock.integerForKey(NSStr('tilesize')) > 16 then
      Tile := Dock.integerForKey(NSStr('tilesize'));
    Ori := Dock.stringForKey(NSStr('orientation'));
    Dock.release;
  end;
  Bottom := True;
  Left := False;
  Right := False;
  if Ori <> nil then
  begin
    if Ori.isEqualToString(NSStr('left')) then
    begin
      Bottom := False;
      Left := True;
    end
    else if Ori.isEqualToString(NSStr('right')) then
    begin
      Bottom := False;
      Right := True;
    end;
  end;
  DockH := Vis.origin.y - Screen.origin.y;
  DockW := (Screen.origin.x + Screen.size.width) - (Vis.origin.x + Vis.size.width);
  if Left then
    DockW := Vis.origin.x - Screen.origin.x;
  if DockH < 24 then
    DockH := Tile + 12;
  if DockW < 24 then
    DockW := Tile + 12;
  if Bottom then
  begin
    { Trash is the last tile on the right of a bottom Dock. }
    Result.size.width := Tile;
    Result.size.height := Max(Tile, DockH - 8);
    Result.origin.x := Screen.origin.x + Screen.size.width - Tile - 18;
    Result.origin.y := Screen.origin.y + 4;
  end
  else if Right then
  begin
    Result.size.width := Max(Tile, DockW - 8);
    Result.size.height := Tile;
    Result.origin.x := Screen.origin.x + Screen.size.width - Result.size.width - 4;
    Result.origin.y := Screen.origin.y + 8;
  end
  else
  begin
    Result.size.width := Max(Tile, DockW - 8);
    Result.size.height := Tile;
    Result.origin.x := Screen.origin.x + 4;
    Result.origin.y := Screen.origin.y + 8;
  end;
end;

function AXTrashRect(out R: NSRect): Boolean;
var
  Pid, I, N, Err: Integer;
  AppEl, ChildrenRef, Child, TitleRef, PosRef, SizeRef: Pointer;
  Children: NSArray;
  Title: NSString;
  Pt: NSPoint;
  Sz: NSSize;
  Screen: NSRect;
begin
  Result := False;
  if not AXIsProcessTrusted then
    Exit;
  Pid := FindBundlePid('com.apple.dock');
  if Pid = 0 then
    Exit;
  AppEl := AXUIElementCreateApplication(Pid);
  if AppEl = nil then
    Exit;
  ChildrenRef := nil;
  Err := AXUIElementCopyAttributeValue(AppEl, NSStr('AXChildren'), @ChildrenRef);
  if (Err <> 0) or (ChildrenRef = nil) then
  begin
    CFRelease(AppEl);
    Exit;
  end;
  Children := NSArray(ChildrenRef);
  N := Integer(Children.count);
  Screen := NSScreen.mainScreen.frame;
  for I := 0 to N - 1 do
  begin
    Child := Children.objectAtIndex(I);
    TitleRef := nil;
    AXUIElementCopyAttributeValue(Child, NSStr('AXTitle'), @TitleRef);
    Title := NSString(TitleRef);
    if (Title <> nil) and (
         Title.isEqualToString(NSStr('Trash')) or
         Title.isEqualToString(NSStr('Bin')) or
         Title.isEqualToString(NSStr('Wastebasket')) or
         Title.isEqualToString(NSStr('Papierkorb'))) then
    begin
      PosRef := nil;
      SizeRef := nil;
      AXUIElementCopyAttributeValue(Child, NSStr('AXPosition'), @PosRef);
      AXUIElementCopyAttributeValue(Child, NSStr('AXSize'), @SizeRef);
      Pt.x := 0;
      Pt.y := 0;
      Sz.width := 48;
      Sz.height := 48;
      if PosRef <> nil then
        AXValueGetValue(PosRef, kAXValueCGPointType, @Pt);
      if SizeRef <> nil then
        AXValueGetValue(SizeRef, kAXValueCGSizeType, @Sz);
      { AX is top-left Y-down. Cocoa windows are bottom-left Y-up. }
      R.origin.x := Pt.x;
      R.origin.y := Screen.origin.y + Screen.size.height - Pt.y - Sz.height;
      R.size.width := Sz.width;
      R.size.height := Sz.height;
      if PosRef <> nil then
        CFRelease(PosRef);
      if SizeRef <> nil then
        CFRelease(SizeRef);
      Result := True;
    end;
    if TitleRef <> nil then
      CFRelease(TitleRef);
    if Result then
      Break;
  end;
  CFRelease(ChildrenRef);
  CFRelease(AppEl);
end;

procedure PlaySfx(Kind: TSfxKind);
var
  Data: NSData;
  Bytes: TBytes;
begin
  if (Kind < sfxLid) or (Kind > sfxSong) then
    Exit;
  Bytes := SfxWav[Kind];
  if Length(Bytes) < 44 then
    Exit;
  Data := NSData.dataWithBytes_length(@Bytes[0], Length(Bytes));
  if SfxRing[SharedApp.sfxSlot] <> nil then
  begin
    SfxRing[SharedApp.sfxSlot].stop;
    SfxRing[SharedApp.sfxSlot].release;
    SfxRing[SharedApp.sfxSlot] := nil;
  end;
  SfxRing[SharedApp.sfxSlot] := NSSound.alloc.initWithData(Data);
  if SfxRing[SharedApp.sfxSlot] <> nil then
    SfxRing[SharedApp.sfxSlot].play;
  SharedApp.sfxSlot := (SharedApp.sfxSlot + 1) mod Length(SfxRing);
end;

procedure TAppDelegate.drainAudio;
var
  Kind: TSfxKind;
begin
  if controller = nil then
    Exit;
  if controller.Model.Config.Muted then
  begin
    while controller.Model.DrainSfx(Kind) do
      ;
    Exit;
  end;
  while controller.Model.DrainSfx(Kind) do
    PlaySfx(Kind);
end;

procedure TAppDelegate.placeOverlay;
var
  Trash, Frame: NSRect;
  HaveAX: Boolean;
begin
  if overlay = nil then
    Exit;
  if atWidget and (widget <> nil) and widget.isVisible then
  begin
    Frame := widget.frame;
    Frame.size.width := OverlayPointsW;
    Frame.size.height := OverlayPointsH;
    Frame.origin.x := Frame.origin.x + (widget.frame.size.width - OverlayPointsW) * 0.5;
    overlay.setFrame_display(Frame, False);
    Exit;
  end;
  HaveAX := AXTrashRect(Trash);
  if not HaveAX then
    Trash := EstimateTrashRect;
  Frame.size.width := OverlayPointsW;
  Frame.size.height := OverlayPointsH;
  Frame.origin.x := Trash.origin.x + Trash.size.width * 0.5 - OverlayPointsW * 0.5;
  { Sit the can on the Dock tile: overlay bottom ≈ trash top. }
  Frame.origin.y := Trash.origin.y + Trash.size.height - 18;
  overlay.setFrame_display(Frame, False);
end;

procedure TAppDelegate.syncOverlay;
begin
  if overlay = nil then
    Exit;
  if (controller <> nil) and controller.Model.Busy then
  begin
    placeOverlay;
    overlay.orderFront(nil);
  end
  else
    overlay.orderOut(nil);
end;

procedure TAppDelegate.syncWidget;
var
  Vis: NSRect;
begin
  if widget = nil then
    Exit;
  if (controller <> nil) and controller.ShowWidget then
  begin
    if not widget.isVisible then
    begin
      Vis := NSScreen.mainScreen.visibleFrame;
      widget.setFrameOrigin(NSMakePoint(Vis.origin.x + 36, Vis.origin.y + 36));
    end;
    widget.orderFront(nil);
  end
  else
    widget.orderOut(nil);
end;

procedure TAppDelegate.redraw;
var
  B: NSRect;
  Btn: NSStatusBarButton;
begin
  if controller = nil then
    Exit;
  controller.Render;
  if view <> nil then
  begin
    B := view.bounds;
    if frameImage <> nil then
      frameImage.release;
    frameImage := MakeImage(controller.Overlay.Ptr, controller.Overlay.Width,
      controller.Overlay.Height, B.size.width, B.size.height);
    view.setNeedsDisplay_(True);
  end;
  if barImage <> nil then
    barImage.release;
  barImage := MakeImage(controller.Bar.Ptr, controller.Bar.Width,
    controller.Bar.Height, BarPointsW, BarPointsH);
  if statusItem <> nil then
  begin
    Btn := statusItem.button;
    if Btn <> nil then
    begin
      Btn.setImage(nil);
      Btn.setImage(barImage);
    end
    else
      statusItem.setImage(barImage);
  end;
  if (widgetView <> nil) and (controller.ShowWidget) then
  begin
    if widgetImage <> nil then
      widgetImage.release;
    widgetImage := MakeImage(controller.Widget.Ptr, controller.Widget.Width,
      controller.Widget.Height, WidgetPointsW, WidgetPointsH);
    widgetView.setNeedsDisplay_(True);
  end;
  controller.ConsumePresent;
end;

procedure FireIfAllowed(App: TAppDelegate; FromWidget: Boolean);
var
  Now: QWord;
begin
  if App = nil then
    Exit;
  Now := GetTickCount64;
  if Now - App.lastTriggerMs < 1500 then
    Exit; { debounce FSEvents + AX double fire }
  if (App.controller <> nil) and App.controller.Model.Busy then
    Exit;
  App.atWidget := FromWidget;
  App.lastTriggerMs := Now;
  App.controller.Trigger;
end;

procedure TAppDelegate.watchTrash;
var
  NowCount: Integer;
begin
  if controller = nil then
    Exit;
  { AppleScript to Finder can take a beat; skip while he is animating. }
  if controller.Model.Busy then
    Exit;
  Inc(pollAcc);
  if (not GTrashDirty) and (pollAcc < 15) and (not GMenuEmpty) then
    Exit;
  pollAcc := 0;
  if GMenuEmpty then
  begin
    GMenuEmpty := False;
    FireIfAllowed(self, False);
  end;
  NowCount := CurrentTrashCount;
  if TrashWasEmptied(lastTrash, NowCount) then
    FireIfAllowed(self, False);
  lastTrash := NowCount;
  GTrashDirty := False;
end;

procedure StartFSEvents;
var
  Paths: NSArray;
  Ctx: FSEventStreamContext;
  Dir: string;
begin
  Dir := DefaultTrashDir;
  if not DirectoryExists(Dir) then
    Exit;
  FillChar(Ctx, SizeOf(Ctx), 0);
  Paths := NSArray.arrayWithObject(NSStr(Dir));
  GFSStream := FSEventStreamCreate(nil, @TrashFSCallback, @Ctx, Paths,
    kFSEventStreamEventIdSinceNow, 0.4, kFSEventStreamCreateFlagFileEvents);
  if GFSStream = nil then
    Exit;
  FSEventStreamScheduleWithRunLoop(GFSStream, CFRunLoopGetCurrent, NSDefaultRunLoopMode);
  FSEventStreamStart(GFSStream);
end;

procedure StartAXFinder;
var
  Pid: Integer;
  Src: Pointer;
begin
  if not AXIsProcessTrusted then
    Exit;
  Pid := FindBundlePid('com.apple.finder');
  if Pid = 0 then
    Exit;
  if AXObserverCreate(Pid, @AXMenuCallback, @GAXObserver) <> 0 then
    Exit;
  GAXFinder := AXUIElementCreateApplication(Pid);
  if GAXFinder = nil then
    Exit;
  AXObserverAddNotification(GAXObserver, GAXFinder, NSStr('AXMenuItemSelected'), nil);
  Src := AXObserverGetRunLoopSource(GAXObserver);
  if Src <> nil then
    CFRunLoopAddSource(CFRunLoopGetCurrent, Src, NSDefaultRunLoopMode);
end;

procedure TAppDelegate.setup;
var
  Menu: NSMenu;
  Item: NSMenuItem;
  PixelScale: Double;
  Style: NSUInteger;
  Kind: TSfxKind;
  I: Integer;
  Frame: NSRect;
begin
  if ready then
    Exit;
  ready := True;

  PixelScale := 2;
  if NSScreen.mainScreen <> nil then
    PixelScale := NSScreen.mainScreen.backingScaleFactor;
  if PixelScale < 1 then
    PixelScale := 1;
  scale := PixelScale;
  sfxSlot := 0;
  atWidget := False;
  lastTriggerMs := 0;
  pollAcc := 0;
  lastTrash := CurrentTrashCount;

  for Kind := sfxLid to sfxSong do
    SfxWav[Kind] := BuildSfxWav(Kind);
  for I := 0 to High(SfxRing) do
    SfxRing[I] := nil;

  controller := TGrouchController.Create(
    Max(1, Round(OverlayPointsW * scale)),
    Max(1, Round(OverlayPointsH * scale)),
    Round(BarPointsW * scale), Round(BarPointsH * scale),
    Round(WidgetPointsW * scale), Round(WidgetPointsH * scale),
    LoadConfig);

  Menu := NSMenu.alloc.init;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Come Out!'), objcselector('comeOutAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Mute Sounds'), objcselector('muteAction:'), NSStr('m'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Show Desktop Bin'), objcselector('widgetAction:'), NSStr('w'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Request Accessibility…'), objcselector('accessAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Menu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('About The Grouch Tribute'), objcselector('aboutAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Menu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Quit The Grouch Tribute'), objcselector('quitAction:'), NSStr('q'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;

  statusItem := NSStatusBar.systemStatusBar.statusItemWithLength(BarPointsW);
  statusItem.retain;
  statusItem.setMenu(Menu);
  if statusItem.button <> nil then
    statusItem.button.setImagePosition(NSImageOnly);
  Menu.release;

  Frame := NSMakeRect(0, 0, OverlayPointsW, OverlayPointsH);
  Style := NSBorderlessWindowMask;
  overlay := TOverlayWindow.alloc.initWithContentRect_styleMask_backing_defer(
    Frame, Style, NSBackingStoreBuffered, False);
  overlay.setTitle(NSStr('The Grouch Tribute'));
  overlay.setOpaque(False);
  overlay.setBackgroundColor(NSColor.clearColor);
  overlay.setHasShadow(False);
  overlay.setIgnoresMouseEvents(True);
  overlay.setLevel(NSStatusWindowLevel);
  overlay.setReleasedWhenClosed(False);
  overlay.setHidesOnDeactivate(False);
  overlay.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces or
    NSWindowCollectionBehaviorStationary or NSWindowCollectionBehaviorIgnoresCycle);
  view := TOverlayView.alloc.initWithFrame(NSMakeRect(0, 0, OverlayPointsW, OverlayPointsH));
  view.app := self;
  overlay.setContentView(view);
  overlay.orderOut(nil);

  widget := TWidgetWindow.alloc.initWithContentRect_styleMask_backing_defer(
    NSMakeRect(80, 80, WidgetPointsW, WidgetPointsH), Style, NSBackingStoreBuffered, False);
  widget.app := self;
  widget.setOpaque(False);
  widget.setBackgroundColor(NSColor.clearColor);
  widget.setHasShadow(False);
  widget.setIgnoresMouseEvents(False);
  widget.setLevel(NSFloatingWindowLevel);
  widget.setReleasedWhenClosed(False);
  widget.setHidesOnDeactivate(False);
  widget.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces);
  widget.setDelegate(self);
  widgetView := TWidgetView.alloc.initWithFrame(NSMakeRect(0, 0, WidgetPointsW, WidgetPointsH));
  widgetView.app := self;
  widget.setContentView(widgetView);

  StartFSEvents;
  StartAXFinder;
  redraw;
  syncWidget;

  animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    TickInterval, self, objcselector('tick:'), nil, True);
  animTimer.retain;
  NSRunLoop.currentRunLoop.addTimer_forMode(animTimer, NSRunLoopCommonModes);
end;

procedure TAppDelegate.applicationDidFinishLaunching(notification: NSNotification);
begin
  setup;
end;

procedure TAppDelegate.tick(timer: NSTimer);
var
  Pool: NSAutoreleasePool;
begin
  Pool := NSAutoreleasePool.alloc.init;
  if controller <> nil then
  begin
    watchTrash;
    controller.Tick;
    drainAudio;
    syncOverlay;
    if controller.NeedsPresent then
      redraw;
  end;
  Pool.release;
end;

procedure TAppDelegate.quitAction(sender: id);
var
  I: Integer;
begin
  for I := 0 to High(SfxRing) do
    if SfxRing[I] <> nil then
    begin
      SfxRing[I].stop;
      SfxRing[I].release;
      SfxRing[I] := nil;
    end;
  if GFSStream <> nil then
  begin
    FSEventStreamStop(GFSStream);
    FSEventStreamInvalidate(GFSStream);
    FSEventStreamRelease(GFSStream);
    GFSStream := nil;
  end;
  NSApplication.sharedApplication.terminate(nil);
end;

procedure TAppDelegate.aboutAction(sender: id);
var
  Alert: NSAlert;
begin
  NSApplication.sharedApplication.activateIgnoringOtherApps(True);
  Alert := NSAlert.alloc.init;
  Alert.setMessageText(NSStr(GrouchAboutTitle));
  Alert.setInformativeText(NSStr(GrouchAboutText));
  Alert.runModal;
  Alert.release;
end;

procedure TAppDelegate.comeOutAction(sender: id);
begin
  atWidget := False;
  if controller <> nil then
    controller.Trigger;
end;

procedure TAppDelegate.muteAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar('M');
end;

procedure TAppDelegate.widgetAction(sender: id);
begin
  if controller <> nil then
  begin
    controller.ApplyChar('W');
    syncWidget;
  end;
end;

procedure TAppDelegate.accessAction(sender: id);
var
  Opts: NSDictionary;
  Prompt: NSString;
begin
  { Shows the system Accessibility prompt once. Empty Trash folder
    watching already works without this; this is only Dock alignment
    and the Finder menu observer. }
  Prompt := NSStr('AXTrustedCheckOptionPrompt');
  Opts := NSDictionary.dictionaryWithObject_forKey(NSNumber.numberWithBool(True), Prompt);
  AXIsProcessTrustedWithOptions(Opts);
  StartAXFinder;
end;

function TAppDelegate.windowShouldClose(sender: id): ObjCBOOL;
begin
  if controller <> nil then
    controller.ApplyChar('W');
  syncWidget;
  Result := False;
end;

procedure TOverlayView.drawRect(dirtyRect: NSRect);
var
  Ctx: NSGraphicsContext;
begin
  Ctx := NSGraphicsContext.currentContext;
  if Ctx <> nil then
    Ctx.setCompositingOperation(NSCompositeCopy);
  NSColor.clearColor.set_;
  NSRectFill(self.bounds);
  if Ctx <> nil then
    Ctx.setCompositingOperation(NSCompositeSourceOver);
  if (app = nil) or (app.frameImage = nil) then
    Exit;
  app.frameImage.drawInRect_fromRect_operation_fraction(self.bounds, NSZeroRect,
    NSCompositeSourceOver, 1.0);
end;

function TOverlayView.isOpaque: ObjCBOOL;
begin
  Result := False;
end;

function TOverlayWindow.canBecomeKeyWindow: ObjCBOOL;
begin
  Result := False;
end;

function TOverlayWindow.canBecomeMainWindow: ObjCBOOL;
begin
  Result := False;
end;

procedure TWidgetView.drawRect(dirtyRect: NSRect);
var
  Ctx: NSGraphicsContext;
begin
  Ctx := NSGraphicsContext.currentContext;
  if Ctx <> nil then
    Ctx.setCompositingOperation(NSCompositeCopy);
  NSColor.clearColor.set_;
  NSRectFill(self.bounds);
  if Ctx <> nil then
    Ctx.setCompositingOperation(NSCompositeSourceOver);
  if (app = nil) or (app.widgetImage = nil) then
    Exit;
  app.widgetImage.drawInRect_fromRect_operation_fraction(self.bounds, NSZeroRect,
    NSCompositeSourceOver, 1.0);
end;

function TWidgetView.isOpaque: ObjCBOOL;
begin
  Result := False;
end;

procedure TWidgetView.mouseDown(event: NSEvent);
begin
  dragging := False;
  dragStart := NSEvent.mouseLocation;
  if app.widget <> nil then
    winStart := app.widget.frame.origin;
end;

procedure TWidgetView.mouseDragged(event: NSEvent);
var
  Now: NSPoint;
begin
  Now := NSEvent.mouseLocation;
  if (Abs(Now.x - dragStart.x) > 4) or (Abs(Now.y - dragStart.y) > 4) then
    dragging := True;
  if dragging and (app.widget <> nil) then
    app.widget.setFrameOrigin(NSMakePoint(winStart.x + (Now.x - dragStart.x),
      winStart.y + (Now.y - dragStart.y)));
end;

procedure TWidgetView.mouseUp(event: NSEvent);
begin
  if (not dragging) and (app <> nil) then
    FireIfAllowed(app, True);
  dragging := False;
end;

function TWidgetWindow.canBecomeKeyWindow: ObjCBOOL;
begin
  Result := True;
end;

procedure HostRun;
var
  Pool: NSAutoreleasePool;
  App: NSApplication;
begin
  Pool := NSAutoreleasePool.alloc.init;
  App := NSApplication.sharedApplication;
  { Accessory + Info.plist LSUIElement: menu extra only, no Dock / Cmd-Tab. }
  App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup;
  App.run;
  Pool.release;
end;

end.
