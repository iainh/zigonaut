#include "bridge.h"
#undef GetCurrentTime
#include <MddBootstrap.h>
#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Content.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/base.h>
#include <Microsoft.UI.Dispatching.Interop.h>
#include <winrt/Microsoft.UI.Interop.h>

using namespace winrt;
using namespace Microsoft::UI;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Hosting;

namespace {
constexpr uint32_t command_new_powershell = 1;
constexpr uint32_t command_new_wsl = 2;
constexpr uint32_t command_close = 3;
constexpr uint32_t command_select = 4;

struct IslandApplication : ApplicationT<IslandApplication> {};

struct Bridge {
    DWORD thread_id = GetCurrentThreadId();
    zigonaut_chrome_command callback{};
    void* context{};
    Microsoft::UI::Dispatching::DispatcherQueueController dispatcher{nullptr};
    IslandApplication application;
    WindowsXamlManager manager{nullptr};
    DesktopWindowXamlSource source;
    StackPanel tabs;
    bool closed = false;

    Bridge(HWND parent, zigonaut_chrome_command cb, void* ctx,
           Microsoft::UI::Dispatching::DispatcherQueueController const& controller)
        : callback(cb), context(ctx), dispatcher(controller) {
        manager = WindowsXamlManager::InitializeForCurrentThread();
        source.Initialize(Microsoft::UI::GetWindowIdFromWindow(parent));

        StackPanel root;
        root.Orientation(Orientation::Vertical);
        root.Padding(Thickness{12, 8, 12, 6});
        StackPanel commands;
        commands.Orientation(Orientation::Horizontal);
        addCommand(commands, L"New PowerShell", command_new_powershell);
        addCommand(commands, L"New WSL", command_new_wsl);
        addCommand(commands, L"Close active tab", command_close);
        tabs.Orientation(Orientation::Horizontal);
        root.Children().Append(commands);
        root.Children().Append(tabs);
        source.Content(root);
    }

    void addCommand(StackPanel const& panel, wchar_t const* label, uint32_t command) {
        Button button;
        button.Content(box_value(label));
        button.Margin(Thickness{0, 0, 8, 4});
        button.Click([this, command](auto&&, auto&&) { callback(context, command, 0); });
        panel.Children().Append(button);
    }

    void update(uint8_t const* kinds, uint32_t count, int32_t active) {
        tabs.Children().Clear();
        for (uint32_t i = 0; i < count; ++i) {
            Button button;
            button.Content(box_value(kinds[i] == 0 ? L"PowerShell" : L"WSL"));
            button.Margin(Thickness{0, 0, 6, 0});
            if (active == static_cast<int32_t>(i)) button.FontWeight(Windows::UI::Text::FontWeights::Bold());
            button.Click([this, i](auto&&, auto&&) { callback(context, command_select, i); });
            tabs.Children().Append(button);
        }
    }

    void close() {
        if (closed) return;
        closed = true;
        source.Content(nullptr);
        source.Close();
    }
};

bool owner(Bridge* bridge) { return bridge && bridge->thread_id == GetCurrentThreadId(); }
}

extern "C" void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context) {
    if (!parent || !callback) return nullptr;
    try {
        init_apartment(apartment_type::single_threaded);
    } catch (...) {
        return nullptr;
    }
    try {
        PACKAGE_VERSION minimum{};
        minimum.Version = 0;
        if (FAILED(MddBootstrapInitialize(0x00010008, nullptr, minimum))) {
            uninit_apartment();
            return nullptr;
        }
        try {
            auto dispatcher = Microsoft::UI::Dispatching::DispatcherQueueController::CreateOnCurrentThread();
            return new Bridge(parent, callback, context, dispatcher);
        }
        catch (...) {
            MddBootstrapShutdown();
            uninit_apartment();
            return nullptr;
        }
    } catch (...) {
        uninit_apartment();
        return nullptr;
    }
}

extern "C" void __cdecl zigonaut_chrome_update(void* value, const uint8_t* kinds, uint32_t count, int32_t active) {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge) || (count && !kinds)) return;
    try { bridge->update(kinds, count, active); } catch (...) {}
}

extern "C" void __cdecl zigonaut_chrome_move(void* value, int32_t x, int32_t y, int32_t width, int32_t height) {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge)) return;
    try { bridge->source.SiteBridge().MoveAndResize({x, y, width > 0 ? width : 1, height > 0 ? height : 1}); } catch (...) {}
}

extern "C" BOOL __cdecl zigonaut_chrome_pretranslate(void* value, MSG* message) {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge) || !message) return FALSE;
    return ContentPreTranslateMessage(message) ? TRUE : FALSE;
}

extern "C" void __cdecl zigonaut_chrome_close(void* value) {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge)) return;
    try { bridge->close(); } catch (...) {}
}

extern "C" void __cdecl zigonaut_chrome_destroy(void* value) {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge)) return;
    auto dispatcher = bridge->dispatcher;
    try { bridge->close(); } catch (...) {}
    delete bridge;
    try { dispatcher.ShutdownQueue(); } catch (...) {}
    dispatcher = nullptr;
    MddBootstrapShutdown();
    uninit_apartment();
}
