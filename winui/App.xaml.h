#pragma once

#include "App.xaml.g.h"
#include <functional>

namespace winrt::ZigonautWinUIBridge::implementation
{
    struct App : AppT<App>
    {
        App() = default;
        explicit App(std::function<void()> launch);

        void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

    private:
        std::function<void()> launch_;
    };
}
