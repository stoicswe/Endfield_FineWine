/* bench.c: where the time goes in the FineWine stack.
 *
 * The same small workloads built four ways, so that each layer's cost can be read off by
 * comparing columns: a native Mac program (the hardware), an x86_64 Mac program (Rosetta, for
 * reference), a Windows ARM64 program (Wine alone) and a Windows x64 program (Wine and FEX).
 * The CPU tests are the same code everywhere; the Windows-only ones time system calls and
 * synchronisation. Prints one line per test, in milliseconds; lower is better.
 * Run by scripts/bench-finewine-runtime.sh. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#ifdef _WIN32
#include <windows.h>
static double now_ms(void) { LARGE_INTEGER c, f; QueryPerformanceCounter(&c); QueryPerformanceFrequency(&f); return 1000.0 * (double)c.QuadPart / (double)f.QuadPart; }
typedef HANDLE thread_t;
#define THREAD_FN(name) static DWORD WINAPI name(void *arg)
#define THREAD_RET return 0
static thread_t start_thread(LPTHREAD_START_ROUTINE fn, void *arg) { return CreateThread(NULL, 0, fn, arg, 0, NULL); }
static void join_thread(thread_t t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
#else
#include <pthread.h>
#include <time.h>
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000.0 + t.tv_nsec / 1e6; }
typedef pthread_t thread_t;
#define THREAD_FN(name) static void *name(void *arg)
#define THREAD_RET return NULL
static thread_t start_thread(void *(*fn)(void *), void *arg) { pthread_t t; pthread_create(&t, NULL, fn, arg); return t; }
static void join_thread(thread_t t) { pthread_join(t, NULL); }
#endif

static volatile uint64_t sink;
#define REPORT(name, t0) printf("%-34s %9.1f ms\n", name, now_ms() - (t0))

/* Integer work with data-dependent branches. */
static void bench_integer(void)
{
    enum { N = 4000000 }; uint8_t *sieve = malloc(N); uint64_t count = 0;
    double t0 = now_ms();
    for (int rep = 0; rep < 6; rep++) {
        memset(sieve, 1, N);
        for (uint32_t i = 2; i * i < N; i++) if (sieve[i]) for (uint32_t j = i * i; j < N; j += i) sieve[j] = 0;
        for (uint32_t i = 2; i < N; i++) count += sieve[i];
    }
    sink = count; REPORT("integer (sieve)", t0); free(sieve);
}

/* Hashing: shifts, multiplies, no memory traffic. */
static void bench_hash(void)
{
    uint64_t h = 1469598103934665603ull; double t0 = now_ms();
    for (uint64_t i = 0; i < 300000000ull; i++) { h ^= i; h *= 1099511628211ull; h ^= h >> 29; }
    sink = h; REPORT("integer (hash loop)", t0);
}

/* Double-precision floating point. */
static void bench_float(void)
{
    enum { N = 220 }; static double a[N][N], b[N][N], c[N][N];
    for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) { a[i][j] = i * 0.5 + j; b[i][j] = i - j * 0.25; }
    double t0 = now_ms();
    for (int rep = 0; rep < 6; rep++)
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) { double s = 0; for (int k = 0; k < N; k++) s += a[i][k] * b[k][j]; c[i][j] = s; }
    sink = (uint64_t)c[N / 2][N / 2]; REPORT("floating point (matrix multiply)", t0);
}

/* The maths library: square roots, sines, as a game's physics or animation code would. */
static void bench_libm(void)
{
    double s = 0; double t0 = now_ms();
    for (int i = 1; i < 20000000; i++) s += sqrt((double)i) * sin(i * 0.001) + cosf(i * 0.002f);
    sink = (uint64_t)s; REPORT("maths library (sqrt, sin, cos)", t0);
}

/* Memory bandwidth and a cache-hostile pointer chase. */
static void bench_memory(void)
{
    enum { N = 64 << 20 }; char *a = malloc(N), *b = malloc(N);
    memset(a, 1, N); memset(b, 2, N);
    double t0 = now_ms();
    uint64_t sum = 0;
    for (int rep = 0; rep < 12; rep++) { memcpy(a, b, N); sum += (unsigned char)a[(rep * 4099) % N]; memset(b, rep, N); sum += (unsigned char)b[(rep * 8191) % N]; sink = sum; }
    REPORT("memory (copy and fill 64 MB)", t0);
    enum { M = 1 << 22 }; uint32_t *next = malloc(M * sizeof(*next)); uint32_t x = 12345;
    for (uint32_t i = 0; i < M; i++) next[i] = i;
    for (uint32_t i = M - 1; i > 0; i--) { x = x * 1664525u + 1013904223u; uint32_t j = x % i; uint32_t t = next[i]; next[i] = next[j]; next[j] = t; }
    t0 = now_ms(); uint32_t p = 0;
    for (int i = 0; i < 20000000; i++) p = next[p];
    sink = p; REPORT("memory (pointer chase)", t0); free(a); free(b); free(next);
}

/* Calls through pointers: what virtual calls and script interpreters do, and what a binary
 * translator finds hardest. */
typedef uint64_t (*op_fn)(uint64_t);
static uint64_t op_a(uint64_t v) { return v * 3 + 1; }
static uint64_t op_b(uint64_t v) { return v ^ (v >> 7); }
static uint64_t op_c(uint64_t v) { return v + 0x9e3779b9; }
static uint64_t op_d(uint64_t v) { return (v << 5) | (v >> 59); }
static void bench_calls(void)
{
    op_fn volatile table[4] = { op_a, op_b, op_c, op_d }; uint64_t v = 1; double t0 = now_ms();
    for (uint32_t i = 0; i < 200000000u; i++) v = table[(i ^ (uint32_t)v) & 3](v);
    sink = v; REPORT("indirect calls", t0);
}

/* Atomic operations, alone and fought over by four threads. On x64 every one of these is a
 * locked instruction, which the translator has to make atomic on ARM. */
static volatile long shared_counter;
static uint32_t padded[4 * 16];
THREAD_FN(atomic_worker)
{
    for (int i = 0; i < 20000000; i++) {
#ifdef _WIN32
        InterlockedIncrement(&shared_counter);
#else
        __sync_fetch_and_add(&shared_counter, 1);
#endif
    }
    THREAD_RET;
}
/* Four threads, each writing its own memory: plain stores, which is where emulating x86's
 * memory ordering costs, if it is being emulated. */
THREAD_FN(store_worker)
{
    volatile uint32_t *mine = (volatile uint32_t *)arg; uint32_t x = 1;
    for (int i = 0; i < 200000000; i++) { x = x * 1664525u + 1013904223u; *mine = x; x += *mine; }
    THREAD_RET;
}
static void bench_atomics(void)
{
    double t0 = now_ms(); atomic_worker(NULL); REPORT("atomics (one thread)", t0);
    thread_t t[4]; t0 = now_ms();
    for (int i = 0; i < 4; i++) t[i] = start_thread(atomic_worker, NULL);
    for (int i = 0; i < 4; i++) join_thread(t[i]);
    REPORT("atomics (four threads, contended)", t0);
    t0 = now_ms();
    for (int i = 0; i < 4; i++) t[i] = start_thread(store_worker, &padded[i * 16]);
    for (int i = 0; i < 4; i++) join_thread(t[i]);
    REPORT("plain loads and stores (4 threads)", t0);
}

#ifdef _WIN32
/* Two threads handing a baton back and forth with events: how game engines wake workers. */
static HANDLE ping, pong; enum { ROUNDS = 100000 };
THREAD_FN(ponger) { for (int i = 0; i < ROUNDS; i++) { WaitForSingleObject(ping, INFINITE); SetEvent(pong); } THREAD_RET; }
static void bench_sync(void)
{
    ping = CreateEventW(NULL, FALSE, FALSE, NULL); pong = CreateEventW(NULL, FALSE, FALSE, NULL);
    thread_t t = start_thread(ponger, NULL); double t0 = now_ms();
    for (int i = 0; i < ROUNDS; i++) { SetEvent(ping); WaitForSingleObject(pong, INFINITE); }
    REPORT("events (100k round trips)", t0); join_thread(t);

    HANDLE mutex = CreateMutexW(NULL, FALSE, NULL), sem = CreateSemaphoreW(NULL, 1, 1, NULL); t0 = now_ms();
    for (int i = 0; i < 1000000; i++) { WaitForSingleObject(mutex, INFINITE); ReleaseMutex(mutex); }
    REPORT("mutex (1M uncontended)", t0); t0 = now_ms();
    for (int i = 0; i < 1000000; i++) { WaitForSingleObject(sem, INFINITE); ReleaseSemaphore(sem, 1, NULL); }
    REPORT("semaphore (1M uncontended)", t0);
    CRITICAL_SECTION cs; InitializeCriticalSection(&cs); t0 = now_ms();
    for (int i = 0; i < 20000000; i++) { EnterCriticalSection(&cs); LeaveCriticalSection(&cs); }
    REPORT("critical section (20M)", t0);
    SRWLOCK srw = SRWLOCK_INIT; t0 = now_ms();
    for (int i = 0; i < 20000000; i++) { AcquireSRWLockExclusive(&srw); ReleaseSRWLockExclusive(&srw); }
    REPORT("SRW lock (20M)", t0);
}

/* Calls into Windows: timers a game reads every frame, and calls that have to reach Wine's
 * Unix side or its server. */
static void bench_system(void)
{
    LARGE_INTEGER c; uint64_t s = 0; double t0 = now_ms();
    for (int i = 0; i < 5000000; i++) { QueryPerformanceCounter(&c); s += c.QuadPart; }
    REPORT("QueryPerformanceCounter (5M)", t0); t0 = now_ms();
    for (int i = 0; i < 5000000; i++) s += GetTickCount64();
    REPORT("GetTickCount64 (5M)", t0); t0 = now_ms();
    for (int i = 0; i < 200000; i++) { void *p = VirtualAlloc(NULL, 65536, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); *(char *)p = 1; VirtualFree(p, 0, MEM_RELEASE); }
    REPORT("VirtualAlloc and free (200k)", t0); t0 = now_ms();
    for (int i = 0; i < 2000000; i++) { void *p = HeapAlloc(GetProcessHeap(), 0, 64 + (i & 255)); HeapFree(GetProcessHeap(), 0, p); }
    REPORT("heap alloc and free (2M)", t0); t0 = now_ms();
    for (int i = 0; i < 300000; i++) { HANDLE e = CreateEventW(NULL, FALSE, FALSE, NULL); CloseHandle(e); }
    REPORT("create and close a handle (300k)", t0); t0 = now_ms();
    for (int i = 0; i < 1000000; i++) SwitchToThread();
    REPORT("SwitchToThread (1M)", t0);
    char path[MAX_PATH], buf[4096]; GetTempPathA(sizeof(path), path); strcat(path, "finewine-bench.tmp");
    HANDLE f = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, NULL); DWORD n;
    memset(buf, 7, sizeof(buf)); t0 = now_ms();
    for (int i = 0; i < 100000; i++) { SetFilePointer(f, 0, NULL, FILE_BEGIN); WriteFile(f, buf, sizeof(buf), &n, NULL); SetFilePointer(f, 0, NULL, FILE_BEGIN); ReadFile(f, buf, sizeof(buf), &n, NULL); }
    REPORT("file write and read 4 KB (100k)", t0); CloseHandle(f);
    sink = s;
}

/* Code that is generated and then run, over and over: what a game's script JIT, or a .NET
 * runtime, does. Each round writes new code into a writable and executable page and calls it. */
static void bench_jit(void)
{
    unsigned char *page = VirtualAlloc(NULL, 65536, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!page) { printf("%-34s unavailable\n", "generated code (20k rewrites)"); return; }
    double t0 = now_ms(); uint64_t s = 0;
    for (uint32_t i = 0; i < 20000; i++) {
#if defined(_M_X64) || defined(__x86_64__) || defined(_M_IX86) || defined(__i386__)
        page[0] = 0xB8; memcpy(page + 1, &i, 4); page[5] = 0xC3;                       /* mov eax, i; ret */
#else
        uint32_t code[2] = { 0x52800000u | ((i & 0xFFFF) << 5), 0xD65F03C0u };         /* movz w0, #i; ret */
        memcpy(page, code, sizeof(code));
#endif
        FlushInstructionCache(GetCurrentProcess(), page, 16);
        s += ((uint32_t (*)(void))page)();
    }
    sink = s; REPORT("generated code (20k rewrites)", t0);
}
#endif

/* With an argument, runs only the group of tests of that name. */
int main(int argc, char **argv)
{
    const char *only = argc > 1 ? argv[1] : NULL;
#define GROUP(name, fn) if (!only || !strcmp(only, name)) fn()
    setvbuf(stdout, NULL, _IONBF, 0);
    GROUP("integer", bench_integer); GROUP("hash", bench_hash); GROUP("float", bench_float); GROUP("libm", bench_libm);
    GROUP("memory", bench_memory); GROUP("calls", bench_calls); GROUP("atomics", bench_atomics);
#ifdef _WIN32
    GROUP("system", bench_system); GROUP("sync", bench_sync); GROUP("jit", bench_jit);
#endif
    return 0;
}
