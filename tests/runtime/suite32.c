/* 32-bit test suite for FineWine's relocated-window 32-bit mode.
 * Each check prints "ok" or "FAIL"; the exit status is the number of failures.
 * Nothing here shows a window: the one window made is message-only. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static int failures;
static void check( int ok, const char *what )
{
    printf( "%-4s %s\n", ok ? "ok" : "FAIL", what );
    fflush( stdout );
    if (!ok) failures++;
}

/* ---- threads ---- */
static CRITICAL_SECTION cs;
static volatile LONG atomic_counter;
static int locked_counter;
static DWORD tls_index;

static DWORD WINAPI worker( void *arg )
{
    int i, id = (int)(INT_PTR)arg;
    TlsSetValue( tls_index, (void *)(INT_PTR)(id * 1000) );
    for (i = 0; i < 20000; i++)
    {
        InterlockedIncrement( &atomic_counter );
        EnterCriticalSection( &cs );
        locked_counter++;
        LeaveCriticalSection( &cs );
    }
    return (DWORD)(INT_PTR)TlsGetValue( tls_index ) + 7;
}

static void test_threads(void)
{
    HANDLE threads[4], event;
    DWORD i, code, ok = 1;

    InitializeCriticalSection( &cs );
    tls_index = TlsAlloc();
    for (i = 0; i < 4; i++) threads[i] = CreateThread( NULL, 0, worker, (void *)(INT_PTR)(i + 1), 0, NULL );
    check( WaitForMultipleObjects( 4, threads, TRUE, 30000 ) == WAIT_OBJECT_0, "threads: four workers finish" );
    for (i = 0; i < 4; i++)
    {
        GetExitCodeThread( threads[i], &code );
        if (code != (i + 1) * 1000 + 7) ok = 0;
        CloseHandle( threads[i] );
    }
    check( ok, "threads: each returns its own TLS value" );
    check( atomic_counter == 80000, "threads: interlocked counter" );
    check( locked_counter == 80000, "threads: critical section counter" );

    event = CreateEventA( NULL, TRUE, FALSE, NULL );
    check( WaitForSingleObject( event, 10 ) == WAIT_TIMEOUT, "sync: unsignalled event times out" );
    SetEvent( event );
    check( WaitForSingleObject( event, 10 ) == WAIT_OBJECT_0, "sync: signalled event" );
    CloseHandle( event );
}

/* ---- exceptions ---- */
static volatile int veh_hits;
static volatile DWORD veh_code;
static void *fault_resume;

static LONG CALLBACK veh( EXCEPTION_POINTERS *info )
{
    veh_hits++;
    veh_code = info->ExceptionRecord->ExceptionCode;
    if (veh_code == EXCEPTION_ACCESS_VIOLATION && fault_resume)
    {
        info->ContextRecord->Eip = (DWORD)fault_resume;   /* skip the faulting store */
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (veh_code == 0xE0001234) return EXCEPTION_CONTINUE_EXECUTION;
    return EXCEPTION_CONTINUE_SEARCH;
}

static void __attribute__((noinline)) do_fault( volatile int *where )
{
    fault_resume = &&after;
    *where = 1;
after:
    fault_resume = NULL;
}

static void test_exceptions(void)
{
    void *handler = AddVectoredExceptionHandler( 1, veh );

    veh_hits = 0;
    RaiseException( 0xE0001234, 0, 0, NULL );
    check( veh_hits == 1 && veh_code == 0xE0001234, "exceptions: RaiseException reaches a vectored handler" );

    veh_hits = 0;
    do_fault( (volatile int *)8 );
    check( veh_hits == 1 && veh_code == EXCEPTION_ACCESS_VIOLATION, "exceptions: access violation is caught and resumed" );

    RemoveVectoredExceptionHandler( handler );
}

/* ---- memory ---- */
static void test_memory(void)
{
    MEMORY_BASIC_INFORMATION info;
    SYSTEM_INFO si;
    char *p, *big;
    HANDLE map;
    DWORD old;
    int stack_var;

    GetSystemInfo( &si );
    check( (ULONG_PTR)si.lpMaximumApplicationAddress < 0x80000000u, "memory: address space ends below 2 GB" );

    p = VirtualAlloc( NULL, 0x30000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    check( p != NULL, "memory: VirtualAlloc" );
    memset( p, 0x5a, 0x30000 );
    check( VirtualQuery( p + 0x1000, &info, sizeof(info) ) == sizeof(info) && info.AllocationBase == p
           && info.State == MEM_COMMIT && info.Protect == PAGE_READWRITE, "memory: VirtualQuery sees it" );
    check( VirtualProtect( p, 0x1000, PAGE_READONLY, &old ) && old == PAGE_READWRITE, "memory: VirtualProtect" );
    check( VirtualFree( p, 0, MEM_RELEASE ), "memory: VirtualFree" );

    p = VirtualAlloc( (void *)0x20000000, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    check( p == (void *)0x20000000, "memory: VirtualAlloc at a chosen address" );
    if (p) { p[0] = 1; VirtualFree( p, 0, MEM_RELEASE ); }

    big = malloc( 64 * 1024 * 1024 );
    check( big != NULL, "memory: 64 MB from the heap" );
    if (big) { memset( big, 1, 64 * 1024 * 1024 ); check( big[64 * 1024 * 1024 - 1] == 1, "memory: 64 MB written" ); free( big ); }

    map = CreateFileMappingA( INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 0x10000, NULL );
    p = map ? MapViewOfFile( map, FILE_MAP_ALL_ACCESS, 0, 0, 0 ) : NULL;
    check( p != NULL, "memory: file mapping" );
    if (p) { strcpy( p, "mapped" ); check( !strcmp( p, "mapped" ), "memory: file mapping written" ); UnmapViewOfFile( p ); }
    if (map) CloseHandle( map );

    check( VirtualQuery( &stack_var, &info, sizeof(info) ) && (char *)info.BaseAddress <= (char *)&stack_var, "memory: the stack is queryable" );
    check( (ULONG_PTR)GetModuleHandleA( NULL ) == 0x400000, "memory: the program is at its own base (0x400000)" );
}

/* ---- files, registry, environment ---- */
static void test_files(void)
{
    char dir[MAX_PATH], path[MAX_PATH], buffer[64] = {0};
    HANDLE file;
    DWORD done, type, size = sizeof(buffer);
    HKEY key;

    check( GetTempPathA( sizeof(dir), dir ) > 0, "files: temp path" );
    snprintf( path, sizeof(path), "%sfinewine32-%lu.tmp", dir, GetCurrentProcessId() );
    file = CreateFileA( path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL );
    check( file != INVALID_HANDLE_VALUE, "files: create" );
    check( WriteFile( file, "thirty-two", 10, &done, NULL ) && done == 10, "files: write" );
    SetFilePointer( file, 0, NULL, FILE_BEGIN );
    check( ReadFile( file, buffer, sizeof(buffer) - 1, &done, NULL ) && done == 10 && !strcmp( buffer, "thirty-two" ), "files: read back" );
    CloseHandle( file );
    check( DeleteFileA( path ), "files: delete" );

    check( !RegOpenKeyExA( HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows NT\\CurrentVersion", 0, KEY_READ, &key ), "registry: open" );
    memset( buffer, 0, sizeof(buffer) );
    check( !RegQueryValueExA( key, "CurrentVersion", NULL, &type, (BYTE *)buffer, &size ) && type == REG_SZ && buffer[0], "registry: read a value" );
    RegCloseKey( key );

    check( GetEnvironmentVariableA( "SystemRoot", buffer, sizeof(buffer) ) > 0, "environment: SystemRoot" );
#ifdef _WIN64
#error this is the 32-bit suite
#endif
    {
        BOOL wow = FALSE;
        check( IsWow64Process( GetCurrentProcess(), &wow ) && wow, "process: runs as a 32-bit program on 64-bit Windows" );
    }
}

/* ---- arithmetic the emulator has to get right ---- */
static void test_arithmetic(void)
{
    volatile double a = 2.0, b = 3.0;
    volatile long double la = 1.0L, lb = 3.0L;
    volatile unsigned long long big = 0x123456789abcdef0ull, div = 0x1000;
    volatile float f = 1.5f;
    char src[64], dst[64];
    int i;

    check( fabs( sqrt( a ) * sqrt( a ) - 2.0 ) < 1e-12, "math: sqrt (double)" );
    check( fabs( pow( a, b ) - 8.0 ) < 1e-12, "math: pow" );
    check( fabs( sin( 0.5 ) * sin( 0.5 ) + cos( 0.5 ) * cos( 0.5 ) - 1.0 ) < 1e-12, "math: sin and cos" );
    check( fabsl( la / lb * lb - 1.0L ) < 1e-15L, "math: long double (x87)" );
    check( (int)(f * 4.0f) == 6, "math: float to int" );
    check( big / div == 0x123456789abcdull && big % div == 0xef0, "math: 64-bit divide" );
    check( big * 3 == 0x369d0369d0369cd0ull, "math: 64-bit multiply" );

    for (i = 0; i < 64; i++) src[i] = (char)i;
    memcpy( dst, src, 64 );
    check( !memcmp( dst, src, 64 ), "strings: memcpy" );
    memmove( dst + 4, dst, 40 );
    check( dst[4] == 0 && dst[43] == 39 && dst[3] == 3, "strings: overlapping memmove" );
    memset( dst, 0x7f, 33 );
    check( dst[0] == 0x7f && dst[32] == 0x7f && dst[33] != 0x7f, "strings: memset" );
    check( strlen( "relocated window" ) == 16, "strings: strlen" );
}

/* ---- code written at run time ---- */
static void test_generated_code(void)
{
    /* mov eax, imm32; ret */
    unsigned char *code = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    int (*fn)(void) = (int (*)(void))code;
    int first, second, third, i, sum = 0;

    check( code != NULL, "generated code: executable memory" );
    if (!code) return;
    code[0] = 0xb8; *(int *)(code + 1) = 1111; code[5] = 0xc3;
    FlushInstructionCache( GetCurrentProcess(), code, 6 );
    first = fn();
    *(int *)(code + 1) = 2222;
    FlushInstructionCache( GetCurrentProcess(), code, 6 );
    second = fn();
    *(int *)(code + 1) = 3333;             /* no flush: Windows programs often don't */
    third = fn();
    check( first == 1111, "generated code: runs" );
    check( second == 2222, "generated code: changed and flushed" );
    check( third == 3333, "generated code: changed without a flush" );
    for (i = 0; i < 200; i++) { *(int *)(code + 1) = i; sum += fn(); }
    check( sum == 19900, "generated code: rewritten 200 times" );
    VirtualFree( code, 0, MEM_RELEASE );
}

/* ---- callbacks from the 64-bit side: a message-only window, never on screen ---- */
static int timer_ticks, got_user_message, enum_count;
static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_USER + 1) { got_user_message = (int)wp + (int)lp; return 4242; }
    if (msg == WM_TIMER) { if (++timer_ticks == 3) PostQuitMessage( 0 ); return 0; }
    if (msg == WM_COPYDATA)
    {
        COPYDATASTRUCT *data = (COPYDATASTRUCT *)lp;
        return data->dwData == 77 && data->cbData == 6 && !memcmp( data->lpData, "hello", 6 );
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static BOOL CALLBACK enum_proc( HWND hwnd, LPARAM lp )
{
    enum_count++;
    return lp == 0x1234;
}

static void test_window_messages(void)
{
    WNDCLASSA cls = {0};
    COPYDATASTRUCT data = { 77, 6, (void *)"hello" };
    char title[32] = {0};
    HWND hwnd;
    MSG msg;

    cls.lpfnWndProc = wndproc;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.lpszClassName = "FineWine32Test";
    check( RegisterClassA( &cls ) != 0, "window: register a class" );
    hwnd = CreateWindowExA( 0, "FineWine32Test", "message only", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, cls.hInstance, NULL );
    check( hwnd != NULL, "window: create a message-only window" );
    if (!hwnd) return;

    check( SendMessageA( hwnd, WM_USER + 1, 40, 2 ) == 4242 && got_user_message == 42, "window: SendMessage calls the window procedure" );
    check( GetWindowTextA( hwnd, title, sizeof(title) ) == 12 && !strcmp( title, "message only" ), "window: text comes back" );
    check( SendMessageA( hwnd, WM_COPYDATA, 0, (LPARAM)&data ) == 1, "window: a message carrying a pointer" );
    check( SetWindowLongPtrA( hwnd, GWLP_USERDATA, 0x12345678 ) == 0 && GetWindowLongPtrA( hwnd, GWLP_USERDATA ) == 0x12345678, "window: user data" );

    EnumThreadWindows( GetCurrentThreadId(), enum_proc, 0x1234 );
    check( enum_count >= 0, "window: EnumThreadWindows returns" );

    SetTimer( hwnd, 1, 10, NULL );
    while (GetMessageA( &msg, NULL, 0, 0 ) > 0) DispatchMessageA( &msg );
    check( timer_ticks == 3, "window: three timer messages through the message loop" );
    KillTimer( hwnd, 1 );
    check( DestroyWindow( hwnd ), "window: destroy" );
}

/* ---- a window on screen, with standard controls: a small one appears for a moment ---- */
static int painted, got_minmax, got_poschanged, got_command;
static HWND shown_edit;

static LRESULT CALLBACK shown_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_GETMINMAXINFO:
        if (((MINMAXINFO *)lp)->ptMaxTrackSize.x > 0) got_minmax = 1;
        break;
    case WM_WINDOWPOSCHANGED:
        if (((WINDOWPOS *)lp)->hwnd == hwnd) got_poschanged = 1;
        break;
    case WM_COMMAND:
        if ((HWND)lp == shown_edit && HIWORD(wp) == EN_CHANGE) got_command = 1;
        return 0;
    case WM_PAINT:
    {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint( hwnd, &ps );
        if (dc) { TextOutA( dc, 4, 4, "32-bit", 6 ); painted++; }
        EndPaint( hwnd, &ps );
        return 0;
    }
    case WM_TIMER:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void test_shown_window(void)
{
    WNDCLASSA cls = {0};
    char text[32] = {0};
    RECT rect = {0};
    HWND hwnd, list;
    MSG msg;

    cls.lpfnWndProc = shown_proc;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( NULL, (const char *)IDC_ARROW );
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    cls.lpszClassName = "FineWine32Shown";
    RegisterClassA( &cls );
    hwnd = CreateWindowExA( 0, "FineWine32Shown", "FineWine 32-bit check", WS_OVERLAPPEDWINDOW,
                            60, 60, 260, 160, NULL, NULL, cls.hInstance, NULL );
    check( hwnd != NULL, "shown window: create" );
    if (!hwnd) return;
    check( got_minmax, "shown window: WM_GETMINMAXINFO carried its structure" );

    shown_edit = CreateWindowExA( WS_EX_CLIENTEDGE, "EDIT", "", WS_CHILD | WS_VISIBLE, 8, 30, 120, 22, hwnd, (HMENU)10, cls.hInstance, NULL );
    list = CreateWindowExA( WS_EX_CLIENTEDGE, "LISTBOX", "", WS_CHILD | WS_VISIBLE, 8, 60, 120, 50, hwnd, (HMENU)11, cls.hInstance, NULL );
    check( shown_edit && list, "shown window: edit and list box controls" );

    ShowWindow( hwnd, SW_SHOWNOACTIVATE );
    UpdateWindow( hwnd );
    check( painted > 0, "shown window: painted" );
    check( IsWindowVisible( hwnd ) && GetClientRect( hwnd, &rect ) && rect.right > 100, "shown window: visible, with a client area" );

    check( SetWindowTextA( shown_edit, "typed text" ) && GetWindowTextA( shown_edit, text, sizeof(text) ) == 10
           && !strcmp( text, "typed text" ), "shown window: edit control keeps its text" );
    check( got_command, "shown window: the edit control told its parent" );
    SendMessageA( list, LB_ADDSTRING, 0, (LPARAM)"first" );
    SendMessageA( list, LB_ADDSTRING, 0, (LPARAM)"second" );
    text[0] = 0;
    check( SendMessageA( list, LB_GETCOUNT, 0, 0 ) == 2 && SendMessageA( list, LB_GETTEXT, 1, (LPARAM)text ) == 6
           && !strcmp( text, "second" ), "shown window: list box strings" );
    check( SendMessageA( list, LB_GETITEMRECT, 0, (LPARAM)&rect ) != LB_ERR && rect.bottom > rect.top, "shown window: list box item rectangle" );

    got_poschanged = 0;
    SetWindowPos( hwnd, NULL, 80, 80, 280, 170, SWP_NOZORDER | SWP_NOACTIVATE );
    check( got_poschanged && GetWindowRect( hwnd, &rect ) && rect.right - rect.left == 280, "shown window: moved and resized" );

    SetTimer( hwnd, 1, 400, NULL );
    while (GetMessageA( &msg, NULL, 0, 0 ) > 0) { TranslateMessage( &msg ); DispatchMessageA( &msg ); }
    check( DestroyWindow( hwnd ), "shown window: destroy" );
}

/* ---- drawing, off screen ---- */
static void test_gdi(void)
{
    BITMAPINFO bmi = {0};
    DWORD *bits = NULL;
    HDC dc = CreateCompatibleDC( NULL );
    HBITMAP bitmap;
    HBRUSH brush;
    RECT rect = { 2, 2, 6, 6 };

    check( dc != NULL, "gdi: memory DC" );
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = 8;
    bmi.bmiHeader.biHeight = -8;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bitmap = CreateDIBSection( dc, &bmi, DIB_RGB_COLORS, (void **)&bits, NULL, 0 );
    check( bitmap != NULL && bits != NULL, "gdi: DIB section with its pixels mapped" );
    if (!bitmap) return;
    SelectObject( dc, bitmap );
    brush = CreateSolidBrush( RGB(255, 0, 0) );
    FillRect( dc, &rect, brush );
    GdiFlush();
    check( (bits[3 * 8 + 3] & 0xffffff) == 0xff0000 && (bits[0] & 0xffffff) == 0, "gdi: FillRect drew into the pixels" );
    check( GetPixel( dc, 3, 3 ) == RGB(255, 0, 0), "gdi: GetPixel" );
    DeleteObject( brush );
    DeleteDC( dc );
    DeleteObject( bitmap );
}

/* ---- another 32-bit process ---- */
static void test_child_process( const char *self )
{
    char cmd[MAX_PATH + 16];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 0;

    snprintf( cmd, sizeof(cmd), "\"%s\" child", self );
    check( CreateProcessA( NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ), "process: start another 32-bit program" );
    check( WaitForSingleObject( pi.hProcess, 60000 ) == WAIT_OBJECT_0, "process: it finishes" );
    GetExitCodeProcess( pi.hProcess, &code );
    check( code == 99, "process: its exit status comes back" );
    CloseHandle( pi.hProcess );
    CloseHandle( pi.hThread );
}

int main( int argc, char **argv )
{
    if (argc > 1 && !strcmp( argv[1], "child" )) return 99;

    test_arithmetic();
    test_memory();
    test_files();
    test_threads();
    test_exceptions();
    test_generated_code();
    if (argc > 1 && !strcmp( argv[1], "nogui" )) printf( "skip window and gdi checks\n" );
    else { test_window_messages(); test_shown_window(); test_gdi(); }
    test_child_process( argv[0] );

    printf( "%d failure(s)\n", failures );
    return failures;
}
