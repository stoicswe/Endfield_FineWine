/* The Mac's open and save panels in place of the Windows file dialogs (runtime patch 0056).
 *
 * A Windows program asks for a file or a folder in one of three ways: the item dialog
 * (IFileOpenDialog, IFileSaveDialog), GetOpenFileName / GetSaveFileName, and SHBrowseForFolder.
 * In a FineWine runtime all three show an NSOpenPanel or NSSavePanel, and what was chosen
 * there comes back as Windows paths.
 *
 * Nobody clicks here: the answer the panel gives is set from outside, as Unix paths in
 * FINEWINE_FILE_PANEL_ANSWER ("cancel", or one path a line), and with it no panel is shown,
 * unless FINEWINE_FILE_PANEL_ANSWER_DELAY says for how many milliseconds a real one is to be
 * open first. The test is told which Windows paths to expect and checks that each API hands
 * them to the program the way the Windows dialog does.
 *
 *   file-dialogs.exe open <path>               item dialog, one file; OnFileOk refuses once
 *   file-dialogs.exe open-multi <path> <path>  item dialog, several files
 *   file-dialogs.exe folder <path>             item dialog, a folder
 *   file-dialogs.exe save <path>               item dialog, saving
 *   file-dialogs.exe ofn <path>                GetOpenFileNameW/A, GetSaveFileNameW, small buffer
 *   file-dialogs.exe ofn-multi <dir> <n> <n>   GetOpenFileNameW, several files
 *   file-dialogs.exe browse <path>             SHBrowseForFolderW/A with a callback
 *   file-dialogs.exe cancel                    all three, cancelled
 *   file-dialogs.exe close                     IFileDialog::Close from another thread
 *   file-dialogs.exe enabled                   prints whether the panels are in use
 *
 * Prints "file-dialogs <mode>: ok", or what was wrong.
 *
 * Build: <llvm-mingw>/bin/x86_64-w64-mingw32-clang -O1 -municode -o file-dialogs.exe file-dialogs.c \
 *            -lole32 -lshell32 -lcomdlg32 -lshlwapi -luuid
 */
#define COBJMACROS
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <commdlg.h>
#include <cderr.h>
#include <stdio.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) { printf("FAIL: %s\n", what); failures++; }
}

static void check_path(const WCHAR *got, const WCHAR *want, const char *what)
{
    if (!got || lstrcmpiW(got, want))
    {
        printf("FAIL: %s: got '%ls', expected '%ls'\n", what, got ? got : L"(null)", want);
        failures++;
    }
}

/* ---- the item dialog ---- */

struct events
{
    IFileDialogEvents IFileDialogEvents_iface;
    int file_ok, refuse, type_change, folder_change;
};

static HRESULT WINAPI ev_QueryInterface(IFileDialogEvents *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IFileDialogEvents)) { *out = iface; return S_OK; }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI ev_AddRef(IFileDialogEvents *iface) { return 2; }
static ULONG WINAPI ev_Release(IFileDialogEvents *iface) { return 1; }
static HRESULT WINAPI ev_OnFileOk(IFileDialogEvents *iface, IFileDialog *dialog)
{
    struct events *ev = (struct events *)iface;
    ev->file_ok++;
    if (ev->refuse) { ev->refuse--; return S_FALSE; }
    return S_OK;
}
static HRESULT WINAPI ev_OnFolderChanging(IFileDialogEvents *iface, IFileDialog *d, IShellItem *i) { return S_OK; }
static HRESULT WINAPI ev_OnFolderChange(IFileDialogEvents *iface, IFileDialog *d)
{
    ((struct events *)iface)->folder_change++;
    return S_OK;
}
static HRESULT WINAPI ev_OnSelectionChange(IFileDialogEvents *iface, IFileDialog *d) { return S_OK; }
static HRESULT WINAPI ev_OnShareViolation(IFileDialogEvents *iface, IFileDialog *d, IShellItem *i, FDE_SHAREVIOLATION_RESPONSE *r) { return E_NOTIMPL; }
static HRESULT WINAPI ev_OnTypeChange(IFileDialogEvents *iface, IFileDialog *d)
{
    ((struct events *)iface)->type_change++;
    return S_OK;
}
static HRESULT WINAPI ev_OnOverwrite(IFileDialogEvents *iface, IFileDialog *d, IShellItem *i, FDE_OVERWRITE_RESPONSE *r) { return E_NOTIMPL; }

static const IFileDialogEventsVtbl events_vtbl =
{
    ev_QueryInterface, ev_AddRef, ev_Release, ev_OnFileOk, ev_OnFolderChanging, ev_OnFolderChange,
    ev_OnSelectionChange, ev_OnShareViolation, ev_OnTypeChange, ev_OnOverwrite
};

static const COMDLG_FILTERSPEC file_types[] =
{
    { L"Text files (*.txt)", L"*.txt;*.log" },
    { L"Pictures", L"*.png" },
    { L"All files", L"*.*" },
};

static WCHAR *item_path(IShellItem *item)
{
    WCHAR *path = NULL;
    if (item) IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path);
    return path;
}

static void test_open(const WCHAR *expected)
{
    struct events ev = { { (IFileDialogEventsVtbl *)&events_vtbl }, 0, 1 };
    IFileOpenDialog *dialog;
    IShellItem *item = NULL;
    WCHAR *path, *name = NULL, folder[MAX_PATH];
    DWORD cookie;
    UINT type = 0;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr)) { check(0, "no FileOpenDialog"); return; }
    IFileOpenDialog_SetFileTypes(dialog, ARRAYSIZE(file_types), file_types);
    IFileOpenDialog_SetFileTypeIndex(dialog, 1);
    IFileOpenDialog_SetTitle(dialog, L"FineWine test: open");
    IFileOpenDialog_SetOkButtonLabel(dialog, L"&Take");
    IFileOpenDialog_Advise(dialog, &ev.IFileDialogEvents_iface, &cookie);

    hr = IFileOpenDialog_Show(dialog, NULL);
    check(hr == S_OK, "open: Show did not return S_OK");
    check(ev.file_ok == 2, "open: OnFileOk should be asked twice (it refuses the first time)");
    check(ev.folder_change >= 1, "open: no OnFolderChange");

    hr = IFileOpenDialog_GetResult(dialog, &item);
    check(hr == S_OK && item, "open: no result");
    path = item_path(item);
    check_path(path, expected, "open: result");
    CoTaskMemFree(path);
    if (item) IShellItem_Release(item);

    IFileOpenDialog_GetFileName(dialog, &name);
    check_path(name, PathFindFileNameW(expected), "open: GetFileName");
    CoTaskMemFree(name);

    item = NULL;
    IFileOpenDialog_GetFolder(dialog, &item);
    path = item_path(item);
    lstrcpynW(folder, expected, MAX_PATH);
    PathRemoveFileSpecW(folder);
    check_path(path, folder, "open: GetFolder");
    CoTaskMemFree(path);
    if (item) IShellItem_Release(item);

    /* the script answers with the third file type */
    IFileOpenDialog_GetFileTypeIndex(dialog, &type);
    check(type == 3, "open: GetFileTypeIndex should be 3");
    check(ev.type_change == 1, "open: one OnTypeChange for the type that was picked");

    IFileOpenDialog_Unadvise(dialog, cookie);
    IFileOpenDialog_Release(dialog);
}

static void test_open_multi(const WCHAR *first, const WCHAR *second)
{
    IFileOpenDialog *dialog;
    IShellItemArray *items = NULL;
    IShellItem *item;
    DWORD count = 0, options = 0;
    WCHAR *path;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr)) { check(0, "no FileOpenDialog"); return; }
    IFileOpenDialog_GetOptions(dialog, &options);
    IFileOpenDialog_SetOptions(dialog, options | FOS_ALLOWMULTISELECT);
    hr = IFileOpenDialog_Show(dialog, NULL);
    check(hr == S_OK, "open-multi: Show did not return S_OK");
    hr = IFileOpenDialog_GetResults(dialog, &items);
    check(hr == S_OK && items, "open-multi: no results");
    if (items)
    {
        IShellItemArray_GetCount(items, &count);
        check(count == 2, "open-multi: two results expected");
        if (count == 2)
        {
            IShellItemArray_GetItemAt(items, 0, &item);
            path = item_path(item); check_path(path, first, "open-multi: first"); CoTaskMemFree(path);
            IShellItem_Release(item);
            IShellItemArray_GetItemAt(items, 1, &item);
            path = item_path(item); check_path(path, second, "open-multi: second"); CoTaskMemFree(path);
            IShellItem_Release(item);
        }
        IShellItemArray_Release(items);
    }
    IFileOpenDialog_Release(dialog);
}

static void test_folder(const WCHAR *expected)
{
    IFileOpenDialog *dialog;
    IShellItem *item = NULL, *start = NULL;
    DWORD options = 0;
    WCHAR *path;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr)) { check(0, "no FileOpenDialog"); return; }
    IFileOpenDialog_GetOptions(dialog, &options);
    IFileOpenDialog_SetOptions(dialog, options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    if (SUCCEEDED(SHCreateItemFromParsingName(expected, NULL, &IID_IShellItem, (void **)&start)))
    {
        IFileOpenDialog_SetFolder(dialog, start);
        IShellItem_Release(start);
    }
    hr = IFileOpenDialog_Show(dialog, NULL);
    check(hr == S_OK, "folder: Show did not return S_OK");
    IFileOpenDialog_GetResult(dialog, &item);
    path = item_path(item);
    check_path(path, expected, "folder: result");
    CoTaskMemFree(path);
    if (item)
    {
        SFGAOF attrs = 0;
        IShellItem_GetAttributes(item, SFGAO_FOLDER, &attrs);
        check(attrs & SFGAO_FOLDER, "folder: the result is not a folder");
        IShellItem_Release(item);
    }
    IFileOpenDialog_Release(dialog);
}

static void test_save(const WCHAR *expected)
{
    IFileSaveDialog *dialog;
    IShellItem *item = NULL;
    WCHAR *path;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileSaveDialog, (void **)&dialog);
    if (FAILED(hr)) { check(0, "no FileSaveDialog"); return; }
    IFileSaveDialog_SetFileTypes(dialog, ARRAYSIZE(file_types), file_types);
    IFileSaveDialog_SetDefaultExtension(dialog, L"txt");
    IFileSaveDialog_SetFileName(dialog, L"untitled.txt");
    hr = IFileSaveDialog_Show(dialog, NULL);
    check(hr == S_OK, "save: Show did not return S_OK");
    IFileSaveDialog_GetResult(dialog, &item);
    path = item_path(item);
    check_path(path, expected, "save: result (a file that does not exist yet)");
    CoTaskMemFree(path);
    if (item) IShellItem_Release(item);
    IFileSaveDialog_Release(dialog);
}

/* ---- GetOpenFileName, GetSaveFileName ---- */

static const WCHAR ofn_filter[] = L"Text files\0*.txt;*.log\0Pictures\0*.png\0All files\0*.*\0";

static void test_ofn(const WCHAR *expected)
{
    WCHAR file[MAX_PATH] = L"", title[MAX_PATH] = L"", small[4] = L"";
    char fileA[MAX_PATH] = "", titleA[MAX_PATH] = "", expectedA[MAX_PATH];
    const WCHAR *name = PathFindFileNameW(expected), *ext = wcsrchr(name, '.');
    OPENFILENAMEW ofn = { sizeof(ofn) };
    OPENFILENAMEA ofnA = { sizeof(ofnA) };
    BOOL ret;

    ofn.lpstrFilter = ofn_filter;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrFileTitle = title;
    ofn.nMaxFileTitle = MAX_PATH;
    ofn.lpstrTitle = L"FineWine test: GetOpenFileName";
    ofn.lpstrDefExt = L"dat";
    ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR | OFN_READONLY;
    ret = GetOpenFileNameW(&ofn);
    check(ret, "ofn: GetOpenFileNameW returned FALSE");
    check_path(file, expected, "ofn: lpstrFile");
    check_path(title, name, "ofn: lpstrFileTitle");
    check(ofn.nFileOffset == name - expected, "ofn: nFileOffset");
    check(ext && ofn.nFileExtension == ext + 1 - expected, "ofn: nFileExtension");
    check(ofn.nFilterIndex == 3, "ofn: nFilterIndex should be 3 (the script answers with the third type)");
    check(!(ofn.Flags & OFN_READONLY), "ofn: OFN_READONLY should be cleared");
    check(ofn.Flags & OFN_EXTENSIONDIFFERENT, "ofn: OFN_EXTENSIONDIFFERENT should be set (the default is .dat)");

    /* ANSI */
    WideCharToMultiByte(CP_ACP, 0, expected, -1, expectedA, MAX_PATH, NULL, NULL);
    ofnA.lpstrFilter = "Text files\0*.txt\0";
    ofnA.lpstrFile = fileA;
    ofnA.nMaxFile = MAX_PATH;
    ofnA.lpstrFileTitle = titleA;
    ofnA.nMaxFileTitle = MAX_PATH;
    ofnA.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR;
    ret = GetOpenFileNameA(&ofnA);
    check(ret, "ofn: GetOpenFileNameA returned FALSE");
    check(!lstrcmpiA(fileA, expectedA), "ofn: GetOpenFileNameA lpstrFile");
    check(!lstrcmpiA(titleA, PathFindFileNameA(expectedA)), "ofn: GetOpenFileNameA lpstrFileTitle");
    check(ofnA.nFileOffset == PathFindFileNameA(expectedA) - expectedA, "ofn: GetOpenFileNameA nFileOffset");

    /* a buffer that is too small: FALSE, and the size that is needed in it */
    ZeroMemory(&ofn, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.lpstrFile = small;
    ofn.nMaxFile = ARRAYSIZE(small);
    ofn.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR;
    ret = GetOpenFileNameW(&ofn);
    check(!ret, "ofn: a buffer of 4 characters should fail");
    check(CommDlgExtendedError() == FNERR_BUFFERTOOSMALL, "ofn: FNERR_BUFFERTOOSMALL expected");
    check(small[0] == lstrlenW(expected) + 1, "ofn: the needed size should be in the buffer");

    /* saving, and the current directory follows without OFN_NOCHANGEDIR */
    ZeroMemory(&ofn, sizeof(ofn));
    file[0] = 0;
    ofn.lStructSize = sizeof(ofn);
    ofn.lpstrFilter = ofn_filter;
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT;
    ret = GetSaveFileNameW(&ofn);
    check(ret, "ofn: GetSaveFileNameW returned FALSE");
    check_path(file, expected, "ofn: GetSaveFileNameW lpstrFile");
    {
        WCHAR cwd[MAX_PATH], folder[MAX_PATH];
        GetCurrentDirectoryW(MAX_PATH, cwd);
        lstrcpynW(folder, expected, MAX_PATH);
        PathRemoveFileSpecW(folder);
        check_path(cwd, folder, "ofn: the current directory after the dialog");
    }
}

static void test_ofn_multi(const WCHAR *dir, const WCHAR *first, const WCHAR *second)
{
    WCHAR file[1024] = L"";
    OPENFILENAMEW ofn = { sizeof(ofn) };
    const WCHAR *p;
    BOOL ret;

    ofn.lpstrFile = file;
    ofn.nMaxFile = ARRAYSIZE(file);
    ofn.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_NOCHANGEDIR;
    ret = GetOpenFileNameW(&ofn);
    check(ret, "ofn-multi: GetOpenFileNameW returned FALSE");
    p = file;
    check_path(p, dir, "ofn-multi: the folder comes first");
    check(ofn.nFileOffset == lstrlenW(dir) + 1, "ofn-multi: nFileOffset is where the first name starts");
    p += lstrlenW(p) + 1;
    check_path(p, first, "ofn-multi: first name");
    p += lstrlenW(p) + 1;
    check_path(p, second, "ofn-multi: second name");
    p += lstrlenW(p) + 1;
    check(!*p, "ofn-multi: the list should end in two zeroes");
}

/* ---- SHBrowseForFolder ---- */

struct browse
{
    const WCHAR *start;
    int initialized, changed, refuse;
    WCHAR seen[MAX_PATH];
};

static int CALLBACK browse_callback(HWND hwnd, UINT msg, LPARAM lp, LPARAM data)
{
    struct browse *b = (struct browse *)data;

    if (msg == BFFM_INITIALIZED)
    {
        b->initialized++;
        SendMessageW(hwnd, BFFM_SETSELECTIONW, TRUE, (LPARAM)b->start);
        SendMessageW(hwnd, BFFM_SETOKTEXT, 0, (LPARAM)L"Use this folder");
        SendMessageW(hwnd, BFFM_SETSTATUSTEXTW, 0, (LPARAM)L"status");
    }
    else if (msg == BFFM_SELCHANGED)
    {
        b->changed++;
        SHGetPathFromIDListW((LPCITEMIDLIST)lp, b->seen);
        if (b->refuse) { b->refuse--; SendMessageW(hwnd, BFFM_ENABLEOK, 0, FALSE); }
    }
    return 0;
}

static void test_browse(const WCHAR *expected)
{
    struct browse b = { expected, 0, 0, 1 };
    WCHAR display[MAX_PATH] = L"", path[MAX_PATH] = L"";
    char displayA[MAX_PATH] = "";
    BROWSEINFOW bi = { 0 };
    BROWSEINFOA biA = { 0 };
    LPITEMIDLIST pidl;

    bi.pszDisplayName = display;
    bi.lpszTitle = L"FineWine test: choose a folder";
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    bi.lpfn = browse_callback;
    bi.lParam = (LPARAM)&b;
    pidl = SHBrowseForFolderW(&bi);
    check(pidl != NULL, "browse: no folder came back");
    if (pidl) SHGetPathFromIDListW(pidl, path);
    check_path(path, expected, "browse: result");
    check_path(display, PathFindFileNameW(expected), "browse: pszDisplayName");
    check(b.initialized == 1, "browse: one BFFM_INITIALIZED");
    check(b.changed == 2, "browse: two BFFM_SELCHANGED (the first choice is refused with BFFM_ENABLEOK)");
    check_path(b.seen, expected, "browse: the folder shown to the callback");
    CoTaskMemFree(pidl);

    biA.pszDisplayName = displayA;
    biA.lpszTitle = "FineWine test";
    pidl = SHBrowseForFolderA(&biA);
    check(pidl != NULL, "browse: SHBrowseForFolderA gave nothing");
    path[0] = 0;
    if (pidl) SHGetPathFromIDListW(pidl, path);
    check_path(path, expected, "browse: SHBrowseForFolderA result");
    CoTaskMemFree(pidl);
}

/* ---- cancelling and closing ---- */

static void test_cancel(void)
{
    WCHAR file[MAX_PATH] = L"";
    OPENFILENAMEW ofn = { sizeof(ofn) };
    BROWSEINFOW bi = { 0 };
    IFileOpenDialog *dialog;
    IShellItem *item = NULL;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr)) { check(0, "no FileOpenDialog"); return; }
    hr = IFileOpenDialog_Show(dialog, NULL);
    check(hr == HRESULT_FROM_WIN32(ERROR_CANCELLED), "cancel: Show should return ERROR_CANCELLED");
    check(FAILED(IFileOpenDialog_GetResult(dialog, &item)), "cancel: there should be no result");
    IFileOpenDialog_Release(dialog);

    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_EXPLORER;
    check(!GetOpenFileNameW(&ofn), "cancel: GetOpenFileNameW should return FALSE");
    check(!CommDlgExtendedError(), "cancel: no extended error for a cancel");
    check(!GetSaveFileNameW(&ofn), "cancel: GetSaveFileNameW should return FALSE");

    check(!SHBrowseForFolderW(&bi), "cancel: SHBrowseForFolderW should return NULL");
}

static DWORD WINAPI close_thread(void *arg)
{
    Sleep(1200);
    IFileOpenDialog_Close((IFileOpenDialog *)arg, E_ABORT);
    return 0;
}

/* A real panel is open here (the script gives the answer a long delay) and the program
 * closes the dialog itself. */
static void test_close(void)
{
    IFileOpenDialog *dialog;
    HANDLE thread;
    DWORD start;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr)) { check(0, "no FileOpenDialog"); return; }
    IFileOpenDialog_SetTitle(dialog, L"FineWine test: this closes by itself");
    thread = CreateThread(NULL, 0, close_thread, dialog, 0, NULL);
    start = GetTickCount();
    hr = IFileOpenDialog_Show(dialog, NULL);
    check(hr == E_ABORT, "close: Show should return what Close was given");
    check(GetTickCount() - start < 8000, "close: Show should return soon after Close");
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    IFileOpenDialog_Release(dialog);
}

int wmain(int argc, WCHAR **argv)
{
    const WCHAR *mode = argc > 1 ? argv[1] : L"";

    setvbuf(stdout, NULL, _IONBF, 0);
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    if (!lstrcmpW(mode, L"enabled"))
    {
        BOOL (WINAPI *enabled)(void) = (void *)GetProcAddress(LoadLibraryW(L"comdlg32.dll"), "__wine_mac_file_panel_enabled");
        printf("file-dialogs enabled: %s\n", !enabled ? "no export" : enabled() ? "yes" : "no");
        return 0;
    }
    else if (!lstrcmpW(mode, L"open") && argc == 3) test_open(argv[2]);
    else if (!lstrcmpW(mode, L"open-multi") && argc == 4) test_open_multi(argv[2], argv[3]);
    else if (!lstrcmpW(mode, L"folder") && argc == 3) test_folder(argv[2]);
    else if (!lstrcmpW(mode, L"save") && argc == 3) test_save(argv[2]);
    else if (!lstrcmpW(mode, L"ofn") && argc == 3) test_ofn(argv[2]);
    else if (!lstrcmpW(mode, L"ofn-multi") && argc == 5) test_ofn_multi(argv[2], argv[3], argv[4]);
    else if (!lstrcmpW(mode, L"browse") && argc == 3) test_browse(argv[2]);
    else if (!lstrcmpW(mode, L"cancel")) test_cancel();
    else if (!lstrcmpW(mode, L"close")) test_close();
    else { printf("file-dialogs: unknown mode\n"); return 2; }

    CoUninitialize();
    if (failures) printf("file-dialogs %ls: %d failure(s)\n", mode, failures);
    else printf("file-dialogs %ls: ok\n", mode);
    return failures != 0;
}
