# How The Grouch Tribute works

This note is for someone who wants to **build and run** the helper on each OS, and to see how a small Free Pascal desktop gimmick is structured: where it starts, who owns the animation, who paints pixels, and how Empty Trash becomes a lid flip without hooking Finder.

You do not need to be a Cocoa, Win32, or GTK expert. The same ideas show up in Eyes, Lemmings Overlay, and the RISC OS Clock: an entry point, a model, a software canvas, and a native host that only presents bytes.

There is **no Lazarus form**. Oscar is a handful of numbers (phase, lid angle, rise, wave, mouth). Each tick those numbers are turned into RGBA pixels. The host uploads that buffer to a borderless overlay sitting above the Dock Trash (or the Recycle Bin corner on other OSes).

## Build / run workflows

Work from the project root. `fpc` must be on `PATH`. Output always lands in `build/` (gitignored).

| What you want | Command | What you get |
|---------------|---------|--------------|
| macOS app | `make` then `make run` | `build/TheGrouch.app`, opened; extra in the menu bar |
| Linux / Raspberry Pi OS | `sudo apt install fpc libgtk2.0-dev` then `make linux` then `./build/thegrouch` | GTK 2 overlay + panel icon |
| Windows 10+ | from a native FPC prompt: `make windows` then `build\TheGrouch.exe` | layered overlay + tray icon |
| Headless checks | `make test` | prints `ok` lines; non-zero if the toggle / trash / sfx are wrong |
| Frozen canvas frames | `make snap` | `build/snap-lid.ppm`, `snap-rise.ppm`, `snap-wave.ppm`, `snap-sing.ppm`, plus bar/widget |
| Start over | `make clean` | deletes `build/` |

macOS (Homebrew, Sonoma+):

```bash
brew install fpc
make
make run
```

Empty Bin watching asks **Finder** for `count items of trash`. That is a normal user Apple Event — **no SIP disable, no Finder injection**. macOS TCC blocks listing `~/.Trash` (`Operation not permitted`), and items from iCloud Desktop / empty folders often never appear there anyway. Allowing **Automation → Finder** is what makes Empty Bin work. Accessibility is optional and only used to (a) read the Dock Bin tile’s screen rect and (b) notice the Finder menu item name.

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
make linux
./build/thegrouch
```

Windows: install FPC, open its command prompt so `fpc` is on `PATH`, then `make windows`. The `Windows` unit ships with FPC; Recycle Bin count comes from `SHQueryRecycleBin`.

Only **one** host unit is compiled. `{$IFDEF DARWIN}` / `WINDOWS` / else picks `uhostcocoa`, `uhostwin`, or `uhostgtk`. Cross-compiling the GUI hosts is not a supported workflow — build on the OS you want to run on.

## Mental model

```
grouch.pas begin
  → HostRun                         # uhostcocoa / uhostwin / uhostgtk
      → create TGrouchController (model + overlay + bar + widget)
      → create menu extra / tray
      → start FSEvents (macOS) or a 0.5 s trash poll
      → timer (~30 Hz)
           → if trash count went >0 → 0 (or Come Out! / widget click)
                Model.Trigger       # DORMANT → LID OPEN
           → Model.Update(dt)       # lid, rise, sing/wave, sink, close
           → drain sfx queue → NSSound / PlaySound / paplay
           → if Busy: position overlay, RenderGrouch, present
           → if Dormant: hide overlay
```

He is **event-driven**. Unlike Lemmings Overlay he does not walk all day: the process is alive (menu extra + watcher) but the canvas is empty until a trigger.

```
┌─────────────┐   Trigger    ┌────────────┐     ┌──────┐
│  DORMANT    ├─────────────►│  LID OPEN  ├────►│ RISE │
│ (hidden)    │              │  + lid sfx │     └──────┘
└─────────────┘              └────────────┘         │
       ▲                                            ▼
       │                                 ┌──────────────────┐
       │                                 │ ACTION           │
       │                                 │ sing+wave  -or-  │
       │                                 │ just wave        │
       │                                 └────────┬─────────┘
┌─────────────┐                          ┌────────▼─────────┐
│ LID CLOSE   │◄─────────────────────────┤ SINK             │
│ then toggle │                          └──────────────────┘
│ NextAction  │
└─────────────┘
```

**Toggle memory.** `NextAction` is latched at Trigger so a mid-song config edit cannot swap routines. When the lid finishes closing, `ToggleNextAction` flips `gaSingAndWave` ↔ `gaJustWave` and the INI is written on Quit so the *next* launch continues the alternation.

## Unit responsibilities

### `grouch.pas` — composition root

Picks one host with `{$IFDEF}` and calls `HostRun`. Nothing else.

### `ugrouchconfig` — the look and the bit

Mute, desktop-bin visibility, `NextAction`. `LoadConfig` / `SaveConfig` write `thegrouch.ini` under `GetAppConfigDir`.

### `ugrouchtrash` — Empty Trash without hooking Finder

`CountTrashItems` skips `.` / `..` / `.DS_Store`. `TrashWasEmptied(Prev, Now)` is the only transition that counts: **something → nothing**. `IsEmptyTrashTitle` matches Finder’s menu item, ellipses, Wastebasket, and a few localisations.

### `ugrouchmodel` — the linear tape

`Trigger` is a no-op unless `gpDormant`. `Update(dt)` advances `FPhaseT` and calls `EnterPhase` when a step’s duration elapses. Durations: lid 0.38 s, rise 0.55 s, wave 1.65 s (or `SongDuration` when singing), sink 0.48 s, lid close 0.32 s. `ForcePose` is for tests and snapshots — no sfx, no toggle.

Pose fields the renderer actually uses:

| Field | Meaning |
|-------|---------|
| `LidAngle` | 0 closed … 1 flipped back (eased) |
| `Rise` | 0 inside the can … 1 popped (ease-out-back so he overshoots) |
| `Wave` | `sin` of action time, right arm |
| `Mouth` | `SongMouthAt` during sing; a small frown otherwise |
| `ShowCaption` | cream bubble only while singing |

Sounds are **not** started from the renderer. `EnterPhase(gpLidOpen)` queues `sfxLid`; `EnterPhase(gpAction)` queues `sfxSong` only for `gaSingAndWave`. The host drains the queue.

### `ugrouchrender` — the overlay

`TPixelBuffer` plus ellipses, a trapezoid can, and 5×7 caption glyphs. Painter’s algorithm: open lid behind him, Oscar, can body covering everything below the rim, closed lid on top. Clear is RGBA `(0,0,0,0)`.

### `ugrouchaudio` — original bytes

`BuildSfxWav` writes in-memory WAVs (22050 Hz, 16-bit mono). The song score is also what `SongMouthAt` reads, so the mouth lip-syncs the shout the host is playing. Not the 1970 recording.

### `ugrouchapp` — glue

Timer → `Tick` → `Update` + dirty flag. Space / Come Out! → `Trigger`. Hosts never touch `FPhase`.

### Hosts — present bytes and notice the bin

**macOS.** Borderless `NSWindow`, `ignoresMouseEvents`, `NSStatusWindowLevel`, hidden while dormant. `FSEventStream` on `~/.Trash` sets a dirty flag; the 30 Hz tick recounts and calls `Trigger` when `TrashWasEmptied`. Optional `AXObserver` on Finder for `AXMenuItemSelected`. Dock tile: `AXUIElement` on Dock if trusted, otherwise `com.apple.dock` `tilesize` / `orientation` plus `visibleFrame`.

**Windows.** `SHQueryRecycleBin` every ~0.5 s. Layered `WS_EX_LAYERED` overlay in the lower-right of the work area.

**Linux.** Poll `~/.local/share/Trash/files`. GTK 2 undecorated keep-above window + `GtkStatusIcon`.

A 1.5 s debounce stops FSEvents and the menu observer from popping him twice for one Empty Trash. A Trigger while `Busy` is ignored.

## Security (why this is not a Finder hack)

Classic Mac OS intercepted the Special menu’s Apple Event. Modern macOS SIP will not let a random app inject into Finder. Watching the user’s own `~/.Trash` folder is the supported equivalent: when Finder actually deletes the files, the count drops to zero and Oscar comes out. Accessibility is a single user toggle, never required for the gag to work.
