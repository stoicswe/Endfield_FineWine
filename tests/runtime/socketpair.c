/* The local "socket pair" that libcurl makes on Windows before every name lookup, step by
 * step as its socketpair.c does it (versions 7.7x-8.x): a listener on the loopback address,
 * a connection to it, a non-blocking accept after waiting for it to be readable, and a check
 * that the two ends are each other's peers. If any step fails, libcurl reports
 * "getaddrinfo() thread failed to start" and cannot resolve any host name.
 * Prints "socketpair: ok" or the step that failed. */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define FAIL(what) do { printf("socketpair: FAILED at %s (error %d)\n", what, WSAGetLastError()); return 1; } while (0)

static int pair(int use_wsapoll)
{
    union { struct sockaddr_in inaddr; struct sockaddr addr; } a, b;
    SOCKET listener, socks[2];
    int addrlen = sizeof(a.inaddr), reuse = 1;
    u_long nonblocking = 1;
    char byte = 'x', got = 0;

    if ((listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)) == INVALID_SOCKET) FAIL("socket (listener)");
    memset(&a, 0, sizeof(a));
    a.inaddr.sin_family = AF_INET;
    a.inaddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.inaddr.sin_port = 0;
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, (char *)&reuse, sizeof(reuse)) == -1) FAIL("setsockopt SO_REUSEADDR");
    if (bind(listener, &a.addr, sizeof(a.inaddr)) == -1) FAIL("bind");
    if (getsockname(listener, &a.addr, &addrlen) == -1 || addrlen < (int)sizeof(a.inaddr)) FAIL("getsockname (listener)");
    if (listen(listener, 1) == -1) FAIL("listen");
    if ((socks[0] = socket(AF_INET, SOCK_STREAM, 0)) == INVALID_SOCKET) FAIL("socket (client)");
    if (connect(socks[0], &a.addr, sizeof(a.inaddr)) == -1) FAIL("connect");
    if (ioctlsocket(listener, FIONBIO, &nonblocking)) FAIL("ioctlsocket FIONBIO");
    if (use_wsapoll)
    {
        WSAPOLLFD pfd = { listener, POLLIN, 0 };
        int r = WSAPoll(&pfd, 1, 10000);
        if (r <= 0) { printf("socketpair: FAILED at WSAPoll: returned %d revents %#x (error %d)\n", r, pfd.revents, WSAGetLastError()); return 1; }
    }
    else
    {
        fd_set set; struct timeval tv = { 10, 0 };
        FD_ZERO(&set); FD_SET(listener, &set);
        if (select(0, &set, NULL, NULL, &tv) <= 0) FAIL("select");
    }
    if ((socks[1] = accept(listener, NULL, NULL)) == INVALID_SOCKET) FAIL("accept");
    addrlen = sizeof(a.inaddr);
    if (getsockname(socks[0], &a.addr, &addrlen) == -1 || addrlen < (int)sizeof(a.inaddr)) FAIL("getsockname (client)");
    addrlen = sizeof(b.inaddr);
    if (getpeername(socks[1], &b.addr, &addrlen) == -1 || addrlen < (int)sizeof(b.inaddr)) FAIL("getpeername");
    if (a.inaddr.sin_family != b.inaddr.sin_family || a.inaddr.sin_addr.s_addr != b.inaddr.sin_addr.s_addr ||
        a.inaddr.sin_port != b.inaddr.sin_port)
    {
        printf("socketpair: FAILED: the two ends are not each other's peers (%#lx:%u and %#lx:%u)\n",
               (unsigned long)ntohl(a.inaddr.sin_addr.s_addr), ntohs(a.inaddr.sin_port),
               (unsigned long)ntohl(b.inaddr.sin_addr.s_addr), ntohs(b.inaddr.sin_port));
        return 1;
    }
    if (send(socks[0], &byte, 1, 0) != 1) FAIL("send");
    {
        /* the accepted socket is non-blocking, like its listener: wait for the byte */
        fd_set set; struct timeval tv = { 10, 0 };
        FD_ZERO(&set); FD_SET(socks[1], &set);
        if (select(0, &set, NULL, NULL, &tv) <= 0) FAIL("select (data)");
    }
    if (recv(socks[1], &got, 1, 0) != 1 || got != byte) FAIL("recv");
    closesocket(listener); closesocket(socks[0]); closesocket(socks[1]);
    return 0;
}

int main(void)
{
    WSADATA wsa;
    int i;

    WSAStartup(MAKEWORD(2, 2), &wsa);
    for (i = 0; i < 20; i++) if (pair(0)) return 1;
    for (i = 0; i < 20; i++) if (pair(1)) return 1;
    printf("socketpair: ok\n");
    return 0;
}
