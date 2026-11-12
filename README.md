# PSCAD 5 on Linux under Wine

PSCAD is a Windows-only power system simulator from Manitoba HVDC. It runs
well under Wine, but several problems get in the way, and none of them produces
a message that points at the cause. This directory holds a script that does
the whole install and applies every workaround.

## Tested on

| Distribution  | Desktop  | Wine  | PSCAD          |
|---------------|----------|-------|----------------|
| Kubuntu 26.04 | KDE      | 10.0  | 5.0.2 U2, 5.1.0 |
| CachyOS       | Hyprland | 11.17 | 5.0.2 U2        |
| CachyOS       | Hyprland | 11.18 | 5.1.0           |

The two distributions differ in ways that matter, and the script handles each:
Debian and Ubuntu patch Wine's automatic Mono download out of their packages
while Arch and its derivatives do not, and Hyprland has none of the KDE tooling
the KDE path relies on. Other distributions should work; the dependency step
only knows `apt`.

The two PSCAD releases ship different installers, and the script works out
which one it was handed:

| PSCAD  | Installer      | Made by                  | Fortran compiler         |
|--------|----------------|--------------------------|--------------------------|
| 5.0.x  | `setup.exe`    | InstallShield            | GFortran 4.6 and 8.1, bundled |
| 5.1.x  | `Installer.exe`| MHI's Installer Utility  | none; see below          |

5.1 also installs Python 3.13 and its automation packages itself, where 5.0.2
bundled Python 3.7; see *Error 112* below.

## Quick start

```bash
./install-pscad.sh --installer ~/Downloads/PSCAD_510_x64_Installer
```

With no `--installer`, the script looks for `~/Downloads/PSCAD_*` folders
holding a `setup.exe` or an `Installer.exe` and takes the highest version by
name, so with both unpacked `PSCAD_510_x64_Installer` wins over
`PSCAD_502_U2_installer`. It prints the others it found; pass `--installer` to
use one of those instead.

Each version installs into its own root, named after it: `~/PSCAD_5.1.0`,
`~/PSCAD_5.0.2`. The version is read from the installer before anything is
installed, so installing a second version never touches the first, and each
gets its own prefix, launchers and application-menu entry. `--root DIR` puts
it somewhere else.

The script needs a desktop session. By default the PSCAD installer runs as
the graphical wizard and you click through it; everything before and after it
is automatic. `--silent=true` (or just `--silent`) skips the wizard's
questions and takes its defaults, so the whole install runs unattended. That
works as is for 5.1. The 5.0.x InstallShield installer can only run silently
from a response file, `setup.iss`, recorded beforehand with MHI's
`RecordSilentInstall.bat`; without one the script says so and runs the wizard.
Budget about twenty minutes, most of it the .NET Framework.

Then start PSCAD:

```bash
~/PSCAD_5.1.0/pscad
```

**On Hyprland, and on most other Wayland compositors, use the other launcher
instead:**

```bash
~/PSCAD_5.1.0/pscad-desktop
```

It runs PSCAD inside a Wine virtual desktop. Wine draws menus and their drop
shadows as separate X11 windows, and a compositor that manages those windows
paints them opaque black, so drop-downs come up as black rectangles over a
menu that is still there and still clickable. A virtual desktop keeps every
Wine window inside one X11 window, where no compositor can get it wrong, and
it also gives PSCAD a normal decorated, resizable window on desktops that have
no equivalent of the KWin rule the script writes for KDE. Both launchers are
otherwise identical.

The application-menu entry uses `pscad-desktop` on Wayland, including
Hyprland, and `pscad` on X11. Its window class matches that launcher, so the
bar can associate the running window with PSCAD's icon.

Useful options: `--root DIR` to install somewhere other than
`~/PSCAD_<version>`, `--gfortran DIR` to name the GFortran installer for 5.1
(see below), `--lm-server ADDR` if you license from a legacy License Manager,
`--edition EDU` to have PSCAD ask that License Manager for Educational first,
`--dpi 192` for 200% UI scaling if automatic detection cannot reach your
compositor, and `--skip-deps` if you manage distribution packages yourself.
The required Linux tools are Wine, winetricks, curl, gcc and Python 3;
Python's standard library extracts the original icon without Pillow.
`--help` lists all options.

To pick up an install that stopped part way through -- the wizard finished but
the script did not -- re-run it with `--force --skip-installer`. Every step is
safe to repeat.

To apply the display and icon fixes to an existing installation, close PSCAD
and other Wine programs in that prefix, then regenerate its configuration:

```bash
./install-pscad.sh \
  --installer ~/Downloads/PSCAD_510_x64_Installer \
  --root ~/PSCAD_5.1.0 --force --skip-installer --dpi 192
```

Use the root where PSCAD is already installed. This skips the PSCAD wizard;
the script still checks prerequisites and refreshes the launchers, registry
settings and desktop entry. Reopen PSCAD from the application menu afterwards.

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

**Installs the Visual C++ runtimes** for 5.0.x, from `ISSetupPrerequisites`
in the installer's own folder, so nothing is downloaded and the versions match
what PSCAD was built against. InstallShield checks for these by registry key,
so installing them first is what lets the wizard run at all. The 5.1 Installer
Utility installs its own -- 2005, 2010 and 2022, from `Support/Redists` -- and
the script leaves that to it, because it knows each package's switches: the
2005 package answers the `/q /norestart` the others take with a *Command line
option syntax error* box that holds everything up until someone clicks OK.

**Installs Wine Gecko.** PSCAD draws some of its forms as HTML. Without Gecko
it starts but those panels stay blank. Ubuntu does not package Gecko, so this
is fetched from winehq.org, at the version your Wine build asks for.

**Stands in for the Python launcher**, by writing `py.bat` into the prefix's
`system32`. Without it PSCAD 5.1 stops with *Error 112*; see below.

**Runs the PSCAD installer**: `setup.exe /v"/IgnoreDrivers"` for 5.0.x, or
`Installer.exe /RunAsElevated=True` for 5.1.x. `/IgnoreDrivers` skips the USB
dongle driver, which Wine cannot load -- dongle licensing will not work on
Linux no matter what you do here. The 5.1 Installer Utility takes no equivalent
switch and runs the Sentinel driver's setup regardless; that is harmless, but
it can leave a `winedevice.exe` behind, which is why every wait for Wine to
settle in this script is bounded.

The wait for the wizard itself is different. `wine Installer.exe` returns
within seconds, with exit code 205: the Installer Utility relaunches itself
elevated, the first instance exits, and the second does all the work -- about
three minutes of unpacking, Python and driver setup after you click Install.
So the script watches the prefix instead, and carries on once nothing but
Wine's own services (`services.exe`, `winedevice.exe` and the like) is left
running in it.

**Installs PSCAD's Python automation packages**, `mhi-pscad` and what it needs,
into the Windows Python the installer put in the prefix. On 5.1 this is not
optional: PSCAD's own package step only gets as far as `pywin32` under Wine
(see *Error 112*), so without it `mhi.pscad` is missing. If the wizard's
"Install Python 3.13.5 now?" was answered no, the script runs the Python
installer PSCAD left in the prefix first; see *Error 103*.

**Installs a Fortran compiler** if the prefix has none, which after a 5.1
install it never does; see *Fortran compiler not detected*.

**Builds the startup shim and writes the launchers.** Several of the
workarounds, described below.

**Adds a KWin rule** so the window gets a real titlebar and resize borders.

**Sets Wine's DPI** to match your desktop's display scaling, so PSCAD's text
is not half the size of everything else on a HiDPI screen. Both launchers
reapply the selected DPI when starting, and the virtual desktop grows with
it to preserve the working area.

**Adds a desktop entry** with PSCAD's original icon and the window class of
the selected launcher, so PSCAD appears in your application menu and bar.

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
WINEPREFIX=~/PSCAD_5.1.0/prefix winetricks list-installed
file ~/PSCAD_5.1.0/prefix/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll
```

A healthy prefix lists `dotnet48`, and `file` does not say `Mono`. To repair
one in place, without reinstalling PSCAD:

```bash
WINEPREFIX=~/PSCAD_5.1.0/prefix winetricks -q --unattended dotnet48
WINEPREFIX=~/PSCAD_5.1.0/prefix winetricks -q win10
```

winetricks removes Mono itself as part of that.

One caveat on Arch and CachyOS: their Wine is built in "new WoW64" mode, with
no 32-bit Unix side (`/usr/lib/wine` has `i386-windows` but no `i386-unix`).
The .NET 4.8 installer is 32-bit, and winetricks considers that combination
experimental. If the install fails there, use a Wine built with real 32-bit
support — `wine-cachyos`, or Proton through Lutris.

### "Unable to fully and correctly install", exit code 32506

PSCAD 5.1's installer finishes with

```
Unable to fully and correctly install the latest product files.
   Failed to update or install all the required environment variables,
   registry keys, and shortcuts. The product may or may not operate correctly.
   Uninstall this product if possible, then re-install it
```

and `ExitCode = 32506`. Ignore it. PSCAD is installed correctly; the only thing
that failed is the Windows desktop shortcut, which is of no use on Linux. The
log names the one error:

```
Installing shortcut: PSCAD 5.1.0 (x64)
   Location: C:\users\Public\Desktop\PSCAD 5.1.0 (x64).lnk
   Error HRESULT E_FAIL has been returned from a call to a COM component.
      Invoking Type: IWshRuntimeLibrary.IWshShortcut
      Method: Void set_IconLocation(System.String)
```

Wine's `wshom.ocx` rejects an icon location with no `,index` suffix, and a bare
path is what PSCAD passes. Reproduce it with `cscript`:

```vbs
Set ws = CreateObject("WScript.Shell")
Set sc = ws.CreateShortcut("C:\users\Public\Desktop\probe.lnk")
sc.IconLocation = "C:\windows\system32\notepad.exe"     ' E_FAIL
sc.IconLocation = "C:\windows\system32\notepad.exe,0"   ' fine
```

The install script reads the newest log under

```
prefix/drive_c/users/<you>/AppData/Local/Manitoba Hydro International/Installer/Messages/
```

after the wizard and tells you whether the shortcut really was the only
failure, so you do not have to take the installer's summary at face value. If
it reports more than one error, that log is where to look.

### "Error: 112 Failed to install Python WHL file(s) as Python is not installed"

PSCAD 5.1 installs cleanly, offers to install Python 3.13, installs that
cleanly too, and then ends with

```
Installers - Error: 112  Failed to install Python WHL file(s) as Python is
not installed.
```

Python *is* installed. `C:\Program Files\Python313\python.exe` runs, reports
its version and has pip. What is broken is `py.exe`, the Python launcher, which
is what PSCAD's `install-packages.bat` calls:

```bash
WINEPREFIX=~/PSCAD_5.1.0/prefix wine 'C:\windows\py.exe' -0
No installed Pythons found!
```

`PYLAUNCHER_DEBUG=1` shows the launcher getting as far as the registry and
finding nothing, even though the key is plainly there. The launcher reads
`PythonCore\<version>\InstallPath` with `RegGetValueW`, asking for
`RRF_RT_REG_SZ|RRF_RT_REG_EXPAND_SZ`, and Wine rejects that combination of
flags outright:

```python
# wine 'C:\Program Files\Python313\python.exe' -
import ctypes, ctypes.wintypes as w
a = ctypes.WinDLL('advapi32'); cb = w.DWORD(0)
for flags in (0x2 | 0x4, 0x2):
    rc = a.RegGetValueW(w.HKEY(0x80000002),
                        "Software\\Python\\PythonCore\\3.13\\InstallPath",
                        None, flags, None, None, ctypes.byref(cb))
    print(hex(flags), rc)     # 0x6 -> 87 (ERROR_INVALID_PARAMETER),  0x2 -> 0
```

Verified on wine-10.0. It is not about which registry view the 32-bit
`py.exe` sees: mirroring the whole key into `Wow6432Node` changes nothing,
because the call fails before it reads anything.

The fix is to not use `py.exe`. `cmd` searches `system32` before `C:\windows`,
so the install script writes a `py.bat` there that finds
`C:\Program Files\Python3*\python.exe` itself and forwards to it, covering
the `-0` and `-X.Y` arguments PSCAD uses. It is written *before* the wizard
runs, so error 112 never appears.

That only gets the wizard half way. `install-packages.bat` runs `py` twice,
first for `pywin32` and then for `mhi-pscad`, and it does so without `CALL`.
With `py` now a batch file, cmd hands control to it and never comes back, so
the second line never runs: the wizard reports success with `pywin32`
installed and `mhi-pscad` not. The script's own package step, which runs
after the wizard, installs the rest.

On a prefix that was installed before that existed, re-running the script with
`--force --skip-installer` writes the shim and installs the packages. Or do it
by hand:

```bash
export WINEPREFIX=~/PSCAD_5.1.0/prefix
wine 'C:\Program Files\Python313\python.exe' -m pip install \
    --find-links 'C:\users\Public\Documents\Manitoba Hydro International\Python\Packages' \
    pywin32 mhi-common mhi-pscad
wine 'C:\Program Files\Python313\python.exe' \
     'C:\Program Files\Python313\Scripts\pywin32_postinstall.py' -install -silent
```

The wheels PSCAD ships are in that `--find-links` folder, but `mhi-common`
needs `packaging`, which PSCAD does not ship, so the rest comes from PyPI and
this step needs a network connection. `pywin32_postinstall.py` is what puts
pywin32's DLLs next to the interpreter; the wheel alone does not.

One thing the shim cannot fix: PSCAD's `install-packages.bat` also does

```bat
SET MHI_PSCAD="mhi-pscad >= 3.0.7, < 4"
%PIP_INSTALL% --upgrade %MHI_PSCAD%
```

Real `cmd` decides what is a redirection before it expands variables. Wine's
`cmd` expands first, so the `>` and `<` inside that string become
redirections and the second install silently does nothing. That is why the
script installs the packages itself afterwards rather than trusting the batch
file.

### "Installers - Error: 103" at the end of the 5.1 wizard

The wizard asks *"Python 3.7 or better is required by the PSCAD Automation
Library. Install Python 3.13.5 now?"* part way through. Answer no, or click
past it, and the log records

```
Attempting to run associated executable...
   User elected to skip the associated action
```

and a little later its package step fails, because there is no Python at all:

```
No installed Pythons found!
Exit code: 103
```

PSCAD itself is installed and works; only the automation library is missing.
The Python installer the wizard would have run is still copied into the
prefix, under `C:\users\Public\Documents\Manitoba Hydro
International\Python\Installers`, so the script runs it itself with the
wizard's own arguments and then installs the packages. On a prefix installed
before the script did that, re-run it with `--force --skip-installer`.

### "Fortran compiler not detected" when running a model (5.1)

EMTDC compiles every model with a Fortran compiler. PSCAD 5.0.x's installer
bundles MHI's GFortran 4.6 and 8.1 installers and runs them. PSCAD 5.1's does
not: it ships the EMTDC libraries for GFortran 8.1 and 13.2 (`emtdc\GF81`,
`emtdc\GF132`) but no compiler, so a fresh 5.1 prefix has none.

The GFortran installers are the same MHI Installer Utility and install
silently, so the script installs one when the prefix has no GFortran. It takes
`--gfortran DIR`, or else the newest `GFortran*` folder it finds in
`~/Downloads` -- the `GFortran81` inside an unpacked 5.0.x download does
nicely. 4.x is skipped: 5.1 lists it as unsupported. Verified under Wine: the
8.1 compiler builds and runs Fortran in a 5.1 prefix.

PSCAD looks for compilers with `Utilities\CompilerDetector.exe`, which reads
`HKLM\SOFTWARE\MHRC\GFortran\<version>` and the `GFORTRAN81` / `GFORTRAN132`
environment variables that those installers set. Its findings are in

```
prefix/drive_c/users/<you>/AppData/Local/Manitoba HVDC Research Centre/PSCAD/5.1/compilers.xml
prefix/drive_c/users/<you>/AppData/Local/Manitoba HVDC Research Centre/PSCAD/5.1/Logs/CompilerDetection_*.txt
```

**Then choose the 64-bit compiler once, before your first build.** A new
PSCAD 5.1 profile has no compiler chosen (`fortran_version="0"`), and PSCAD
offers the 32-bit *GFortran 8.1* in its place, which it cannot build with:

```
The specified Fortran compiler is not detected
```

even though the detector found it. Pick *GFortran 8.1 (64-bit)* under *File >
Application Options > Dependencies > Fortran compiler*; PSCAD stores it as
`GF81x64`, for both `fortran_version` and `c_version`, in

```
prefix/drive_c/users/<you>/AppData/Local/Manitoba HVDC Research Centre/PSCAD/user_profile_51.xml
```

The launchers set that for you whenever the profile exists and still has no
compiler, and never override a choice you made. They cannot help the very
first session: PSCAD writes the profile when it exits, and it cannot be
written for it in advance -- a profile holding only the compiler lets PSCAD
start, but it then hangs on exit and never saves one. The install script's
closing message says which compiler to pick.

A prefix copied from a 5.0 install also has GFortran 4.6.2, which PSCAD may
offer first and which 5.1 marks unsupported. The same choice fixes it.

### The License Manager rejects the machine as off-net

Only affects sites using the legacy License Manager, not certificate
licensing. PSCAD shows a license dialog, and the log records:

```
LM Client on   MYBOX (100.101.102.103), [7]
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
LM Client on   MYBOX (10.20.30.40), [4]
LM Server on   10.0.0.1 (10.0.0.1), [3]
ERROR: Unable to connect to <10.0.0.1>. Cause: IP request timed out
   LM service is not running. Status: 12010
```

The client address is right, the server answers `ping` from Linux in a
couple of milliseconds, and still every attempt fails. The wording is the
clue: *IP request timed out* is not a connection error but the status of an
ICMP echo, `IP_REQ_TIMED_OUT` (11010). Before it connects, PSCAD's License
Manager client pings the server, and it gives that ping a very short deadline
-- the defaults PSCAD 5.0.2 writes say `Timeout="1"`. Wine's `IcmpSendEcho`
honours a 1 ms deadline to the letter, so a server 2 ms away never answers in
time:

```python
# wine 'C:\Program Files\Python313\python.exe' -   (argtypes set properly)
IcmpSendEcho(h, <server>, ..., 1)     # -> 0 replies, status 11010
IcmpSendEcho(h, <server>, ..., 1000)  # -> 1 reply,   status 0
```

The ping is only a pre-check; the licence itself goes over an ordinary
connection. PSCAD has a switch for it, `PingEnabled` under
`HKLM\Software\Manitoba HVDC Research Centre Inc\PSCAD\License`, and the
install script sets it to `false`. It is shared by every PSCAD version in the
prefix. That is why an older prefix where it had once been switched off kept
working while a fresh one failed, on the same machine, at the same address, at
the same minute. To set it by hand:

```bash
WINEPREFIX=~/PSCAD_5.1.0/prefix wine reg add \
    'HKLM\Software\Manitoba HVDC Research Centre Inc\PSCAD\License' \
    /v PingEnabled /t REG_SZ /d false /f
```

Separately, a new prefix has no remembered edition (`Most Recently Used
Edition: <none>` in the log) and asks for Professional first. That is not what
produces this error, but if your site serves only Educational licences, pick
it in PSCAD once, or pass `--edition EDU` to the script, which writes
`MRUEdition` under `HKCU\Software\Manitoba HVDC Research Centre
Inc\PSCAD\<version>`. PSCAD keeps that per version, so a 5.1 prefix starts
without it even when 5.0 has long had it.

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
one X11 window that the compositor never sees into. Its default size follows
the selected DPI: 1440×880 at 96 DPI, 2160×1320 at 144 DPI, and 2880×1760 at
192 DPI. Override it for your screen if needed:

```bash
PSCAD_DESKTOP_SIZE=3200x1800 ~/PSCAD_5.1.0/pscad-desktop
```

Float the window rather than tiling it, since the virtual desktop has a fixed
internal size. For example, on Hyprland versions using the older rule syntax:

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
which scales PSCAD's fonts, icons and controls together. A 2x desktop gives
192 DPI, a 1.7x desktop 163, and a 1.25x desktop 120. It first asks `hyprctl`
for Hyprland's monitor JSON, then tries `kscreen-doctor` for KDE and
`wlr-randr` for other wlroots compositors. An installed tool that cannot
reach a running session does not prevent the next one from being tried.
The largest active monitor scale is used. If detection fails, the default
is 96 DPI; pass `--dpi N` to set it explicitly.

Both launchers remember the install-time DPI and reapply it before starting
PSCAD. To try another value, close PSCAD and other programs in its prefix,
then set `PSCAD_DPI` for the next launch:

```bash
PSCAD_DPI=144 ~/PSCAD_5.1.0/pscad-desktop
```

96 is 100%, 144 is 150%, 192 is 200%. Values must be whole numbers from 96 to
480. To change the saved default, rerun the installer with `--force
--skip-installer --dpi N`. Passing `--dpi 96` also resets a previously scaled
prefix. A DPI chosen only in winecfg is replaced by the launcher's saved
default on the next launch.

### The application menu or Hyprland bar has no PSCAD icon

The installer extracts the largest PNG frame from PSCAD's embedded main
application icon, using Python 3 without additional modules. This works with
PSCAD 5.1 even though its installer folder contains no `hvdc.ico`. Older icon
formats fall back to ImageMagick or icoutils, or keep an existing icon when
available. If extraction fails altogether, the installer reports it and uses
a generic application icon.

The icon is installed under
`${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/`, and the desktop
entry points directly to that PNG so a stale theme cache cannot hide it.
Entries go under the same data directory's `applications/` folder.

The window class matters separately: `pscad` creates `pscad.exe` windows,
while `pscad-desktop` creates an `explorer.exe` window containing PSCAD.
The menu entry uses the virtual-desktop launcher and
`StartupWMClass=explorer.exe` on Wayland; it uses the native launcher and
`StartupWMClass=pscad.exe` on X11. If you manually switch the entry's `Exec`
between these launchers, change `StartupWMClass` to match it too.

Refresh an existing installation with `--force --skip-installer` as shown in
Quick start, then close and reopen PSCAD from the application menu.

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

What the install creates, by default in `~/PSCAD_<version>`:

```
pscad                    launcher; always start PSCAD through it
pscad-desktop            same, inside a Wine virtual desktop; fixes black
                         menus and gives PSCAD a normal titlebar anywhere
fortranmedic             PSCAD's compiler diagnostics, same environment
fix/pscad_shim.c         the shim source, and the .so built from it
winetricks-dotnet48.log  what winetricks did, if .NET went wrong
pip-mhi-pscad.log        what pip did, if the automation packages went wrong
prefix/                  the Wine prefix, about 4 GB
```

Inside the prefix, `drive_c/windows/system32/py.bat` stands in for the broken
Python launcher, and PSCAD's Windows Python lives in
`drive_c/Program Files/Python313` (5.1) or `Python37` (5.0.2). That Python is
the one to run automation scripts with:

```bash
export WINEPREFIX=~/PSCAD_5.1.0/prefix WINEDEBUG=-all
export LD_PRELOAD=~/PSCAD_5.1.0/fix/pscad_shim.so
wine 'C:\Program Files\Python313\python.exe' -u your_script.py
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
  (with 32-bit support), winetricks, curl, gcc and Python 3 yourself first.
- The titlebar fix is written for KWin. Other window managers need the same
  idea applied their own way, or can use `pscad-desktop`.
- Maximise cannot be made to work. Drag to resize instead.
- Wine virtual desktops share the `explorer.exe` class. Bars that identify
  windows only by class cannot distinguish PSCAD versions or other Wine
  virtual desktops by their icons.
- `py.exe`, the real Python launcher, does not work in any prefix; `py.bat`
  covers the arguments PSCAD uses and nothing more.
- PSCAD's `install-packages.bat` cannot fully work under Wine, because Wine's
  `cmd` turns the `>=` in its version specifiers into a redirection. The
  install script installs those packages itself instead.
- PSCAD 5.1's installer always ends in an error, because Wine cannot create its
  desktop shortcut. There is no way to make it exit cleanly.
