#!/bin/bash
#
# Install PSCAD 5.0.2 into a dedicated Wine prefix on Linux.
#
# Run with --help for options.  The companion README.md explains what each
# step is for and what to do when something goes wrong.
#
set -euo pipefail

INSTALLER_DIR="${HOME}/Downloads/PSCAD_502_U2_installer"
PSCAD_ROOT="${HOME}/pscad_local"
LM_SERVER=""
DPI=""
SKIP_DEPS=0
FORCE=0
GECKO_FALLBACK="2.47.4"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Install PSCAD 5.0.2 into its own Wine prefix.

  --installer DIR   Unpacked PSCAD installer (the folder holding setup.exe).
                    Default: ~/Downloads/PSCAD_502_U2_installer
  --root DIR        Where to put the prefix, launcher and shim.
                    Default: ~/pscad_local
  --lm-server ADDR  Legacy License Manager address.  Only used to work out
                    which network interface faces the licence server; you
                    still enter the address in PSCAD itself.
  --dpi N           Font/UI scale for PSCAD, in dots per inch.  96 is 100%,
                    144 is 150%, 192 is 200%.  Default: derived from your
                    desktop's display scaling.
  --skip-deps       Do not try to install distribution packages.
  --force           Reuse an existing prefix directory instead of stopping.
  -h, --help        This text.

The PSCAD installer itself is a graphical InstallShield wizard, so this
script needs a desktop session and will pause while you click through it.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --installer) INSTALLER_DIR="${2:?}"; shift 2 ;;
        --root)      PSCAD_ROOT="${2:?}";    shift 2 ;;
        --lm-server) LM_SERVER="${2:?}";     shift 2 ;;
        --dpi)       DPI="${2:?}";           shift 2 ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        --force)     FORCE=1;     shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

PREFIX="${PSCAD_ROOT}/prefix"
FIXDIR="${PSCAD_ROOT}/fix"
PSCAD_EXE='drive_c/Program Files (x86)/PSCAD50/bin/win64/Pscad.exe'

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=-all

# --------------------------------------------------------------------------
say "Checking the environment"

[ "$(uname -m)" = "x86_64" ] || die "PSCAD needs an x86_64 machine; this is $(uname -m)."
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || die "No graphical session found. The PSCAD installer is a GUI wizard."
[ -f "${INSTALLER_DIR}/setup.exe" ] || die "No setup.exe in ${INSTALLER_DIR}. Point --installer at the unpacked installer."

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
    dpkg -l wine32 2>/dev/null | grep -q '^ii' || missing+=(wine32)
    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing: ${missing[*]}"
        sudo dpkg --add-architecture i386
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi
else
    [ "$SKIP_DEPS" -eq 1 ] || warn "Not a Debian/Ubuntu system; install wine (with 32-bit support), winetricks, curl and gcc yourself."
fi

for tool in wine winetricks curl gcc; do
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

wineserver_bin=$(command -v wineserver || find /usr/lib -name wineserver -type f 2>/dev/null | head -1)
[ -n "$wineserver_bin" ] || die "Cannot find the wineserver binary."
wait_for_wine() { "$wineserver_bin" -w; }

# --------------------------------------------------------------------------
say "Creating the Wine prefix at ${PREFIX}"
mkdir -p "$PSCAD_ROOT" "$FIXDIR"
wineboot -u >/dev/null 2>&1 || true
wait_for_wine
info "64-bit prefix created."

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
say "Installing the Visual C++ 2022 runtimes"
# Taken from the installer's own prerequisite folder, so nothing is downloaded
# and the versions match what PSCAD was built against.
prq="${INSTALLER_DIR}/ISSetupPrerequisites"
found_vc=0
while IFS= read -r -d '' redist; do
    info "$(basename "$(dirname "$redist")")/$(basename "$redist")"
    wine "$redist" /q /norestart >/dev/null 2>&1 || warn "$(basename "$redist") returned non-zero"
    wait_for_wine
    found_vc=1
done < <(find "$prq" -name 'vc_redist.*.exe' -print0 2>/dev/null)
[ "$found_vc" -eq 1 ] || warn "No vc_redist binaries found under ${prq}; PSCAD may fail to start."

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
say "Running the PSCAD installer"
cat <<'NOTE'
    The InstallShield wizard opens now.  Accept the defaults unless you have
    a reason not to.  The USB dongle driver is skipped on purpose: Wine
    cannot load Windows kernel drivers, so dongle licensing will not work
    here regardless.  This script continues when the wizard exits.
NOTE
( cd "$INSTALLER_DIR" && wine setup.exe /v"/IgnoreDrivers" ) || true
wait_for_wine

[ -f "${PREFIX}/${PSCAD_EXE}" ] || die "PSCAD is not where it should be. Did the wizard finish?"
info "PSCAD installed."

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
    if command -v kscreen-doctor >/dev/null; then          # KDE
        kscreen-doctor -o 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | awk '/Scale:/ {print $2}' | sort -rn | head -1
    elif command -v hyprctl >/dev/null; then               # Hyprland
        hyprctl -j monitors 2>/dev/null \
            | awk -F'[:,]' '/"scale"/ {gsub(/[[:space:]]/,"",$2); print $2}' \
            | sort -rn | head -1
    elif command -v wlr-randr >/dev/null; then             # other wlroots
        wlr-randr 2>/dev/null | awk '/Scale:/ {print $2}' | sort -rn | head -1
    fi
}

if [ -z "$DPI" ]; then
    scale=$(desktop_scale || true)
    DPI=$(awk -v s="${scale:-1}" 'BEGIN{printf "%d", 96*(s>1?s:1)}')
fi
if [ "$DPI" -gt 96 ] 2>/dev/null; then
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$DPI" /f >/dev/null 2>&1
    info "Set to ${DPI} DPI ($(awk -v d="$DPI" 'BEGIN{printf "%d", d*100/96}')%)."
    info "Change it later with: WINEPREFIX=${PREFIX} winecfg  (Graphics tab)"
else
    info "Desktop is unscaled; leaving PSCAD at 96 DPI."
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
    -e 's|^exec wine "|exec wine explorer /desktop=PSCAD,1440x880 "|' \
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
apps="${HOME}/.local/share/applications"
icons="${HOME}/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$apps" "$icons"
if [ -f "${INSTALLER_DIR}/hvdc.ico" ]; then
    for im in magick convert; do
        command -v "$im" >/dev/null || continue
        "$im" "${INSTALLER_DIR}/hvdc.ico[0]" -resize 256x256 "${icons}/pscad.png" 2>/dev/null && break
    done
fi
cat > "${apps}/pscad.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=PSCAD
GenericName=Power System Simulation
Comment=Manitoba HVDC PSCAD/EMTDC running under Wine
Exec=${PSCAD_ROOT}/pscad %f
Icon=pscad
Terminal=false
Categories=Science;Engineering;
StartupWMClass=pscad.exe
DESKTOP
update-desktop-database "$apps" 2>/dev/null || true

# --------------------------------------------------------------------------
say "Done"
cat <<FINISH
    Start PSCAD with:   ${PSCAD_ROOT}/pscad
    or from the application menu.

    Licensing is not configured yet.  Open PSCAD and enter your certificate
    credentials or your License Manager address.  If a legacy License Manager
    refuses the machine, read
      ${PREFIX}/drive_c/ProgramData/Manitoba HVDC Research Centre/LicenseManager/PscadLmgr.txt
    The "LM Client on" line shows which address PSCAD reported, and that is
    almost always the whole diagnosis.  README.md has the details.
FINISH
