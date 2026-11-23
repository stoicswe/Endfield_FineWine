/* Run through the Steam stand-in: steam.exe steam-probe.exe <report file>.
 * Reports whether this program finds what a game started by Steam finds. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

static int parent_is_steam(void)
{
    DWORD me = GetCurrentProcessId(), parent = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32 e = { sizeof(e) };
    int found = 0;
    if (Process32First(snap, &e)) do { if (e.th32ProcessID == me) parent = e.th32ParentProcessID; } while (Process32Next(snap, &e));
    e.dwSize = sizeof(e);
    if (Process32First(snap, &e)) do {
        if (e.th32ProcessID == parent && !_stricmp(e.szExeFile, "steam.exe")) found = 1;
    } while (Process32Next(snap, &e));
    CloseHandle(snap);
    return found;
}

int main(int argc, char **argv)
{
    char value[512];
    DWORD pid = 0, size = sizeof(pid);
    HANDLE event, process;
    int ok = 1;
    FILE *f = argc > 1 ? fopen(argv[1], "w") : stdout;
    if (!f) return 2;
#define CHECK(what, cond) do { int c = (cond); fprintf(f, "%s: %s\n", what, c ? "ok" : "MISSING"); ok &= c; } while (0)
    CHECK("SteamGameId", GetEnvironmentVariableA("SteamGameId", value, sizeof(value)) && !strcmp(value, "zenlesszonezero"));
    CHECK("SteamAppId", GetEnvironmentVariableA("SteamAppId", value, sizeof(value)) > 0);
    CHECK("SteamPath", GetEnvironmentVariableA("SteamPath", value, sizeof(value)) > 0);
    CHECK("ValvePlatformMutex", GetEnvironmentVariableA("ValvePlatformMutex", value, sizeof(value)) > 0);
    event = OpenEventA(SYNCHRONIZE, FALSE, "Steam3Master_SharedMemLock");
    CHECK("Steam3Master_SharedMemLock", event != NULL);
    CHECK("Steam window", FindWindowA("vguiPopupWindow", "Steam") != NULL);
    CHECK("ActiveProcess pid", !RegGetValueA(HKEY_CURRENT_USER, "Software\\Valve\\Steam\\ActiveProcess", "pid",
                                             RRF_RT_REG_DWORD, NULL, &pid, &size) && pid);
    process = pid ? OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) : NULL;
    CHECK("ActiveProcess is running", process != NULL);
    CHECK("parent is steam.exe", parent_is_steam());
    CHECK("library list", GetFileAttributesA("C:\\Program Files (x86)\\Steam\\steamapps\\libraryfolders.vdf") != INVALID_FILE_ATTRIBUTES);
    {
        /* What a program wrapped in Steam's copy protection does at its start: asks through one
         * semaphore, and waits for its event to be set and the other semaphore to be released. */
        HANDLE ack = CreateEventA(NULL, FALSE, FALSE, "STEAM_START_ACK_EVENT_probe");
        HANDLE consume = OpenSemaphoreA(SEMAPHORE_ALL_ACCESS, FALSE, "STEAM_DIPC_CONSUME");
        HANDLE produce = OpenSemaphoreA(SEMAPHORE_ALL_ACCESS, FALSE, "SREAM_DIPC_PRODUCE");
        CHECK("start-acknowledgement semaphores", consume && produce);
        if (consume && produce)
        {
            WaitForSingleObject(produce, 2000);
            ReleaseSemaphore(consume, 1, NULL);
            CHECK("start is acknowledged", WaitForSingleObject(ack, 5000) == WAIT_OBJECT_0);
            CHECK("the answer is released", WaitForSingleObject(produce, 5000) == WAIT_OBJECT_0);
        }
    }
    fprintf(f, ok ? "steam-probe: ok\n" : "steam-probe: FAILED\n");
    fclose(f);
    return !ok;
}
