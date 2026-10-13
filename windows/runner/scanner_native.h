#pragma once
#include <flutter/flutter_engine.h>
#include <windows.h>
void RegisterScannerNative(flutter::FlutterEngine* engine, HWND window);
bool HandleScannerNativeMessage(UINT message, LPARAM lparam);
void ShutdownScannerNative(HWND window);
