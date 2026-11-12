#!/bin/bash
#
# Install PSCAD 5 into a dedicated Wine prefix on Linux.
#
# Works with both installers Manitoba HVDC ships.  PSCAD 5.0.x comes as an
# InstallShield wizard, setup.exe, with its prerequisites in
# ISSetupPrerequisites.  PSCAD 5.1.x comes as MHI's own Installer Utility,
# Installer.exe, with the product in a zip under Product and the runtimes
# under Support/Redists.  The script works out which one it was given.
#
# Run with --help for options.  The companion README.md explains what each
# step is for and what to do when something goes wrong.
#
set -euo pipefail

INSTALLER_DIR=""
PSCAD_ROOT=""         # default ~/PSCAD_<version>, worked out from the installer
GFORTRAN_DIR=""
LM_SERVER=""
EDITION=""
DPI=""
SILENT=0
SKIP_DEPS=0
SKIP_INSTALLER=0
FORCE=0
GECKO_FALLBACK="2.47.4"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Install PSCAD 5 into its own Wine prefix.

  --installer DIR   Unpacked PSCAD installer: the folder holding setup.exe
                    (5.0.x) or Installer.exe (5.1.x).
                    Default: the newest ~/Downloads/PSCAD_* folder that has
                    one of those in it.
  --root DIR        Where to put the prefix, launcher and shim.
                    Default: ~/PSCAD_<version>, e.g. ~/PSCAD_5.1.0, so each
                    version gets its own and they never collide.
  --silent=BOOL     true: install without the wizard's questions, accepting
                    its defaults.  false (the default): click through the
                    wizard.  A bare --silent means true.  5.0.x can only do
                    this with a response file, setup.iss, recorded
                    beforehand; without one the wizard runs as usual.
  --gfortran DIR    Unpacked MHI GFortran installer, the folder holding
                    Installer.exe and Product/GFortran*.zip.  PSCAD 5.1 ships
                    no Fortran compiler.  Default: the newest GFortran*
                    folder in ~/Downloads or inside a PSCAD 5.0.x installer
                    there (PSCAD_502_*/GFortran81), otherwise download MHI's
                    GFortran 13.2 for PSCAD 5.1, or 8.1 for PSCAD 5.0.
  --lm-server ADDR  Legacy License Manager address.  Only used to work out
                    which network interface faces the licence server; you
                    still enter the address in PSCAD itself.
  --edition CODE    The licence edition PSCAD asks the License Manager for
                    first, e.g. EDU for Educational.  Default: none, and a
                    new prefix asks for Professional until you pick one.
  --dpi N           Font/UI scale for PSCAD, in dots per inch.  96 is 100%,
                    144 is 150%, 192 is 200%.  Default: derived from your
                    desktop's display scaling. Whole numbers from 96 to 480.
  --skip-deps       Do not try to install distribution packages.
  --skip-installer  Do not run the PSCAD wizard; PSCAD is already in the
                    prefix.  Use with --force to finish an install that
                    stopped part way through.
  --force           Reuse an existing prefix directory instead of stopping.
  -h, --help        This text.

The PSCAD installer itself is a graphical wizard, so this script needs a
desktop session and will pause while you click through it.
Generated launchers accept PSCAD_DPI to override the saved DPI and
PSCAD_DESKTOP_SIZE=WIDTHxHEIGHT to override the virtual desktop's size.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --installer) INSTALLER_DIR="${2:?}"; shift 2 ;;
        --root)      PSCAD_ROOT="${2:?}";    shift 2 ;;
        --gfortran)  GFORTRAN_DIR="${2:?}";  shift 2 ;;
        --silent|--silent=true|--silent=yes|--silent=1)    SILENT=1; shift ;;
        --silent=false|--silent=no|--silent=0)             SILENT=0; shift ;;
        --silent=*)  die "--silent takes true or false, not '${1#--silent=}'" ;;
        --lm-server) LM_SERVER="${2:?}";     shift 2 ;;
        --edition)   EDITION="${2:?}";       shift 2 ;;
        --dpi)       DPI="${2:?}";           shift 2 ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        --skip-installer) SKIP_INSTALLER=1; shift ;;
        --force)     FORCE=1;     shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

if [ -n "$DPI" ]; then
    [[ "$DPI" =~ ^[0-9]{2,3}$ ]] && ((10#$DPI >= 96 && 10#$DPI <= 480)) \
        || die "--dpi must be a whole number from 96 to 480."
    DPI=$((10#$DPI))
fi

PSCAD_EXE=""          # found after the wizard runs; the path carries the version
PSCAD_VERSION=""

export WINEARCH=win64
export WINEDEBUG=-all

# --------------------------------------------------------------------------
say "Checking the environment"

[ "$(uname -m)" = "x86_64" ] || die "PSCAD needs an x86_64 machine; this is $(uname -m)."
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ "$SKIP_INSTALLER" -eq 1 ] \
    || die "No graphical session found. The PSCAD installer is a GUI wizard."

# Which of the two installers is this?  5.0.x ships InstallShield's setup.exe,
# 5.1.x ships MHI's own Installer.exe.  They take different arguments and keep
# their Visual C++ runtimes in different places, and nothing else in the script
# depends on the version.
installer_kind() {
    if   [ -f "${1}/Installer.exe" ]; then echo mhi
    elif [ -f "${1}/setup.exe" ];     then echo installshield
    fi
}

# With both versions unpacked in ~/Downloads, take the newest version by name
# (PSCAD_510_* sorts after PSCAD_502_*) rather than by modification time,
# which only says which one was unzipped last.  The others are listed so the
# user can see what --installer would pick instead.
if [ -z "$INSTALLER_DIR" ]; then
    candidates=()
    while IFS= read -r d; do
        [ -n "$(installer_kind "$d")" ] && candidates+=("$d")
    done < <(find "${HOME}/Downloads" -maxdepth 1 -type d -name 'PSCAD_*' 2>/dev/null | sort -V || true)
    [ ${#candidates[@]} -gt 0 ] || die "No unpacked PSCAD installer found in ~/Downloads. Use --installer DIR."
    INSTALLER_DIR="${candidates[-1]}"
    info "Installer: ${INSTALLER_DIR}"
    for d in "${candidates[@]}"; do
        [ "$d" = "$INSTALLER_DIR" ] || info "  (also found ${d}; pass --installer to use it)"
    done
fi

INSTALLER_KIND=$(installer_kind "$INSTALLER_DIR")
case "$INSTALLER_KIND" in
    mhi)           INSTALLER_EXE="Installer.exe"
                   # The utility relaunches itself elevated whatever it is
                   # given (AlwaysElevate.txt asks for that too); the first
                   # instance exits with 205 and the second does the work.
                   #
                   # There is no /IgnoreDrivers here.  This installer takes no
                   # switch for it, so the Sentinel USB dongle driver's setup
                   # runs whatever we do.  Wine cannot load a Windows kernel
                   # driver, so it achieves nothing except occasionally leaving
                   # a winedevice.exe behind -- which is what wait_for_wine's
                   # timeout is for.
                   INSTALLER_ARGS=(/RunAsElevated=True)
                   # Silent mode answers yes to its questions, Python included.
                   [ "$SILENT" -eq 1 ] && INSTALLER_ARGS+=(/Silent=true) ;;
    installshield) INSTALLER_EXE="setup.exe"
                   # /v passes the rest to MSI.  The USB dongle driver is
                   # skipped on purpose: Wine cannot load Windows kernel
                   # drivers, so dongle licensing cannot work here anyway.
                   INSTALLER_ARGS=('/v/IgnoreDrivers')
                   # An InstallScript installer cannot answer its own
                   # questions: /s replays the answers recorded in setup.iss
                   # by an earlier "setup.exe /r" (MHI's RecordSilentInstall.bat)
                   # and fails without one.
                   if [ "$SILENT" -eq 1 ]; then
                       if [ -f "${INSTALLER_DIR}/setup.iss" ]; then
                           # Wine maps / to Z:, and winepath would need the
                           # prefix, which does not exist yet.
                           iss="$(cd "$INSTALLER_DIR" && pwd)/setup.iss"
                           INSTALLER_ARGS+=(/s "/f1Z:${iss//\//\\}")
                       else
                           warn "--silent needs a recorded setup.iss next to setup.exe for PSCAD 5.0.x;"
                           warn "none found, so the wizard will run as usual."
                           SILENT=0
                       fi
                   fi ;;
    *) die "No setup.exe or Installer.exe in ${INSTALLER_DIR}. Point --installer at the unpacked installer." ;;
esac

# The version, before anything is installed, so that the default root can
# carry it.  5.1's product zip holds a manifest with DisplayVersion="5.1.0";
# 5.0.x has BUILD_PRODUCT=PSCAD 5.0.2 in BuildNumber.txt.  Failing both, the
# folder name MHI ships it under, PSCAD_510_... or PSCAD_502_..., says it too.
installer_version() {
    local v="" zip
    zip=$(find "${INSTALLER_DIR}/Product" -maxdepth 1 -iname 'PSCAD*.zip' 2>/dev/null | head -1 || true)
    if [ -n "$zip" ]; then
        if command -v unzip >/dev/null; then
            v=$(unzip -p "$zip" manifest.xml 2>/dev/null | grep -oE 'DisplayVersion="[0-9.]+"' | head -1 | grep -oE '[0-9.]+' || true)
        elif command -v python3 >/dev/null; then
            v=$(python3 -c 'import re,sys,zipfile; m=re.search(rb"DisplayVersion=\"([0-9.]+)\"", zipfile.ZipFile(sys.argv[1]).read("manifest.xml")); print(m.group(1).decode() if m else "")' "$zip" 2>/dev/null || true)
        fi
    fi
    if [ -z "$v" ] && [ -f "${INSTALLER_DIR}/BuildNumber.txt" ]; then
        v=$(sed -n 's/^BUILD_PRODUCT=.* \([0-9][0-9.]*\).*$/\1/p' "${INSTALLER_DIR}/BuildNumber.txt" | head -1 || true)
    fi
    if [ -z "$v" ]; then
        v=$(basename "$INSTALLER_DIR" | sed -n 's/^PSCAD_\([0-9]\)\([0-9]\)\([0-9]\)_.*/\1.\2.\3/p' || true)
    fi
    echo "$v"
}
INSTALLER_VERSION=$(installer_version)
info "PSCAD version: ${INSTALLER_VERSION:-unknown} ($([ "$SILENT" -eq 1 ] && echo silent || echo wizard))"

if [ -z "$PSCAD_ROOT" ]; then
    [ -n "$INSTALLER_VERSION" ] \
        || die "Cannot tell which PSCAD version ${INSTALLER_DIR} holds; pass --root DIR."
    PSCAD_ROOT="${HOME}/PSCAD_${INSTALLER_VERSION}"
fi
info "Root: ${PSCAD_ROOT}"

PREFIX="${PSCAD_ROOT}/prefix"
FIXDIR="${PSCAD_ROOT}/fix"
export WINEPREFIX="$PREFIX"

if [ -e "$PREFIX" ] && [ "$FORCE" -eq 0 ]; then
    die "${PREFIX} already exists. Delete it, pick another --root, or pass --force."
fi

# The InstallShield bootstrapper is a 32-bit binary, so a 64-bit-only Wine
# cannot run it even though PSCAD itself is 64-bit.
if [ "$SKIP_DEPS" -eq 0 ] && command -v apt-get >/dev/null; then
    missing=()
    command -v wine      >/dev/null || missing+=(wine wine64)
    command -v winetricks>/dev/null || missing+=(winetricks)
    command -v curl      >/dev/null || missing+=(curl)
    command -v gcc       >/dev/null || missing+=(gcc)
    command -v python3   >/dev/null || missing+=(python3)
    dpkg -l wine32 2>/dev/null | grep -q '^ii' || missing+=(wine32)
    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing: ${missing[*]}"
        sudo dpkg --add-architecture i386
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi
else
    [ "$SKIP_DEPS" -eq 1 ] || warn "Not a Debian/Ubuntu system; install wine (with 32-bit support), winetricks, curl, gcc and python3 yourself."
fi

for tool in wine winetricks curl gcc python3; do
    command -v "$tool" >/dev/null || die "$tool is not installed."
done
info "Wine: $(wine --version)"

# The .NET 4.8 installer is a 32-bit binary.  Wine's "new WoW64" builds have no
# 32-bit Unix side at all -- Arch and its derivatives ship one by default -- and
# winetricks calls .NET on such a build experimental.  Not fatal, but it is the
# first thing to suspect if the dotnet48 step below fails.
if ! find /usr/lib /usr/lib32 /usr/lib64 -maxdepth 3 -type d -name i386-unix 2>/dev/null | grep -q .; then
    warn "This Wine is built in new WoW64 mode (no 32-bit Unix support)."
    warn "If .NET 4.8 fails to install, use a Wine with real 32-bit support:"
    warn "  Debian/Ubuntu: wine32    Arch/CachyOS: wine-cachyos, or Proton via Lutris"
fi

# Not on PATH on Debian and Ubuntu.  Prefer a 64-bit build, since that is what
# the prefix is; a distribution that ships both puts them in sibling
# directories.  Spelled out as a loop rather than a chain of "find ... | head"
# alternatives: under "set -o pipefail" a find that walks a directory which
# does not exist fails the whole pipeline even when it did print a match, so
# the chain runs its fallback too and the variable ends up holding two paths.
wineserver_bin=""
for cand in "$(command -v wineserver 2>/dev/null || true)" \
            /usr/lib/x86_64-linux-gnu/wine/wineserver \
            /usr/lib64/wine/wineserver \
            /usr/lib/wine/wineserver; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then wineserver_bin="$cand"; break; fi
done
if [ -z "$wineserver_bin" ]; then
    wineserver_bin=$(find /usr/lib /usr/lib64 -name wineserver -type f 2>/dev/null | head -1 || true)
fi
[ -n "$wineserver_bin" ] && [ -x "$wineserver_bin" ] || die "Cannot find the wineserver binary."
info "wineserver: ${wineserver_bin}"

# Bounded, because "wineserver -w" waits for the prefix to shut down completely
# and a wedged winedevice.exe never lets that happen.  PSCAD 5.1's installer
# runs the Sentinel USB dongle driver's setup, which is exactly the kind of
# thing that leaves one behind, and an unbounded wait here hangs the install
# with no output at all.  Killing the server is safe: every step that calls
# this has already finished its work.
wait_for_wine() {
    timeout 120 "$wineserver_bin" -w && return 0
    warn "Wine did not shut down within 120s; stopping it."
    "$wineserver_bin" -k 2>/dev/null || true
    sleep 2
    return 0
}

# Is anything other than Wine's own services running in this prefix?  "wine
# Installer.exe" comes back within seconds: the 5.1 Installer Utility relaunches
# itself elevated and the first instance exits (205) while the second does all
# the work, so neither the exit of "wine" nor a bounded wait_for_wine says when
# the wizard is done -- and wait_for_wine's timeout would kill it half way
# through.  Wine processes carry the prefix in their environment and a Windows
# path as argv[0]; the services listed here are the ones that never exit on
# their own.  Written without pipelines, because under "set -o pipefail" a
# reader cut short by "head" would stop the script.
wine_busy() {
    local pid argv0 name
    for pid in $(ps -u "$(id -u)" -o pid= 2>/dev/null); do
        grep -qzxF "WINEPREFIX=${PREFIX}" "/proc/${pid}/environ" 2>/dev/null || continue
        argv0=""
        IFS= read -r -d '' argv0 < "/proc/${pid}/cmdline" 2>/dev/null || true
        case "$argv0" in [A-Za-z]:\\*) ;; *) continue ;; esac
        name="${argv0##*\\}"
        case "${name,,}" in
            services.exe|winedevice.exe|plugplay.exe|svchost.exe|rpcss.exe|\
            explorer.exe|lsass.exe|mscorsvw.exe|conhost.exe|tabtip.exe) continue ;;
        esac
        return 0
    done
    return 1
}

# --------------------------------------------------------------------------
say "Creating the Wine prefix at ${PREFIX}"
mkdir -p "$PSCAD_ROOT" "$FIXDIR"
# Only on a prefix that does not exist yet.  Running "wineboot -u" again over a
# prefix that already has .NET in it re-runs wine.inf, which wakes the .NET
# native image service and can then sit in Wow64Install forever.
if [ -f "${PREFIX}/system.reg" ]; then
    info "Already exists, leaving it alone."
else
    wineboot -u >/dev/null 2>&1 || true
    wait_for_wine
    info "64-bit prefix created."
fi

# --------------------------------------------------------------------------
say "Installing .NET Framework 4.8 (several minutes, no output while it runs)"
# The registry cannot answer this.  Wine installs its own Mono into every new
# prefix, and Mono registers the same NDP\v4\Full key the real framework does,
# so querying it reports success on a prefix that has no .NET at all.  PSCAD's
# assemblies are obfuscated and Mono refuses them -- "field dx3 in <Module>
# should have RVA data, but hasn't", then "Invalid IL code" -- so ask instead
# for winetricks' own marker file, and for Mono being gone.
if [ -f "${PREFIX}/drive_c/windows/dotnet48.installed.workaround" ] \
   && [ ! -d "${PREFIX}/drive_c/windows/mono" ]; then
    info "Already present, skipping."
else
    winetricks -q --unattended dotnet48 >"${PSCAD_ROOT}/winetricks-dotnet48.log" 2>&1 \
        || die "dotnet48 failed; see ${PSCAD_ROOT}/winetricks-dotnet48.log"
    wait_for_wine
    if [ -d "${PREFIX}/drive_c/windows/mono" ]; then
        warn "Wine Mono survived the .NET install; PSCAD will fail with \"Invalid IL code\"."
        warn "See ${PSCAD_ROOT}/winetricks-dotnet48.log"
    fi
fi

# dotnet48 leaves the prefix reporting an old Windows; PSCAD's installer
# checks the version, so put it back to Windows 10.
say "Setting the prefix to Windows 10"
winetricks -q win10 >/dev/null 2>&1 || true
wait_for_wine

# --------------------------------------------------------------------------
say "Installing the Visual C++ runtimes"
# Taken from the installer's own folder, so nothing is downloaded and the
# versions match what PSCAD was built against.
#
# Only for 5.0.x, whose InstallShield wizard checks for the 2022 runtimes in
# ISSetupPrerequisites before it will run.  The 5.1 Installer Utility installs
# its own, 2005, 2010 and 2022 from Support/Redists, and does it better than
# this script can: it knows each package's switches, and the 2005 package
# answers the "/q /norestart" the others take with a "Command line option
# syntax error" box that stops everything until someone clicks OK.
if [ "$INSTALLER_KIND" = "mhi" ]; then
    info "Left to the PSCAD installer, which installs them from Support/Redists."
else
    found_vc=0
    while IFS= read -r -d '' redist; do
        info "$(basename "$(dirname "$redist")")/$(basename "$redist")"
        timeout 180 wine "$redist" /q /norestart >/dev/null 2>&1 \
            || warn "$(basename "$redist") returned non-zero or timed out"
        wait_for_wine
        found_vc=1
    done < <(find "${INSTALLER_DIR}/ISSetupPrerequisites" -iname 'vc_redist*.exe' -print0 2>/dev/null)
    [ "$found_vc" -eq 1 ] || warn "No Visual C++ runtimes found in ISSetupPrerequisites; PSCAD may fail to start."
fi

# --------------------------------------------------------------------------
say "Installing Wine Gecko (PSCAD renders its forms as HTML)"
gecko_version() {
    local f v
    if command -v strings >/dev/null; then
        for f in /usr/lib/*/wine/*-windows/mshtml.dll /usr/lib/wine/*/mshtml.dll; do
            [ -f "$f" ] || continue
            v=$(strings "$f" 2>/dev/null | grep -oE 'Wine Gecko [0-9.]+' | head -1 | awk '{print $3}' || true)
            [ -n "$v" ] && { echo "$v"; return; }
        done
    fi
    v=$(grep -rhoE 'wine-gecko-[0-9.]+' /usr/lib/*/wine/ 2>/dev/null | head -1 | sed 's/wine-gecko-//' || true)
    echo "${v:-$GECKO_FALLBACK}"
}
GV=$(gecko_version)
info "Version ${GV}"
mkdir -p "${HOME}/.cache/wine"
for arch in x86_64 x86; do
    msi="${HOME}/.cache/wine/wine-gecko-${GV}-${arch}.msi"
    [ -s "$msi" ] || curl -fL --retry 3 -o "$msi" \
        "https://dl.winehq.org/wine/wine-gecko/${GV}/wine-gecko-${GV}-${arch}.msi" \
        || { warn "Could not download Gecko ${arch}; HTML forms will not render."; continue; }
    wine msiexec /i "$msi" /qn >/dev/null 2>&1 || warn "Gecko ${arch} install returned non-zero"
    wait_for_wine
done

# --------------------------------------------------------------------------
say "Standing in for the Python launcher"
# PSCAD installs Python and then runs "py -3 -m pip install ..." to add its
# automation packages.  Wine's RegGetValueW rejects the flag combination
# RRF_RT_REG_SZ|RRF_RT_REG_EXPAND_SZ with ERROR_INVALID_PARAMETER, and that is
# exactly how py.exe reads PythonCore\<version>\InstallPath, so the launcher
# finds no interpreter at all.  PSCAD 5.1 then stops with
#
#   Error: 112  Failed to install Python WHL file(s) as Python is not installed
#
# even though Python installed perfectly well.  cmd looks in system32 before
# C:\windows, so a py.bat there is found ahead of the real py.exe.  Written
# before the wizard runs, which gets rid of error 112 -- but only half of the
# wizard's package step runs: its install-packages.bat calls "py" without
# CALL, and cmd never returns to a batch file that hands over to another one
# that way.  pywin32 goes in and mhi-pscad does not, which is why the script
# installs the packages again itself after the wizard.
cat > "${PREFIX}/drive_c/windows/system32/py.bat" <<'PYBAT'
@echo off
REM Stand-in for the Python launcher, py.exe, inside this Wine prefix.
REM
REM py.exe reads PythonCore\<version>\InstallPath through RegGetValueW, asking
REM for RRF_RT_REG_SZ|RRF_RT_REG_EXPAND_SZ.  Wine rejects that combination of
REM flags with ERROR_INVALID_PARAMETER, so the real launcher sees no
REM interpreter at all and every "py -3 ..." call dies with
REM "No installed Pythons found!".  PSCAD's installer uses exactly that to add
REM its Python packages, and reports "Error 112 ... Python is not installed".
REM
REM cmd looks in system32 before C:\windows, so this file is found ahead of
REM C:\windows\py.exe.  It covers the part of py.exe that PSCAD uses: -0, and
REM a leading -X[.Y][-nn] version selector.
setlocal

set "PY_EXE="
set "PY_BEST=0"
set "LIST="
set "ARGS="

if "%~1"=="-0"           set "LIST=1"
if "%~1"=="-0p"          set "LIST=1"
if "%~1"=="--list"       set "LIST=1"
if "%~1"=="--list-paths" set "LIST=1"
if defined LIST (
    call :scan 3
    if not defined PY_EXE echo No installed Pythons found!
    exit /b 0
)

set "WANT="
if not "%~1"=="" call :selector "%~1"
if defined WANT shift

call :scan %WANT%
if not defined PY_EXE (
    echo No installed Pythons found!
    exit /b 103
)

:parse
if "%~1"=="" goto :run
set ARGS=%ARGS% "%~1"
shift
goto :parse

:run
"%PY_EXE%" %ARGS%
exit /b %ERRORLEVEL%


REM ---- "-3", "-3.13", "-3.13-64" -> WANT=3 / 313 ---------------------------
:selector
set "S=%~1"
if not "%S:~0,2%"=="-3" if not "%S:~0,2%"=="-2" goto :eof
set "S=%S:-64=%"
set "S=%S:-32=%"
set "S=%S:.=%"
set "WANT=%S:~1%"
goto :eof

REM ---- find the newest C:\Program Files*\Python<WANT>* ----------------------
:scan
if "%~1"=="" (set "V=3") else (set "V=%~1")
for %%D in ("C:\Program Files" "C:\Program Files (x86)") do (
    for /f "delims=" %%P in ('dir /b /ad "%%~D\Python%V%*" 2^>nul') do call :consider "%%~D" "%%P"
)
goto :eof

:consider
if not exist "%~1\%~2\python.exe" goto :eof
set "N=%~2"
set "N=%N:Python=%"
if defined LIST echo  -V:%N:~0,1%.%N:~1%        %~1\%~2\python.exe
if %N% GTR %PY_BEST% set "PY_BEST=%N%"
if %N% GEQ %PY_BEST% set "PY_EXE=%~1\%~2\python.exe"
goto :eof
PYBAT
sed -e 's|"%PY_EXE%" %ARGS%|"%PY_EXE:python.exe=pythonw.exe%" %ARGS%|' \
    "${PREFIX}/drive_c/windows/system32/py.bat" \
    > "${PREFIX}/drive_c/windows/system32/pyw.bat"
# cmd is fussy about line endings in batch files.
sed -i 's/\r*$/\r/' "${PREFIX}/drive_c/windows/system32/py.bat" \
                     "${PREFIX}/drive_c/windows/system32/pyw.bat"
info "C:\windows\system32\py.bat"

# --------------------------------------------------------------------------
say "Running the PSCAD installer"
if [ "$SKIP_INSTALLER" -eq 0 ] && [ "$SILENT" -eq 1 ]; then
    info "Running ${INSTALLER_EXE} silently; this takes a few minutes and prints nothing."
elif [ "$SKIP_INSTALLER" -eq 0 ]; then
    cat <<NOTE
    The ${INSTALLER_EXE} wizard opens now.  Accept the defaults unless you
    have a reason not to, and say yes when it offers to install Python (if
    you do not, this script installs it afterwards).  This script continues
    when the wizard exits.
NOTE
    if [ "$INSTALLER_KIND" = "mhi" ]; then
        cat <<'NOTE'

    Expect it to finish with "Unable to fully and correctly install the
    latest product files" and exit code 32506.  That is only the Windows
    desktop shortcut, which Wine cannot create and which is of no use on
    Linux anyway; this script checks afterwards and says so.
NOTE
    fi
fi
if [ "$SKIP_INSTALLER" -eq 1 ]; then
    info "Skipped, --skip-installer."
else
    ( cd "$INSTALLER_DIR" && wine "$INSTALLER_EXE" "${INSTALLER_ARGS[@]}" ) || true
    # Follow the wizard, not the "wine" that started it; see wine_busy.  No
    # timeout worth the name: the wizard waits on the user, and 5.1 then
    # unpacks 700 MB and installs Python.
    sleep 3
    waited=0
    while wine_busy; do
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge 7200 ]; then
            warn "The installer is still running after two hours; carrying on without it."
            break
        fi
    done
    wait_for_wine
fi

# 5.0.x installs to PSCAD50\bin\win64, 5.1.x to PSCAD\5.1.0\bin\win64, and
# several versions can sit side by side.  Take the most recently installed
# Pscad.exe rather than assuming either layout.  By change time, not
# modification time: both installers stamp their files with the build date,
# so mtime says which version is newer, not which one was just installed.
PSCAD_EXE=$(cd "$PREFIX" && find "drive_c/Program Files (x86)" "drive_c/Program Files" \
                -ipath '*/bin/win64/Pscad.exe' -printf '%C@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2- || true)
[ -n "$PSCAD_EXE" ] && [ -f "${PREFIX}/${PSCAD_EXE}" ] \
    || die "PSCAD is not where it should be. Did the wizard finish?"

PSCAD_HOME="${PSCAD_EXE%/bin/win64/Pscad.exe}"
if [ -f "${PREFIX}/${PSCAD_HOME}/BuildNumber.txt" ]; then
    PSCAD_VERSION=$(sed -n 's/^BUILD_PRODUCT=.* \([0-9][0-9.]*\).*$/\1/p' "${PREFIX}/${PSCAD_HOME}/BuildNumber.txt" | head -1 || true)
fi
[ -n "$PSCAD_VERSION" ] || PSCAD_VERSION=$(basename "$PSCAD_HOME" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)
info "PSCAD ${PSCAD_VERSION:-(unknown version)} installed in ${PSCAD_HOME#drive_c}"

# The 5.1 Installer Utility always ends in an error on Wine, and its summary
# ("The product may or may not operate correctly") gives no way to tell a
# harmless failure from a real one.  Its log does.  Wine's wshom.ocx rejects
# an icon location that carries no ",index" suffix, which is how PSCAD asks
# for its shortcut icon, so creating the desktop .lnk fails -- and nothing
# else does.  Read the log rather than leave the user with the scary message.
#
# Only for 5.1: 5.0.x's InstallShield wizard runs the same utility for its
# GFortran packages, and those logs have nothing to say about PSCAD.  The logs
# are CRLF text; the "|| true"s keep a pattern that is not there from
# stopping the script under "set -e".
#
# The GFortran installers below use the same utility and log to the same
# folder, so on a re-run the newest log may be theirs: take the newest one
# about PSCAD.
mhi_log=""
if [ "$INSTALLER_KIND" = "mhi" ]; then
    while IFS= read -r f; do
        if grep -q 'manifest for <PSCAD' "$f" 2>/dev/null; then mhi_log="$f"; break; fi
    done < <(ls -t "${PREFIX}/drive_c/users/${USER}/AppData/Local/Manitoba Hydro International/Installer/Messages/"*.txt 2>/dev/null || true)
fi
if [ -n "$mhi_log" ]; then
    exit_code=$(tr -d '\r' < "$mhi_log" | sed -n 's/^ *ExitCode = \([0-9]*\)$/\1/p' | tail -1 || true)
    reported=$(tr -d '\r' < "$mhi_log" | sed -n 's/^ *\([0-9][0-9]*\) error(s)$/\1/p' | tail -1 || true)
    shortcut=$(grep -c 'set_IconLocation' "$mhi_log" || true)
    if [ "${exit_code:-}" = "0" ]; then
        info "The wizard reported success."
    elif [ "${shortcut:-0}" -gt 0 ] && [ "${reported:-0}" -le 1 ]; then
        info "The wizard's one error (exit code ${exit_code:-unknown}) was the Windows desktop shortcut; nothing else failed."
    else
        warn "The wizard exited with code ${exit_code:-unknown} and ${reported:-an unknown number of} error(s)."
        warn "Read ${mhi_log}"
    fi
fi

# --------------------------------------------------------------------------
say "Installing PSCAD's Python automation packages"
# mhi.pscad is what drives PSCAD from a script.  PSCAD 5.1's own installer
# step for it stops after pywin32 (see py.bat above), so on 5.1 this is what
# actually puts the automation library in place.  On 5.0.x it only upgrades
# what the wizard installed into Python 3.7.
#
# The wheels PSCAD ships are kept in the prefix and used first, but mhi-common
# depends on "packaging", which PSCAD does not ship, so the rest comes from
# PyPI.  Without a network connection the mhi packages cannot be installed at
# all; pywin32 alone would still work from the bundled wheel.
find_win_python() {
    (cd "$PREFIX" && find "drive_c/Program Files" "drive_c/Program Files (x86)" \
         -maxdepth 2 -ipath '*/Python3*/python.exe' 2>/dev/null | sort -V | tail -1 || true)
}
WIN_PYTHON=$(find_win_python)
MHI_PACKAGES="drive_c/users/Public/Documents/Manitoba Hydro International/Python/Packages"
MHI_PACKAGES_WIN='C:\users\Public\Documents\Manitoba Hydro International\Python\Packages'

# The wizard asks before it installs Python, and a "no" -- or a click past the
# question -- leaves PSCAD without one: its package step then fails with
# "Installers - Error: 103" (5.1).  The Python installer it would have run is
# still copied into the prefix, so run it here, with the wizard's own
# arguments.
if [ -z "$WIN_PYTHON" ]; then
    py_setup=$(find "${PREFIX}/drive_c/users/Public/Documents/Manitoba Hydro International/Python/Installers" \
                   -maxdepth 1 -iname 'python-3*.exe' 2>/dev/null | sort -V | tail -1 || true)
    if [ -n "$py_setup" ]; then
        info "The wizard did not install Python; installing $(basename "$py_setup")"
        timeout 600 wine "$py_setup" /quiet InstallAllUsers=1 Include_launcher=1 InstallLauncherAllUsers=1 \
            >/dev/null 2>&1 || warn "$(basename "$py_setup") returned non-zero or timed out"
        wait_for_wine
        WIN_PYTHON=$(find_win_python)
    fi
fi

if [ -z "$WIN_PYTHON" ]; then
    warn "No Windows Python in the prefix, and no Python installer from PSCAD to run."
    warn "Re-run ${INSTALLER_EXE} and say yes when it offers to install Python."
elif [ ! -d "${PREFIX}/${MHI_PACKAGES}" ]; then
    warn "PSCAD shipped no Python packages; skipping."
else
    info "$(basename "$(dirname "$WIN_PYTHON")")"
    pip_log="${PSCAD_ROOT}/pip-mhi-pscad.log"
    if wine "${PREFIX}/${WIN_PYTHON}" -m pip install \
            --no-warn-script-location --disable-pip-version-check --upgrade \
            --find-links "$MHI_PACKAGES_WIN" \
            pywin32 mhi-common mhi-pscad >"$pip_log" 2>&1; then
        # pywin32's DLLs have to be copied next to the interpreter and its COM
        # objects registered; the wheel alone does not do that.
        postinstall="$(dirname "$WIN_PYTHON")/Scripts/pywin32_postinstall.py"
        [ -f "${PREFIX}/${postinstall}" ] \
            && wine "${PREFIX}/${WIN_PYTHON}" "${PREFIX}/${postinstall}" -install -silent \
                 >>"$pip_log" 2>&1 || true
        wait_for_wine
        if mhi_version=$(wine "${PREFIX}/${WIN_PYTHON}" -c 'import mhi.pscad; print(mhi.pscad.VERSION)' 2>/dev/null | tr -d '\r'); then
            info "mhi.pscad ${mhi_version}"
        else
            warn "mhi.pscad installed but will not import; see ${pip_log}"
        fi
    else
        warn "Could not install the Python packages; see ${pip_log}"
        warn "Usually no network. Re-run afterwards with:"
        warn "  WINEPREFIX=${PREFIX} wine '${PREFIX}/${WIN_PYTHON}' -m pip install pywin32 mhi-common mhi-pscad"
    fi
fi

# --------------------------------------------------------------------------
say "Checking for a Fortran compiler"
# EMTDC compiles every model with a Fortran compiler, and PSCAD finds one
# through HKLM\SOFTWARE\MHRC\GFortran\<version> and GFORTRAN<nn> variables that
# MHI's GFortran installers set.  5.0.x's wizard runs those installers itself
# (GFortran46, GFortran81).  5.1 ships only the EMTDC libraries for GFortran 8.1
# and 13.2, not the compiler, so a 5.1 prefix ends up with none and every run
# stops at "Fortran compiler not detected".  The GFortran installers are the
# same MHI Installer Utility and install silently. Prefer --gfortran, then a
# GFortran* folder in ~/Downloads, such as the GFortran81 in a PSCAD 5.0.x
# download. If neither exists, fetch the separate installer from MHI.
find_gfortran() {
    (cd "$PREFIX" && find "drive_c/Program Files" "drive_c/Program Files (x86)" -maxdepth 5 \
         -ipath '*/GFortran/*/gfortran.exe' 2>/dev/null | sort -V \
         | if [[ "$PSCAD_VERSION" = 5.1.* ]]; then
               grep -E '/GFortran/(8\.1|13\.2)/x64/'
           else cat; fi || true)
}
gfortran_installer() {
    local d best="" bestv=0 v
    if [ -n "$GFORTRAN_DIR" ]; then echo "$GFORTRAN_DIR"; return; fi
    while IFS= read -r d; do
        [ -f "${d}/Installer.exe" ] || continue
        compgen -G "${d}/Product/*.zip" >/dev/null || continue
        v=$(basename "$d" | grep -oE '[0-9]+' | head -1 || true)
        [ -n "$v" ] && [ "$v" -ge 80 ] || continue
        [[ "$PSCAD_VERSION" != 5.0.* ]] || [ "$v" -eq 81 ] || continue
        if [ "$v" -gt "$bestv" ]; then best="$d"; bestv="$v"; fi
    done < <(find "${HOME}/Downloads" -maxdepth 2 -type d -iname 'GFortran*' 2>/dev/null || true)
    echo "$best"
}

download_gfortran() {
    # Public downloads linked by https://www.pscad.com/knowledge-base/article/357.
    # Cache under this installation so re-runs do not download hundreds of MB.
    local package url cache archive
    if [[ "$PSCAD_VERSION" = 5.0.* ]]; then
        package=GFortran81
        url="https://ptcstoragegroup.blob.core.windows.net/publisher/GFortran_81_W60XD4N8BR8062A48BXE/GFortran81_Installer.zip"
    else
        package=GFortran132
        url="https://ptcstoragegroup.blob.core.windows.net/publisher/GFortran_132_C7W2APMR99V1U1BR9NH0/GFortran132_Installer.zip"
    fi
    cache="${PSCAD_ROOT}/installers/${package}"
    archive="${PSCAD_ROOT}/installers/${package}_Installer.zip"
    mkdir -p "$cache"
    if [ ! -f "${cache}/Installer.exe" ] || [ ! -f "${cache}/Product/${package}.zip" ]; then
        if [ ! -s "$archive" ]; then
            info "Downloading ${package} from PSCAD's official download server."
            curl --fail --location --retry 3 --connect-timeout 30 -o "${archive}.part" "$url" \
                || die "Could not download ${package}. Check the network and re-run, or use --gfortran DIR."
            mv "${archive}.part" "$archive"
        fi
        python3 - "$archive" "$cache" <<'EXTRACT_GF' \
            || die "Could not unpack ${archive}. Remove it and re-run, or use --gfortran DIR."
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
EXTRACT_GF
    fi
    GFORTRAN_DOWNLOADED_DIR="$cache"
}

compilers=$(find_gfortran)
if [ -z "$compilers" ] || [ -n "$GFORTRAN_DIR" ]; then
    gf_dir=$(gfortran_installer)
    if [ -z "$gf_dir" ]; then
        download_gfortran
        gf_dir="$GFORTRAN_DOWNLOADED_DIR"
    fi
    [ -f "${gf_dir}/Installer.exe" ] \
        || die "No Installer.exe in ${gf_dir}; pass --gfortran the unpacked MHI compiler installer folder."
    info "Installing $(basename "$gf_dir") from ${gf_dir}"
    gf_log="${PSCAD_ROOT}/install-gfortran.log"
    # The original instance exits with 205 when it relaunches elevated.
    # Wait for the child and check the installed compiler, not that exit code.
    ( cd "$gf_dir" && wine Installer.exe /Silent=true ) >"$gf_log" 2>&1 || true
    sleep 3
    waited=0
    while wine_busy; do
        [ "$waited" -lt 1800 ] || die "GFortran installation timed out; see ${gf_log} and MHI's Installer/Messages logs."
        sleep 5
        waited=$((waited + 5))
    done
    wait_for_wine
    compilers=$(find_gfortran)
fi
[ -n "$compilers" ] \
    || die "No supported GFortran compiler was installed. See ${PSCAD_ROOT}/install-gfortran.log and MHI's Installer/Messages logs."
while IFS= read -r c; do info "${c#drive_c}"; done <<< "$compilers"
# File presence alone can hide a broken installation or missing runtime DLLs.
gf_compiler=$(printf '%s\n' "$compilers" | tail -1)
if ! timeout 60 wine "${PREFIX}/${gf_compiler}" --version >"${PSCAD_ROOT}/gfortran-version.log" 2>&1; then
    die "GFortran is installed but will not run; see ${PSCAD_ROOT}/gfortran-version.log."
fi
info "$(head -1 "${PSCAD_ROOT}/gfortran-version.log" | tr -d '\r')"

# --------------------------------------------------------------------------
say "Building the startup shim"
cat > "${FIXDIR}/pscad_shim.c" <<'SHIM'
/*
 * Three fixes PSCAD needs under Wine.  All of them concern one call: PSCAD asks
 * for its own host name at startup and again when it introduces itself to the
 * licence server.
 *
 * 1. Wine's ws2_32 does not implement AI_FQDN.  GetAddrInfoW() returns success
 *    but leaves ai_canonname NULL, and PSCAD's AsyncSocket::getHostName()
 *    dereferences it without a null check, so Pscad.exe takes a null page
 *    fault before it ever shows a window.  Requesting AI_CANONNAME from libc
 *    fills the field in, and Wine copies it through to the Windows structure.
 *
 * 2. On a machine running an overlay VPN such as Tailscale, the canonical name
 *    libc returns belongs to the VPN's own DNS zone, because the VPN puts its
 *    domain first in the resolver search list.  PSCAD resolves that name to
 *    decide which address to show the licence server, gets the overlay
 *    address, and the server refuses the request as off-net.  Truncating to
 *    the short host name sends PSCAD to the LAN name instead; the launcher
 *    sets LOCALDOMAIN so that name is completed with the right domain.
 *
 * 3. Most Linux distributions put a line like "127.0.1.1  thishost" in
 *    /etc/hosts, and nsswitch reads that file before it asks DNS.  So the
 *    short name from fix 2 resolves straight back to loopback, PSCAD announces
 *    itself to the License Manager as 127.0.1.1, and the server refuses it
 *    with "Client is not on same net as LM".  Replacing a loopback answer for
 *    our own name with the address of the interface that actually faces the
 *    network is what gets the right address into the request.  This is only
 *    needed for a legacy License Manager; certificate licensing does not care.
 *
 *    Both resolver entry points need it.  PSCAD asks Winsock through the old
 *    gethostbyname(), and Wine answers that one from the C library's
 *    gethostbyname_r(), not from getaddrinfo() -- so hooking getaddrinfo alone
 *    fixes the name but leaves the address untouched.
 *
 * The name is edited in place and only ever shortened, so freeaddrinfo() still
 * owns the allocation, and addresses are rewritten inside the structures libc
 * already allocated.  PSCAD_KEEP_FQDN=1 disables the truncation,
 * PSCAD_KEEP_LOOPBACK=1 disables the address fix, PSCAD_LM_SERVER names the
 * host to route towards when the machine has more than one way out, and
 * PSCAD_SHIM_DEBUG=1 traces all of it.
 */
#define _GNU_SOURCE
#include <netdb.h>
#include <dlfcn.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

typedef int (*gai_fn)(const char *, const char *,
                      const struct addrinfo *, struct addrinfo **);

static int debug_on(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("PSCAD_SHIM_DEBUG"); v = e && *e && *e != '0'; }
    return v;
}

static int real_gethostname(char *buf, size_t len)
{
    static int (*real)(char *, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "gethostname");
    return real(buf, len);
}

/* 127.0.0.0/8.  Spelled out rather than using glibc's IN_LOOPBACK, which is
 * not exposed by every libc we might be built against. */
static int is_loopback(const struct in_addr *a)
{
    return (ntohl(a->s_addr) >> 24) == 127;
}

/* The address of the interface that faces the network, worked out the way the
 * routing table would: connecting a UDP socket sends no packet but does make
 * the kernel choose a source address.  Cached, because PSCAD asks repeatedly. */
static int outward_addr(struct in_addr *out)
{
    static struct in_addr addr;
    static int known = -1;

    if (known < 0)
    {
        const char *probe = getenv("PSCAD_LM_SERVER");
        struct sockaddr_in sa;
        socklen_t len = sizeof(sa);
        int fd = -1;

        known = 0;
        if (!probe || !*probe) probe = "1.1.1.1";

        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons(9);              /* discard; nothing is sent */

        if (inet_pton(AF_INET, probe, &sa.sin_addr) == 1 &&
            (fd = socket(AF_INET, SOCK_DGRAM, 0)) >= 0)
        {
            if (!connect(fd, (struct sockaddr *)&sa, sizeof(sa)) &&
                !getsockname(fd, (struct sockaddr *)&sa, &len) &&
                !is_loopback(&sa.sin_addr))
            {
                addr = sa.sin_addr;
                known = 1;
            }
            close(fd);
        }
    }

    if (known) *out = addr;
    return known;
}

/* Does this lookup name the machine we are running on? */
static int is_own_name(const char *node, char *host, size_t hostlen)
{
    size_t n;

    if (!node || real_gethostname(host, hostlen)) return 0;
    host[hostlen - 1] = 0;
    if (!strcasecmp(node, host)) return 1;

    /* "box" also matches a configured "box.example.com", and vice versa. */
    n = strcspn(host, ".");
    return strlen(node) >= n && !strncasecmp(node, host, n) &&
           (node[n] == 0 || node[n] == '.');
}

/* The same repair for the hostent the gethostbyname family returns.  The
 * addresses are rewritten in place, so the caller still owns every buffer. */
static void fix_hostent(const char *node, struct hostent *he)
{
    char host[256];
    struct in_addr lan;
    int i, have_lan = -1;

    if (!he || he->h_addrtype != AF_INET || !he->h_addr_list) return;
    if (getenv("PSCAD_KEEP_LOOPBACK")) return;
    if (!is_own_name(node, host, sizeof(host))) return;

    for (i = 0; he->h_addr_list[i]; i++)
    {
        struct in_addr *a = (struct in_addr *)(void *)he->h_addr_list[i];

        if (!is_loopback(a)) continue;
        if (have_lan < 0) have_lan = outward_addr(&lan);
        if (!have_lan) return;
        if (debug_on())
        {
            char was[INET_ADDRSTRLEN], now[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, a, was, sizeof(was));
            inet_ntop(AF_INET, &lan, now, sizeof(now));
            fprintf(stderr, "[pscad-shim] hostent %s -> %s\n", was, now);
        }
        *a = lan;
    }
}

struct hostent *gethostbyname(const char *name)
{
    static struct hostent *(*real)(const char *);
    struct hostent *he;

    if (!real) real = dlsym(RTLD_NEXT, "gethostbyname");
    he = real(name);
    fix_hostent(name, he);
    return he;
}

struct hostent *gethostbyname2(const char *name, int af)
{
    static struct hostent *(*real)(const char *, int);
    struct hostent *he;

    if (!real) real = dlsym(RTLD_NEXT, "gethostbyname2");
    he = real(name, af);
    fix_hostent(name, he);
    return he;
}

int gethostbyname_r(const char *name, struct hostent *ret, char *buf,
                    size_t buflen, struct hostent **result, int *h_errnop)
{
    static int (*real)(const char *, struct hostent *, char *, size_t,
                       struct hostent **, int *);
    int rc;

    if (!real) real = dlsym(RTLD_NEXT, "gethostbyname_r");
    rc = real(name, ret, buf, buflen, result, h_errnop);
    if (!rc && result) fix_hostent(name, *result);
    return rc;
}

int gethostbyname2_r(const char *name, int af, struct hostent *ret, char *buf,
                     size_t buflen, struct hostent **result, int *h_errnop)
{
    static int (*real)(const char *, int, struct hostent *, char *, size_t,
                       struct hostent **, int *);
    int rc;

    if (!real) real = dlsym(RTLD_NEXT, "gethostbyname2_r");
    rc = real(name, af, ret, buf, buflen, result, h_errnop);
    if (!rc && result) fix_hostent(name, *result);
    return rc;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res)
{
    static gai_fn real_gai;
    struct addrinfo h;
    char host[256];
    size_t hlen;
    int rc;

    if (!real_gai) real_gai = (gai_fn)dlsym(RTLD_NEXT, "getaddrinfo");

    /* AI_CANONNAME with a NULL node is EAI_BADFLAGS, so only touch lookups
     * that actually name a host. */
    if (node)
    {
        if (hints) h = *hints; else memset(&h, 0, sizeof(h));
        h.ai_flags |= AI_CANONNAME;
        hints = &h;
    }

    rc = real_gai(node, service, hints, res);
    if (rc) return rc;
    if (!is_own_name(node, host, sizeof(host))) return rc;

    hlen = strcspn(host, ".");

    if (!getenv("PSCAD_KEEP_FQDN"))
    {
        struct addrinfo *ai;
        for (ai = *res; ai; ai = ai->ai_next)
        {
            char *cn = ai->ai_canonname;
            if (!cn || strlen(cn) <= hlen) continue;
            if (strncasecmp(cn, host, hlen) || cn[hlen] != '.') continue;
            if (debug_on())
                fprintf(stderr, "[pscad-shim] canonname %s -> %.*s\n",
                        cn, (int)hlen, cn);
            cn[hlen] = 0;
        }
    }

    if (!getenv("PSCAD_KEEP_LOOPBACK"))
    {
        struct addrinfo *ai;
        struct in_addr lan;
        int have_lan = -1;

        for (ai = *res; ai; ai = ai->ai_next)
        {
            struct sockaddr_in *sin = (struct sockaddr_in *)(void *)ai->ai_addr;

            if (ai->ai_family != AF_INET || !sin) continue;
            if (!is_loopback(&sin->sin_addr)) continue;
            if (have_lan < 0) have_lan = outward_addr(&lan);
            if (!have_lan) break;
            if (debug_on())
            {
                char was[INET_ADDRSTRLEN], now[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &sin->sin_addr, was, sizeof(was));
                inet_ntop(AF_INET, &lan, now, sizeof(now));
                fprintf(stderr, "[pscad-shim] address %s -> %s\n", was, now);
            }
            sin->sin_addr = lan;
        }
    }
    return rc;
}
SHIM
gcc -shared -fPIC -O2 -Wall -o "${FIXDIR}/pscad_shim.so" "${FIXDIR}/pscad_shim.c" -ldl
info "Built ${FIXDIR}/pscad_shim.so"

# --------------------------------------------------------------------------
say "Working out which DNS domain names this machine on the LAN"
# PSCAD completes its short host name with the first domain in the resolver
# search list.  If an overlay VPN owns that domain, PSCAD reports the overlay
# address and a legacy License Manager refuses it.  Pick the first search
# domain whose FQDN resolves to the address that actually faces the network.
detect_domains() {
    local host lan probe d rest resolved search
    host=$(hostname -s 2>/dev/null || hostname 2>/dev/null | cut -d. -f1)
    [ -n "$host" ] || return 1
    probe="${LM_SERVER:-1.1.1.1}"
    lan=$(ip route get "$probe" 2>/dev/null | grep -oE 'src [0-9.]+' | head -1 | awk '{print $2}')
    [ -n "$lan" ] || return 1

    search=$(grep -E '^[[:space:]]*search' /etc/resolv.conf 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$search" ] || return 1

    for d in $search; do
        resolved=$(getent ahostsv4 "${host}.${d}" 2>/dev/null | awk '{print $1; exit}')
        if [ "$resolved" = "$lan" ]; then
            rest=$(printf '%s\n' $search | grep -vx "$d" | tr '\n' ' ' || true)
            echo "$d ${rest}" | sed 's/[[:space:]]*$//'
            return 0
        fi
    done
    return 1
}

if DOMAINS=$(detect_domains); then
    info "Using: ${DOMAINS}"
else
    DOMAINS=""
    warn "Could not match a search domain to this machine's LAN address."
    warn "If a legacy License Manager rejects you as \"not on same net\", set"
    warn "LOCALDOMAIN in ${PSCAD_ROOT}/pscad to your site's DNS domain."
fi

# --------------------------------------------------------------------------
say "Matching PSCAD's text size to the desktop"
# Wine renders at 96 DPI regardless of the desktop's display scaling, so on a
# HiDPI screen PSCAD comes out tiny next to everything else.  Telling Wine the
# real DPI scales its fonts and controls to match.
# Each branch is guarded by command -v on purpose: under `set -o pipefail` a
# missing tool makes the whole pipeline exit 127, and `set -e` would then kill
# the script here -- before the launcher below is ever written.
desktop_scale() {
    local scale=""
    # Ask the running compositor first. Installed KDE tools do not mean a KDE
    # session is running, and Hyprland's JSON may be compact or pretty-printed.
    if command -v hyprctl >/dev/null; then
        scale=$(hyprctl -j monitors 2>/dev/null | python3 -c '
import json, sys
monitors = json.load(sys.stdin)
scales = [float(m["scale"]) for m in monitors if not m.get("disabled", False)]
print(max(scales, default=0))
' 2>/dev/null || true)
    fi
    if ! valid_scale "$scale" && command -v kscreen-doctor >/dev/null; then
        scale=$(kscreen-doctor -o 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | awk '/Scale:/ {print $2}' | sort -rn | head -1 || true)
    fi
    if ! valid_scale "$scale" && command -v wlr-randr >/dev/null; then
        scale=$(wlr-randr 2>/dev/null | awk '/Scale:/ {print $2}' | sort -rn | head -1 || true)
    fi
    valid_scale "$scale" && printf '%s\n' "$scale"
}

valid_scale() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v s="$1" 'BEGIN{exit !(s>0)}'
}

if [ -z "$DPI" ]; then
    scale=$(desktop_scale || true)
    DPI=$(awk -v s="${scale:-1}" 'BEGIN{d=96*(s>1?s:1); printf "%d", (d>480?480:d)+0.5}')
fi
# Write 96 too, so --dpi 96 can reset a previously scaled prefix.
wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$DPI" /f >/dev/null 2>&1
info "Set to ${DPI} DPI ($(awk -v d="$DPI" 'BEGIN{printf "%d", d*100/96}')%)."
info "Launchers preserve this DPI; PSCAD_DPI overrides it for a launch."

# --------------------------------------------------------------------------
say "Preparing licensing"
# Before it connects, PSCAD's License Manager client pings the server, with a
# very short deadline (the defaults 5.0.2 writes say Timeout="1").  Wine's
# IcmpSendEcho honours a 1 ms deadline exactly, so a server 2 ms away "fails"
# the ping, and PSCAD reports
#
#   ERROR: Unable to connect to <server>. Cause: IP request timed out
#
# -- IP_REQ_TIMED_OUT, 11010, the ping's status, not a connection error --
# while the server is answering ordinary pings in 2 ms.  The client needs no
# ping to connect, and PSCAD's own switch for it is PingEnabled under
# HKLM\...\PSCAD\License, shared by every PSCAD version in the prefix.
wine reg add 'HKLM\Software\Manitoba HVDC Research Centre Inc\PSCAD\License' \
    /v PingEnabled /t REG_SZ /d false /f >/dev/null 2>&1 \
    && info "License Manager ping check off." \
    || warn "Could not turn off the License Manager ping check; see README.md."

# PSCAD also asks the License Manager for the edition it used last, kept per
# version as HKCU\...\PSCAD\<version>\MRUEdition.  A new prefix has none and
# asks for Professional first; seeding it saves picking the edition by hand.
edition_key="HKCU\\Software\\Manitoba HVDC Research Centre Inc\\PSCAD\\${PSCAD_VERSION}"
if [ -n "$EDITION" ] && [ -n "$PSCAD_VERSION" ]; then
    wine reg add "$edition_key" /v MRUEdition /t REG_SZ /d "$EDITION" /f >/dev/null 2>&1 \
        && info "PSCAD ${PSCAD_VERSION} will ask for ${EDITION} first." \
        || warn "Could not set MRUEdition; pick the edition in PSCAD instead."
elif [ -n "$EDITION" ]; then
    warn "PSCAD's version is unknown, so --edition cannot be applied; pick it in PSCAD."
else
    info "No --edition; PSCAD asks for Professional until you pick an edition in it."
fi

# --------------------------------------------------------------------------
say "Writing the launcher"
cat > "${PSCAD_ROOT}/pscad" <<LAUNCHER
#!/bin/bash
# Launch PSCAD in its own Wine prefix.
#
# LD_PRELOAD is required to start at all: Wine does not implement the AI_FQDN
# flag PSCAD uses to look up its own host name, and PSCAD faults on the NULL it
# gets back.  See fix/pscad_shim.c.
#
# The other two variables only matter for a legacy License Manager, which
# refuses a machine whose reported address is not on its network.
#
# PSCAD_LM_SERVER tells the shim which host to route towards when it works out
# this machine's outward-facing address.  Only matters with more than one way
# out; the shim falls back to the default route.
#
# LOCALDOMAIN overrides the resolver search list for this process only, so an
# overlay VPN such as Tailscale keeps working normally.  Change it if this
# machine moves to a different network; clear it if you do not use a License
# Manager.
set -euo pipefail

PSCAD_ROOT="${PSCAD_ROOT}"
export WINEPREFIX="\${PSCAD_ROOT}/prefix"
export WINEDEBUG="\${WINEDEBUG:--all}"
export LD_PRELOAD="\${PSCAD_ROOT}/fix/pscad_shim.so\${LD_PRELOAD:+:\$LD_PRELOAD}"
LAUNCHER
if [ -n "$LM_SERVER" ]; then
    printf 'export PSCAD_LM_SERVER="${PSCAD_LM_SERVER:-%s}"\n' "$LM_SERVER" >> "${PSCAD_ROOT}/pscad"
else
    printf '# export PSCAD_LM_SERVER="10.0.0.1"   # see README.md\n' >> "${PSCAD_ROOT}/pscad"
fi
if [ -n "$DOMAINS" ]; then
    printf 'export LOCALDOMAIN="${LOCALDOMAIN:-%s}"\n' "$DOMAINS" >> "${PSCAD_ROOT}/pscad"
else
    printf '# export LOCALDOMAIN="your.dns.domain"   # see README.md\n' >> "${PSCAD_ROOT}/pscad"
fi
# PSCAD 5.1 starts a new user profile with no compiler chosen,
# fortran_version="0", and shows the 32-bit GFortran in its place, which it
# then refuses to build with: "The specified Fortran compiler is not
# detected".  Picking the 64-bit one in Application Options > Dependencies
# fixes it, and is stored as its ID, e.g. GF81x64.  The launcher makes that
# choice for PSCAD whenever the profile still has none, so it never overrides
# one made by hand.  Newest 64-bit GFortran in the prefix; 5.0.x does not need
# this.
COMPILER_OID=""
if [ "$INSTALLER_KIND" = "mhi" ]; then
    case "$(find_gfortran | grep -i '/x64/' | tail -1 || true)" in
        */GFortran/13.2/*) COMPILER_OID="GF132x64" ;;
        */GFortran/8.1/*)  COMPILER_OID="GF81x64" ;;
    esac
fi
PROFILE_NAME="user_profile_$(echo "$PSCAD_VERSION" | cut -d. -f1-2 | tr -d .).xml"
if [ -n "$COMPILER_OID" ]; then
    cat >> "${PSCAD_ROOT}/pscad" <<'LAUNCHER'

# A new PSCAD 5.1 profile has no compiler chosen, and PSCAD then offers the
# 32-bit GFortran, which it cannot build with ("The specified Fortran compiler
# is not detected").  Choose the 64-bit one while nothing is chosen; a choice
# made in Application Options > Dependencies is left alone.
LAUNCHER
    printf 'PSCAD_COMPILER="%s"\n' "$COMPILER_OID" >> "${PSCAD_ROOT}/pscad"
    printf 'PSCAD_PROFILE="${WINEPREFIX}/drive_c/users/${USER}/AppData/Local/Manitoba HVDC Research Centre/PSCAD/%s"\n' \
        "$PROFILE_NAME" >> "${PSCAD_ROOT}/pscad"
    cat >> "${PSCAD_ROOT}/pscad" <<'LAUNCHER'
if [ -f "$PSCAD_PROFILE" ]; then
    sed -i -E 's#(<param name="(fortran|c)_version" value=")0?(")#\1'"$PSCAD_COMPILER"'\3#' \
        "$PSCAD_PROFILE" || true
fi
LAUNCHER
fi
cat >> "${PSCAD_ROOT}/pscad" <<LAUNCHER

# Keep the selected UI scale when Wine starts a new desktop or server.
# Override it with PSCAD_DPI=144 (150%), for example.
PSCAD_DPI="\${PSCAD_DPI:-${DPI}}"
LAUNCHER
cat >> "${PSCAD_ROOT}/pscad" <<'LAUNCHER'
if ! [[ "$PSCAD_DPI" =~ ^[0-9]{2,3}$ ]] || ((10#$PSCAD_DPI < 96 || 10#$PSCAD_DPI > 480)); then
    printf '%s\n' 'PSCAD_DPI must be a whole number from 96 to 480.' >&2
    exit 1
fi
PSCAD_DPI=$((10#$PSCAD_DPI))
wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$PSCAD_DPI" /f >/dev/null
LAUNCHER
cat >> "${PSCAD_ROOT}/pscad" <<LAUNCHER

exec wine "\${WINEPREFIX}/${PSCAD_EXE}" "\$@"
LAUNCHER
chmod +x "${PSCAD_ROOT}/pscad"

sed -e 's|/bin/win64/Pscad.exe|/Utilities/FortranMedic.exe|' \
    "${PSCAD_ROOT}/pscad" > "${PSCAD_ROOT}/fortranmedic"
chmod +x "${PSCAD_ROOT}/fortranmedic"

# A second launcher that puts PSCAD inside a Wine virtual desktop.  Wine draws
# menus and their drop shadows as separate X11 windows and advertises the
# shadows as ordinary dialogs, so a compositor that manages them paints them
# opaque black: a drop-down becomes a black curtain over a menu that is still
# there and still clickable.  A virtual desktop keeps every Wine window inside
# one X11 window, which no compositor can get wrong, and gives PSCAD a normal
# decorated window on desktops with no equivalent of the KWin rule below.
sed -e 's|^# Launch PSCAD in its own Wine prefix\.|# Launch PSCAD inside a Wine virtual desktop.\n#\n# Use this one if drop-down menus come up as black rectangles, or if your\n# window manager leaves PSCAD with no titlebar.  See README.md.|' \
    -e 's|^exec wine "|exec wine explorer "/desktop=PSCAD,${PSCAD_DESKTOP_SIZE:-$((1440 * PSCAD_DPI / 96))x$((880 * PSCAD_DPI / 96))}" "|' \
    "${PSCAD_ROOT}/pscad" > "${PSCAD_ROOT}/pscad-desktop"
chmod +x "${PSCAD_ROOT}/pscad-desktop"

info "${PSCAD_ROOT}/pscad"
info "${PSCAD_ROOT}/pscad-desktop   (virtual desktop: black menus, no titlebar)"
info "${PSCAD_ROOT}/fortranmedic  (compiler diagnostics)"

# --------------------------------------------------------------------------
say "Fixing PSCAD's window behaviour (KDE only)"
# PSCAD draws its own titlebar, so Wine asks the window manager for a window
# with no decorations at all.  The result under KWin is a window with no
# titlebar buttons and no borders to grab, so minimise, maximise and resize
# are simply not reachable with the mouse.  A KWin rule overrides that for
# this one window class.  Other desktops need the equivalent rule set by hand.
add_kwin_rule() {
    local cfg="${HOME}/.config/kwinrulesrc" idx count rules kw
    kw=$(command -v kwriteconfig6 || command -v kwriteconfig5) || return 1

    if [ -f "$cfg" ] && grep -q '^wmclass=pscad\.exe$' "$cfg"; then
        info "Rule already present."
        return 0
    fi

    count=$(kreadconfig6 --file kwinrulesrc --group General --key count 2>/dev/null || echo 0)
    [ -n "$count" ] || count=0
    idx=$((count + 1))
    rules=$(kreadconfig6 --file kwinrulesrc --group General --key rules 2>/dev/null || true)

    "$kw" --file kwinrulesrc --group "$idx" --key Description "PSCAD under Wine: force a real titlebar and resize borders"
    "$kw" --file kwinrulesrc --group "$idx" --key wmclass "pscad.exe"
    "$kw" --file kwinrulesrc --group "$idx" --key wmclasscomplete "false"
    "$kw" --file kwinrulesrc --group "$idx" --key wmclassmatch "1"
    "$kw" --file kwinrulesrc --group "$idx" --key noborder "false"
    "$kw" --file kwinrulesrc --group "$idx" --key noborderrule "2"
    "$kw" --file kwinrulesrc --group General --key count "$idx"
    "$kw" --file kwinrulesrc --group General --key rules "${rules:+$rules,}$idx"

    qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null \
        || qdbus org.kde.KWin /KWin reconfigure 2>/dev/null \
        || dbus-send --session --dest=org.kde.KWin --type=method_call \
             /KWin org.kde.KWin.reconfigure 2>/dev/null || true
    return 0
}

if [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ] && add_kwin_rule; then
    info "KWin will now decorate PSCAD's window."
    info "PSCAD still draws its own titlebar underneath; that duplication is cosmetic."
    info "Resize by dragging; do not maximise, see README.md."
else
    warn "Not KDE, or the rule could not be written."
    warn "If PSCAD has no titlebar, tell your window manager to decorate the"
    warn "window class \"pscad.exe\".  Meta+drag moves and Meta+right-drag"
    warn "resizes an undecorated window in the meantime."
fi

# --------------------------------------------------------------------------
say "Adding a desktop entry"
# Named after the version, so installing 5.1 beside an existing 5.0 leaves
# both in the application menu.
data_dir="${XDG_DATA_HOME:-${HOME}/.local/share}"
apps="${data_dir}/applications"
icons="${data_dir}/icons/hicolor/256x256/apps"
slug="pscad${PSCAD_VERSION:+-${PSCAD_VERSION}}"
mkdir -p "$apps" "$icons"

# PSCAD embeds its full-resolution icon in Pscad.exe. The 256px frame is PNG,
# so Python's standard library can extract it without Pillow or icoutils.
# Prefer the main application icon (resource group 128), then other groups.
extract_pscad_icon() {
    python3 - "${PREFIX}/${PSCAD_EXE}" "${icons}/${slug}.png" <<'PYICON'
import struct
import sys
from pathlib import Path

def extract(source):
    data = source.read_bytes()
    pe = struct.unpack_from('<I', data, 60)[0]
    if data[:2] != b'MZ' or data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('Not a Windows executable')
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional = pe + 24
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    directories = optional + (112 if struct.unpack_from('<H', data, optional)[0] == 0x20b else 96)
    resource_rva = struct.unpack_from('<I', data, directories + 16)[0]
    sections = [struct.unpack_from('<8sIIII', data, optional + optional_size + 40 * i)
                for i in range(count)]

    def offset(rva):
        for _, virtual_size, address, raw_size, position in sections:
            if address <= rva < address + max(virtual_size, raw_size):
                return position + rva - address
        raise ValueError('Resource is outside the executable sections')

    root = offset(resource_rva)

    def entries(relative):
        position = root + relative
        named, numbered = struct.unpack_from('<HH', data, position + 12)
        return [struct.unpack_from('<II', data, position + 16 + 8 * i)
                for i in range(named + numbered)]

    def resources(kind):
        for resource_type, directory in entries(0):
            if resource_type != kind:
                continue
            for name, languages in entries(directory & 0x7fffffff):
                for language, leaf in entries(languages & 0x7fffffff):
                    rva, size = struct.unpack_from('<II', data, root + leaf)
                    start = offset(rva)
                    yield name, language, data[start:start + size]

    icons = {(name, language): content for name, language, content in resources(3)}
    groups = sorted(resources(14), key=lambda group: group[0] != 128)
    for _, language, group in groups:
        frames = []
        for i in range(struct.unpack_from('<H', group, 4)[0]):
            icon_id = struct.unpack_from('<H', group, 6 + 14 * i + 12)[0]
            frame = icons.get((icon_id, language), b'')
            if frame.startswith(b'\x89PNG\r\n\x1a\n'):
                width, height = struct.unpack_from('>II', frame, 16)
                frames.append((width * height, frame))
        if frames:
            return max(frames, key=lambda frame: frame[0])[1]
    raise ValueError('No PNG icon frame; try ImageMagick or icoutils')

try:
    png = extract(Path(sys.argv[1]))
    Path(sys.argv[2]).write_bytes(png)
except (OSError, ValueError, struct.error) as error:
    print(f'Could not extract PSCAD icon: {error}', file=sys.stderr)
    sys.exit(1)
PYICON
}

if extract_pscad_icon 2>/dev/null; then
    info "Extracted PSCAD's original icon from Pscad.exe."
elif [ -f "${INSTALLER_DIR}/hvdc.ico" ]; then
    for im in magick convert; do
        command -v "$im" >/dev/null || continue
        "$im" "${INSTALLER_DIR}/hvdc.ico[0]" -resize 256x256 "${icons}/${slug}.png" 2>/dev/null && break
    done
elif command -v wrestool >/dev/null && command -v icotool >/dev/null; then
    tmpico=$(mktemp -d)
    wrestool -x -t 14 -o "$tmpico" "${PREFIX}/${PSCAD_EXE}" 2>/dev/null || true
    ico=$(find "$tmpico" -type f | head -1)
    [ -n "$ico" ] && icotool -x -w 256 -o "$tmpico" "$ico" 2>/dev/null \
        && cp "$(find "$tmpico" -name '*.png' | head -1)" "${icons}/${slug}.png" 2>/dev/null || true
    rm -rf "$tmpico"
fi
# Use an absolute path so an icon-theme cache cannot hide the new icon.
# If extraction failed, keep a prior icon or use an installed generic icon.
icon_name="application-x-executable"
if [ -s "${icons}/${slug}.png" ]; then
    icon_name="${icons}/${slug}.png"
else
    warn "Could not extract PSCAD's icon; install ImageMagick or icoutils and rerun."
fi

# The virtual desktop belongs to explorer.exe, not pscad.exe. Match the
# launcher actually used by the menu entry, so Hyprland's bar can find it.
desktop_launcher="pscad"
desktop_class="pscad.exe"
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    desktop_launcher="pscad-desktop"
    desktop_class="explorer.exe"
fi

# Earlier versions of this script wrote an unversioned pscad.desktop.  If that
# one launches this same root, the entry below replaces it; one that launches
# a different root belongs to another install and is left alone.
if [ "$slug" != "pscad" ] && grep -qxF "Exec=${PSCAD_ROOT}/pscad %f" "${apps}/pscad.desktop" 2>/dev/null; then
    rm -f "${apps}/pscad.desktop"
fi

cat > "${apps}/${slug}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=PSCAD${PSCAD_VERSION:+ ${PSCAD_VERSION}}
GenericName=Power System Simulation
Comment=Manitoba HVDC PSCAD/EMTDC running under Wine
Exec="${PSCAD_ROOT}/${desktop_launcher}" %f
Icon=${icon_name}
Terminal=false
Categories=Science;Engineering;
StartupWMClass=${desktop_class}
DESKTOP
update-desktop-database "$apps" 2>/dev/null || true
if command -v gtk-update-icon-cache >/dev/null && [ -f "${data_dir}/icons/hicolor/index.theme" ]; then
    gtk-update-icon-cache -f -t "${data_dir}/icons/hicolor" >/dev/null 2>&1 || true
fi
info "Menu launcher: ${PSCAD_ROOT}/${desktop_launcher} (${desktop_class})."

# --------------------------------------------------------------------------
say "Done"
cat <<FINISH
    Start PSCAD with:   ${PSCAD_ROOT}/${desktop_launcher}
    or from the application menu.

    Licensing is not configured yet.  Open PSCAD and enter your certificate
    credentials or your License Manager address.  If a legacy License Manager
    refuses the machine, read
      ${PREFIX}/drive_c/ProgramData/Manitoba HVDC Research Centre/LicenseManager/PscadLmgr.txt
    The "LM Client on" line shows which address PSCAD reported, and that is
    almost always the whole diagnosis.  README.md has the details.
FINISH
# The launcher can only fill in the compiler once PSCAD has written a profile,
# which it does when it exits.  It cannot be written for it in advance: a
# profile holding just the compiler lets PSCAD 5.1 start, but it then hangs on
# exit and never saves.  So the first session needs the choice made by hand.
case "$COMPILER_OID" in
    GF132x64) compiler_name="GFortran 13.2 (64-bit)" ;;
    GF81x64)  compiler_name="GFortran 8.1 (64-bit)" ;;
    *)        compiler_name="" ;;
esac
if [ -n "$compiler_name" ]; then
    cat <<FINISH

    Before the first build, choose the compiler once: Application Options >
    Dependencies > Fortran compiler > "${compiler_name}".  PSCAD offers the
    32-bit one by default and cannot build with it ("The specified Fortran
    compiler is not detected").  The launcher sets it for later sessions if
    it is still unset.
FINISH
fi
