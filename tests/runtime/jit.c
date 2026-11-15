/* jit.c: checks that a Windows program can generate code and run it under FineWine's runtime.
 * Built and run by scripts/test-finewine-runtime.sh. An x64 emulator depends on all three
 * cases: code written and then made executable, code in a page that is writable and
 * executable at once, and code rewritten in place. Prints "jit: ok" on success. */
#include <windows.h>
#include <stdio.h>
typedef int (*fn_t)(void);
static int try_alloc(DWORD prot, const char *name)
{
    DWORD *code = VirtualAlloc(NULL, 0x10000, MEM_COMMIT | MEM_RESERVE, prot), old;
    if (!code) { printf("%s: VirtualAlloc failed %lu\n", name, GetLastError()); return 0; }
    code[0] = 0x52800540; /* mov w0, #42 */
    code[1] = 0xd65f03c0; /* ret */
    if (prot == PAGE_READWRITE && !VirtualProtect(code, 0x10000, PAGE_EXECUTE_READ, &old))
    { printf("%s: VirtualProtect failed %lu\n", name, GetLastError()); return 0; }
    FlushInstructionCache(GetCurrentProcess(), code, 8);
    int r = ((fn_t)code)();
    printf("%s: ran generated code, returned %d\n", name, r);
    if (r != 42) return 0;
    if (prot == PAGE_EXECUTE_READWRITE)
    {
        /* rewrite while executable, as a JIT that patches its own code does */
        code[0] = 0x52800e00; /* mov w0, #112 */
        FlushInstructionCache(GetCurrentProcess(), code, 8);
        r = ((fn_t)code)();
        printf("%s: after rewriting in place, returned %d\n", name, r);
        if (r != 112) return 0;
    }
    return 1;
}
int main(void)
{
    int ok = try_alloc(PAGE_READWRITE, "write, then make executable")
           & try_alloc(PAGE_EXECUTE_READWRITE, "writable and executable at once");
    printf(ok ? "jit: ok\n" : "jit: FAILED\n");
    return !ok;
}
