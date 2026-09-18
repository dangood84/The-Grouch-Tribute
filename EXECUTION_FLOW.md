# Execution flow: from `begin` to a singing grouch

A step-by-step trace of what happens from `program TheGrouch` through host initialisation and timer startup, down to how one Empty Trash becomes a lid flip, a shout, a wave, and a toggle.

Default launch (`make run`) opens the **macOS menu extra**. `make windows` / `make linux` use the same model and renderer; only the present step and the trash watcher change. This trace is **macOS** (`uhostcocoa`) unless a step says otherwise.

One thread does everything after startup:

- **main (Pascal, then Cocoa run loop)** — `HostRun`, `setup`, `tick:`, `redraw`, AppKit drawing
- **FSEvents / AX callbacks** — only set `GTrashDirty` / `GMenuEmpty`; they never call `Trigger` themselves

There is no background animation thread. `NSTimer` and `NSWindow` run on the same thread that called `NSApplication.run`.

---

## Phase A — process entry

**1.** The OS loads `TheGrouch.app/Contents/MacOS/TheGrouch`. FPC unit initialisation runs (`TGrouchModel` is not constructed yet).

**2.** `program TheGrouch` executes `HostRun`.

```pascal
{ src/grouch.pas }
begin
  HostRun;
end.
```

**3.** `HostRun` (Cocoa):

```pascal
procedure HostRun;
begin
  ...
  App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup;
  App.run;
end.
```

Accessory policy (and `LSUIElement` in `Info.plist`) means: **no Dock icon**, no Cmd-Tab. The menu extra is how you quit. `App.run` does not return until Quit.

Windows: `HostRun` registers two window classes (overlay + widget), `CreateWindowEx` with `WS_EX_LAYERED`, `SetTimer(33)`, a tray icon, then `GetMessage`.
Linux: `gtk_init`, two undecorated keep-above windows, `g_timeout_add(33, ...)`, `gtk_main`.

---

## Phase B — extra + watcher (`setup`)

**4.** `TAppDelegate.setup` is idempotent (`if ready then Exit`). `applicationDidFinishLaunching` calls it again after `App.run` has started; the second call is a no-op.

**5.** Pixel scale: `NSScreen.mainScreen.backingScaleFactor` (typically `2` on Sonoma retina). The controller buffers are in **pixels**; the overlay window is in **points** (`160×220`).

**6.** Original WAV stings are built once (`BuildSfxWav` for lid + song). They sit in memory; nothing is read from disk.

**7.** `controller := TGrouchController.Create(..., LoadConfig)`:

- `TGrouchModel.Create` — `gpDormant`, `NextAction` from the INI (default sing)
- Overlay / bar / widget `TPixelBuffer`s allocated (RGBA, cleared to alpha 0)
- `NeedsPresent := True` so the extra gets a closed-can icon before the timer

**8.** Menu extra: Come Out!, Mute, Show Desktop Bin, Request Accessibility…, About, Quit. `NSStatusItem` length 22 pt, image only.

**9.** Overlay window: **borderless**, `setOpaque(False)`, `clearColor`, **`setIgnoresMouseEvents(True)`**, `NSStatusWindowLevel`, joins all Spaces. Starts **`orderOut`** — you should not see a hole in the desktop until he performs.

**10.** Optional desktop-bin window: same transparency, but **clicks are live**. Hidden unless `ShowWidget`. Drag moves it; a click without a drag is `Trigger` at the widget.

**11.** `lastTrash := CurrentTrashCount` asks Finder `count items of trash` (this is the first Apple Event; macOS may prompt to allow control of Finder). `~/.Trash` is not listed — TCC returns “Operation not permitted”.

**12.** `StartFSEvents` still watches `~/.Trash` as a “something happened” hint, but the count always comes from Finder so iCloud items and empty folders are included.

**13.** If Accessibility is already trusted, `StartAXFinder` attaches `AXObserver` to Finder for `AXMenuItemSelected` (Empty Bin / Empty Trash). Folder watching no longer depends on this.

**14.** Timer is armed at **1/30 s**.

```pascal
animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
  1.0 / 30.0, self, objcselector('tick:'), nil, True);
```

---

## Phase C — idle ticks (dormant)

**15.** `tick:` wraps an `NSAutoreleasePool`, then `watchTrash`, `controller.Tick`, `drainAudio`, `syncOverlay`, `redraw` if dirty.

**16.** While `gpDormant`, `Update` returns immediately. `syncOverlay` keeps the overlay `orderOut`. The extra still shows a tiny closed can.

**17.** `watchTrash` recounts when FSEvents fired, when the menu observer fired, or every 15 ticks (~0.5 s) as a backup poll.

---

## Phase D — Empty Trash

**18.** You choose **Finder → Empty Bin…** (or Empty Trash…, or ⌘⇧⌫) and confirm. Finder deletes the files.

**19.** About twice a second, `watchTrash` asks Finder how many items are in the Bin. When that count goes from N to 0, `TrashWasEmptied` is true. (An AX menu-title match may also set `GMenuEmpty` if Accessibility was granted.)

**20.** `FireIfAllowed` applies a **1.5 s debounce** and refuses if `Busy`. Then `controller.Trigger`.

**21.** `TGrouchModel.Trigger`:

```
if FPhase <> gpDormant then Exit;   { already out }
FAction := FConfig.NextAction;      { latch sing vs wave NOW }
EnterPhase(gpLidOpen);              { queues sfxLid }
```

**22.** `syncOverlay` sees `Busy`, calls `placeOverlay` (AX Dock Trash rect, or a tilesize guess on the right of a bottom Dock), `orderFront`.

**23.** `drainAudio` pops `sfxLid` and plays it with `NSSound` unless muted.

---

## Phase E — one performance

**24.** Each tick `Update` adds `dt` (capped at 0.05 s) to `FPhaseT`. When it passes the step duration:

```
gpLidOpen  0.38s   LidAngle 0→1 (ease-out cubic)
    → gpRise
gpRise     0.55s   Rise 0→1 (ease-out back, slight overshoot)
    → gpAction
gpAction   song length (~4.6s) or 1.65s wave
           Wave = sin(t); Mouth = SongMouthAt(t) if singing
           caption only if singing
    → gpSink
gpSink     0.48s   Rise 1→0
    → gpLidClose
gpLidClose 0.32s   LidAngle 1→0
    → gpDormant    ToggleNextAction  { sing ↔ wave for next time }
```

Entering `gpAction` with `gaSingAndWave` queues `sfxSong`. The renderer reads `SongMouthAt` so the mouth follows the same score the WAV was built from.

**25.** `RenderGrouch` clears to transparent, optionally draws the cream bubble, then:

1. Open lid (behind him)
2. Oscar (head, unibrow, yellow squint, waving arm)
3. Galvanised can body (covers everything below the rim)
4. Closed lid (on top, while he is still hiding)

Cocoa copies the RGBA bytes into a fresh `NSImage` and invalidates the view. Windows uses `CopyBGRA` + `UpdateLayeredWindow`. GTK copies into a `GdkPixbuf`.

**26.** When `gpDormant` returns, `syncOverlay` `orderOut`s the window. The extra goes back to a closed can. Next Empty Trash will use the flipped `NextAction`.

---

## Phase F — menu extra

**27.** **Come Out!** calls `Trigger` with `atWidget = False` (Dock placement) without touching Trash.

**28.** Mute / Show Desktop Bin reach `ApplyChar`. Mute only stops the host playing; the model still queues events. Widget show/hide is `syncWidget`. Settings are written to the INI when the controller is destroyed (Quit).

**29.** **Request Accessibility…** calls `AXIsProcessTrustedWithOptions` with the prompt flag, then retries `StartAXFinder`. Folder watching already worked.

**30.** About runs a modal `NSAlert` after `activateIgnoringOtherApps` (accessory apps otherwise have no key window). Quit stops FSEvents and `terminate`s.

---

## Headless paths

`make test` never opens a window. It checks title matching, a temp-dir trash count, WAV headers, Trigger → lid → rise → sing, ignored re-trigger, toggle to wave, then back to sing.

`make snap` builds a controller with `Persist=False`, `ForcePose`s lid / rise / wave / sing, and writes PPM files so the original sprites can be inspected without AppKit.
