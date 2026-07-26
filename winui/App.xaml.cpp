#include "pch.h"
#include "App.xaml.h"

namespace winrt::ZigonautWinUIBridge::implementation
{
    App::App(std::function<void()> launch)
        : launch_(std::move(launch))
    {
    }

    void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&)
    {
        auto launch = std::move(launch_);
        if (launch) launch();
    }
}
