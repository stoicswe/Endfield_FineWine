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

/* Not in every compiler's headers. */
typedef struct
{
    UNICODE_STRING ObjectName;
    UNICODE_STRING ObjectTypeName;
} STEAM_DIRECTORY_ENTRY;
NTSTATUS WINAPI NtOpenDirectoryObject(HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr);
NTSTATUS WINAPI NtQueryDirectoryObject(HANDLE handle, void *buffer, ULONG size, BOOLEAN single, BOOLEAN restart,
                                       ULONG *context, ULONG *ret_size);

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

/* Steam's own files that programs look at: the list of game libraries. The stand-in has one
 * library, the Steam folder itself. A file that is already there is left alone. */
static void steam_files(void)
{
    static const char folders[] = "\"LibraryFolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\"\n\t}\n}\n";
    HANDLE file;
    DWORD written;

    CreateDirectoryW(STEAM_DIR L"\\config", NULL);
    CreateDirectoryW(STEAM_DIR L"\\steamapps", NULL);
    file = CreateFileW(STEAM_DIR L"\\steamapps\\libraryfolders.vdf", GENERIC_WRITE, 0, NULL, CREATE_NEW, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, folders, sizeof(folders) - 1, &written, NULL);
    CloseHandle(file);
}

/* Xbox Game Studios titles run GamingRepair.exe, which takes about 20 seconds and cannot
 * succeed here, unless this value says it already has. Only for a numeric Steam id. */
static void gaming_repair_done(void)
{
    WCHAR id[32], path[96];
    DWORD done = 1, i, len = GetEnvironmentVariableW(L"SteamGameId", id, ARRAY_SIZE(id));

    if (!len || len >= ARRAY_SIZE(id)) return;
    for (i = 0; i < len; i++) if (id[i] < '0' || id[i] > '9') return;
    swprintf(path, ARRAY_SIZE(path), L"SOFTWARE\\Valve\\Steam\\Apps\\%ls", id);
    RegSetKeyValueW(HKEY_LOCAL_MACHINE, path, L"GamingRepair", REG_DWORD, &done, sizeof(done));
}

/* A program wrapped in Steam's own copy protection asks the client to acknowledge its start
 * through two semaphores and an event whose name begins STEAM_START_ACK_EVENT. This answers
 * as the client does. (The misspelt second name is the real one.) */
static HANDLE find_ack_event(void)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attr;
    char buffer[1024];
    STEAM_DIRECTORY_ENTRY *info = (STEAM_DIRECTORY_ENTRY *)buffer;
    HANDLE dir, event = NULL;
    ULONG context = 0, size;
    NTSTATUS status;

    RtlInitUnicodeString(&name, L"\\BaseNamedObjects\\Session\\1");
    InitializeObjectAttributes(&attr, &name, 0, 0, NULL);
    if (NtOpenDirectoryObject(&dir, 1 /* DIRECTORY_QUERY */, &attr)) return NULL;
    status = NtQueryDirectoryObject(dir, info, sizeof(buffer), TRUE, TRUE, &context, &size);
    while (!status)
    {
        if (info->ObjectName.Length >= 21 * sizeof(WCHAR) && !wcsncmp(info->ObjectName.Buffer, L"STEAM_START_ACK_EVENT", 21))
        {
            event = OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE, info->ObjectName.Buffer);
            break;
        }
        status = NtQueryDirectoryObject(dir, info, sizeof(buffer), TRUE, FALSE, &context, &size);
    }
    CloseHandle(dir);
    return event;
}

static DWORD WINAPI steam_start_ack(void *arg)
{
    HANDLE consume = CreateSemaphoreW(NULL, 0, 512, L"STEAM_DIPC_CONSUME");
    HANDLE produce = CreateSemaphoreW(NULL, 1, 512, L"SREAM_DIPC_PRODUCE");
    HANDLE ack = NULL;

    if (!consume || !produce) return 1;
    while (WaitForSingleObject(consume, INFINITE) == WAIT_OBJECT_0)
    {
        if (!ack) ack = find_ack_event();
        if (ack) SetEvent(ack);
        ReleaseSemaphore(produce, 1, NULL);
    }
    return 0;
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
    steam_files();
    gaming_repair_done();
    CreateThread(NULL, 0, steam_start_ack, NULL, 0, NULL);

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
