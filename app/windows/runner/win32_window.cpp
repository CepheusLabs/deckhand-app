#include "win32_window.h"

#include <algorithm>
#include <cstdint>

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";
constexpr const wchar_t kWindowPlacementRegKey[] =
    L"Software\\Deckhand\\Window";
constexpr const wchar_t kWindowPlacementLeftValue[] = L"Left";
constexpr const wchar_t kWindowPlacementTopValue[] = L"Top";
constexpr const wchar_t kWindowPlacementRightValue[] = L"Right";
constexpr const wchar_t kWindowPlacementBottomValue[] = L"Bottom";
constexpr const wchar_t kWindowPlacementShowValue[] = L"ShowCmd";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

RECT GetMonitorWorkArea(HMONITOR monitor) {
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (GetMonitorInfo(monitor, &monitor_info)) {
    return monitor_info.rcWork;
  }
  return RECT{0, 0, GetSystemMetrics(SM_CXSCREEN),
              GetSystemMetrics(SM_CYSCREEN)};
}

int RectWidth(const RECT& rect) {
  return rect.right - rect.left;
}

int RectHeight(const RECT& rect) {
  return rect.bottom - rect.top;
}

bool ReadWindowPlacementValue(const wchar_t* value_name, int* value) {
  DWORD raw = 0;
  DWORD raw_size = sizeof(raw);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kWindowPlacementRegKey,
                               value_name, RRF_RT_REG_DWORD, nullptr, &raw,
                               &raw_size);
  if (result != ERROR_SUCCESS) {
    return false;
  }
  *value = static_cast<int>(static_cast<int32_t>(raw));
  return true;
}

void WriteWindowPlacementValue(HKEY key, const wchar_t* value_name, int value) {
  DWORD raw = static_cast<DWORD>(value);
  RegSetValueEx(key, value_name, 0, REG_DWORD,
                reinterpret_cast<const BYTE*>(&raw), sizeof(raw));
}

bool LoadWindowPlacement(RECT* rect, int* show_command) {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;
  int stored_show_command = SW_SHOWNORMAL;
  if (!ReadWindowPlacementValue(kWindowPlacementLeftValue, &left) ||
      !ReadWindowPlacementValue(kWindowPlacementTopValue, &top) ||
      !ReadWindowPlacementValue(kWindowPlacementRightValue, &right) ||
      !ReadWindowPlacementValue(kWindowPlacementBottomValue, &bottom)) {
    return false;
  }

  ReadWindowPlacementValue(kWindowPlacementShowValue, &stored_show_command);
  if (right <= left || bottom <= top) {
    return false;
  }

  *rect = RECT{left, top, right, bottom};
  *show_command = stored_show_command == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED
                                                          : SW_SHOWNORMAL;
  return true;
}

void SaveWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(window, &placement)) {
    return;
  }

  RECT rect = placement.rcNormalPosition;
  if (rect.right <= rect.left || rect.bottom <= rect.top) {
    return;
  }

  HKEY key = nullptr;
  LSTATUS result = RegCreateKeyEx(HKEY_CURRENT_USER, kWindowPlacementRegKey, 0,
                                  nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                                  nullptr);
  if (result != ERROR_SUCCESS) {
    return;
  }

  WriteWindowPlacementValue(key, kWindowPlacementLeftValue, rect.left);
  WriteWindowPlacementValue(key, kWindowPlacementTopValue, rect.top);
  WriteWindowPlacementValue(key, kWindowPlacementRightValue, rect.right);
  WriteWindowPlacementValue(key, kWindowPlacementBottomValue, rect.bottom);
  WriteWindowPlacementValue(
      key, kWindowPlacementShowValue,
      placement.showCmd == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED
                                            : SW_SHOWNORMAL);
  RegCloseKey(key);
}

RECT CenteredRectInMonitor(HMONITOR monitor, int requested_width,
                           int requested_height, double scale_factor) {
  RECT work_area = GetMonitorWorkArea(monitor);
  int work_width = RectWidth(work_area);
  int work_height = RectHeight(work_area);
  int margin = Scale(32, scale_factor);
  int width = std::min(requested_width, std::max(1, work_width - margin));
  int height = std::min(requested_height, std::max(1, work_height - margin));
  int left = work_area.left + (work_width - width) / 2;
  int top = work_area.top + (work_height - height) / 2;
  return RECT{left, top, left + width, top + height};
}

RECT ClampRectToMonitor(RECT rect, HMONITOR monitor, double scale_factor) {
  RECT work_area = GetMonitorWorkArea(monitor);
  int work_width = RectWidth(work_area);
  int work_height = RectHeight(work_area);
  int margin = Scale(32, scale_factor);
  int width = std::min(RectWidth(rect), std::max(1, work_width - margin));
  int height = std::min(RectHeight(rect), std::max(1, work_height - margin));
  int min_left = static_cast<int>(work_area.left);
  int min_top = static_cast<int>(work_area.top);
  int max_left = std::max(min_left, static_cast<int>(work_area.right) - width);
  int max_top = std::max(min_top, static_cast<int>(work_area.bottom) - height);
  int left = std::clamp(static_cast<int>(rect.left), min_left, max_left);
  int top = std::clamp(static_cast<int>(rect.top), min_top, max_top);
  return RECT{left, top, left + width, top + height};
}

void EnsureWindowVisible(HWND window) {
  if (window == nullptr || IsIconic(window)) {
    return;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (GetWindowPlacement(window, &placement) &&
      placement.showCmd == SW_SHOWMAXIMIZED) {
    return;
  }

  RECT rect{};
  if (!GetWindowRect(window, &rect) ||
      rect.right <= rect.left ||
      rect.bottom <= rect.top) {
    return;
  }

  HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  RECT clamped = ClampRectToMonitor(rect, monitor, dpi / 96.0);
  if (clamped.left == rect.left &&
      clamped.top == rect.top &&
      clamped.right == rect.right &&
      clamped.bottom == rect.bottom) {
    return;
  }

  SetWindowPos(window, nullptr, clamped.left, clamped.top,
               RectWidth(clamped), RectHeight(clamped),
               SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  HMONITOR primary_monitor =
      MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  UINT primary_dpi = FlutterDesktopGetDpiForMonitor(primary_monitor);
  double primary_scale_factor = primary_dpi / 96.0;
  int requested_width = Scale(size.width, primary_scale_factor);
  int requested_height = Scale(size.height, primary_scale_factor);
  RECT window_rect{};
  int loaded_show_command = SW_SHOWNORMAL;
  if (LoadWindowPlacement(&window_rect, &loaded_show_command)) {
    HMONITOR restored_monitor =
        MonitorFromRect(&window_rect, MONITOR_DEFAULTTONULL);
    if (restored_monitor == nullptr) {
      window_rect = CenteredRectInMonitor(primary_monitor, requested_width,
                                          requested_height,
                                          primary_scale_factor);
      show_command_ = SW_SHOWNORMAL;
    } else {
      UINT dpi = FlutterDesktopGetDpiForMonitor(restored_monitor);
      window_rect =
          ClampRectToMonitor(window_rect, restored_monitor, dpi / 96.0);
      show_command_ = loaded_show_command;
    }
  } else {
    window_rect =
        CenteredRectInMonitor(primary_monitor, requested_width,
                              requested_height, primary_scale_factor);
    show_command_ = SW_SHOWNORMAL;
  }

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      window_rect.left, window_rect.top, RectWidth(window_rect),
      RectHeight(window_rect), nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  bool shown = ShowWindow(window_handle_, show_command_);
  EnsureWindowVisible(window_handle_);
  return shown;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      SaveWindowPlacement(hwnd);
      return DefWindowProc(window_handle_, message, wparam, lparam);

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      EnsureWindowVisible(hwnd);

      return 0;
    }
    case WM_DISPLAYCHANGE:
      EnsureWindowVisible(hwnd);
      return 0;

    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
