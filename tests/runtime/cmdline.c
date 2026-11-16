/* Writes its own command line to cmdline.txt beside itself. Used to check that a program which
 * merely lives in a folder with Chromium in it is started with the command line it was given. */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    char path[MAX_PATH], *p;
    FILE *f;

    GetModuleFileNameA(NULL, path, MAX_PATH);
    if ((p = strrchr(path, '\\'))) strcpy(p + 1, "cmdline.txt");
    if (!(f = fopen(path, "w"))) return 1;
    fputs(GetCommandLineA(), f);
    fclose(f);
    return 0;
}
