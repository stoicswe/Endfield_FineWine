/* arm64-x18.c: an ARM64 Windows program that reaches the TEB through x18, the way code not
 * built for FineWine's runtime does (third-party programs, prebuilt toolchain libraries).
 * macOS clears x18, so each access below faults and Wine has to repair it.
 * Prints "arm64-x18: ok" when every access gave the right answer. */
#include <windows.h>
#include <stdio.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("%s: %s\n", what, ok ? "ok" : "FAILED");
    if (!ok) failures++;
}

/* TEB.NtTib.Self is at 0x30 and holds the TEB's own address; LastErrorValue is at 0x68. */
__attribute__((noinline)) static void *self_through_x18(void)
{
    void *teb;
    __asm__ volatile("ldr %0, [x18, #0x30]" : "=r"(teb));
    return teb;
}
__attribute__((noinline)) static void *self_through_copy(void)
{
    void *teb;
    __asm__ volatile("mov x9, x18\n\tldr %0, [x9, #0x30]" : "=r"(teb) : : "x9");
    return teb;
}
__attribute__((noinline)) static void store_through_x18(unsigned int value)
{
    __asm__ volatile("str %w0, [x18, #0x68]" : : "r"(value));
}
__attribute__((noinline)) static unsigned int load_pair_through_x18(void **base)
{
    void *lo, *hi;   /* StackBase at 0x08, StackLimit at 0x10 */
    __asm__ volatile("ldp %0, %1, [x18, #0x08]" : "=r"(lo), "=r"(hi));
    *base = lo;
    return lo > hi;
}

int main(void)
{
    void *teb = NtCurrentTeb(), *base = 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    Sleep(1);   /* a trip through the kernel: x18 is cleared from here on */

    check(self_through_x18() == teb, "load through x18");
    Sleep(1);
    check(self_through_copy() == teb, "load through a copy of x18");
    Sleep(1);
    store_through_x18(0x1234);
    check(GetLastError() == 0x1234, "store through x18");
    Sleep(1);
    check(load_pair_through_x18(&base) && base != 0, "load pair through x18");

    printf(failures ? "arm64-x18: %d FAILED\n" : "arm64-x18: ok\n", failures);
    return failures;
}
