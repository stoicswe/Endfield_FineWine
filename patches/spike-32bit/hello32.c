/* The smallest 32-bit Windows console program: no C runtime, two kernel32 calls. */
#include <windows.h>
void entry(void)
{
    static const char text[] = "hello from 32-bit x86\r\n";
    DWORD written;
    WriteFile( GetStdHandle( STD_OUTPUT_HANDLE ), text, sizeof(text) - 1, &written, NULL );
    ExitProcess( written == sizeof(text) - 1 ? 0 : 3 );
}
