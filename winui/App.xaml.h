#pragma once

#include "App.xaml.g.h"

namespace winrt::ZigonautWinUIBridge::implementation
{
    struct App : AppT<App>
    {
        App()
            : xaml_manager(Microsoft::UI::Xaml::Hosting::WindowsXamlManager::InitializeForCurrentThread())
        {
        }

        void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

    private:
        Microsoft::UI::Xaml::Hosting::WindowsXamlManager xaml_manager{ nullptr };
    };
}
