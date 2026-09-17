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
