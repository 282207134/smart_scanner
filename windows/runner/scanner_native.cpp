#include "scanner_native.h"
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <stdexcept>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr UINT kOcrComplete = WM_APP + 0x510;
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
struct Reply { std::unique_ptr<Result> result; std::string text; std::string error; };
std::unique_ptr<flutter::MethodChannel<Value>> channel;
std::vector<std::thread> workers;
std::string Argument(const flutter::EncodableMap& args, const char* key) {
  const auto found = args.find(Value(key));
  if (found == args.end() || !std::holds_alternative<std::string>(found->second)) return "";
  return std::get<std::string>(found->second);
}
}

void RegisterScannerNative(flutter::FlutterEngine* engine, HWND window) {
  channel = std::make_unique<flutter::MethodChannel<Value>>(engine->messenger(), "smart_scanner/native", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
    if (call.method_name() != "ocr") { result->NotImplemented(); return; }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("ARGUMENT", "缺少 OCR 参数"); return; }
    const auto path = Argument(*args, "path"), language = Argument(*args, "language");
    auto reply = std::make_unique<Reply>(); reply->result = std::move(result);
    workers.emplace_back([window, path, language, reply = std::move(reply)]() mutable {
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        using namespace winrt::Windows::Graphics::Imaging;
        using namespace winrt::Windows::Media::Ocr;
        auto ocr = OcrEngine::TryCreateFromLanguage(winrt::Windows::Globalization::Language(winrt::to_hstring(language)));
        if (!ocr) throw std::runtime_error("当前系统没有所选 OCR 语言包，请在 Windows 语言设置中安装中文、日语或英语的基本输入功能");
        auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
        auto stream = file.OpenAsync(winrt::Windows::Storage::FileAccessMode::Read).get();
        auto decoder = BitmapDecoder::CreateAsync(stream).get();
        auto transform = BitmapTransform();
        const double scale = std::min(1.0, static_cast<double>(OcrEngine::MaxImageDimension()) / std::max(decoder.PixelWidth(), decoder.PixelHeight()));
        transform.ScaledWidth(static_cast<uint32_t>(decoder.PixelWidth() * scale));
        transform.ScaledHeight(static_cast<uint32_t>(decoder.PixelHeight() * scale));
        // JPEG decoders do not all support direct Gray8 output. Decode to BGRA
        // first and use the platform converter for the OCR pixel format.
        auto decoded = decoder.GetSoftwareBitmapAsync(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore, transform,
          ExifOrientationMode::RespectExifOrientation, ColorManagementMode::DoNotColorManage).get();
        auto bitmap = SoftwareBitmap::Convert(decoded, BitmapPixelFormat::Gray8);
        auto recognized = ocr.RecognizeAsync(bitmap).get();
        for (const auto& line : recognized.Lines()) { reply->text += winrt::to_string(line.Text()) + "\n"; }
        stream.Close();
      } catch (const winrt::hresult_error& e) { reply->error = winrt::to_string(e.message()); }
      catch (const std::exception& e) { reply->error = e.what(); }
      winrt::uninit_apartment();
      auto* raw = reply.release();
      if (!PostMessage(window, kOcrComplete, 0, reinterpret_cast<LPARAM>(raw))) delete raw;
    });
  });
}

bool HandleScannerNativeMessage(UINT message, LPARAM lparam) {
  if (message != kOcrComplete) return false;
  std::unique_ptr<Reply> reply(reinterpret_cast<Reply*>(lparam));
  if (reply->error.empty()) reply->result->Success(Value(reply->text));
  else reply->result->Error("OCR", reply->error);
  return true;
}

void ShutdownScannerNative(HWND window) {
  if (channel) channel->SetMethodCallHandler(nullptr);
  for (auto& worker : workers) if (worker.joinable()) worker.join();
  workers.clear();
  MSG message;
  while (PeekMessage(&message, window, kOcrComplete, kOcrComplete, PM_REMOVE)) delete reinterpret_cast<Reply*>(message.lParam);
  channel.reset();
}
