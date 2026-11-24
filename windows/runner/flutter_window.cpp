#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <shlobj.h>
#include <windowsx.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <functional>
#include <limits>
#include <objbase.h>
#include <optional>
#include <utility>
#include <wincodec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT_PTR kChildViewSubclassId = 1;
constexpr UINT kTrayCallbackMessage = WM_APP + 2;
constexpr UINT kDestroyWindowMessage = WM_APP + 3;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayCmdShowWindow = 1001;
constexpr UINT kTrayCmdDownloads = 1002;
constexpr UINT kTrayCmdQuit = 1003;

bool StartsWithCaseInsensitive(const std::string& text, const char* prefix) {
  const std::string p(prefix);
  if (text.size() < p.size()) {
    return false;
  }
  for (size_t i = 0; i < p.size(); ++i) {
    const auto lhs =
        static_cast<char>(std::tolower(static_cast<unsigned char>(text[i])));
    const auto rhs =
        static_cast<char>(std::tolower(static_cast<unsigned char>(p[i])));
    if (lhs != rhs) {
      return false;
    }
  }
  return true;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int required = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (required <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(required), L'\0');
  const int written =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                            static_cast<int>(utf8.size()), out.data(), required);
  if (written <= 0) {
    return std::wstring();
  }
  return out;
}

std::string Utf8FromUtf16(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int required = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (required <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(required), '\0');
  const int written = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), out.data(),
      required, nullptr, nullptr);
  if (written <= 0) {
    return std::string();
  }
  return out;
}

constexpr size_t kMaxClipboardImageBytes = 32 * 1024 * 1024;

std::string OpenLocalFileOnWindows(HWND hwnd, const std::string& utf8_path) {
  const std::wstring wide = Utf16FromUtf8(utf8_path);
  if (wide.empty()) {
    return "failed";
  }
  if (::GetFileAttributesW(wide.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return "notFound";
  }
  const HINSTANCE result =
      ::ShellExecuteW(hwnd, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<intptr_t>(result) > 32 ? "opened" : "failed";
}

std::string ShowLocalFileInFolderOnWindows(HWND hwnd,
                                           const std::string& utf8_path) {
  const std::wstring wide = Utf16FromUtf8(utf8_path);
  if (wide.empty()) {
    return "failed";
  }
  if (::GetFileAttributesW(wide.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return "notFound";
  }
  PIDLIST_ABSOLUTE pidl = ::ILCreateFromPathW(wide.c_str());
  if (pidl != nullptr) {
    const HRESULT hr = ::SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
    ::ILFree(pidl);
    if (SUCCEEDED(hr)) {
      return "opened";
    }
  }
  const size_t slash = wide.find_last_of(L"\\/");
  if (slash != std::wstring::npos && slash > 0) {
    const std::wstring parent = wide.substr(0, slash);
    const HINSTANCE result = ::ShellExecuteW(hwnd, L"open", parent.c_str(),
                                             nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<intptr_t>(result) > 32) {
      return "opened";
    }
  }
  return "failed";
}

class ParfaitDropTarget final : public IDropTarget {
 public:
  using Callback =
      std::function<void(const char*, const std::vector<std::string>&)>;

  explicit ParfaitDropTarget(Callback callback)
      : callback_(std::move(callback)) {}

  void Detach() { callback_ = nullptr; }

  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *ppv = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  STDMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(++ref_count_);
  }

  STDMETHODIMP_(ULONG) Release() override {
    const ULONG next = static_cast<ULONG>(--ref_count_);
    if (next == 0) {
      delete this;
    }
    return next;
  }

  STDMETHODIMP DragEnter(IDataObject* data_obj,
                         DWORD grfKeyState,
                         POINTL pt,
                         DWORD* pdwEffect) override {
    (void)grfKeyState;
    (void)pt;
    has_files_ = HasDropFiles(data_obj);
    if (pdwEffect != nullptr) {
      *pdwEffect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    if (has_files_ && callback_) {
      callback_("entered", {});
    }
    return S_OK;
  }

  STDMETHODIMP DragOver(DWORD grfKeyState,
                        POINTL pt,
                        DWORD* pdwEffect) override {
    (void)grfKeyState;
    (void)pt;
    if (pdwEffect != nullptr) {
      *pdwEffect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    return S_OK;
  }

  STDMETHODIMP DragLeave() override {
    if (has_files_ && callback_) {
      callback_("exited", {});
    }
    has_files_ = false;
    return S_OK;
  }

  STDMETHODIMP Drop(IDataObject* data_obj,
                    DWORD grfKeyState,
                    POINTL pt,
                    DWORD* pdwEffect) override {
    (void)grfKeyState;
    (void)pt;
    const std::vector<std::string> paths = ExtractDropPaths(data_obj);
    has_files_ = false;
    if (pdwEffect != nullptr) {
      *pdwEffect = paths.empty() ? DROPEFFECT_NONE : DROPEFFECT_COPY;
    }
    if (callback_) {
      callback_("exited", {});
      if (!paths.empty()) {
        callback_("dropped", paths);
      }
    }
    return S_OK;
  }

 private:
  static bool HasDropFiles(IDataObject* data_obj) {
    if (data_obj == nullptr) {
      return false;
    }
    FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    return data_obj->QueryGetData(&fmt) == S_OK;
  }

  static std::vector<std::string> ExtractDropPaths(IDataObject* data_obj) {
    std::vector<std::string> paths;
    if (data_obj == nullptr) {
      return paths;
    }
    FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM stg{};
    if (FAILED(data_obj->GetData(&fmt, &stg))) {
      return paths;
    }
    if (stg.tymed == TYMED_HGLOBAL && stg.hGlobal != nullptr) {
      HDROP hdrop = static_cast<HDROP>(::GlobalLock(stg.hGlobal));
      if (hdrop != nullptr) {
        const UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFFu, nullptr, 0);
        for (UINT i = 0; i < count; ++i) {
          const UINT chars = ::DragQueryFileW(hdrop, i, nullptr, 0);
          if (chars == 0) {
            continue;
          }
          std::wstring buf(static_cast<size_t>(chars) + 1, L'\0');
          if (::DragQueryFileW(hdrop, i, buf.data(), chars + 1) > 0) {
            buf.resize(chars);
            std::string utf8 = Utf8FromUtf16(buf);
            if (!utf8.empty()) {
              paths.push_back(std::move(utf8));
            }
          }
        }
        ::GlobalUnlock(stg.hGlobal);
      }
    }
    ::ReleaseStgMedium(&stg);
    return paths;
  }

  std::atomic<ULONG> ref_count_{1};
  bool has_files_ = false;
  Callback callback_;
};

bool ReadEncodableDouble(const flutter::EncodableValue& value, double* out) {
  if (const auto* d = std::get_if<double>(&value)) {
    *out = *d;
    return true;
  }
  if (const auto* i32 = std::get_if<int32_t>(&value)) {
    *out = static_cast<double>(*i32);
    return true;
  }
  if (const auto* i64 = std::get_if<int64_t>(&value)) {
    *out = static_cast<double>(*i64);
    return true;
  }
  return false;
}

std::string ReadEncodableString(const flutter::EncodableMap& map,
                                const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::string();
  }
  if (const auto* str = std::get_if<std::string>(&it->second)) {
    return *str;
  }
  return std::string();
}

flutter::EncodableMap BuildViewIntentMap(const std::string& uri) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("action"),
       flutter::EncodableValue("android.intent.action.VIEW")},
      {flutter::EncodableValue("uri"), flutter::EncodableValue(uri)},
  };
}

bool WriteSensitiveClipboardFormat(UINT format, const void* data, size_t bytes) {
  HGLOBAL handle = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (handle == nullptr) {
    return false;
  }
  void* locked = ::GlobalLock(handle);
  if (locked == nullptr) {
    ::GlobalFree(handle);
    return false;
  }
  ::CopyMemory(locked, data, bytes);
  ::GlobalUnlock(handle);
  if (::SetClipboardData(format, handle) == nullptr) {
    ::GlobalFree(handle);
    return false;
  }
  return true;
}

bool WriteSensitiveClipboardText(HWND owner, const std::string& utf8_text) {
  const std::wstring wide = Utf16FromUtf8(utf8_text);
  if (wide.empty()) {
    return false;
  }
  const UINT monitor_format = ::RegisterClipboardFormatW(
      L"ExcludeClipboardContentFromMonitorProcessing");
  const UINT history_format =
      ::RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
  const UINT cloud_format =
      ::RegisterClipboardFormatW(L"CanUploadToCloudClipboard");
  if (monitor_format == 0 || history_format == 0 || cloud_format == 0) {
    return false;
  }
  if (!::OpenClipboard(owner)) {
    return false;
  }
  bool ok = ::EmptyClipboard() != FALSE;
  if (ok) {
    const size_t text_bytes = (wide.size() + 1) * sizeof(wchar_t);
    const DWORD exclude_monitor = 1;
    const DWORD disable_flag = 0;
    ok = WriteSensitiveClipboardFormat(CF_UNICODETEXT, wide.c_str(),
                                       text_bytes) &&
         WriteSensitiveClipboardFormat(monitor_format, &exclude_monitor,
                                       sizeof(exclude_monitor)) &&
         WriteSensitiveClipboardFormat(history_format, &disable_flag,
                                       sizeof(disable_flag)) &&
         WriteSensitiveClipboardFormat(cloud_format, &disable_flag,
                                       sizeof(disable_flag));
    if (!ok) {
      ::EmptyClipboard();
    }
  }
  ::CloseClipboard();
  return ok;
}

}  // namespace

bool IsSupportedLaunchUri(const std::string& uri) {
  return StartsWithCaseInsensitive(uri, "pixiv://") ||
         StartsWithCaseInsensitive(uri, "parfait://") ||
         StartsWithCaseInsensitive(uri, "http://") ||
         StartsWithCaseInsensitive(uri, "https://");
}

template <typename T>
struct ComPtr {
  ComPtr() = default;
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;
  ~ComPtr() { reset(); }

  void reset() {
    if (ptr != nullptr) {
      ptr->Release();
      ptr = nullptr;
    }
  }

  T** put() {
    reset();
    return &ptr;
  }

  T* operator->() const { return ptr; }

  T* ptr = nullptr;
};

struct ComInitScope {
  bool uninit = false;
  ~ComInitScope() {
    if (uninit) {
      ::CoUninitialize();
    }
  }
};

HGLOBAL AllocClipboardHGlobal(const void* data, size_t size) {
  if (data == nullptr || size == 0) {
    return nullptr;
  }
  HGLOBAL handle = ::GlobalAlloc(GMEM_MOVEABLE, size);
  if (handle == nullptr) {
    return nullptr;
  }
  void* dst = ::GlobalLock(handle);
  if (dst == nullptr) {
    ::GlobalFree(handle);
    return nullptr;
  }
  std::memcpy(dst, data, size);
  ::GlobalUnlock(handle);
  return handle;
}

bool CopyEncodedImageToClipboard(HWND hwnd, const std::vector<uint8_t>& bytes) {
  if (bytes.empty() ||
      bytes.size() > static_cast<size_t>((std::numeric_limits<DWORD>::max)())) {
    return false;
  }

  const HRESULT co_hr =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(co_hr) && co_hr != RPC_E_CHANGED_MODE) {
    return false;
  }
  ComInitScope com_scope{SUCCEEDED(co_hr)};

  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(factory.put())))) {
    return false;
  }

  ComPtr<IWICStream> wic_stream;
  if (FAILED(factory->CreateStream(wic_stream.put())) ||
      FAILED(wic_stream->InitializeFromMemory(
          const_cast<BYTE*>(bytes.data()),
          static_cast<DWORD>(bytes.size())))) {
    return false;
  }

  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          wic_stream.ptr, nullptr, WICDecodeMetadataCacheOnDemand,
          decoder.put()))) {
    return false;
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, frame.put()))) {
    return false;
  }

  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(converter.put())) ||
      FAILED(converter->Initialize(frame.ptr, GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return false;
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 ||
      height == 0 ||
      width > static_cast<UINT>((std::numeric_limits<LONG>::max)()) ||
      height > static_cast<UINT>((std::numeric_limits<LONG>::max)())) {
    return false;
  }

  const uint64_t stride64 = static_cast<uint64_t>(width) * 4ULL;
  const uint64_t pixel_bytes64 = stride64 * static_cast<uint64_t>(height);
  const uint64_t dib_total64 = sizeof(BITMAPINFOHEADER) + pixel_bytes64;
  if (stride64 > (std::numeric_limits<UINT>::max)() ||
      pixel_bytes64 > (std::numeric_limits<UINT>::max)() ||
      dib_total64 > (std::numeric_limits<size_t>::max)()) {
    return false;
  }

  const UINT stride = static_cast<UINT>(stride64);
  const UINT pixel_bytes = static_cast<UINT>(pixel_bytes64);
  std::vector<uint8_t> pixels(static_cast<size_t>(pixel_bytes));
  if (FAILED(converter->CopyPixels(nullptr, stride, pixel_bytes,
                                   pixels.data()))) {
    return false;
  }

  HGLOBAL dib_handle =
      ::GlobalAlloc(GMEM_MOVEABLE, static_cast<SIZE_T>(dib_total64));
  if (dib_handle == nullptr) {
    return false;
  }
  void* dib_mem = ::GlobalLock(dib_handle);
  if (dib_mem == nullptr) {
    ::GlobalFree(dib_handle);
    return false;
  }

  BITMAPINFOHEADER bih{};
  bih.biSize = sizeof(BITMAPINFOHEADER);
  bih.biWidth = static_cast<LONG>(width);
  bih.biHeight = static_cast<LONG>(height);
  bih.biPlanes = 1;
  bih.biBitCount = 32;
  bih.biCompression = BI_RGB;
  bih.biSizeImage = static_cast<DWORD>(pixel_bytes);
  std::memcpy(dib_mem, &bih, sizeof(bih));

  uint8_t* dib_pixels = static_cast<uint8_t*>(dib_mem) + sizeof(bih);
  for (UINT y = 0; y < height; ++y) {
    const uint8_t* src_row = pixels.data() + static_cast<size_t>(height - 1 - y) * stride;
    uint8_t* dst_row = dib_pixels + static_cast<size_t>(y) * stride;
    std::memcpy(dst_row, src_row, stride);
  }
  ::GlobalUnlock(dib_handle);

  HGLOBAL png_handle = nullptr;
  ComPtr<IStream> png_stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> enc_frame;
  if (SUCCEEDED(::CreateStreamOnHGlobal(nullptr, TRUE, png_stream.put())) &&
      SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                       encoder.put())) &&
      SUCCEEDED(encoder->Initialize(png_stream.ptr, WICBitmapEncoderNoCache)) &&
      SUCCEEDED(encoder->CreateNewFrame(enc_frame.put(), nullptr)) &&
      SUCCEEDED(enc_frame->Initialize(nullptr)) &&
      SUCCEEDED(enc_frame->SetSize(width, height))) {
    WICPixelFormatGUID png_format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(enc_frame->SetPixelFormat(&png_format)) &&
        SUCCEEDED(enc_frame->WriteSource(converter.ptr, nullptr)) &&
        SUCCEEDED(enc_frame->Commit()) &&
        SUCCEEDED(encoder->Commit())) {
      HGLOBAL png_src = nullptr;
      STATSTG stat{};
      if (SUCCEEDED(::GetHGlobalFromStream(png_stream.ptr, &png_src)) &&
          png_src != nullptr &&
          SUCCEEDED(png_stream->Stat(&stat, STATFLAG_NONAME)) &&
          stat.cbSize.QuadPart > 0 &&
          stat.cbSize.QuadPart <= ::GlobalSize(png_src)) {
        const size_t png_bytes = static_cast<size_t>(stat.cbSize.QuadPart);
        if (void* locked = ::GlobalLock(png_src); locked != nullptr) {
          png_handle = AllocClipboardHGlobal(locked, png_bytes);
          ::GlobalUnlock(png_src);
        }
      }
    }
  }

  const UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (!::OpenClipboard(hwnd)) {
    ::GlobalFree(dib_handle);
    if (png_handle != nullptr) {
      ::GlobalFree(png_handle);
    }
    return false;
  }

  ::EmptyClipboard();
  bool ok = false;
  if (::SetClipboardData(CF_DIB, dib_handle) != nullptr) {
    dib_handle = nullptr;
    ok = true;
  }
  if (png_format != 0 && png_handle != nullptr) {
    if (::SetClipboardData(png_format, png_handle) != nullptr) {
      png_handle = nullptr;
      ok = true;
    }
  }
  ::CloseClipboard();

  if (dib_handle != nullptr) {
    ::GlobalFree(dib_handle);
  }
  if (png_handle != nullptr) {
    ::GlobalFree(png_handle);
  }
  return ok;
}

std::optional<std::vector<uint8_t>> EncodeWicSourceToPng(
    IWICImagingFactory* factory,
    IWICBitmapSource* source) {
  if (factory == nullptr || source == nullptr) {
    return std::nullopt;
  }
  UINT width = 0;
  UINT height = 0;
  if (FAILED(source->GetSize(&width, &height)) || width == 0 || height == 0) {
    return std::nullopt;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(converter.put())) ||
      FAILED(converter->Initialize(source, GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return std::nullopt;
  }
  ComPtr<IStream> png_stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> enc_frame;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, png_stream.put())) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    encoder.put())) ||
      FAILED(encoder->Initialize(png_stream.ptr, WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(enc_frame.put(), nullptr)) ||
      FAILED(enc_frame->Initialize(nullptr)) ||
      FAILED(enc_frame->SetSize(width, height))) {
    return std::nullopt;
  }
  WICPixelFormatGUID png_format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(enc_frame->SetPixelFormat(&png_format)) ||
      FAILED(enc_frame->WriteSource(converter.ptr, nullptr)) ||
      FAILED(enc_frame->Commit()) ||
      FAILED(encoder->Commit())) {
    return std::nullopt;
  }
  HGLOBAL png_src = nullptr;
  STATSTG stat{};
  if (FAILED(::GetHGlobalFromStream(png_stream.ptr, &png_src)) ||
      png_src == nullptr ||
      FAILED(png_stream->Stat(&stat, STATFLAG_NONAME)) ||
      stat.cbSize.QuadPart <= 0 ||
      static_cast<uint64_t>(stat.cbSize.QuadPart) > kMaxClipboardImageBytes ||
      stat.cbSize.QuadPart > static_cast<ULONGLONG>(::GlobalSize(png_src))) {
    return std::nullopt;
  }
  const size_t png_bytes = static_cast<size_t>(stat.cbSize.QuadPart);
  void* locked = ::GlobalLock(png_src);
  if (locked == nullptr) {
    return std::nullopt;
  }
  std::vector<uint8_t> out(png_bytes);
  std::memcpy(out.data(), locked, png_bytes);
  ::GlobalUnlock(png_src);
  return out;
}

std::optional<std::vector<uint8_t>> ReadEncodedImageFromClipboard(HWND hwnd) {
  const UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (!::OpenClipboard(hwnd)) {
    return std::nullopt;
  }

  std::optional<std::vector<uint8_t>> png_direct;
  std::vector<uint8_t> dib_bytes;
  HBITMAP hbitmap_copy = nullptr;

  if (png_format != 0 && ::IsClipboardFormatAvailable(png_format)) {
    if (HANDLE handle = ::GetClipboardData(png_format); handle != nullptr) {
      const SIZE_T size = ::GlobalSize(handle);
      if (size > 0 && size <= kMaxClipboardImageBytes) {
        if (const void* locked = ::GlobalLock(handle); locked != nullptr) {
          std::vector<uint8_t> raw(static_cast<size_t>(size));
          std::memcpy(raw.data(), locked, static_cast<size_t>(size));
          ::GlobalUnlock(handle);
          png_direct = std::move(raw);
        }
      }
    }
  } else if (::IsClipboardFormatAvailable(CF_DIBV5) ||
             ::IsClipboardFormatAvailable(CF_DIB)) {
    const UINT fmt =
        ::IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB;
    if (HANDLE handle = ::GetClipboardData(fmt); handle != nullptr) {
      const SIZE_T size = ::GlobalSize(handle);
      if (size >= sizeof(BITMAPINFOHEADER) &&
          size <= kMaxClipboardImageBytes) {
        if (const void* locked = ::GlobalLock(handle); locked != nullptr) {
          dib_bytes.resize(static_cast<size_t>(size));
          std::memcpy(dib_bytes.data(), locked, static_cast<size_t>(size));
          ::GlobalUnlock(handle);
        }
      }
    }
  } else if (::IsClipboardFormatAvailable(CF_BITMAP)) {
    if (HANDLE handle = ::GetClipboardData(CF_BITMAP); handle != nullptr) {
      hbitmap_copy = static_cast<HBITMAP>(
          ::CopyImage(handle, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION));
    }
  }

  ::CloseClipboard();

  if (png_direct.has_value()) {
    return png_direct;
  }
  if (dib_bytes.empty() && hbitmap_copy == nullptr) {
    return std::nullopt;
  }

  const HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(co_hr) && co_hr != RPC_E_CHANGED_MODE) {
    if (hbitmap_copy != nullptr) {
      ::DeleteObject(hbitmap_copy);
    }
    return std::nullopt;
  }
  ComInitScope com_scope{SUCCEEDED(co_hr)};

  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(factory.put())))) {
    if (hbitmap_copy != nullptr) {
      ::DeleteObject(hbitmap_copy);
    }
    return std::nullopt;
  }

  if (!dib_bytes.empty()) {
    BITMAPINFOHEADER bih{};
    std::memcpy(&bih, dib_bytes.data(), sizeof(bih));
    if (bih.biSize < sizeof(BITMAPINFOHEADER) ||
        bih.biSize > dib_bytes.size()) {
      return std::nullopt;
    }
    DWORD color_entries = bih.biClrUsed;
    if (color_entries == 0 && bih.biBitCount <= 8) {
      color_entries = 1u << bih.biBitCount;
    }
    DWORD extra_masks = 0;
    if (bih.biSize == sizeof(BITMAPINFOHEADER) &&
        bih.biCompression == BI_BITFIELDS) {
      extra_masks = 12;
    }
    const uint64_t offset64 = sizeof(BITMAPFILEHEADER) +
                              static_cast<uint64_t>(bih.biSize) +
                              static_cast<uint64_t>(color_entries) * 4ULL +
                              static_cast<uint64_t>(extra_masks);
    const uint64_t total64 = sizeof(BITMAPFILEHEADER) + dib_bytes.size();
    if (offset64 > total64 || total64 > kMaxClipboardImageBytes + sizeof(BITMAPFILEHEADER)) {
      return std::nullopt;
    }
    BITMAPFILEHEADER bfh{};
    bfh.bfType = 0x4D42;  // 'BM'
    bfh.bfSize = static_cast<DWORD>(total64);
    bfh.bfOffBits = static_cast<DWORD>(offset64);
    std::vector<uint8_t> bmp(static_cast<size_t>(total64));
    std::memcpy(bmp.data(), &bfh, sizeof(bfh));
    std::memcpy(bmp.data() + sizeof(bfh), dib_bytes.data(), dib_bytes.size());

    ComPtr<IWICStream> wic_stream;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (SUCCEEDED(factory->CreateStream(wic_stream.put())) &&
        SUCCEEDED(wic_stream->InitializeFromMemory(
            bmp.data(), static_cast<DWORD>(bmp.size()))) &&
        SUCCEEDED(factory->CreateDecoderFromStream(
            wic_stream.ptr, nullptr, WICDecodeMetadataCacheOnDemand,
            decoder.put())) &&
        SUCCEEDED(decoder->GetFrame(0, frame.put()))) {
      return EncodeWicSourceToPng(factory.ptr, frame.ptr);
    }
    return std::nullopt;
  }

  std::optional<std::vector<uint8_t>> result;
  if (hbitmap_copy != nullptr) {
    ComPtr<IWICBitmap> wic_bitmap;
    if (SUCCEEDED(factory->CreateBitmapFromHBITMAP(
            hbitmap_copy, nullptr, WICBitmapIgnoreAlpha, wic_bitmap.put()))) {
      result = EncodeWicSourceToPng(factory.ptr, wic_bitmap.ptr);
    }
    ::DeleteObject(hbitmap_copy);
  }
  return result;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::string initial_intent_uri,
                             bool is_dev_profile)
    : project_(project),
      initial_intent_uri_(std::move(initial_intent_uri)),
      is_dev_profile_(is_dev_profile) {}

FlutterWindow::~FlutterWindow() {
  if (flutter_controller_) {
    OnDestroy();
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::SetPropW(hwnd,
               is_dev_profile_ ? kParfaitDevMainWindowProp
                               : kParfaitMainWindowProp,
               reinterpret_cast<HANDLE>(1));
    taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
    is_active_ = (::GetForegroundWindow() == hwnd);
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  child_view_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child_view_hwnd_);
  if (child_view_hwnd_ != nullptr) {
    ::SetWindowSubclass(child_view_hwnd_, ChildViewSubclassProc,
                        kChildViewSubclassId, reinterpret_cast<DWORD_PTR>(this));
  }

  RegisterNativeChannels();
  RegisterDropTargets();

  if (hwnd != nullptr) {
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                       SWP_NOACTIVATE);
  }

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RevokeDropTargets();
  RemoveTrayIcon();

  if (desktop_window_channel_) {
    desktop_window_channel_->SetMethodCallHandler(nullptr);
    desktop_window_channel_.reset();
  }
  if (tray_channel_) {
    tray_channel_->SetMethodCallHandler(nullptr);
    tray_channel_.reset();
  }
  if (navigation_channel_) {
    navigation_channel_->SetMethodCallHandler(nullptr);
    navigation_channel_.reset();
  }
  if (sensitive_clipboard_channel_) {
    sensitive_clipboard_channel_->SetMethodCallHandler(nullptr);
    sensitive_clipboard_channel_.reset();
  }
  if (image_clipboard_channel_) {
    image_clipboard_channel_->SetMethodCallHandler(nullptr);
    image_clipboard_channel_.reset();
  }
  if (desktop_file_actions_channel_) {
    desktop_file_actions_channel_->SetMethodCallHandler(nullptr);
    desktop_file_actions_channel_.reset();
  }
  if (file_drop_event_channel_) {
    file_drop_event_channel_->SetStreamHandler(nullptr);
    file_drop_event_channel_.reset();
  }
  file_drop_event_sink_.reset();
  if (intent_channel_) {
    intent_channel_->SetMethodCallHandler(nullptr);
    intent_channel_.reset();
  }
  if (intent_event_channel_) {
    intent_event_channel_->SetStreamHandler(nullptr);
    intent_event_channel_.reset();
  }
  intent_event_sink_.reset();

  if (child_view_hwnd_ != nullptr) {
    ::RemoveWindowSubclass(child_view_hwnd_, ChildViewSubclassProc,
                           kChildViewSubclassId);
    child_view_hwnd_ = nullptr;
  }
  if (HWND hwnd = GetHandle(); hwnd != nullptr) {
    ::RemovePropW(hwnd, is_dev_profile_ ? kParfaitDevMainWindowProp
                                        : kParfaitMainWindowProp);
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterNativeChannels() {
  flutter::BinaryMessenger* messenger =
      flutter_controller_->engine()->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();

  desktop_window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/desktop_window", codec);
  desktop_window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        const std::string& method = call.method_name();
        if (method == "getMetrics") {
          result->Success(flutter::EncodableValue(BuildWindowMetricsMap()));
          return;
        }
        if (method == "setTitleBarMetrics") {
          std::vector<TitleBarRegion> next_regions;
          if (call.arguments() != nullptr) {
            if (const auto* map =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              const auto it = map->find(flutter::EncodableValue("regions"));
              if (it != map->end()) {
                if (const auto* list =
                        std::get_if<flutter::EncodableList>(&it->second)) {
                  for (const auto& item : *list) {
                    const auto* tuple =
                        std::get_if<flutter::EncodableList>(&item);
                    if (tuple == nullptr || tuple->size() < 5) {
                      continue;
                    }
                    TitleBarRegion region;
                    if (!ReadEncodableDouble((*tuple)[0], &region.left) ||
                        !ReadEncodableDouble((*tuple)[1], &region.top) ||
                        !ReadEncodableDouble((*tuple)[2], &region.right) ||
                        !ReadEncodableDouble((*tuple)[3], &region.bottom)) {
                      continue;
                    }
                    if (const auto* kind =
                            std::get_if<std::string>(&(*tuple)[4])) {
                      region.kind = *kind;
                      next_regions.push_back(std::move(region));
                    }
                  }
                }
              }
            }
          }
          title_bar_regions_ = std::move(next_regions);
          result->Success();
          return;
        }
        if (method == "minimize") {
          if (hwnd != nullptr) {
            ::ShowWindow(hwnd, SW_MINIMIZE);
          }
          result->Success();
          return;
        }
        if (method == "toggleMaximize" || method == "titleBarDoubleClick") {
          if (hwnd != nullptr) {
            ::PostMessageW(hwnd, WM_SYSCOMMAND,
                           ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
          }
          result->Success();
          return;
        }
        if (method == "close") {
          if (hwnd != nullptr) {
            ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
          }
          result->Success();
          return;
        }
        if (method == "destroy") {
          // Post destruction onto the live Win32 message queue after replying
          // so DestroyWindow runs outside the MethodChannel stack frame and
          // triggers WM_DESTROY -> OnDestroy() -> PostQuitMessage(0) cleanly.
          result->Success();
          if (hwnd != nullptr) {
            ::PostMessageW(hwnd, kDestroyWindowMessage, 0, 0);
          }
          return;
        }
        if (method == "startDragging") {
          if (hwnd != nullptr) {
            ::ReleaseCapture();
            ::SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          }
          result->Success();
          return;
        }
        if (method == "toggleFullScreen") {
          ToggleFullscreen();
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/tray", codec);
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "isSupported") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "initialize" || method == "updateLabels") {
          if (call.arguments() != nullptr) {
            if (const auto* map =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              const std::string tip = ReadEncodableString(*map, "tooltip");
              const std::string show = ReadEncodableString(*map, "showWindow");
              const std::string dl = ReadEncodableString(*map, "downloads");
              const std::string quit = ReadEncodableString(*map, "quit");
              if (!tip.empty()) {
                tray_labels_.tooltip = Utf16FromUtf8(tip);
              }
              if (!show.empty()) {
                tray_labels_.show_window = Utf16FromUtf8(show);
              }
              if (!dl.empty()) {
                tray_labels_.downloads = Utf16FromUtf8(dl);
              }
              if (!quit.empty()) {
                tray_labels_.quit = Utf16FromUtf8(quit);
              }
            }
          }
          if (method == "initialize") {
            EnsureTrayIcon();
          } else {
            UpdateTrayIconTip();
          }
          result->Success();
          return;
        }
        if (method == "dispose") {
          RemoveTrayIcon();
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  navigation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/navigation_commands", codec);

  sensitive_clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/desktop_sensitive_clipboard", codec);
  sensitive_clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "capabilities") {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("sensitiveMarkSupported"),
               flutter::EncodableValue(true)},
          }));
          return;
        }
        if (call.method_name() == "write") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          const std::string text = args == nullptr
                                       ? std::string()
                                       : ReadEncodableString(*args, "text");
          if (text.empty()) {
            result->Error("invalid_argument", "text is required");
            return;
          }
          if (!WriteSensitiveClipboardText(GetHandle(), text)) {
            result->Error("clipboard_unavailable",
                          "failed to write sensitive clipboard data");
            return;
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });

  intent_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/android_intents", codec);
  intent_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialIntent") {
          initial_intent_consumed_ = true;
          if (!initial_intent_uri_.empty()) {
            const std::string uri = std::move(initial_intent_uri_);
            initial_intent_uri_.clear();
            result->Success(flutter::EncodableValue(BuildViewIntentMap(uri)));
          } else {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("action"),
                 flutter::EncodableValue("android.intent.action.MAIN")},
            }));
          }
          return;
        }
        result->NotImplemented();
      });

  intent_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "parfait/android_intents/events", codec);
  intent_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            intent_event_sink_ = std::move(events);
            if (!pending_live_uris_.empty() && intent_event_sink_) {
              for (const auto& uri : pending_live_uris_) {
                intent_event_sink_->Success(
                    flutter::EncodableValue(BuildViewIntentMap(uri)));
              }
              pending_live_uris_.clear();
            }
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            intent_event_sink_.reset();
            return nullptr;
          }));

  image_clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/image_clipboard", codec);
  image_clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "readImage") {
          auto encoded = ReadEncodedImageFromClipboard(GetHandle());
          if (encoded.has_value()) {
            result->Success(flutter::EncodableValue(std::move(*encoded)));
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() != "copyImage") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("INVALID_ARGS", "Expected argument map");
          return;
        }
        const auto it = args->find(flutter::EncodableValue("bytes"));
        if (it == args->end()) {
          result->Error("INVALID_ARGS", "Missing bytes");
          return;
        }
        const auto* bytes = std::get_if<std::vector<uint8_t>>(&it->second);
        if (bytes == nullptr) {
          result->Error("INVALID_ARGS", "Expected Uint8List bytes");
          return;
        }
        result->Success(flutter::EncodableValue(
            CopyEncodedImageToClipboard(GetHandle(), *bytes)));
      });

  desktop_file_actions_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/desktop_file_actions", codec);
  desktop_file_actions_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string path =
            args == nullptr ? std::string() : ReadEncodableString(*args, "path");
        if (path.empty()) {
          result->Success(flutter::EncodableValue(std::string("failed")));
          return;
        }
        if (call.method_name() == "openFile") {
          result->Success(flutter::EncodableValue(
              OpenLocalFileOnWindows(GetHandle(), path)));
          return;
        }
        if (call.method_name() == "showInFolder") {
          result->Success(flutter::EncodableValue(
              ShowLocalFileInFolderOnWindows(GetHandle(), path)));
          return;
        }
        result->NotImplemented();
      });

  file_drop_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "parfait/file_drop/events", codec);
  file_drop_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            (void)arguments;
            file_drop_event_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            (void)arguments;
            file_drop_event_sink_.reset();
            return nullptr;
          }));
}

void FlutterWindow::EmitFileDropEvent(const char* type,
                                      const std::vector<std::string>& paths) {
  if (!file_drop_event_sink_ || type == nullptr) {
    return;
  }
  flutter::EncodableMap payload{
      {flutter::EncodableValue("type"),
       flutter::EncodableValue(std::string(type))},
  };
  if (!paths.empty()) {
    flutter::EncodableList list;
    list.reserve(paths.size());
    for (const auto& path : paths) {
      list.emplace_back(path);
    }
    payload.emplace(flutter::EncodableValue("paths"),
                    flutter::EncodableValue(std::move(list)));
  }
  file_drop_event_sink_->Success(flutter::EncodableValue(std::move(payload)));
}

void FlutterWindow::RegisterDropTargets() {
  if (drop_target_ != nullptr) {
    return;
  }
  auto* target = new ParfaitDropTarget(
      [this](const char* type, const std::vector<std::string>& paths) {
        EmitFileDropEvent(type, paths);
      });
  drop_target_ = target;
  if (child_view_hwnd_ != nullptr &&
      SUCCEEDED(::RegisterDragDrop(child_view_hwnd_, drop_target_))) {
    child_drop_registered_ = true;
  }
  if (HWND hwnd = GetHandle();
      hwnd != nullptr && SUCCEEDED(::RegisterDragDrop(hwnd, drop_target_))) {
    main_drop_registered_ = true;
  }
}

void FlutterWindow::RevokeDropTargets() {
  if (child_drop_registered_ && child_view_hwnd_ != nullptr) {
    ::RevokeDragDrop(child_view_hwnd_);
    child_drop_registered_ = false;
  }
  if (main_drop_registered_) {
    if (HWND hwnd = GetHandle(); hwnd != nullptr) {
      ::RevokeDragDrop(hwnd);
    }
    main_drop_registered_ = false;
  }
  if (drop_target_ != nullptr) {
    static_cast<ParfaitDropTarget*>(drop_target_)->Detach();
    drop_target_->Release();
    drop_target_ = nullptr;
  }
}

flutter::EncodableMap FlutterWindow::BuildWindowMetricsMap() const {
  HWND hwnd = GetHandle();
  const bool zoomed = hwnd != nullptr && ::IsZoomed(hwnd) != FALSE;
  return flutter::EncodableMap{
      {flutter::EncodableValue("isWayland"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("usesSystemTitleBar"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("isFullScreen"),
       flutter::EncodableValue(IsFullscreenState())},
      {flutter::EncodableValue("isMaximized"), flutter::EncodableValue(zoomed)},
      {flutter::EncodableValue("isActive"),
       flutter::EncodableValue(is_active_)},
      {flutter::EncodableValue("trafficLightWidth"),
       flutter::EncodableValue(0.0)},
      {flutter::EncodableValue("trafficLightHeight"),
       flutter::EncodableValue(0.0)},
      {flutter::EncodableValue("hoveredButton"),
       flutter::EncodableValue(hovered_button_)},
      {flutter::EncodableValue("pressedButton"),
       flutter::EncodableValue(pressed_button_)},
  };
}

void FlutterWindow::EmitWindowMetrics(bool force) {
  if (!desktop_window_channel_) {
    return;
  }
  HWND hwnd = GetHandle();
  const bool zoomed = hwnd != nullptr && ::IsZoomed(hwnd) != FALSE;
  const bool fullscreen = IsFullscreenState();
  if (!force && has_emitted_metrics_ && zoomed == last_emitted_maximized_ &&
      fullscreen == last_emitted_fullscreen_ &&
      is_active_ == last_emitted_active_ &&
      hovered_button_ == last_emitted_hovered_ &&
      pressed_button_ == last_emitted_pressed_) {
    return;
  }
  has_emitted_metrics_ = true;
  last_emitted_maximized_ = zoomed;
  last_emitted_fullscreen_ = fullscreen;
  last_emitted_active_ = is_active_;
  last_emitted_hovered_ = hovered_button_;
  last_emitted_pressed_ = pressed_button_;
  desktop_window_channel_->InvokeMethod(
      "metricsChanged",
      std::make_unique<flutter::EncodableValue>(BuildWindowMetricsMap()));
}

LRESULT CALLBACK FlutterWindow::ChildViewSubclassProc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    UINT_PTR subclass_id,
    DWORD_PTR ref_data) noexcept {
  auto* self = reinterpret_cast<FlutterWindow*>(ref_data);
  if (message == WM_NCHITTEST && self != nullptr) {
    const LRESULT hit =
        self->HitTestNonClient(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
    if (hit != HTCLIENT) {
      return HTTRANSPARENT;
    }
  } else if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(hwnd, ChildViewSubclassProc, subclass_id);
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT FlutterWindow::HitTestNonClient(int screen_x, int screen_y) const {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return HTCLIENT;
  }

  RECT window_rect{};
  if (!::GetWindowRect(hwnd, &window_rect)) {
    return HTCLIENT;
  }

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);

  POINT client_pt{screen_x, screen_y};
  if (!::ScreenToClient(hwnd, &client_pt)) {
    return HTCLIENT;
  }
  const double scale = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
  const double lx = static_cast<double>(client_pt.x) / scale;
  const double ly = static_cast<double>(client_pt.y) / scale;

  bool in_maximize_button = false;
  bool in_caption_buttons = false;
  for (const auto& region : title_bar_regions_) {
    if (region.kind == "maximize") {
      if (lx >= region.left && lx < region.right && ly >= region.top &&
          ly < region.bottom) {
        in_maximize_button = true;
        in_caption_buttons = true;
      } else {
        const double button_width = region.right - region.left;
        if (button_width > 0 && lx >= region.left - button_width &&
            lx < region.right + button_width && ly >= region.top &&
            ly < region.bottom) {
          in_caption_buttons = true;
        }
      }
    } else if (region.kind == "buttons" && lx >= region.left &&
               lx < region.right && ly >= region.top && ly < region.bottom) {
      in_caption_buttons = true;
    }
  }

  const bool resizable =
      !IsFullscreenState() && ::IsZoomed(hwnd) == FALSE &&
      (::GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_THICKFRAME) != 0;
  if (resizable) {
    const int border_x = ::GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                         ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int border_y = ::GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                         ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int button_rim =
        std::max(1, ::MulDiv(2, static_cast<int>(dpi), 96));
    const int right_rim =
        std::min(border_x, std::max(1, ::MulDiv(3, static_cast<int>(dpi), 96)));
    const int top_hit_height = in_caption_buttons ? button_rim : border_y;

    const bool on_left =
        screen_x >= window_rect.left && screen_x < window_rect.left + border_x;
    const bool on_top = screen_y >= window_rect.top &&
                        screen_y < window_rect.top + top_hit_height;
    const bool on_bottom = screen_y < window_rect.bottom &&
                           screen_y >= window_rect.bottom - border_y;
    const int right_hit_width = in_caption_buttons
        ? button_rim
        : ((on_top || on_bottom) ? border_x : right_rim);
    const bool on_right = screen_x < window_rect.right &&
                          screen_x >= window_rect.right - right_hit_width;

    if (on_top && on_left) return HTTOPLEFT;
    if (on_top && on_right) return HTTOPRIGHT;
    if (on_bottom && on_left) return HTBOTTOMLEFT;
    if (on_bottom && on_right) return HTBOTTOMRIGHT;
    if (on_left) return HTLEFT;
    if (on_right) return HTRIGHT;
    if (on_top) return HTTOP;
    if (on_bottom) return HTBOTTOM;
  }

  if (in_maximize_button) {
    return HTMAXBUTTON;
  }
  if (in_caption_buttons) {
    return HTCLIENT;
  }
  for (const auto& region : title_bar_regions_) {
    if (region.kind == "caption" && lx >= region.left && lx < region.right &&
        ly >= region.top && ly < region.bottom) {
      return HTCAPTION;
    }
  }

  return HTCLIENT;
}

void FlutterWindow::ToggleFullscreen() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  if (!IsFullscreenState()) {
    saved_style_ = ::GetWindowLongPtrW(hwnd, GWL_STYLE);
    saved_placement_.length = sizeof(saved_placement_);
    if (!::GetWindowPlacement(hwnd, &saved_placement_)) {
      return;
    }
    HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!::GetMonitorInfoW(monitor, &mi)) {
      return;
    }
    SetFullscreenState(true);
    EmitWindowMetrics();
    ::SetWindowLongPtrW(
        hwnd, GWL_STYLE,
        saved_style_ & ~static_cast<LONG_PTR>(WS_CAPTION | WS_THICKFRAME));
    ::SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetFullscreenState(false);
    EmitWindowMetrics();
    if (saved_style_ != 0) {
      ::SetWindowLongPtrW(hwnd, GWL_STYLE, saved_style_);
    }
    if (saved_placement_.length == sizeof(saved_placement_)) {
      ::SetWindowPlacement(hwnd, &saved_placement_);
    }
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
  }
  EmitWindowMetrics();
}

void FlutterWindow::RestoreAndFocusWindow() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_SHOWMAXIMIZED : SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
  ::BringWindowToTop(hwnd);
  if (child_view_hwnd_ != nullptr) {
    ::SetFocus(child_view_hwnd_);
  }
}

void FlutterWindow::SendNavigationCommand(const char* command) {
  if (!navigation_channel_) {
    return;
  }
  navigation_channel_->InvokeMethod(command, nullptr);
}

void FlutterWindow::DeliverExternalUri(const std::string& uri) {
  if (!IsSupportedLaunchUri(uri)) {
    return;
  }
  if (intent_event_sink_) {
    intent_event_sink_->Success(flutter::EncodableValue(BuildViewIntentMap(uri)));
  } else if (initial_intent_consumed_) {
    pending_live_uris_.push_back(uri);
  } else {
    initial_intent_uri_ = uri;
  }
}

void FlutterWindow::EnsureTrayIcon() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (!tray_initialized_) {
    tray_icon_data_ = {};
    tray_icon_data_.cbSize = sizeof(tray_icon_data_);
    tray_icon_data_.hWnd = hwnd;
    tray_icon_data_.uID = kTrayIconId;
    tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
    tray_icon_data_.hIcon = ::LoadIconW(
        ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
    UpdateTrayIconTip();
    if (::Shell_NotifyIconW(NIM_ADD, &tray_icon_data_)) {
      tray_initialized_ = true;
    }
    return;
  }
  UpdateTrayIconTip();
}

void FlutterWindow::UpdateTrayIconTip() {
  const size_t max_chars =
      (sizeof(tray_icon_data_.szTip) / sizeof(wchar_t)) - 1;
  const std::wstring& tip = tray_labels_.tooltip;
  const size_t count = std::min(tip.size(), max_chars);
  for (size_t i = 0; i < count; ++i) {
    tray_icon_data_.szTip[i] = tip[i];
  }
  tray_icon_data_.szTip[count] = L'\0';
  if (tray_initialized_) {
    tray_icon_data_.uFlags = NIF_TIP;
    ::Shell_NotifyIconW(NIM_MODIFY, &tray_icon_data_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_initialized_) {
    ::Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
    tray_initialized_ = false;
  }
}

void FlutterWindow::ShowTrayContextMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  POINT pt{};
  if (!::GetCursorPos(&pt)) {
    return;
  }
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kTrayCmdShowWindow,
                tray_labels_.show_window.c_str());
  ::AppendMenuW(menu, MF_STRING, kTrayCmdDownloads,
                tray_labels_.downloads.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayCmdQuit, tray_labels_.quit.c_str());

  ::SetForegroundWindow(hwnd);
  const BOOL cmd = ::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, hwnd, nullptr);
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  switch (cmd) {
    case kTrayCmdShowWindow:
      RestoreAndFocusWindow();
      SendTrayAction("showWindow");
      break;
    case kTrayCmdDownloads:
      RestoreAndFocusWindow();
      SendTrayAction("openDownloads");
      break;
    case kTrayCmdQuit:
      SendTrayAction("quit");
      break;
    default:
      break;
  }
}

void FlutterWindow::SendTrayAction(const char* action) {
  if (!tray_channel_) {
    return;
  }
  tray_channel_->InvokeMethod(
      "onTrayAction",
      std::make_unique<flutter::EncodableValue>(std::string(action)));
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (tray_initialized_) {
      tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
      ::Shell_NotifyIconW(NIM_ADD, &tray_icon_data_);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case WM_NCHITTEST:
      return HitTestNonClient(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));

    case WM_NCMOUSEMOVE: {
      const std::string next_hover =
          (wparam == HTMAXBUTTON) ? "maximize" : std::string();
      if (!next_hover.empty() && !tracking_nc_leave_) {
        TRACKMOUSEEVENT tme{};
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE | TME_NONCLIENT;
        tme.hwndTrack = hwnd;
        tracking_nc_leave_ = ::TrackMouseEvent(&tme) != FALSE;
      }
      if (pressed_button_.empty() && hovered_button_ != next_hover) {
        hovered_button_ = next_hover;
        EmitWindowMetrics();
      }
      break;
    }

    case WM_NCMOUSELEAVE:
      tracking_nc_leave_ = false;
      if (pressed_button_.empty() && !hovered_button_.empty()) {
        hovered_button_.clear();
        EmitWindowMetrics();
      }
      return 0;

    case WM_NCLBUTTONDOWN:
      if (wparam == HTMAXBUTTON) {
        pressed_button_ = "maximize";
        hovered_button_ = "maximize";
        ::SetCapture(hwnd);
        EmitWindowMetrics();
        return 0;
      }
      break;

    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTMAXBUTTON) {
        return 0;
      }
      break;

    case WM_MOUSEMOVE:
      if (pressed_button_ == "maximize") {
        POINT pt{};
        if (::GetCursorPos(&pt)) {
          const bool over = HitTestNonClient(pt.x, pt.y) == HTMAXBUTTON;
          const std::string next_hover = over ? "maximize" : std::string();
          if (hovered_button_ != next_hover) {
            hovered_button_ = next_hover;
            EmitWindowMetrics();
          }
        }
        return 0;
      }
      break;

    case WM_LBUTTONUP:
      if (pressed_button_ == "maximize") {
        ::ReleaseCapture();
        pressed_button_.clear();
        POINT pt{};
        const bool over =
            ::GetCursorPos(&pt) && HitTestNonClient(pt.x, pt.y) == HTMAXBUTTON;
        hovered_button_.clear();
        EmitWindowMetrics();
        if (over) {
          ::PostMessageW(hwnd, WM_SYSCOMMAND,
                         ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        }
        return 0;
      }
      break;

    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        const bool trigger = (pressed_button_ == "maximize");
        pressed_button_.clear();
        hovered_button_.clear();
        EmitWindowMetrics();
        if (trigger) {
          ::PostMessageW(hwnd, WM_SYSCOMMAND,
                         ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        }
        return 0;
      }
      break;

    case WM_CAPTURECHANGED:
      if (!pressed_button_.empty()) {
        pressed_button_.clear();
        EmitWindowMetrics();
      }
      break;

    case WM_NCRBUTTONUP:
      if (wparam == HTCAPTION) {
        HMENU sys_menu = ::GetSystemMenu(hwnd, FALSE);
        if (sys_menu != nullptr) {
          const bool zoomed = ::IsZoomed(hwnd) != FALSE;
          ::EnableMenuItem(sys_menu, SC_RESTORE,
                           MF_BYCOMMAND | (zoomed ? MF_ENABLED : MF_GRAYED));
          ::EnableMenuItem(sys_menu, SC_MAXIMIZE,
                           MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          ::EnableMenuItem(sys_menu, SC_SIZE,
                           MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          ::EnableMenuItem(sys_menu, SC_MOVE,
                           MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          const BOOL cmd = ::TrackPopupMenuEx(
              sys_menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, GET_X_LPARAM(lparam),
              GET_Y_LPARAM(lparam), hwnd, nullptr);
          if (cmd > 0) {
            ::PostMessageW(hwnd, WM_SYSCOMMAND, static_cast<WPARAM>(cmd), 0);
          }
          return 0;
        }
      }
      break;

    case WM_COPYDATA: {
      const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (cds != nullptr && cds->dwData == kCopyDataOpenUriTag) {
        RestoreAndFocusWindow();
        if (cds->cbData > 0 && cds->lpData != nullptr) {
          const std::string uri(static_cast<const char*>(cds->lpData),
                                cds->cbData);
          DeliverExternalUri(uri);
        }
        return TRUE;
      }
      break;
    }

    case WM_APPCOMMAND: {
      const UINT cmd = GET_APPCOMMAND_LPARAM(lparam);
      const UINT device = GET_DEVICE_LPARAM(lparam);
      if (cmd == APPCOMMAND_BROWSER_BACKWARD ||
          cmd == APPCOMMAND_BROWSER_FORWARD) {
        // Mouse side buttons already arrive via Flutter's PointerDownEvent;
        // DefWindowProc synthesizes a duplicate WM_APPCOMMAND on mouse release
        // which would double-navigate when held past Dart's 120ms debounce.
        if (device == FAPPCOMMAND_MOUSE) {
          return TRUE;
        }
        SendNavigationCommand(cmd == APPCOMMAND_BROWSER_BACKWARD ? "back"
                                                                 : "forward");
        return TRUE;
      }
      break;
    }

    case kTrayCallbackMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          RestoreAndFocusWindow();
          SendTrayAction("showWindow");
          break;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayContextMenu();
          break;
        default:
          break;
      }
      return 0;

    case kDestroyWindowMessage:
      RemoveTrayIcon();
      ::RemovePropW(hwnd, is_dev_profile_ ? kParfaitDevMainWindowProp
                                          : kParfaitMainWindowProp);
      ::ShowWindow(hwnd, SW_HIDE);
      ::DestroyWindow(hwnd);
      return 0;

    case WM_SIZE:
      EmitWindowMetrics();
      break;

    case WM_ACTIVATE: {
      const bool next_active = (LOWORD(wparam) != WA_INACTIVE);
      if (is_active_ != next_active) {
        is_active_ = next_active;
        EmitWindowMetrics();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
