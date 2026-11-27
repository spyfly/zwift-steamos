/*
 * zwift-dns-shim.c — LD_PRELOAD getaddrinfo interposer for Zluggish offline mode.
 *
 * Redirects a fixed set of hostnames to one IP before DNS is consulted, for the
 * lifetime of the process it is preloaded into (the wine process running Zwift).
 * The app keeps using the original hostname string, so TLS SNI, certificate
 * validation and HTTP Host headers are untouched — only the IP changes.
 *
 * This is the root-free alternative to an /etc/hosts redirect: the file lives
 * under $HOME (shared with the pressure-vessel container) and is activated via
 * LD_PRELOAD + env vars in the game's Steam launch options, so no host system
 * file is ever touched.
 *
 * Configuration (set by share/steam-prelaunch.sh):
 *   ZWIFT_DNS_SHIM_IP=192.168.30.240          target IP
 *   ZWIFT_DNS_SHIM_HOSTS=a.zwift.com,b.zwift.com   comma-separated hostnames
 *   ZWIFT_DNS_SHIM_LOG=/path/to/log           optional request log
 *
 * Build (any host gcc; only ancient glibc symbols are used so the .so loads
 * inside the Steam Linux Runtime container):
 *   cc -shared -fPIC -O2 -Wall -o zwift-dns-shim.so zwift-dns-shim.c -ldl
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>

static char shim_ip[64];
static char shim_names[2048]; /* '|' separated */
static char shim_log[512];
static int shim_ready;

static void shim_init(void)
{
    const char *ip = getenv("ZWIFT_DNS_SHIM_IP");
    const char *names = getenv("ZWIFT_DNS_SHIM_HOSTS");
    const char *log = getenv("ZWIFT_DNS_SHIM_LOG");

    if (!ip || !*ip || !names || !*names)
        return;
    snprintf(shim_ip, sizeof(shim_ip), "%s", ip);
    snprintf(shim_names, sizeof(shim_names), "%s", names);
    for (char *p = shim_names; *p; p++)
        if (*p == ',')
            *p = '|';
    if (log && *log)
        snprintf(shim_log, sizeof(shim_log), "%s", log);
    shim_ready = 1;
}

static int shim_match(const char *name)
{
    char qname[256];
    char entry[256];
    size_t nlen, i;
    char *p;

    if (!name)
        return 0;
    nlen = strlen(name);
    if (nlen >= sizeof(qname))
        return 0;
    memcpy(qname, name, nlen + 1);
    if (nlen > 0 && qname[nlen - 1] == '.') /* tolerate FQDN lookups */
        qname[nlen - 1] = 0;
    for (p = shim_names; *p;) {
        i = 0;
        while (*p && *p != '|' && i + 1 < sizeof(entry))
            entry[i++] = *p++;
        entry[i] = 0;
        if (*p == '|')
            p++;
        if (entry[0] && !strcasecmp(qname, entry))
            return 1;
    }
    return 0;
}

static void shim_log_line(const char *via, const char *name)
{
    FILE *f;

    if (!shim_log[0])
        return;
    f = fopen(shim_log, "a");
    if (f) {
        fprintf(f, "%s: %s -> %s\n", via, name, shim_ip);
        fclose(f);
    }
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res)
{
    static int (*real_fn)(const char *, const char *, const struct addrinfo *,
                          struct addrinfo **);
    int rc;

    if (!real_fn)
        real_fn = dlsym(RTLD_NEXT, "getaddrinfo");
    if (!shim_ready)
        shim_init();
    if (shim_ready && node && shim_match(node)) {
        shim_log_line("getaddrinfo", node);
        rc = real_fn(shim_ip, service, hints, res);
        if (rc == 0 || !hints || hints->ai_family == AF_UNSPEC ||
            hints->ai_family == AF_INET)
            return rc;
        /* numeric IPv4 cannot satisfy AF_INET6 hints — resolve normally */
        shim_log_line("getaddrinfo-fallback", node);
    }
    return real_fn(node, service, hints, res);
}

struct hostent *gethostbyname(const char *name)
{
    static struct hostent *(*real_fn)(const char *);

    if (!real_fn)
        real_fn = dlsym(RTLD_NEXT, "gethostbyname");
    if (!shim_ready)
        shim_init();
    if (shim_ready && name && shim_match(name)) {
        shim_log_line("gethostbyname", name);
        return real_fn(shim_ip);
    }
    return real_fn(name);
}
