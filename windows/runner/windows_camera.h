#pragma once

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <windows.h>
#include <memory>

void RegisterWindowsCamera(flutter::FlutterEngine* engine, HWND window);
bool HandleWindowsCameraCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
bool HandleWindowsCameraMessage(UINT message, LPARAM lparam);
void ShutdownWindowsCamera(HWND window);
