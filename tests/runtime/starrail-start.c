/* The two start-up workarounds for Honkai: Star Rail (runtime patch 0057).
 *
 * Under Wine the game ends a few seconds after it starts unless its first network connection is
 * refused and its first lookup in Windows' signature catalogues appears to succeed. The runtime
 * does both for a program whose file is StarRail.exe; FINEWINE_STARRAIL_WORKAROUNDS=1 does it
 * for any program (how this test asks for it) and =0 for none.
 *
 * Prints "starrail-start: on ok" when the first connection is refused, the second is treated
 * normally, and the first catalogue lookup succeeds once; "starrail-start: off ok" when
 * neither happens. Which of the two is expected is the argument: "on" or "off". */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <mscat.h>
#include <stdio.h>
#include <string.h>

/* connects to a listening socket of our own; returns 0 or the error */
static int try_connect(unsigned short port)
{
    struct sockaddr_in to = { .sin_family = AF_INET, .sin_port = port };
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    int err = 0;
    to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&to, sizeof(to))) err = WSAGetLastError();
    closesocket(s);
    return err;
}

int main(int argc, char **argv)
{
    int on = argc > 1 && !strcmp(argv[1], "on"), ok = 1;
    struct sockaddr_in addr = { .sin_family = AF_INET };
    int len = sizeof(addr), first, second;
    BYTE hash[20] = { 1, 2, 3 };
    HCATADMIN admin = NULL;
    HCATINFO found, again;
    CATALOG_INFO info = { sizeof(info) };
    BOOL has_info, released;
    WSADATA data;
    SOCKET server;

    WSAStartup(MAKEWORD(2, 2), &data);
    server = socket(AF_INET, SOCK_STREAM, 0);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(server, (struct sockaddr *)&addr, sizeof(addr));
    listen(server, 4);
    getsockname(server, (struct sockaddr *)&addr, &len);

    first = try_connect(addr.sin_port);
    second = try_connect(addr.sin_port);
    if (first != (on ? WSAECONNREFUSED : 0)) { printf("first connection: error %d\n", first); ok = 0; }
    if (second) { printf("second connection: error %d\n", second); ok = 0; }

    if (!CryptCATAdminAcquireContext(&admin, NULL, 0)) { printf("no catalogue context: %lu\n", GetLastError()); ok = 0; }
    found = CryptCATAdminEnumCatalogFromHash(admin, hash, sizeof(hash), 0, NULL);
    if (!!found != on) { printf("first lookup: %p\n", (void *)found); ok = 0; }
    if (found)
    {
        has_info = CryptCATCatalogInfoFromContext(found, &info, 0);
        again = found;
        again = CryptCATAdminEnumCatalogFromHash(admin, hash, sizeof(hash), 0, &again);
        released = CryptCATAdminReleaseCatalogContext(admin, found, 0);
        if (!has_info || again || !released) { printf("info %d, a second catalogue %p, released %d\n", has_info, (void *)again, released); ok = 0; }
    }
    if (CryptCATAdminEnumCatalogFromHash(admin, hash, sizeof(hash), 0, NULL)) { printf("a second lookup found a catalogue\n"); ok = 0; }
    CryptCATAdminReleaseContext(admin, 0);

    printf(ok ? "starrail-start: %s ok\n" : "starrail-start: %s FAILED\n", on ? "on" : "off");
    return !ok;
}
