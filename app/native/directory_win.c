#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

// Capture the thread-local Windows error before returning to the Dart VM.
// These operations inspect metadata or pin directories; none read contents.
__declspec(dllexport) uint32_t ustc_directory_attributes(
    const uint16_t* path, uint32_t* out_error) {
  const DWORD attributes = GetFileAttributesW((LPCWSTR)path);
  const DWORD error = attributes == INVALID_FILE_ATTRIBUTES
      ? GetLastError() : ERROR_SUCCESS;
  *out_error = (uint32_t)error;
  return (uint32_t)attributes;
}

__declspec(dllexport) int32_t ustc_directory_create(
    const uint16_t* path, uint32_t* out_error) {
  const BOOL created = CreateDirectoryW((LPCWSTR)path, NULL);
  const DWORD error = created ? ERROR_SUCCESS : GetLastError();
  *out_error = (uint32_t)error;
  return (int32_t)created;
}

__declspec(dllexport) void* ustc_directory_open(
    const uint16_t* path, int32_t exclusive, uint32_t* out_error) {
  const HANDLE handle = CreateFileW(
      (LPCWSTR)path,
      exclusive ? FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES
                : FILE_READ_ATTRIBUTES,
      exclusive ? 0 : FILE_SHARE_READ | FILE_SHARE_WRITE,
      NULL, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  const DWORD error = handle == INVALID_HANDLE_VALUE
      ? GetLastError() : ERROR_SUCCESS;
  *out_error = (uint32_t)error;
  return handle;
}
