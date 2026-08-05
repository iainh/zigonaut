#pragma once

#include <functional>
#include <memory>
#include <string>
#include <string_view>

namespace ZigonautSettings {

struct Dialog;

std::shared_ptr<Dialog> show(
    HWND owner,
    std::string_view config_path,
    std::string_view contents,
    std::wstring_view version,
    std::wstring_view git_hash,
    bool high_contrast,
    bool dark_theme,
    std::function<void()> saved);

bool isOpen(std::shared_ptr<Dialog> const& dialog) noexcept;
void activate(std::shared_ptr<Dialog> const& dialog);
void setTheme(std::shared_ptr<Dialog> const& dialog, bool high_contrast, bool dark_theme);
void close(std::shared_ptr<Dialog> const& dialog);

}
