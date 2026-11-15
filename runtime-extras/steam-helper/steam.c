/*
 * FineWine's stand-in for the Steam client.
 *
 * Some games only start when they find Steam running, which is how they are run on Linux
 * (Proton starts every game through a helper of this name). This does the part of that
 * helper a game can see: the objects and registry values a running Steam client leaves, and
 * the variables Steam gives a game. It is not Steam and provides none of its services.
 *
 * Usage: steam.exe <program> [arguments]. Runs the program and stays for as long as it, or
 * anything it started, is running.
 *
 * Written for FineWine after the behaviour of Proton's steam_helper (Valve, BSD 3-clause).
 */

#include <windows.h>
#include <winternl.h>
#include <wchar.h>

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#endif

#define STEAM_DIR L"C:\\Program Files (x86)\\Steam"

static DWORD WINAPI steam_windows(void *arg)
{
    WNDCLASSEXW cls = { sizeof(cls) };
    MSG msg;

    cls.lpfnWndProc = DefWindowProcW;
    cls.lpszClassName = L"vguiPopupWindow";
    RegisterClassExW(&cls);
    /* Never shown; programs look it up by class and title. */
    CreateWindowW(cls.lpszClassName, L"Steam", WS_POPUP, 40, 40, 400, 300, NULL, NULL, NULL, NULL);
    while (GetMessageW(&msg, NULL, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

static void set_string(HKEY key, const WCHAR *name, const WCHAR *value)
{
    RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
}

static void steam_registry(void)
{
    DWORD pid = GetCurrentProcessId();
    HKEY key;

    if (!RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL))
    {
        set_string(key, L"SteamPath", L"c:/program files (x86)/steam");
        set_string(key, L"SteamExe", L"c:/program files (x86)/steam/steam.exe");
        RegCloseKey(key);
    }
    RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", L"pid", REG_DWORD, &pid, sizeof(pid));
}

/* The command line after this program's own name. */
static WCHAR *rest_of_command_line(void)
{
    WCHAR *p = GetCommandLineW();
    BOOL quoted = FALSE;

    while (*p && (quoted || (*p != ' ' && *p != '\t')))
    {
        if (*p == '"') quoted = !quoted;
        p++;
    }
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, WCHAR *unused, int show)
{
    WCHAR path[MAX_PATH] = L"", *p, *cmdline;
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    HANDLE all_exited = NULL;
    DWORD rc = 1;

    cmdline = rest_of_command_line();
    if (!*cmdline) return 2;

    /* What a running Steam client holds. */
    CreateEventW(NULL, FALSE, FALSE, L"Steam3Master_SharedMemLock");
    CreateEventW(NULL, FALSE, FALSE, L"Global\\Valve_SteamIPC_Class");
    GetDesktopWindow();
    CreateThread(NULL, 0, steam_windows, NULL, 0, NULL);
    steam_registry();

    /* What Steam gives a game it starts. The ids come from whoever started us. */
    SetEnvironmentVariableW(L"SteamPath", STEAM_DIR);
    GetModuleFileNameW(NULL, path, ARRAY_SIZE(path));
    for (p = path; *p; p++) if (*p == '\\') *p = '/';
    SetEnvironmentVariableW(L"ValvePlatformMutex", path);

    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return 1;
    CloseHandle(pi.hThread);

    /* Become a system process: Wine then gives an event that is set when no ordinary program
     * is left, so a game started by a launcher that exits still finds us. */
    NtSetInformationProcess(GetCurrentProcess(), 1000 /* ProcessWineMakeProcessSystem */,
                            &all_exited, sizeof(HANDLE *));

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &rc);
    CloseHandle(pi.hProcess);
    if (all_exited) WaitForSingleObject(all_exited, INFINITE);
    return (int)rc;
}
