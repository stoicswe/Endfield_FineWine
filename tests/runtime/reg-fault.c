/* CPU state must survive the faults the emulator takes to commit its own memory.
 *
 * FEX commits its lookup tables, call-return stacks and compile buffers in its fault handler
 * (patches/fex/0005 and 0007), so a thread can fault in the middle of translated code, at an
 * indirect call for instance, and is continued from the saved context. Every thread here loads
 * known values into the general registers, xmm0-15, the flags, the x87 stack and MXCSR, calls a
 * function it has not called before (2048 of them, a page apart, so each call reaches new parts
 * of the thread's tables), and compares everything afterwards. 192 threads in six rounds.
 * Prints "reg-fault: ok calls N ..." or "reg-fault: BAD" with a count for each kind of state. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <malloc.h>

#define THREADS 32
#define ROUNDS 6
#define STUBS 2048
struct table { unsigned long long gpr[16]; unsigned char xmm[16][16]; unsigned char fa[16], fb[16], sa[16], sb[16]; };
extern unsigned probe(void *stub, struct table *t);
#define G(off, reg) "cmp " #off "(%rdx),%" #reg "\n je 1f\n orl $1,176(%rsp)\n1:\n"
#define X(i) "pcmpeqb " #i "*16+128(%rdx),%xmm" #i "\n pmovmskb %xmm" #i ",%eax\n cmp $0xffff,%eax\n je 1f\n orl $2,176(%rsp)\n1:\n"
#define L(i) "movdqu " #i "*16+128(%rdx),%xmm" #i "\n"
__asm__(".text\n.globl probe\nprobe:\n"
 "push %rbx\n push %rbp\n push %rsi\n push %rdi\n push %r12\n push %r13\n push %r14\n push %r15\n"
 "sub $184,%rsp\n"
 "movdqu %xmm6,0(%rsp)\n movdqu %xmm7,16(%rsp)\n movdqu %xmm8,32(%rsp)\n movdqu %xmm9,48(%rsp)\n movdqu %xmm10,64(%rsp)\n"
 "movdqu %xmm11,80(%rsp)\n movdqu %xmm12,96(%rsp)\n movdqu %xmm13,112(%rsp)\n movdqu %xmm14,128(%rsp)\n movdqu %xmm15,144(%rsp)\n"
 "mov %rdx,160(%rsp)\n mov %rcx,%rax\n movl $0,176(%rsp)\n"
 "fninit\n fldt 384(%rdx)\n fldt 400(%rdx)\n"
 "movl $0x3f80,168(%rsp)\n ldmxcsr 168(%rsp)\n"
 L(0) L(1) L(2) L(3) L(4) L(5) L(6) L(7) L(8) L(9) L(10) L(11) L(12) L(13) L(14) L(15)
 "mov 0(%rdx),%rbx\n mov 8(%rdx),%rbp\n mov 16(%rdx),%rsi\n mov 24(%rdx),%rdi\n mov 32(%rdx),%r8\n mov 40(%rdx),%r9\n"
 "mov 48(%rdx),%r10\n mov 56(%rdx),%r11\n mov 64(%rdx),%r12\n mov 72(%rdx),%r13\n mov 80(%rdx),%r14\n mov 88(%rdx),%r15\n mov 96(%rdx),%rcx\n"
 "cmp %rbx,%rbx\n stc\n"
 "call *%rax\n"
 "pushfq\n pop %rax\n and $0x8d5,%eax\n cmp $0x45,%eax\n je 1f\n orl $4,176(%rsp)\n1:\n"
 "cmp 160(%rsp),%rdx\n je 1f\n orl $1,176(%rsp)\n1:\n mov 160(%rsp),%rdx\n"
 G(0,rbx) G(8,rbp) G(16,rsi) G(24,rdi) G(32,r8) G(40,r9) G(48,r10) G(56,r11) G(64,r12) G(72,r13) G(80,r14) G(88,r15) G(96,rcx)
 X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7) X(8) X(9) X(10) X(11) X(12) X(13) X(14) X(15)
 "stmxcsr 168(%rsp)\n mov 168(%rsp),%eax\n and $0xffc0,%eax\n cmp $0x3f80,%eax\n je 1f\n orl $16,176(%rsp)\n1:\n"
 "fstpt 432(%rdx)\n fstpt 416(%rdx)\n"
 "mov 432(%rdx),%rax\n cmp 400(%rdx),%rax\n jne 2f\n movzwl 440(%rdx),%eax\n cmp 408(%rdx),%ax\n jne 2f\n"
 "mov 416(%rdx),%rax\n cmp 384(%rdx),%rax\n jne 2f\n movzwl 424(%rdx),%eax\n cmp 392(%rdx),%ax\n je 1f\n2:\n orl $8,176(%rsp)\n1:\n"
 "movl $0x1f80,168(%rsp)\n ldmxcsr 168(%rsp)\n fninit\n"
 "movdqu 0(%rsp),%xmm6\n movdqu 16(%rsp),%xmm7\n movdqu 32(%rsp),%xmm8\n movdqu 48(%rsp),%xmm9\n movdqu 64(%rsp),%xmm10\n"
 "movdqu 80(%rsp),%xmm11\n movdqu 96(%rsp),%xmm12\n movdqu 112(%rsp),%xmm13\n movdqu 128(%rsp),%xmm14\n movdqu 144(%rsp),%xmm15\n"
 "mov 176(%rsp),%eax\n add $184,%rsp\n"
 "pop %r15\n pop %r14\n pop %r13\n pop %r12\n pop %rdi\n pop %rsi\n pop %rbp\n pop %rbx\n ret\n");

static unsigned char *code;
static volatile LONG kinds[5], total;

static DWORD WINAPI worker(void *arg)
{
    struct table *t = _aligned_malloc(sizeof(*t), 16);
    unsigned long long s = 0x9e3779b97f4a7c15ull * ((ULONG_PTR)arg + 1);
    unsigned char *b = (unsigned char *)t;
    for (size_t i = 0; i < sizeof(*t); i++) { s = s * 6364136223846793005ull + 1442695040888963407ull; b[i] = s >> 56; }
    memset(t->fa, 0, 16); memset(t->fb, 0, 16);
    /* two valid 80-bit numbers: explicit integer bit set, ordinary exponents */
    *(unsigned long long *)t->fa = 0xc90fdaa22168c235ull ^ (ULONG_PTR)arg; t->fa[7] |= 0x80; *(unsigned short *)(t->fa + 8) = 0x4000;
    *(unsigned long long *)t->fb = 0xb17217f7d1cf79abull + (ULONG_PTR)arg; t->fb[7] |= 0x80; *(unsigned short *)(t->fb + 8) = 0xbffe;
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < STUBS; i++)
        {
            unsigned r = probe(code + (size_t)i * 4096 + (i % 61) * 16, t);
            InterlockedIncrement(&total);
            for (int k = 0; k < 5; k++) if (r & (1u << k)) InterlockedIncrement(&kinds[k]);
        }
    _aligned_free(t);
    return 0;
}

int main(void)
{
    code = VirtualAlloc(NULL, (size_t)STUBS * 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    for (int i = 0; i < STUBS; i++) code[(size_t)i * 4096 + (i % 61) * 16] = 0xc3;
    FlushInstructionCache(GetCurrentProcess(), code, (size_t)STUBS * 4096);
    for (int r = 0; r < ROUNDS; r++)
    {
        HANDLE h[THREADS];
        for (int i = 0; i < THREADS; i++) h[i] = CreateThread(NULL, 0, worker, (void *)(ULONG_PTR)(r * THREADS + i), 0, NULL);
        WaitForMultipleObjects(THREADS, h, TRUE, INFINITE);
        for (int i = 0; i < THREADS; i++) CloseHandle(h[i]);
    }
    printf("reg-fault: %s calls %ld gpr %ld xmm %ld flags %ld x87 %ld mxcsr %ld\n",
           (kinds[0] | kinds[1] | kinds[2] | kinds[3] | kinds[4]) ? "BAD" : "ok", total, kinds[0], kinds[1], kinds[2], kinds[3], kinds[4]);
    return 0;
}
