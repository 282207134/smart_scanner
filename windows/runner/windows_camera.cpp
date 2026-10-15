#include "windows_camera.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <dshow.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
using Clock = std::chrono::steady_clock;
constexpr UINT kReply = WM_APP + 0x511;
constexpr UINT kFrame = WM_APP + 0x512;
constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAllStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);

void Check(HRESULT hr) { winrt::check_hresult(hr); }
const Value* Find(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  return it == args.end() ? nullptr : &it->second;
}
int Number(const Map& args, const char* key, int fallback) {
  const auto* v = Find(args, key);
  return v && std::holds_alternative<int32_t>(*v) ? std::get<int32_t>(*v) : fallback;
}
double Decimal(const Value* v, double fallback) {
  if (v && std::holds_alternative<double>(*v)) return std::get<double>(*v);
  if (v && std::holds_alternative<int32_t>(*v)) return std::get<int32_t>(*v);
  return fallback;
}
std::string Text(const Map& args, const char* key) {
  const auto* v = Find(args, key);
  return v && std::holds_alternative<std::string>(*v) ? std::get<std::string>(*v) : "";
}
std::string CameraError(HRESULT hr) {
  if (hr == E_ACCESSDENIED) return "摄像头访问被拒绝，请在 Windows 设置中允许桌面应用使用摄像头";
  return "无法使用摄像头，请检查连接并关闭其它占用相机的软件：" +
         winrt::to_string(winrt::hresult_error(hr).message());
}
struct Reply { std::unique_ptr<Result> result; Value value; std::string error; };
struct Device { std::string name; std::wstring link; };
struct Pixels { int width = 0, height = 0; std::vector<uint8_t> bgra; };
struct View {
  int width = 640, height = 480, rotation = 0;
  // 0 compact, 1 maximized, 2 manual.
  int mode = 0;
  double zoom = 1, pan_x = 0, pan_y = 0;

  void Resize(const Map& args) {
    width = std::clamp(Number(args, "canvasW", 640), 1, 8192);
    height = std::clamp(Number(args, "canvasH", 480), 1, 8192);
  }
};
struct StreamState {
  std::mutex mutex;
  std::condition_variable ready;
  bool active = false, posted = false;
  int generation = 0;
  int width = 0, height = 0;
  LONG stride = 0;
  HRESULT error = S_OK;
  HWND window = nullptr;
  View view;
  Pixels latest;
  Value pending;
  Clock::time_point received{}, previewed{};
  ComPtr<IMFSourceReader> reader;

  // Called while holding mutex, for both preview frames and stream errors.
  void PostPreview() {
    if (!posted) posted = PostMessage(window, kFrame, 0, 0) != 0;
  }
  void Fail(HRESULT status) {
    error = status;
    active = false;
    PostPreview();
    ready.notify_all();
  }
};

// Rotate coordinates independently of the preview scale. Photos always retain
// the selected sensor dimensions, even when the view is zoomed or panned.
const uint8_t* Pixel(const Pixels& image, int x, int y, int rotation) {
  int sx = x, sy = y;
  if (rotation == 1) { sx = y; sy = image.height - 1 - x; }
  if (rotation == 2) { sx = image.width - 1 - x; sy = image.height - 1 - y; }
  if (rotation == 3) { sx = image.width - 1 - y; sy = x; }
  return image.bgra.data() + (static_cast<size_t>(sy) * image.width + sx) * 4;
}
Value Preview(const Pixels& image, View& view) {
  const int iw = view.rotation % 2 ? image.height : image.width;
  const int ih = view.rotation % 2 ? image.width : image.height;
  const double fit = std::min(static_cast<double>(view.width) / iw,
                              static_cast<double>(view.height) / ih);
  double scale = fit * view.zoom;
  if (view.mode == 0) scale = fit * .85;
  if (view.mode == 1) scale = static_cast<double>(view.height) / ih;
  view.zoom = scale / fit;
  const double sw = iw * scale, sh = ih * scale;
  view.pan_x = std::clamp(view.pan_x, -std::abs(view.width - sw) / 2, std::abs(view.width - sw) / 2);
  view.pan_y = std::clamp(view.pan_y, -std::abs(view.height - sh) / 2, std::abs(view.height - sh) / 2);
  const double left = (view.width - sw) / 2 + view.pan_x;
  const double top = (view.height - sh) / 2 + view.pan_y;
  const int x = std::max(0, static_cast<int>(std::ceil(left)));
  const int y = std::max(0, static_cast<int>(std::ceil(top)));
  const int w = std::min(view.width, static_cast<int>(std::floor(left + sw))) - x;
  const int h = std::min(view.height, static_cast<int>(std::floor(top + sh))) - y;
  if (w <= 0 || h <= 0) return Value();
  std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3);
  for (int row = 0; row < h; ++row) for (int col = 0; col < w; ++col) {
    const int px = std::clamp(static_cast<int>((x + col - left) / scale), 0, iw - 1);
    const int py = std::clamp(static_cast<int>((y + row - top) / scale), 0, ih - 1);
    const auto* pixel = Pixel(image, px, py, view.rotation);
    const size_t dst = (static_cast<size_t>(row) * w + col) * 3;
    rgb[dst] = pixel[2]; rgb[dst + 1] = pixel[1]; rgb[dst + 2] = pixel[0];
  }
  return Value(Map{{Value("x"), Value(x)}, {Value("y"), Value(y)},
                   {Value("width"), Value(w)}, {Value("height"), Value(h)},
                   {Value("rgb"), Value(std::move(rgb))}});
}

class ReaderCallback final : public IMFSourceReaderCallback {
 public:
  ReaderCallback(std::weak_ptr<StreamState> state, int generation) : state_(std::move(state)), generation_(generation) {}
  STDMETHODIMP QueryInterface(REFIID iid, void** value) override {
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFSourceReaderCallback)) {
      *value = static_cast<IMFSourceReaderCallback*>(this); AddRef(); return S_OK;
    }
    *value = nullptr; return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG count = InterlockedDecrement(&refs_);
    if (!count) delete this;
    return count;
  }
  STDMETHODIMP OnEvent(DWORD, IMFMediaEvent*) override { return S_OK; }
  STDMETHODIMP OnFlush(DWORD) override { return S_OK; }
  STDMETHODIMP OnReadSample(HRESULT status, DWORD, DWORD flags, LONGLONG, IMFSample* sample) override {
    const auto state = state_.lock();
    if (!state) return S_OK;
    ComPtr<IMFSourceReader> reader;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->active || state->generation != generation_) return S_OK;
      if (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM | MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) status = E_FAIL;
      if (SUCCEEDED(status) && sample) {
        ComPtr<IMFMediaBuffer> buffer;
        status = sample->ConvertToContiguousBuffer(&buffer);
        if (SUCCEEDED(status)) {
          ComPtr<IMF2DBuffer> buffer2d;
          BYTE* data = nullptr;
          LONG stride = state->stride;
          DWORD size = 0;
          const bool is2d = SUCCEEDED(buffer.As(&buffer2d));
          status = is2d ? buffer2d->Lock2D(&data, &stride) : buffer->Lock(&data, nullptr, &size);
          if (SUCCEEDED(status)) {
            const int width = state->width, height = state->height;
            const size_t row_bytes = static_cast<size_t>(width) * 4;
            if (std::abs(stride) < static_cast<LONG>(row_bytes) ||
                (!is2d && size < static_cast<size_t>(std::abs(stride)) * height)) {
              status = E_FAIL;
            } else {
              Pixels frame{width, height, std::vector<uint8_t>(row_bytes * height)};
              if (!is2d && stride < 0) data += static_cast<size_t>(-stride) * (height - 1);
              for (int y = 0; y < height; ++y) {
                std::copy_n(data + static_cast<ptrdiff_t>(y) * stride, row_bytes,
                            frame.bgra.data() + static_cast<size_t>(y) * row_bytes);
              }
              state->latest = std::move(frame);
              state->received = Clock::now();
              if (state->received - state->previewed >= std::chrono::milliseconds(83)) {
                state->pending = Preview(state->latest, state->view);
                state->previewed = state->received;
                state->PostPreview();
              }
            }
            if (is2d) buffer2d->Unlock2D(); else buffer->Unlock();
          }
        }
      }
      if (FAILED(status)) {
        state->Fail(status);
      } else {
        reader = state->reader;
        state->ready.notify_all();
      }
    }
    if (reader) {
      const HRESULT next = reader->ReadSample(kVideoStream, 0, nullptr, nullptr, nullptr, nullptr);
      if (FAILED(next)) {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->active && state->generation == generation_) {
          state->Fail(next);
        }
      }
    }
    return S_OK;
  }
 private:
  LONG refs_ = 1;
  std::weak_ptr<StreamState> state_;
  int generation_;
};

ComPtr<IMFMediaSource> Source(const Device& device) {
  ComPtr<IMFAttributes> attrs;
  Check(MFCreateAttributes(&attrs, 2));
  Check(attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID));
  Check(attrs->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, device.link.c_str()));
  ComPtr<IMFMediaSource> source;
  Check(MFCreateDeviceSource(attrs.Get(), &source));
  return source;
}

std::vector<uint8_t> Encode(const Pixels& raw, int rotation) {
  const UINT width = static_cast<UINT>(rotation % 2 ? raw.height : raw.width);
  const UINT height = static_cast<UINT>(rotation % 2 ? raw.width : raw.height);
  std::vector<uint8_t> bgr(static_cast<size_t>(width) * height * 3);
  for (UINT y = 0; y < height; ++y) for (UINT x = 0; x < width; ++x) {
    const auto* src = Pixel(raw, static_cast<int>(x), static_cast<int>(y), rotation);
    std::copy_n(src, 3, bgr.data() + (static_cast<size_t>(y) * width + x) * 3);
  }
  ComPtr<IWICImagingFactory> factory;
  Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
  ComPtr<IStream> stream;
  Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  ComPtr<IWICBitmapEncoder> encoder;
  Check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
  Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame;
  Check(encoder->CreateNewFrame(&frame, nullptr));
  Check(frame->Initialize(nullptr));
  Check(frame->SetSize(width, height));
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  Check(frame->SetPixelFormat(&format));
  if (format != GUID_WICPixelFormat24bppBGR) throw std::runtime_error("相机图像编码格式不可用");
  Check(frame->WritePixels(height, width * 3, static_cast<UINT>(bgr.size()), bgr.data()));
  Check(frame->Commit()); Check(encoder->Commit());
  STATSTG stat{}; Check(stream->Stat(&stat, STATFLAG_NONAME));
  std::vector<uint8_t> bytes(static_cast<size_t>(stat.cbSize.QuadPart));
  LARGE_INTEGER start{}; Check(stream->Seek(start, STREAM_SEEK_SET, nullptr));
  ULONG read = 0; Check(stream->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &read));
  bytes.resize(read);
  return bytes;
}

// Only this worker touches device enumeration and open/close. Frames arrive on
// Media Foundation threads; Flutter replies/events are delivered on the UI thread.
class CameraWorker {
 public:
  explicit CameraWorker(HWND window) : state(std::make_shared<StreamState>()) {
    state->window = window;
    thread_ = std::thread([this] { Run(); });
  }
  ~CameraWorker() {
    { std::lock_guard<std::mutex> lock(queue_mutex_); quitting_ = true; }
    queued_.notify_one();
    thread_.join();
  }
  void Submit(std::string method, Map args, std::unique_ptr<Result> result) {
    auto reply = std::make_shared<Reply>(); reply->result = std::move(result);
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      tasks_.emplace_back([this, method, args, reply] {
        try { Check(startup_); reply->value = Invoke(method, args); }
        catch (const winrt::hresult_error& e) { reply->error = CameraError(e.code()); }
        catch (const std::exception& e) { reply->error = e.what(); }
        auto* posted = new Reply(std::move(*reply));
        if (!PostMessage(state->window, kReply, 0, reinterpret_cast<LPARAM>(posted))) delete posted;
      });
    }
    queued_.notify_one();
  }
  std::shared_ptr<StreamState> state;
 private:
  void Run() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    startup_ = FAILED(com) ? com : MFStartup(MF_VERSION);
    while (true) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        queued_.wait(lock, [this] { return quitting_ || !tasks_.empty(); });
        if (tasks_.empty() && quitting_) break;
        task = std::move(tasks_.front()); tasks_.pop_front();
      }
      task();
    }
    Close();
    if (SUCCEEDED(startup_)) MFShutdown();
    if (SUCCEEDED(com)) CoUninitialize();
  }
  void Close() {
    ComPtr<IMFSourceReader> reader;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->active = false; ++state->generation; reader = std::move(state->reader);
      state->latest = {}; state->pending = Value(); state->error = S_OK;
      state->ready.notify_all();
    }
    if (reader) reader->Flush(kAllStreams);
    if (source_) source_->Shutdown();
    source_.Reset();
    opened_link_.clear();
  }
  flutter::EncodableList Devices() {
    ComPtr<IMFAttributes> attrs;
    Check(MFCreateAttributes(&attrs, 1));
    Check(attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID));
    IMFActivate** found = nullptr; UINT32 count = 0;
    Check(MFEnumDeviceSources(attrs.Get(), &found, &count));
    devices_.clear();
    flutter::EncodableList names;
    for (UINT32 i = 0; i < count; ++i) {
      WCHAR* name = nullptr; WCHAR* link = nullptr; UINT32 length = 0;
      const HRESULT a = found[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length);
      const HRESULT b = found[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link, &length);
      if (SUCCEEDED(a) && SUCCEEDED(b)) {
        devices_.push_back({winrt::to_string(name), link});
        names.emplace_back(devices_.back().name);
      }
      CoTaskMemFree(name); CoTaskMemFree(link); found[i]->Release();
    }
    CoTaskMemFree(found);
    return names;
  }
  Device GetDevice(int index) {
    if (index < 0 || static_cast<size_t>(index) >= devices_.size()) throw std::runtime_error("摄像头不存在，请刷新设备列表");
    return devices_[index];
  }
  flutter::EncodableList Resolutions(const Device& device) {
    if (device.link == formats_link_ && !formats_.empty()) return formats_;
    auto source = Source(device);
    flutter::EncodableList list;
    try {
      ComPtr<IMFSourceReader> reader;
      Check(MFCreateSourceReaderFromMediaSource(source.Get(), nullptr, &reader));
      std::set<std::pair<UINT32, UINT32>> seen;
      for (DWORD index = 0; ; ++index) {
        ComPtr<IMFMediaType> type;
        const HRESULT hr = reader->GetNativeMediaType(kVideoStream, index, &type);
        if (hr == MF_E_NO_MORE_TYPES) break;
        Check(hr);
        UINT32 width = 0, height = 0;
        if (SUCCEEDED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height)) && width && height && seen.insert({width, height}).second) {
          list.emplace_back(Map{{Value("width"), Value(static_cast<int>(width))}, {Value("height"), Value(static_cast<int>(height))}});
        }
      }
    } catch (...) { source->Shutdown(); throw; }
    source->Shutdown();
    formats_link_ = device.link; formats_ = list;
    return list;
  }
  void Focus(bool required) {
    ComPtr<IAMCameraControl> control;
    HRESULT hr = source_ ? source_.As(&control) : E_FAIL;
    if (FAILED(hr) && source_) hr = MFGetService(source_.Get(), GUID_NULL, IID_PPV_ARGS(&control));
    LONG low = 0, high = 0, step = 0, def = 0, flags = 0;
    if (SUCCEEDED(hr)) hr = control->GetRange(CameraControl_Focus, &low, &high, &step, &def, &flags);
    if (SUCCEEDED(hr) && (flags & CameraControl_Flags_Auto)) {
      control->Set(CameraControl_Focus, def, CameraControl_Flags_Manual);
      hr = control->Set(CameraControl_Focus, def, CameraControl_Flags_Auto);
    } else { hr = E_NOTIMPL; }
    if (required && FAILED(hr)) throw std::runtime_error("当前相机不支持通过系统接口重新对焦，请调整镜头或拍摄距离");
  }
  void Open(const Map& args) {
    const auto device = GetDevice(Number(args, "device", 0));
    const int width = Number(args, "width", 1920), height = Number(args, "height", 1080);
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->active && opened_link_ == device.link && state->width == width && state->height == height) {
        state->view.Resize(args);
        return;
      }
    }
    Close();
    try {
      source_ = Source(device);
      ComPtr<IMFAttributes> attrs;
      Check(MFCreateAttributes(&attrs, 2));
      Check(attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE));
      ComPtr<IMFSourceReaderCallback> callback;
      callback.Attach(new ReaderCallback(state, state->generation));
      Check(attrs->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback.Get()));
      ComPtr<IMFSourceReader> reader;
      Check(MFCreateSourceReaderFromMediaSource(source_.Get(), attrs.Get(), &reader));
      ComPtr<IMFMediaType> chosen;
      double score = -1;
      for (DWORD index = 0; ; ++index) {
        ComPtr<IMFMediaType> type;
        const HRESULT hr = reader->GetNativeMediaType(kVideoStream, index, &type);
        if (hr == MF_E_NO_MORE_TYPES) break;
        Check(hr);
        UINT32 w = 0, h = 0, num = 0, den = 1;
        Check(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h));
        if (w != static_cast<UINT32>(width) || h != static_cast<UINT32>(height)) continue;
        MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &num, &den);
        const double fps = den ? static_cast<double>(num) / den : 0;
        const double rank = fps <= 30 ? fps : 30 - (fps - 30) / 1000;
        if (rank > score) { score = rank; chosen = type; }
      }
      if (!chosen) throw std::runtime_error("设备不支持所选分辨率，请刷新设备后重新选择");
      Check(reader->SetCurrentMediaType(kVideoStream, nullptr, chosen.Get()));
      ComPtr<IMFMediaType> rgb;
      Check(MFCreateMediaType(&rgb));
      Check(rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
      Check(rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32));
      Check(MFSetAttributeSize(rgb.Get(), MF_MT_FRAME_SIZE, static_cast<UINT32>(width), static_cast<UINT32>(height)));
      Check(reader->SetCurrentMediaType(kVideoStream, nullptr, rgb.Get()));
      Check(reader->GetCurrentMediaType(kVideoStream, &rgb));
      UINT32 w = 0, h = 0; Check(MFGetAttributeSize(rgb.Get(), MF_MT_FRAME_SIZE, &w, &h));
      if (w != static_cast<UINT32>(width) || h != static_cast<UINT32>(height)) throw std::runtime_error("摄像头返回了不同的采集尺寸，请重新选择分辨率");
      UINT32 stride = static_cast<UINT32>(width * 4);
      rgb->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride);
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->width = width; state->height = height; state->stride = static_cast<LONG>(stride);
        state->view.Resize(args);
        state->reader = reader; state->active = true; state->previewed = {};
      }
      Focus(false);
      const auto settling = Clock::now() + std::chrono::seconds(2);
      Check(reader->ReadSample(kVideoStream, 0, nullptr, nullptr, nullptr, nullptr));
      std::unique_lock<std::mutex> lock(state->mutex);
      if (!state->ready.wait_for(lock, std::chrono::seconds(12), [this] { return !state->latest.bgra.empty() || FAILED(state->error); })) {
        throw std::runtime_error("摄像头没有返回画面，请关闭占用设备的软件后重试");
      }
      Check(state->error);
      // Some UVC cameras initially return completely black frames. Continue
      // previewing while exposure/focus settles before enabling the shutter.
      state->ready.wait_until(lock, settling, [this] { return FAILED(state->error); });
      Check(state->error);
      opened_link_ = device.link;
    } catch (...) { Close(); throw; }
  }
  Value Invoke(const std::string& method, const Map& args) {
    if (method == "connect") return Value();
    if (method == "devices") return Value(Devices());
    if (method == "resolutions") return Value(Resolutions(GetDevice(Number(args, "device", 0))));
    if (method == "open") { Open(args); return Value(); }
    if (method == "close") { Close(); return Value(); }
    if (method == "barcode") throw std::runtime_error("系统摄像头暂不支持条码识别，请在设置中切换至厂商扫描仪服务");
    if (method == "capture" || method == "captureRaw") {
      Pixels photo; int rotation = 0;
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->active || state->latest.bgra.empty() || Clock::now() - state->received > std::chrono::seconds(5)) {
          throw std::runtime_error("没有实时摄像头画面，请重新连接设备");
        }
        photo = state->latest; rotation = state->view.rotation;
      }
      return Value(Encode(photo, rotation));
    }
    if (method == "setting") {
      const auto key = Text(args, "key"); const auto* value = Find(args, "value");
      if (key == "focus") { Focus(true); return Value(); }
      std::lock_guard<std::mutex> lock(state->mutex);
      auto& view = state->view;
      if (key == "rotation") view.rotation = (static_cast<int>(Decimal(value, 0)) % 4 + 4) % 4;
      if (key == "rotateDelta") view.rotation = (view.rotation + static_cast<int>(Decimal(value, 0)) % 4 + 4) % 4;
      if (key == "previewSize") { view.mode = value && std::holds_alternative<bool>(*value) && std::get<bool>(*value) ? 1 : 0; view.pan_x = view.pan_y = 0; }
      if (key == "zoom") { view.mode = 2; view.zoom = std::clamp(Decimal(value, 1), .2, 10.0); view.pan_x = view.pan_y = 0; }
      if (key == "zoomDelta") { view.mode = 2; view.zoom = std::clamp(view.zoom + Decimal(value, 0), .2, 10.0); }
      if (key == "trueSize" && !state->latest.bgra.empty()) {
        view.mode = 2;
        const int w = view.rotation % 2 ? state->height : state->width;
        const int h = view.rotation % 2 ? state->width : state->height;
        view.zoom = 1 / std::min(static_cast<double>(view.width) / w, static_cast<double>(view.height) / h);
      }
      if (key == "pan" && value && std::holds_alternative<flutter::EncodableList>(*value)) {
        const auto& pan = std::get<flutter::EncodableList>(*value);
        if (pan.size() == 2) { view.pan_x += Decimal(&pan[0], 0); view.pan_y += Decimal(&pan[1], 0); }
      }
      return Value();
    }
    throw std::runtime_error("不支持的相机操作");
  }
  std::vector<Device> devices_;
  std::wstring formats_link_;
  std::wstring opened_link_;
  flutter::EncodableList formats_;
  ComPtr<IMFMediaSource> source_;
  HRESULT startup_ = S_OK;
  bool quitting_ = false;
  std::mutex queue_mutex_;
  std::condition_variable queued_;
  std::deque<std::function<void()>> tasks_;
  std::thread thread_;
};

std::unique_ptr<CameraWorker> camera;
std::unique_ptr<flutter::EventChannel<Value>> frames;
std::unique_ptr<flutter::EventSink<Value>> event_sink;
}  // namespace

void RegisterWindowsCamera(flutter::FlutterEngine* engine, HWND window) {
  camera = std::make_unique<CameraWorker>(window);
  frames = std::make_unique<flutter::EventChannel<Value>>(engine->messenger(), "smart_scanner/frames", &flutter::StandardMethodCodec::GetInstance());
  frames->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& events) { event_sink = std::move(events); return nullptr; },
      [](const Value*) { event_sink.reset(); return nullptr; }));
}
bool HandleWindowsCameraCall(const flutter::MethodCall<Value>& call, std::unique_ptr<Result>& result) {
  const auto& method = call.method_name();
  if (method != "connect" && method != "devices" && method != "resolutions" && method != "open" &&
      method != "close" && method != "capture" && method != "captureRaw" && method != "setting" && method != "barcode") return false;
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  camera->Submit(method, args ? *args : Map{}, std::move(result));
  return true;
}
bool HandleWindowsCameraMessage(UINT message, LPARAM lparam) {
  if (message == kReply) {
    std::unique_ptr<Reply> reply(reinterpret_cast<Reply*>(lparam));
    if (reply->error.empty()) reply->result->Success(reply->value);
    else reply->result->Error("CAMERA", reply->error);
    return true;
  }
  if (message != kFrame || !camera) return false;
  Value frame; HRESULT error;
  {
    std::lock_guard<std::mutex> lock(camera->state->mutex);
    frame = std::move(camera->state->pending); error = camera->state->error;
    camera->state->posted = false;
  }
  if (event_sink) {
    if (FAILED(error)) event_sink->Error("CAMERA", CameraError(error));
    else if (!std::holds_alternative<std::monostate>(frame)) event_sink->Success(frame);
  }
  return true;
}
void ShutdownWindowsCamera(HWND window) {
  camera.reset();
  MSG message;
  while (PeekMessage(&message, window, kReply, kReply, PM_REMOVE)) delete reinterpret_cast<Reply*>(message.lParam);
  while (PeekMessage(&message, window, kFrame, kFrame, PM_REMOVE)) {}
  event_sink.reset(); frames.reset();
}
