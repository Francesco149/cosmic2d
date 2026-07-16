/* Player-facing Windows entrance for an exported game.
 *
 * The file is built with project icon/version resources and placed at the
 * archive root. It delegates, with the original Unicode argv, to the same-
 * named cosmic2d engine executable under bin/. Keeping the engine binary
 * separate preserves its truthful engine identity and its basename-based
 * D052 play lock while giving Explorer a project-owned front door. */

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <wchar.h>
#include <windows.h>
#include <shellapi.h>

#define PATH_CAP 32768

static int fail(const wchar_t *message) {
  MessageBoxW(NULL, message, L"Could not start the game",
              MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
  return 127;
}

/* Inverse of CommandLineToArgvW for one argument. Always quote, double runs
 * of backslashes before a quote/the closing quote, and preserve all other
 * UTF-16 code units. `capacity` is a defensive bound, not normal flow. */
static bool append_quoted(wchar_t *line, size_t capacity, size_t *used,
                          const wchar_t *arg) {
  if (*used + 1 >= capacity) return false;
  line[(*used)++] = L'"';
  size_t slashes = 0;
  for (const wchar_t *at = arg;; at++) {
    wchar_t ch = *at;
    if (ch == L'\\') {
      slashes++;
      continue;
    }
    size_t copies = (ch == L'"' || ch == L'\0') ? slashes * 2 : slashes;
    if (*used + copies + (ch == L'"' ? 2 : 0) + 2 >= capacity) return false;
    while (copies--) line[(*used)++] = L'\\';
    slashes = 0;
    if (ch == L'\0') break;
    if (ch == L'"') line[(*used)++] = L'\\';
    line[(*used)++] = ch;
  }
  line[(*used)++] = L'"';
  line[*used] = L'\0';
  return true;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line,
                    int show) {
  (void)instance;
  (void)previous;
  (void)command_line;
  (void)show;

  wchar_t self[PATH_CAP];
  DWORD length = GetModuleFileNameW(NULL, self, PATH_CAP);
  if (length == 0 || length >= PATH_CAP)
    return fail(L"The launcher path is unavailable or too long.");

  wchar_t *slash = wcsrchr(self, L'\\');
  wchar_t *forward = wcsrchr(self, L'/');
  if (!slash || (forward && forward > slash)) slash = forward;
  if (!slash || !slash[1]) return fail(L"The launcher filename is invalid.");

  const wchar_t middle[] = L"bin\\";
  size_t directory_len = (size_t)(slash - self + 1);
  size_t basename_len = wcslen(slash + 1);
  if (directory_len + (sizeof middle / sizeof middle[0] - 1) + basename_len
      >= PATH_CAP)
    return fail(L"The bundled engine path is too long.");

  wchar_t target[PATH_CAP];
  wmemcpy(target, self, directory_len);
  size_t at = directory_len;
  wmemcpy(target + at, middle, sizeof middle / sizeof middle[0] - 1);
  at += sizeof middle / sizeof middle[0] - 1;
  wmemcpy(target + at, slash + 1, basename_len + 1);

  int argc = 0;
  wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv || argc < 1) return fail(L"Windows could not decode the command line.");

  size_t capacity = wcslen(target) * 2 + 4;
  for (int i = 1; i < argc; i++) capacity += wcslen(argv[i]) * 2 + 4;
  wchar_t *child_line = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                                  capacity * sizeof *child_line);
  if (!child_line) {
    LocalFree(argv);
    return fail(L"The launcher ran out of memory.");
  }
  size_t used = 0;
  bool command_ok = append_quoted(child_line, capacity, &used, target);
  for (int i = 1; command_ok && i < argc; i++) {
    if (used + 1 >= capacity) {
      command_ok = false;
      break;
    }
    child_line[used++] = L' ';
    command_ok = append_quoted(child_line, capacity, &used, argv[i]);
  }
  LocalFree(argv);
  if (!command_ok) {
    HeapFree(GetProcessHeap(), 0, child_line);
    return fail(L"The delegated command line is too long.");
  }

  STARTUPINFOW startup = {.cb = sizeof startup};
  PROCESS_INFORMATION process = {0};
  BOOL started = CreateProcessW(target, child_line, NULL, NULL, FALSE, 0,
                                NULL, NULL, &startup, &process);
  DWORD start_error = started ? ERROR_SUCCESS : GetLastError();
  HeapFree(GetProcessHeap(), 0, child_line);
  if (!started) {
    wchar_t message[PATH_CAP];
    _snwprintf(message, PATH_CAP - 1,
               L"The bundled engine could not be started:\n%s\n\nerror %d",
               target, (int)start_error);
    message[PATH_CAP - 1] = L'\0';
    return fail(message);
  }
  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD status = 1;
  GetExitCodeProcess(process.hProcess, &status);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return (int)status;
}
