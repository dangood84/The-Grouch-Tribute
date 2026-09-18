# The Grouch Tribute

A tribute to the classic Mac OS utility that popped a grouch out of the **Wastebasket** when you chose **Empty Trash** from the **Special** menu.

On modern macOS that menu lives under **Finder**. This helper sits in the menu extras, watches `~/.Trash`, and when the bin goes from “has stuff” to empty he pops a colour can up above the Dock Trash icon, flips the lid, and either **waves and sings** or **just waves** — alternating each time, remembered across launches.

Written in **Free Pascal**. Lazarus and Delphi are not required — `fpc` plus the platform GUI libraries already on the machine are enough. There is no widget-toolkit theme to fight. Oscar is a software RGBA canvas; each host only uploads those bytes into a borderless overlay.

Sprites and chip sounds are **original**. This is not affiliated with Sesame Workshop, Apple, or the classic Grouch INIT, and it does not ship their bitmaps or samples.

How the pieces fit together (same style as Eyes, Lemmings Overlay, and the RISC OS Clock): `WORKINGS.md` for responsibilities and the state machine, `EXECUTION_FLOW.md` for a tick-by-tick trace.

## Requirements

- **Free Pascal** 3.2+ (`fpc` on your `PATH`)

macOS (Homebrew), Sonoma-compatible:

```bash
brew install fpc
```

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
```

Windows 10+: a native Free Pascal install (the `Windows` unit ships with FPC).

On **macOS**, Empty Bin is noticed by asking **Finder** how many items are in the Bin (the same list **Finder → Empty Bin** clears). macOS blocks apps from reading `~/.Trash` directly. The first launch will ask to allow The Grouch Tribute to **control Finder** — that is required for Empty Bin, not for Come Out!.

Optionally grant **Accessibility** (menu extra → Request Accessibility…) so he can sit exactly on the Dock Bin tile. Without it he still appears, using a geometric guess for the Dock’s right-hand bin.

## Run

From the project root:

```bash
make
make run
```

That compiles to `build/` and opens `TheGrouch.app` on macOS. There is **no Dock icon** (`LSUIElement`); look for the tiny can in the **right-hand menu extras**.

Or with Make on other OSes:

```bash
make linux      # Linux / Raspberry Pi OS overlay + panel icon
make windows    # TheGrouch.exe — overlay + tray icon
make test       # headless state / toggle / sfx / trash checks (no GUI)
make snap       # PPM frames of lid / rise / wave / sing
make clean      # remove build/
```

Manual compile on macOS (Make still has to wrap the binary in the `.app` bundle):

```bash
fpc -Mobjfpc -Scgi -O2 -Fusrc -FUbuild -FEbuild -obuild/TheGrouch src/grouch.pas
make app
open build/TheGrouch.app
```

## Using it

1. Leave some files or folders in the Bin, then choose **Finder → Empty Bin…** (or **Empty Trash…**, or ⌘⇧⌫). When Finder’s count hits zero, the lid flips above the Dock.
2. First time he **sings** an original 8-bit shout and waves, with a cream “I LOVE TRASH!” bubble. Next Empty Trash he **only waves**. Then it flips back. The bit is stored in `thegrouch.ini`.
3. **Come Out!** from the menu extra plays the sequence without emptying anything.
4. **Show Desktop Bin** drops a clickable can on the desktop (drag to move; click to trigger).
5. The animation overlay **ignores mouse clicks**, so you can still use the real Trash underneath.

## Where it appears

| OS | Presence |
|----|----------|
| **macOS** | Menu extra + borderless overlay above the Dock Trash. No Dock icon. Optional desktop bin. |
| **Windows** | Notification-area icon + overlay in the lower-right of the work area when Recycle Bin empties. |
| **Linux** | Panel status icon + overlay; watches `~/.local/share/Trash/files`. |

Quit from the extra / tray. Closing is not a window close box — there isn’t one on the overlay.

## Project layout

```
src/
  grouch.pas          # program; picks the host with {$IFDEF}
  ugrouchconfig.pas   # mute, widget, sing/wave toggle, INI
  ugrouchtrash.pas    # trash-folder count + Empty Trash title match
  ugrouchmodel.pas    # dormant → lid → rise → action → sink → close
  ugrouchrender.pas   # software RGBA canvas (original grouch + can)
  ugrouchapp.pas      # TGrouchController: overlay + bar + widget buffers
  ugrouchaudio.pas    # original WAV lid squeak + sung shout
  uhostcocoa.pas      # macOS overlay, FSEvents, optional AX
  uhostwin.pas        # Windows layered HWND + Recycle Bin poll
  uhostgtk.pas        # Linux GtkWindow + trash-dir poll
  grouchtest.pas      # headless state / sfx / trash checks
  grouchsnap.pas      # paints PPM frames without a window
bundle/
  Info.plist          # LSUIElement menu extra, retina-capable
Makefile
```
