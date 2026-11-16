/* Does what an installer does with a helper: starts the program beside it that is named on the
 * command line, waits for it, and reports its exit code. */
#include <windows.h>
#include <stdio.h>

int wmain(int argc, WCHAR **argv)
{
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 99999;
    WCHAR cmd[1024], dir[MAX_PATH], *p;

    if (argc < 2) return 2;
    GetModuleFileNameW(NULL, dir, MAX_PATH);
    if ((p = wcsrchr(dir, '\\'))) *p = 0;
    swprintf(cmd, 1024, L"\"%ls\\%ls\" /install /quiet /norestart", dir, argv[1]);
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    {
        printf("could not start: error %lu\n", GetLastError());
        return 1;
    }
    WaitForSingleObject(pi.hProcess, 60000);
    GetExitCodeProcess(pi.hProcess, &code);
    printf("started, exit code %lu\n", code);
    return 0;
}
