#include <windows.h>
#include <stdio.h>
int main(void)
{
    SYSTEM_INFO si; GetNativeSystemInfo(&si);
    volatile double x = 1.5; volatile int n = 0;
    for (int i = 1; i <= 1000; i++) n += i;
    printf("hello from x64: sum=%d, 1.5*2=%.1f, pid=%lu, tick=%lu\n", n, x * 2, GetCurrentProcessId(), (unsigned long)(GetTickCount() != 0));
    return 0;
}
