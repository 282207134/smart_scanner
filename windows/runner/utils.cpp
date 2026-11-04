#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <iostream>

void DisableUnsafeDartProfiling() {
  // The affected engine statically links its own CRT and snapshots the process
  // environment when loaded. CMake delay-loads it and the plugin DLLs so this
  // runs BEFORE that snapshot; changing the runner's CRT alone is insufficient.
  const auto set = [](const std::string& key, const std::string& value) {
    ::SetEnvironmentVariableA(key.c_str(), value.empty() ? nullptr : value.c_str());
  };
  const auto get = [](const std::string& key) {
    const DWORD size = ::GetEnvironmentVariableA(key.c_str(), nullptr, 0);
    if (!size) return std::string();
    std::string value(size, '\0');
    const DWORD length =
        ::GetEnvironmentVariableA(key.c_str(), value.data(), size);
    value.resize(length < size ? length : 0);
    return value;
  };
  const int count = std::clamp(
      std::atoi(get("FLUTTER_ENGINE_SWITCHES").c_str()), 0, 50);
  std::vector<std::string> switches;
  bool removed = false;
  for (int i = 1; i <= count; ++i) {
    auto value = get("FLUTTER_ENGINE_SWITCH_" + std::to_string(i));
    if (value == "enable-dart-profiling" ||
        value.rfind("enable-dart-profiling=", 0) == 0) {
      removed = true;
    } else if (!value.empty()) {
      switches.push_back(std::move(value));
    }
  }
  if (!removed) return;
  for (int i = 1; i <= count; ++i) {
    set("FLUTTER_ENGINE_SWITCH_" + std::to_string(i),
        i <= static_cast<int>(switches.size()) ? switches[i - 1] : "");
  }
  set("FLUTTER_ENGINE_SWITCHES", std::to_string(switches.size()));
  std::cerr << "Dart 3.13 Windows stability workaround: CPU sampling disabled "
               "(dart-lang/sdk#64627). Hot reload and debugging remain enabled."
            << std::endl;
}

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
