# PSCAD 5.0.2 on Linux under Wine

PSCAD is a Windows-only power system simulator from Manitoba HVDC. It runs
well under Wine, but several problems get in the way, and none of them produces
a message that points at the cause. This directory holds a script that does
the whole install and applies every workaround.

## Tested on

| Distribution  | Desktop  | Wine  |
|---------------|----------|-------|
| Kubuntu 26.04 | KDE      | 10.0  |
| CachyOS       | Hyprland | 11.17 |

Both with the PSCAD 5.0.2 Update 2 installer. The two differ in ways that
matter, and the script handles each: Debian and Ubuntu patch Wine's automatic
Mono download out of their packages while Arch and its derivatives do not, and
Hyprland has none of the KDE tooling the KDE path relies on. Other
distributions should work; the dependency step only knows `apt`.

## Quick start

```bash
./install-pscad.sh --installer ~/Downloads/PSCAD_502_U2_installer
```

The script needs a desktop session, because the PSCAD installer is a graphical
wizard that you click through. Everything before and after it is automatic.
Budget about twenty minutes, most of it the .NET Framework.

Then start PSCAD:

```bash
~/pscad_local/pscad
```

**On Hyprland, and on most other Wayland compositors, use the other launcher
instead:**

```bash
~/pscad_local/pscad-desktop
```

It runs PSCAD inside a Wine virtual desktop. Wine draws menus and their drop
shadows as separate X11 windows, and a compositor that manages those windows
paints them opaque black, so drop-downs come up as black rectangles over a
menu that is still there and still clickable. A virtual desktop keeps every
Wine window inside one X11 window, where no compositor can get it wrong, and
it also gives PSCAD a normal decorated, resizable window on desktops that have
no equivalent of the KWin rule the script writes for KDE. Both launchers are
otherwise identical.

Useful options: `--root DIR` to install somewhere other than `~/pscad_local`,
`--lm-server ADDR` if you license from a legacy License Manager, and
`--skip-deps` if you manage distribution packages yourself. `--help` lists
them all.

## What the script does, and why

**Creates a 64-bit Wine prefix.** A dedicated prefix rather than `~/.wine`, so
PSCAD's requirements cannot disturb anything else you run under Wine, and so
removing PSCAD is one `rm -rf`.

**Installs .NET Framework 4.8**, through winetricks. PSCAD's user interface is
partly managed code and will not start without it. This is the slowest step
and prints nothing while it works.

**Sets the prefix to Windows 10.** Installing .NET leaves the prefix reporting
an older Windows, and PSCAD's installer checks the version before it will
proceed.

**Installs the Visual C++ 2022 runtimes**, taken from the installer's own
`ISSetupPrerequisites` folder rather than downloaded, so the versions match
what PSCAD was built against. InstallShield checks for these by registry key,
so installing them first is what lets the wizard run at all.

**Installs Wine Gecko.** PSCAD draws some of its forms as HTML. Without Gecko
it starts but those panels stay blank. Ubuntu does not package Gecko, so this
is fetched from winehq.org, at the version your Wine build asks for.

**Runs the PSCAD installer** with `/v"/IgnoreDrivers"`. The USB dongle driver
is skipped deliberately. Wine cannot load Windows kernel drivers, so dongle
licensing will not work on Linux no matter what you do here.

**Builds the startup shim and writes the launchers.** Several of the
workarounds, described below.

**Adds a KWin rule** so the window gets a real titlebar and resize borders.

**Sets Wine's DPI** to match your desktop's display scaling, so PSCAD's text
is not half the size of everything else on a HiDPI screen.

**Adds a desktop entry** so PSCAD appears in your application menu.

## The problems, and the fixes

### PSCAD crashes before it draws a window

Launching `Pscad.exe` directly gives you this and nothing else:

```
Unhandled Exception: System.AccessViolationException: Attempted to read or
write protected memory.
   at aa()
wine: Unhandled page fault on read access to 0000000000000000
```

PSCAD looks up its own fully-qualified host name using the `AI_FQDN` flag.
Wine does not implement that flag: the call reports success but leaves the
canonical-name field null, and PSCAD reads the field without checking it.

`fix/pscad_shim.c` asks the C library for the canonical name, which fills the
field in. The launcher loads it with `LD_PRELOAD`. **PSCAD will not start
without it**, so always launch through `pscad` rather than calling the
executable directly. Upgrading Wine does not help; the flag has been
unimplemented for years.

### PSCAD exits with "Invalid IL code" instead of starting

The launcher runs, and PSCAD gets as far as loading managed code before it
gives up:

```
field dx3 in <Module> should have RVA data, but hasn't
System.TypeInitializationException: The type initializer for 'a84' threw an
exception. ---> System.InvalidProgramException: Invalid IL code in a84:.cctor ()
```

Those single-letter type names are the giveaway: PSCAD's assemblies are
obfuscated, and it is Wine Mono, not the real .NET Framework, that is refusing
to load them. .NET 4.8 was never installed in the prefix.

The trap is that the prefix will insist otherwise. Wine installs its own Mono
into every new prefix, and Mono registers the very same
`HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full` key that the real
framework does, complete with a plausible `Release` and `Version`. Any check
that asks the registry whether .NET is present gets back yes on a prefix that
has no .NET at all. The script used to ask exactly that, and so skipped the
install with "Already present, skipping" wherever the distribution ships Wine
Mono by default — Arch and its derivatives do, Debian and Ubuntu do not. It
now looks for winetricks' own `drive_c/windows/dotnet48.installed.workaround`
marker, and for `drive_c/windows/mono` being gone.

To confirm the state of a prefix by hand:

```bash
WINEPREFIX=~/pscad_local/prefix winetricks list-installed
file ~/pscad_local/prefix/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll
```

A healthy prefix lists `dotnet48`, and `file` does not say `Mono`. To repair
one in place, without reinstalling PSCAD:

```bash
WINEPREFIX=~/pscad_local/prefix winetricks -q --unattended dotnet48
WINEPREFIX=~/pscad_local/prefix winetricks -q win10
```

winetricks removes Mono itself as part of that.

One caveat on Arch and CachyOS: their Wine is built in "new WoW64" mode, with
no 32-bit Unix side (`/usr/lib/wine` has `i386-windows` but no `i386-unix`).
The .NET 4.8 installer is 32-bit, and winetricks considers that combination
experimental. If the install fails there, use a Wine built with real 32-bit
support — `wine-cachyos`, or Proton through Lutris.

### The License Manager rejects the machine as off-net

Only affects sites using the legacy License Manager, not certificate
licensing. PSCAD shows a license dialog, and the log records:

```
LM Client on   MYBOX (100.64.0.20), [7]
LM Server on   10.0.0.1 (10.0.0.1), [3]
ERROR: Client is not on same net as LM
   LM refused to grant license
```

The address on the client line is the giveaway. If it is not the address your
machine uses on the LAN, the licence server is right to refuse it, and the
problem is name resolution rather than the licence.

On a machine running an overlay VPN such as Tailscale, the VPN puts its own
domain first in the resolver search list. PSCAD completes its short host name
with that domain, resolves the result, the VPN's DNS answers with the overlay
address, and PSCAD introduces itself to the licence server under an address
that is genuinely not on the server's network.

The launcher sets `LOCALDOMAIN`, which overrides the search list for PSCAD
alone. The VPN keeps working normally and the system resolver is untouched.
The install script picks the domain by testing which one resolves your host
name to the address your machine actually uses toward the network, but you can
edit the line in `pscad` if it guesses wrong or the machine moves networks.

The other cause is `/etc/hosts`. Most distributions put a line like

```
127.0.1.1  mybox
```

in it, and the name service reads that file before it asks DNS, so the host
name resolves straight back to loopback. PSCAD then announces itself as
127.0.1.1, which is on nobody's network:

```
LM Client on   MYBOX (127.0.1.1), [7]
```

`LOCALDOMAIN` cannot help here, because the loopback answer comes from a file
that is consulted before the resolver ever sees the search list. Instead the
shim replaces a loopback answer for this machine's own name with the address
of the interface that faces the network, found the way the routing table
would: connecting a UDP socket sends no packet but makes the kernel choose a
source address. `PSCAD_LM_SERVER` in the launcher names the host to route
towards, which only matters when the machine has more than one way out.

Both resolver entry points need that fix. PSCAD asks Winsock through the old
`gethostbyname()`, and Wine answers that one from the C library's
`gethostbyname_r()` rather than from `getaddrinfo()` -- so hooking
`getaddrinfo` alone corrects the *name* and leaves the *address* untouched,
which looks exactly like the fix not working. `PSCAD_SHIM_DEBUG=1` traces
every rewrite; `PSCAD_KEEP_LOOPBACK=1` turns this fix off.

When it is working, the client line names your LAN address, and the number in
brackets changes with it:

```
LM Client on   MYBOX (10.20.30.40), [4]
MYBOX: Asking for <Educational v4/x4>
```

Note that PSCAD does not take this address from the network interface list, so
changing interface metrics, routes or adapter order has no effect. Only name
resolution matters.

### "IP request timed out" from the License Manager

A different failure, with a thoroughly misleading message:

```
Most Recently Used Edition: <none>
mybox requesting PSCAD 5 Professional
ERROR: Unable to connect to <10.0.0.1>. Cause: IP request timed out
   LM service is not running. Status: 12010
```

This is not a network problem. Read the line above the error instead: the
outcome tracks the *edition* PSCAD asked for, not whether the server is
reachable.

```
Asking for <Educational v4/x4>     -> the server answers, every time
requesting PSCAD 5 Professional    -> IP request timed out, every time
```

If the site's License Manager does not serve the edition being requested, the
request times out instead of being refused. PSCAD asks for Professional
whenever it has no remembered edition, which is exactly what `Most Recently
Used Edition: <none>` means -- and what a newly created prefix always says. So
a from-scratch reinstall reintroduces this on a machine where licensing
previously worked.

Pick your edition in PSCAD and it is remembered from then on. If the edition
drop-down is one of the black rectangles described below, start PSCAD with
`pscad-desktop` so you can read it.

Confirm reachability separately before believing the message:

```bash
ping <lm-host>
```

### Drop-down menus come up as solid black rectangles

The menu is there and still works -- clicks land on the right entries -- but a
black rectangle is painted over it. On Hyprland you can even drag the
rectangle to another workspace and find the menu intact underneath.

Wine draws a menu's drop shadow as a *separate* X11 window and advertises it
as `_NET_WM_WINDOW_TYPE_DIALOG`, so a Wayland compositor manages it like any
other window and paints its content opaque black over the menu. `xprop` shows
the pair: two windows with the application's class, an empty `WM_NAME` and
nearly the same geometry, a few pixels apart.

No window rule fixes this. The shadow is a genuine window whose content is
black, so making it opaque, unblurred or undecorated changes nothing, and it
cannot be told apart from the menu by class or title. Turning Windows' drop
shadows off in the prefix does not reach it either.

Use `pscad-desktop` instead of `pscad`. It runs PSCAD inside a Wine virtual
desktop, so every Wine window -- menus, shadows and dialogs -- is drawn inside
one X11 window that the compositor never sees into. Change the size in the
launcher's `explorer /desktop=PSCAD,1440x880` if the default does not suit
your screen, and float the window rather than tiling it, since it is a fixed
size:

```
# Hyprland
windowrule = float, class:^(explorer\.exe)$, title:^(.*Wine Desktop)$
```

### The window has no titlebar buttons and will not resize

Minimise, maximise and resize do nothing, and there is no border to drag.

PSCAD draws its own titlebar, the way Office-style ribbon applications do, so
Wine tells the window manager the window wants no decorations at all. The
window manager obliges, which leaves nothing to click and nothing to grab.
Nothing is actually broken inside PSCAD: sending the same actions
programmatically works, and so do KDE's keyboard alternatives, Meta+drag to
move and Meta+right-drag to resize.

The install script adds a KWin rule that forces decorations for the window
class `pscad.exe`. You then get a normal titlebar with working buttons and
7-pixel resize borders. PSCAD keeps drawing its own titlebar underneath, so
you see two of them; that is cosmetic and there is no way to suppress the
inner one without giving up PSCAD's quick-access toolbar.

Minimise, restore, close and drag-resize all work after this. Maximise does
not, for the separate reason below.

To remove the rule later, open System Settings, Window Management, Window
Rules, and delete the PSCAD entry, or edit `~/.config/kwinrulesrc`.

On desktops other than KDE, set the equivalent rule yourself. The property you
are looking for is usually described as forcing server-side decorations for a
window class. Simpler still, use `pscad-desktop`: a Wine virtual desktop is an
ordinary window that every window manager decorates without being asked.

### Maximise leaves the window half-painted

Maximising grows the window frame but PSCAD's contents stay their previous
size, so the desktop shows through the rest of the window.

This is not fixable from outside the application. Windows reports the window
as maximised and at the full size, and `GetClientRect` agrees, but PSCAD's own
layout never runs, so nothing is redrawn. It happens whichever way the
maximise is triggered: the titlebar button, the window manager directly, a
`WM_SYSCOMMAND` sent straight to the window, or PSCAD restoring a saved
maximised state at startup.

**Resize by dragging instead, and do not maximise.** Dragging relayouts
correctly at every size, right up to filling the screen, and PSCAD remembers
the size between sessions. If you do maximise by accident, un-maximise and the
layout comes back immediately; nothing is lost.

Do not try to solve this with a KWin rule that forces the maximised state off.
That looks like it works, but PSCAD keeps its own internal maximised flag,
which the window manager is then refusing to clear, and the window ends up
pinned to the size it had when it got stuck. Dragging it larger stops having
any effect past that point, which is much worse than the original problem.

### Everything is too small on a HiDPI screen

Wine renders at 96 DPI whatever the desktop does, so on a scaled display PSCAD
comes out much smaller than native applications.

The install script reads your desktop's scaling and sets Wine's DPI to match,
which scales PSCAD's fonts, icons and controls together. A 1.7x desktop gives
163 DPI, a 1.25x desktop 120. It asks `kscreen-doctor` on KDE, `hyprctl` on
Hyprland and `wlr-randr` on other wlroots compositors, and leaves PSCAD at 96
DPI if none of them is there; pass `--dpi N` to say so yourself.

To change it afterwards, either re-run with `--dpi N`, or use the Graphics tab
of winecfg:

```bash
WINEPREFIX=~/pscad_local/prefix winecfg
```

96 is 100%, 144 is 150%, 192 is 200%. Restart PSCAD after changing it.

## Layout

This repository:

```
install-pscad.sh     the installer; the only thing you need to run
README.md            this file
fix/pscad_shim.c     the LD_PRELOAD shim, with the reasoning in its comments
```

`install-pscad.sh` embeds its own copy of the shim and writes it out at
install time, so the script is self-contained. `fix/pscad_shim.c` is the same
source, kept here so it can be read without scrolling through the installer.

What the install creates, by default in `~/pscad_local`:

```
pscad              launcher; always start PSCAD through it
pscad-desktop      same, inside a Wine virtual desktop; fixes black menus
                   and gives PSCAD a normal titlebar anywhere
fortranmedic       PSCAD's compiler diagnostics, same environment
fix/pscad_shim.c   the shim source, and the .so built from it
prefix/            the Wine prefix, about 4 GB
```

## Checking that it works

The title bar tells you the licence state, `Educational` or `Unlicensed`.

For licensing problems, read this file, which is the most useful thing on the
machine:

```
prefix/drive_c/ProgramData/Manitoba HVDC Research Centre/LicenseManager/PscadLmgr.txt
```

To confirm the Fortran toolchain, which EMTDC needs to build cases, run
`./fortranmedic`. It should list GFortran 8.1. Note that anything you compile
by hand needs the compiler's `bin` directory on the Windows PATH, or the
resulting executable will not find its runtime DLLs.

To see what the shim is doing, set `PSCAD_SHIM_DEBUG=1`. To turn its host name
handling off and confirm a problem is really the shim's doing, set
`PSCAD_KEEP_FQDN=1`; PSCAD will then crash at startup as described above.

## Known limits

- Dongle licensing cannot work, since Wine cannot load the USB driver.
- Certificate licensing was not tested here; only the legacy License Manager.
- The dependency step only knows `apt`. On other distributions install wine
  (with 32-bit support), winetricks, curl and gcc yourself first.
- The titlebar fix is written for KWin. Other window managers need the same
  idea applied their own way, or can use `pscad-desktop`.
- Maximise cannot be made to work. Drag to resize instead.
