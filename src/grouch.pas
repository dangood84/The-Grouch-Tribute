program TheGrouch;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$linkframework Cocoa}
{$linkframework CoreServices}
{$linkframework ApplicationServices}
{$ENDIF}

{ The Grouch Tribute — Empty Trash companion in Pascal.

  macOS:    menu extra + overlay above the Dock Trash (no Dock icon).
  Windows:  tray icon + small overlay near the work-area corner.
  Linux:    panel icon + overlay.

  Only one HostRun is linked; the other two host units are not compiled.
  Build: see the Makefile. }

uses
  {$IFDEF DARWIN}
  uhostcocoa
  {$ELSE}
    {$IFDEF WINDOWS}
    uhostwin
    {$ELSE}
    uhostgtk
    {$ENDIF}
  {$ENDIF};

begin
  HostRun; { Cocoa run loop, Win32 GetMessage, or gtk_main — see uhost*.pas }
end.
