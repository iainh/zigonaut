#include "pch.h"
#include "settings_dialog.h"

#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Media.Animation.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.Windows.Storage.Pickers.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Text.h>
#include <dwmapi.h>
#include <dwrite_1.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <map>
#include <optional>
#include <stdexcept>
#include <vector>

using namespace winrt;
using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;

namespace ZigonautSettings {
namespace {

std::wstring executablePath() {
    std::wstring path(32768, L'\0');
    auto const length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) throw hresult_error(HRESULT_FROM_WIN32(GetLastError()));
    path.resize(length);
    return path;
}

void setRegistryString(HKEY key, wchar_t const* name, std::wstring const& value) {
    auto const status = RegSetValueExW(key, name, 0, REG_SZ,
        reinterpret_cast<BYTE const*>(value.c_str()), static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    if (status != ERROR_SUCCESS) throw hresult_error(HRESULT_FROM_WIN32(status));
}

void registerExplorerVerb(std::wstring const& key_path, std::wstring const& directory_argument) {
    auto const executable = executablePath();
    HKEY key{};
    auto status = RegCreateKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
    if (status != ERROR_SUCCESS) throw hresult_error(HRESULT_FROM_WIN32(status));
    try {
        setRegistryString(key, L"MUIVerb", L"Open in Zigonaut");
        setRegistryString(key, L"Icon", executable);
        HKEY command_key{};
        status = RegCreateKeyExW(key, L"command", 0, nullptr, 0, KEY_WRITE, nullptr, &command_key, nullptr);
        if (status != ERROR_SUCCESS) throw hresult_error(HRESULT_FROM_WIN32(status));
        try {
            setRegistryString(command_key, nullptr, L"\"" + executable + L"\" -d \"" + directory_argument + L"\"");
        } catch (...) {
            RegCloseKey(command_key);
            throw;
        }
        RegCloseKey(command_key);
    } catch (...) {
        RegCloseKey(key);
        throw;
    }
    RegCloseKey(key);
}

void removeExplorerIntegration() {
    for (auto const* path : {
             L"Software\\Classes\\Directory\\shell\\Zigonaut",
             L"Software\\Classes\\Directory\\Background\\shell\\Zigonaut"}) {
        auto const status = RegDeleteTreeW(HKEY_CURRENT_USER, path);
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
            throw hresult_error(HRESULT_FROM_WIN32(status));
    }
}

void installExplorerIntegration() {
    try {
        registerExplorerVerb(L"Software\\Classes\\Directory\\shell\\Zigonaut", L"%1");
        registerExplorerVerb(L"Software\\Classes\\Directory\\Background\\shell\\Zigonaut", L"%V");
    } catch (...) {
        try { removeExplorerIntegration(); } catch (...) {}
        throw;
    }
}

bool explorerIntegrationInstalled() {
    for (auto const* path : {
             L"Software\\Classes\\Directory\\shell\\Zigonaut\\command",
             L"Software\\Classes\\Directory\\Background\\shell\\Zigonaut\\command"}) {
        HKEY key{};
        auto const status = RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_READ, &key);
        if (status != ERROR_SUCCESS) return false;
        RegCloseKey(key);
    }
    return true;
}

std::string trim(std::string value) {
    auto const first = value.find_first_not_of(" \t\r");
    if (first == std::string::npos) return {};
    auto const last = value.find_last_not_of(" \t\r");
    return value.substr(first, last - first + 1);
}

std::map<std::string, std::string> parse(std::string_view contents) {
    std::map<std::string, std::string> values;
    auto const root = Windows::Data::Json::JsonObject::Parse(to_hstring(contents));
    auto const appearance = root.GetNamedObject(L"appearance");
    auto const font = appearance.GetNamedObject(L"font");
    auto const themes = appearance.GetNamedObject(L"themes");
    auto const padding = appearance.GetNamedObject(L"padding");
    auto const background = appearance.GetNamedObject(L"background");
    auto const palette = appearance.GetNamedObject(L"palette");
    auto const terminal = root.GetNamedObject(L"terminal");
    auto const initial_size = terminal.GetNamedObject(L"initialSize");
    auto const profiles = root.GetNamedObject(L"profiles");
    auto const advanced = root.GetNamedObject(L"advanced");
    auto const clipboard = advanced.GetNamedObject(L"clipboard");
    auto number = [](double value) { return std::to_string(static_cast<uint64_t>(value)); };

    values["font_family"] = to_string(font.GetNamedString(L"family"));
    values["font_size"] = number(font.GetNamedNumber(L"size"));
    values["font_weight"] = to_string(font.GetNamedString(L"weight", L"regular"));
    values["intense_font_weight"] = to_string(font.GetNamedString(L"intenseWeight", L"bold"));
    values["intense_text_style"] = to_string(font.GetNamedString(L"intenseTextStyle", L"all"));
    values["text_antialiasing"] = to_string(font.GetNamedString(L"antialiasing", L"acceleratedGrayscale"));
    values["scrollback_size"] = number(terminal.GetNamedNumber(L"scrollbackSize"));
    values["initial_columns"] = number(initial_size.GetNamedNumber(L"columns"));
    values["initial_rows"] = number(initial_size.GetNamedNumber(L"rows"));
    values["dark_theme"] = to_string(themes.GetNamedString(L"dark"));
    values["light_theme"] = to_string(themes.GetNamedString(L"light"));
    values["color_scheme"] = to_string(themes.GetNamedString(L"colorScheme"));
    values["padding_horizontal"] = number(padding.GetNamedNumber(L"horizontal"));
    values["padding_vertical"] = number(padding.GetNamedNumber(L"vertical"));
    values["padding_balance"] = to_string(padding.GetNamedString(L"balance", L"none"));
    values["padding_color"] = to_string(padding.GetNamedString(L"color", L"background"));
    values["background_opacity"] = number(background.GetNamedNumber(L"opacity"));
    values["background_opacity_cells"] = background.GetNamedBoolean(L"opacityCells", false) ? "true" : "false";
    values["backdrop"] = to_string(background.GetNamedString(L"backdrop"));
    values["randomize_tab_background"] = appearance.GetNamedBoolean(L"randomizeTabBackground") ? "true" : "false";
    values["default_profile"] = to_string(profiles.GetNamedString(L"default"));
    values["hold_on_exit"] = profiles.GetNamedBoolean(L"holdOnExit") ? "true" : "false";
    values["osc52_clipboard_write"] = clipboard.GetNamedBoolean(L"terminalWrites") ? "true" : "false";
    values["osc52_clipboard_max_bytes"] = number(clipboard.GetNamedNumber(L"maximumBytes"));
    values["pipe_command_output"] = to_string(advanced.GetNamedString(L"pipeCommandOutput"));

    for (auto const& [name, key] : std::initializer_list<std::pair<char const*, wchar_t const*>>{
             {"foreground", L"foreground"}, {"background", L"background"}, {"cursor", L"cursor"}}) {
        if (palette.HasKey(key) && palette.GetNamedValue(key).ValueType() == Windows::Data::Json::JsonValueType::String)
            values[name] = to_string(palette.GetNamedString(key));
    }
    if (palette.HasKey(L"ansi") && palette.GetNamedValue(L"ansi").ValueType() == Windows::Data::Json::JsonValueType::Array) {
        auto const ansi = palette.GetNamedArray(L"ansi");
        for (uint32_t index = 0; index < ansi.Size() && index < 16; ++index) {
            auto const item = ansi.GetAt(index);
            if (item.ValueType() == Windows::Data::Json::JsonValueType::String)
                values["ansi" + std::to_string(index)] = to_string(item.GetString());
        }
    }
    return values;
}

struct ProfileValue {
    std::string name;
    std::string shell;
    std::string command;
    std::string working_directory;
};

std::vector<ProfileValue> profileValues(std::string_view contents) {
    auto const profile_settings = Windows::Data::Json::JsonObject::Parse(to_hstring(contents)).GetNamedObject(L"profiles");
    auto const legacy_working_directory = profile_settings.HasKey(L"workingDirectory")
        ? profile_settings.GetNamedString(L"workingDirectory") : hstring{};
    auto const profiles = profile_settings.GetNamedArray(L"items");
    std::vector<ProfileValue> result;
    for (auto const& item : profiles) {
        auto const profile = item.GetObject();
        result.push_back({
            to_string(profile.GetNamedString(L"name")),
            to_string(profile.GetNamedString(L"shell")),
            to_string(profile.GetNamedString(L"command")),
            to_string(profile.HasKey(L"workingDirectory")
                ? profile.GetNamedString(L"workingDirectory") : legacy_working_directory),
        });
    }
    return result;
}

std::string value(std::map<std::string, std::string> const& values, std::string const& key, std::string fallback = {}) {
    auto const found = values.find(key);
    return found == values.end() ? fallback : found->second;
}

TextBlock label(std::wstring_view text, std::wstring_view description = {}) {
    auto panel = TextBlock{};
    panel.Text(text);
    panel.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
    if (!description.empty()) ToolTipService::SetToolTip(panel, box_value(description));
    return panel;
}

void appendLabeled(StackPanel const& panel, std::wstring_view text, UIElement const& control, std::wstring_view description = {}) {
    auto heading = label(text, description);
    Microsoft::UI::Xaml::Automation::AutomationProperties::SetLabeledBy(control, heading);
    if (!description.empty()) Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(control, description);
    panel.Children().Append(heading);
    panel.Children().Append(control);
}

StackPanel actionContent(Symbol symbol, std::wstring_view text) {
    auto content = StackPanel{};
    content.Orientation(Orientation::Horizontal);
    content.Spacing(8);
    auto icon = SymbolIcon{};
    icon.Symbol(symbol);
    Microsoft::UI::Xaml::Automation::AutomationProperties::SetAccessibilityView(
        icon, Microsoft::UI::Xaml::Automation::Peers::AccessibilityView::Raw);
    content.Children().Append(icon);
    auto caption = TextBlock{};
    caption.Text(text);
    content.Children().Append(caption);
    return content;
}

Border card(std::wstring_view title, std::wstring_view description, UIElement const& control, bool expanded = false) {
    auto text = StackPanel{};
    text.Spacing(4);
    auto heading = label(title, description);
    Microsoft::UI::Xaml::Automation::AutomationProperties::SetHeadingLevel(
        heading, Microsoft::UI::Xaml::Automation::Peers::AutomationHeadingLevel::Level2);
    Microsoft::UI::Xaml::Automation::AutomationProperties::SetLabeledBy(control, heading);
    if (!description.empty()) Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(control, description);
    text.Children().Append(heading);
    if (!description.empty()) {
        auto detail = TextBlock{};
        detail.Text(description);
        detail.TextWrapping(TextWrapping::Wrap);
        detail.Style(Application::Current().Resources().Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
        text.Children().Append(detail);
    }

    auto layout = Grid{};
    layout.VerticalAlignment(VerticalAlignment::Top);
    layout.RowSpacing(expanded ? 8 : 0);
    auto header_row = RowDefinition{};
    header_row.Height(GridLength{1, GridUnitType::Auto});
    layout.RowDefinitions().Append(header_row);
    auto action_row = RowDefinition{};
    action_row.Height(GridLength{1, GridUnitType::Auto});
    layout.RowDefinitions().Append(action_row);
    auto text_column = ColumnDefinition{};
    text_column.Width(GridLength{1, GridUnitType::Star});
    layout.ColumnDefinitions().Append(text_column);
    auto action_column = ColumnDefinition{};
    action_column.Width(expanded ? GridLength{0, GridUnitType::Pixel} : GridLength{320, GridUnitType::Pixel});
    layout.ColumnDefinitions().Append(action_column);
    layout.Children().Append(text);
    auto element = control.as<FrameworkElement>();
    if (expanded) {
        Grid::SetRow(element, 1);
        Grid::SetColumnSpan(element, 2);
        element.Margin(Thickness{0});
    } else {
        Grid::SetColumn(element, 1);
        element.Margin(Thickness{24, 0, 0, 0});
        element.VerticalAlignment(VerticalAlignment::Center);
        layout.SizeChanged([element, action_column](auto const& sender, SizeChangedEventArgs const& args) {
            auto const wrapped = args.NewSize().Width <= 476;
            action_column.Width(wrapped ? GridLength{0, GridUnitType::Pixel} : GridLength{320, GridUnitType::Pixel});
            Grid::SetRow(element, wrapped ? 1 : 0);
            Grid::SetColumn(element, wrapped ? 0 : 1);
            Grid::SetColumnSpan(element, wrapped ? 2 : 1);
            element.Margin(wrapped ? Thickness{0} : Thickness{24, 0, 0, 0});
            element.HorizontalAlignment(HorizontalAlignment::Stretch);
            sender.as<Grid>().RowSpacing(wrapped ? 8 : 0);
        });
    }
    layout.Children().Append(control);

    auto result = Border{};
    result.Style(Application::Current().Resources().Lookup(box_value(L"ZigonautSettingsCardStyle")).as<Style>());
    result.Child(layout);
    return result;
}

TextBox textBox(std::string const& text, std::wstring_view placeholder = {}) {
    auto result = TextBox{};
    result.Text(to_hstring(text));
    result.PlaceholderText(placeholder);
    result.HorizontalAlignment(HorizontalAlignment::Stretch);
    return result;
}

NumberBox numberBox(std::string const& text, double fallback, double minimum, double maximum, double step = 1) {
    auto result = NumberBox{};
    try { result.Value(std::stod(text)); } catch (...) { result.Value(fallback); }
    result.Minimum(minimum);
    result.Maximum(maximum);
    result.SmallChange(step);
    result.SpinButtonPlacementMode(NumberBoxSpinButtonPlacementMode::Compact);
    return result;
}

ComboBox combo(std::string const& selected, std::initializer_list<std::wstring_view> choices) {
    auto result = ComboBox{};
    result.HorizontalAlignment(HorizontalAlignment::Stretch);
    int32_t index = 0;
    int32_t selected_index = 0;
    for (auto choice : choices) {
        result.Items().Append(box_value(choice));
        if (to_string(choice) == selected) selected_index = index;
        ++index;
    }
    result.SelectedIndex(selected_index);
    return result;
}

struct ThemeChoice {
    std::string name;
    std::array<uint32_t, 19> colors;
};

std::optional<uint32_t> parseColor(std::string const& text) {
    if (text.size() != 7 || text[0] != '#') return std::nullopt;
    try {
        size_t parsed{};
        auto const result = std::stoul(text.substr(1), &parsed, 16);
        if (parsed != 6 || result > 0xffffff) return std::nullopt;
        return static_cast<uint32_t>(result);
    } catch (...) {
        return std::nullopt;
    }
}

ThemeChoice rasmusTheme(std::string name = "rasmus") {
    return {
        std::move(name),
        {
            0x1a1a19, 0xd1d1d1, 0xd1d1d1,
            0x333332, 0xff968c, 0x61957f, 0xffc591,
            0x8db4d4, 0xde9bc8, 0x7bb099, 0xd1d1d1,
            0x4c4c4b, 0xffafa5, 0x7aae98, 0xffdeaa,
            0xa6cded, 0xf7b4e1, 0x94c9b2, 0xeaeaea,
        },
    };
}

std::optional<ThemeChoice> parseTheme(std::string name, std::string const& contents) {
    try {
        auto const object = Windows::Data::Json::JsonObject::Parse(to_hstring(contents));
        ThemeChoice result{std::move(name)};
        for (auto const& [index, key] : std::initializer_list<std::pair<size_t, wchar_t const*>>{
                 {0, L"background"}, {1, L"foreground"}, {2, L"cursor"}}) {
            auto const color = parseColor(to_string(object.GetNamedString(key)));
            if (!color) return std::nullopt;
            result.colors[index] = *color;
        }
        auto const ansi = object.GetNamedArray(L"ansi");
        if (ansi.Size() != 16) return std::nullopt;
        for (uint32_t index = 0; index < ansi.Size(); ++index) {
            auto const color = parseColor(to_string(ansi.GetStringAt(index)));
            if (!color) return std::nullopt;
            result.colors[index + 3] = *color;
        }
        return result;
    } catch (...) {
        return std::nullopt;
    }
}

std::vector<ThemeChoice> loadThemes() {
    std::vector<ThemeChoice> result{rasmusTheme()};
    std::wstring executable(32768, L'\0');
    auto const length = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
    if (length == 0 || length == executable.size()) return result;
    executable.resize(length);
    auto const directory = std::filesystem::path{executable}.parent_path() / L"themes";
    std::error_code error;
    for (auto const& entry : std::filesystem::directory_iterator{directory, error}) {
        if (!entry.is_regular_file(error) || entry.path().extension() != L".json") continue;
        std::ifstream file{entry.path(), std::ios::binary};
        std::ostringstream contents;
        if (!file || !(contents << file.rdbuf())) continue;
        auto theme = parseTheme(to_string(entry.path().stem().wstring()), contents.str());
        if (theme) result.push_back(std::move(*theme));
    }
    std::sort(result.begin(), result.end(), [](auto const& left, auto const& right) { return left.name < right.name; });
    return result;
}

Windows::UI::Color xamlColor(uint32_t color) {
    Windows::UI::Color result{};
    result.A = 255;
    result.R = static_cast<uint8_t>(color >> 16);
    result.G = static_cast<uint8_t>(color >> 8);
    result.B = static_cast<uint8_t>(color);
    return result;
}

ComboBoxItem themeItem(ThemeChoice const& theme) {
    auto row = StackPanel{};
    row.Orientation(Orientation::Horizontal);
    row.Spacing(12);
    auto name = TextBlock{};
    name.Text(to_hstring(theme.name));
    name.Width(112);
    name.VerticalAlignment(VerticalAlignment::Center);
    row.Children().Append(name);
    auto palette = StackPanel{};
    palette.Orientation(Orientation::Horizontal);
    palette.Spacing(1);
    for (auto color : theme.colors) {
        auto tile = Border{};
        tile.Width(8);
        tile.Height(20);
        tile.Background(Media::SolidColorBrush{xamlColor(color)});
        palette.Children().Append(tile);
    }
    row.Children().Append(palette);
    auto item = ComboBoxItem{};
    item.Tag(box_value(to_hstring(theme.name)));
    item.Content(row);
    return item;
}

std::vector<std::wstring> monospaceFonts() {
    std::vector<std::wstring> result;
    com_ptr<IDWriteFactory> factory;
    check_hresult(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(factory.put())));
    com_ptr<IDWriteFontCollection> collection;
    check_hresult(factory->GetSystemFontCollection(collection.put()));

    for (UINT32 index = 0; index < collection->GetFontFamilyCount(); ++index) {
        IDWriteFontFamily* family{};
        if (FAILED(collection->GetFontFamily(index, &family))) continue;
        IDWriteFont* font{};
        auto const font_result = family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, &font);
        if (FAILED(font_result)) { family->Release(); continue; }
        IDWriteFont1* font1{};
        auto const monospaced = SUCCEEDED(font->QueryInterface(&font1)) && font1->IsMonospacedFont();
        if (font1) font1->Release();
        font->Release();
        if (!monospaced) { family->Release(); continue; }

        IDWriteLocalizedStrings* names{};
        if (SUCCEEDED(family->GetFamilyNames(&names))) {
            UINT32 name_index{};
            BOOL exists{};
            if (FAILED(names->FindLocaleName(L"en-us", &name_index, &exists)) || !exists) name_index = 0;
            UINT32 length{};
            if (SUCCEEDED(names->GetStringLength(name_index, &length))) {
                std::wstring name(length + 1, L'\0');
                if (SUCCEEDED(names->GetString(name_index, name.data(), length + 1))) {
                    name.resize(length);
                    result.push_back(std::move(name));
                }
            }
            names->Release();
        }
        family->Release();
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

ComboBox fontCombo(std::string const& selected) {
    auto result = ComboBox{};
    result.HorizontalAlignment(HorizontalAlignment::Stretch);
    auto choices = monospaceFonts();
    auto const selected_name = to_hstring(selected);
    if (std::find(choices.begin(), choices.end(), selected_name.c_str()) == choices.end()) choices.push_back(selected_name.c_str());
    std::sort(choices.begin(), choices.end());
    for (size_t index = 0; index < choices.size(); ++index) {
        result.Items().Append(box_value(choices[index]));
        if (choices[index] == selected_name.c_str()) result.SelectedIndex(static_cast<int32_t>(index));
    }
    return result;
}

struct FontWeightChoice {
    DWRITE_FONT_WEIGHT value;
    wchar_t const* label;
    char const* key;
};

constexpr FontWeightChoice font_weight_choices[] = {
    {DWRITE_FONT_WEIGHT_THIN, L"Thin", "thin"},
    {DWRITE_FONT_WEIGHT_EXTRA_LIGHT, L"Extra light", "extraLight"},
    {DWRITE_FONT_WEIGHT_LIGHT, L"Light", "light"},
    {DWRITE_FONT_WEIGHT_SEMI_LIGHT, L"Semi-light", "semiLight"},
    {DWRITE_FONT_WEIGHT_NORMAL, L"Regular", "regular"},
    {DWRITE_FONT_WEIGHT_MEDIUM, L"Medium", "medium"},
    {DWRITE_FONT_WEIGHT_SEMI_BOLD, L"Semi-bold", "semiBold"},
    {DWRITE_FONT_WEIGHT_BOLD, L"Bold", "bold"},
    {DWRITE_FONT_WEIGHT_EXTRA_BOLD, L"Extra bold", "extraBold"},
    {DWRITE_FONT_WEIGHT_BLACK, L"Black", "black"},
    {DWRITE_FONT_WEIGHT_EXTRA_BLACK, L"Extra black", "extraBlack"},
};

std::vector<FontWeightChoice const*> fontWeights(std::wstring const& family_name) {
    std::vector<FontWeightChoice const*> result;
    com_ptr<IDWriteFactory> factory;
    check_hresult(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(factory.put())));
    com_ptr<IDWriteFontCollection> collection;
    check_hresult(factory->GetSystemFontCollection(collection.put()));
    UINT32 family_index{};
    BOOL exists{};
    check_hresult(collection->FindFamilyName(family_name.c_str(), &family_index, &exists));
    if (!exists) return result;
    com_ptr<IDWriteFontFamily> family;
    check_hresult(collection->GetFontFamily(family_index, family.put()));
    for (UINT32 index = 0; index < family->GetFontCount(); ++index) {
        com_ptr<IDWriteFont> font;
        if (FAILED(family->GetFont(index, font.put())) || font->GetStyle() != DWRITE_FONT_STYLE_NORMAL) continue;
        auto const weight = font->GetWeight();
        auto const choice = std::find_if(std::begin(font_weight_choices), std::end(font_weight_choices),
            [weight](auto const& candidate) { return candidate.value == weight; });
        if (choice != std::end(font_weight_choices) && std::find(result.begin(), result.end(), &*choice) == result.end())
            result.push_back(&*choice);
    }
    std::sort(result.begin(), result.end(), [](auto left, auto right) { return left->value < right->value; });
    return result;
}

void refreshWeightCombo(ComboBox const& combo_box, std::wstring const& family, std::string const& selected) {
    auto choices = fontWeights(family);
    if (choices.empty()) choices.push_back(&font_weight_choices[4]);
    auto selected_choice = std::find_if(choices.begin(), choices.end(), [&](auto choice) { return selected == choice->key; });
    if (selected_choice == choices.end()) {
        auto const requested = std::find_if(std::begin(font_weight_choices), std::end(font_weight_choices),
            [&](auto const& choice) { return selected == choice.key; });
        auto const requested_value = requested == std::end(font_weight_choices)
            ? DWRITE_FONT_WEIGHT_NORMAL : requested->value;
        selected_choice = std::min_element(choices.begin(), choices.end(), [requested_value](auto left, auto right) {
            return std::abs(static_cast<int>(left->value) - static_cast<int>(requested_value)) <
                std::abs(static_cast<int>(right->value) - static_cast<int>(requested_value));
        });
    }
    auto const selected_index = static_cast<int32_t>(std::distance(choices.begin(), selected_choice));
    combo_box.Items().Clear();
    for (auto choice : choices) {
        auto item = ComboBoxItem{};
        item.Content(box_value(choice->label));
        item.Tag(box_value(to_hstring(choice->key)));
        combo_box.Items().Append(item);
    }
    combo_box.SelectedIndex(selected_index);
}

ComboBox weightCombo(std::wstring const& family, std::string const& selected) {
    auto result = ComboBox{};
    result.HorizontalAlignment(HorizontalAlignment::Stretch);
    refreshWeightCombo(result, family, selected);
    return result;
}

ToggleSwitch toggle(std::string const& selected) {
    auto result = ToggleSwitch{};
    result.IsOn(selected == "true");
    result.OnContent(box_value(L"On"));
    result.OffContent(box_value(L"Off"));
    return result;
}

std::string colorOrEmpty(std::map<std::string, std::string> const& values, std::string const& key) {
    auto result = value(values, key);
    return result.size() == 7 && result[0] == '#' ? result : std::string{};
}

bool validColor(std::string const& color) {
    if (color.empty()) return true;
    if (color.size() != 7 || color[0] != '#') return false;
    return color.find_first_not_of("0123456789abcdefABCDEF", 1) == std::string::npos;
}

struct FieldValidationError : std::runtime_error {
    FieldValidationError(char const* message, Control const& responsible)
        : std::runtime_error(message), control(responsible) {}
    Control control;
};

} // namespace

struct Dialog : std::enable_shared_from_this<Dialog> {
    Window window{nullptr};
    Grid root{nullptr};
    NavigationView navigation{nullptr};
    InfoBar error{nullptr};
    std::vector<TextBlock> save_status;
    std::vector<ScrollViewer> pages;
    std::filesystem::path path;
    std::wstring app_version;
    std::wstring git_hash;
    std::function<void()> saved;
    bool open = true;
    bool updating_font_weights = false;

    ComboBox dark_theme{nullptr}, light_theme{nullptr}, font_family{nullptr}, font_weight{nullptr}, intense_font_weight{nullptr}, intense_text_style{nullptr}, text_antialiasing{nullptr};
    NumberBox font_size{nullptr}, scrollback_size{nullptr}, initial_columns{nullptr}, initial_rows{nullptr}, padding_horizontal{nullptr}, padding_vertical{nullptr}, opacity{nullptr};
    ComboBox color_scheme{nullptr}, backdrop{nullptr}, padding_balance{nullptr}, padding_color{nullptr};
    ToggleSwitch random_background{nullptr}, opacity_cells{nullptr};
    std::vector<TextBox> colors;
    std::vector<ThemeChoice> themes;

    struct ProfileEditor {
        uint64_t id;
        TextBox name{nullptr};
        ComboBox shell{nullptr};
        TextBox command{nullptr};
        TextBox working_directory{nullptr};
        Button remove{nullptr};
        Expander expander{nullptr};
        Border container{nullptr};
    };

    ComboBox default_profile{nullptr};
    StackPanel profile_list{nullptr};
    Button add_profile{nullptr};
    std::vector<ProfileEditor> profile_editors;
    uint64_t next_profile_id{};
    bool updating_profiles{};
    bool updating_explorer{};
    ToggleSwitch hold_on_exit{nullptr};
    ToggleSwitch clipboard_write{nullptr};
    NumberBox clipboard_limit{nullptr};
    Border clipboard_limit_card{nullptr};
    TextBox pipe_command{nullptr};

    Window::Closed_revoker closed_revoker{};
    NavigationView::SelectionChanged_revoker navigation_revoker{};

    Dialog(HWND owner, std::string_view config_path, std::string_view contents, std::wstring_view version, std::wstring_view hash,
           bool high_contrast, bool dark_theme, std::function<void()> on_saved)
        : path(to_hstring(config_path).c_str()), app_version(version), git_hash(hash),
          saved(std::move(on_saved)), themes(loadThemes()) {
        auto const values = parse(contents);
        window = Window{};
        window.Title(L"Zigonaut Settings");
        HWND settings_window{};
        check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&settings_window));
        SetWindowLongPtrW(settings_window, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner));
        auto const app_icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1));
        if (app_icon) {
            SendMessageW(settings_window, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(app_icon));
            SendMessageW(settings_window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(app_icon));
        }
        auto const dpi = GetDpiForWindow(settings_window);
        auto const app_window = window.AppWindow();
        auto const work_area = Microsoft::UI::Windowing::DisplayArea::GetFromWindowId(
            app_window.Id(), Microsoft::UI::Windowing::DisplayAreaFallback::Nearest).WorkArea();
        auto const inset = MulDiv(24, dpi, 96);
        auto const available_width = std::max(1, work_area.Width - inset * 2);
        auto const available_height = std::max(1, work_area.Height - inset * 2);
        auto const width = std::min(MulDiv(1200, dpi, 96), available_width);
        auto const height = std::min(MulDiv(800, dpi, 96), available_height);
        app_window.MoveAndResize({
            work_area.X + (work_area.Width - width) / 2,
            work_area.Y + (work_area.Height - height) / 2,
            width,
            height,
        });

        root = Grid{};
        applyTheme(high_contrast, dark_theme);
        auto backdrop = Media::MicaBackdrop{};
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::Base);
        window.SystemBackdrop(backdrop);

        auto error_row = RowDefinition{};
        error_row.Height(GridLength{1, GridUnitType::Auto});
        root.RowDefinitions().Append(error_row);
        auto content_row = RowDefinition{};
        content_row.Height(GridLength{1, GridUnitType::Star});
        root.RowDefinitions().Append(content_row);

        error = InfoBar{};
        error.Severity(InfoBarSeverity::Error);
        error.IsOpen(false);
        error.IsClosable(true);
        Grid::SetRow(error, 0);
        root.Children().Append(error);

        navigation = NavigationView{};
        navigation.PaneDisplayMode(NavigationViewPaneDisplayMode::Auto);
        navigation.IsBackButtonVisible(NavigationViewBackButtonVisible::Collapsed);
        navigation.IsSettingsVisible(false);
        navigation.OpenPaneLength(220);
        navigation.PaneTitle(L"Settings");
        navigation.ContentTransitions().Append(Microsoft::UI::Xaml::Media::Animation::NavigationThemeTransition{});
        Grid::SetRow(navigation, 1);

        auto add_navigation = [this](std::wstring_view title, wchar_t const* glyph) {
            auto item = NavigationViewItem{};
            item.Content(box_value(title));
            auto icon = FontIcon{};
            icon.Glyph(glyph);
            item.Icon(icon);
            navigation.MenuItems().Append(item);
            return item;
        };
        auto appearance_item = add_navigation(L"Appearance", L"\xE790");
        add_navigation(L"Terminal", L"\xE756");
        add_navigation(L"Profiles", L"\xE77B");
        add_navigation(L"Advanced", L"\xE713");

        pages.push_back(makeAppearance(values));
        pages.push_back(makeTerminal(values));
        pages.push_back(makeProfiles(values, profileValues(contents)));
        pages.push_back(makeAdvanced(values));
        navigation.Content(pages[0]);
        navigation.SelectedItem(appearance_item);
        navigation_revoker = navigation.SelectionChanged(auto_revoke, [this](auto const&, NavigationViewSelectionChangedEventArgs const& args) {
            uint32_t index{};
            if (navigation.MenuItems().IndexOf(args.SelectedItem(), index) && index < pages.size()) navigation.Content(pages[index]);
        });
        root.Children().Append(navigation);
        window.Content(root);
        closed_revoker = window.Closed(auto_revoke, [this](auto const&, auto const&) { open = false; });
        registerAutoSave();
    }

    ScrollViewer page(std::wstring_view title, std::wstring_view description, std::vector<Border> const& section_cards) {
        auto panel = StackPanel{};
        panel.Spacing(12);
        panel.Padding(Thickness{0, 24, 0, 36});
        panel.MaxWidth(1064);
        panel.HorizontalAlignment(HorizontalAlignment::Stretch);
        auto heading = TextBlock{};
        heading.Text(title);
        heading.Style(Application::Current().Resources().Lookup(box_value(L"TitleTextBlockStyle")).as<Style>());
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetHeadingLevel(
            heading, Microsoft::UI::Xaml::Automation::Peers::AutomationHeadingLevel::Level1);
        panel.Children().Append(heading);
        auto detail = TextBlock{};
        detail.Text(description);
        detail.TextWrapping(TextWrapping::Wrap);
        detail.Style(Application::Current().Resources().Lookup(box_value(L"BodyTextBlockStyle")).as<Style>());
        panel.Children().Append(detail);
        auto automatic = TextBlock{};
        automatic.Text(L"Saved automatically");
        automatic.TextWrapping(TextWrapping::Wrap);
        automatic.Style(Application::Current().Resources().Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(automatic, L"Settings save status");
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(automatic, L"Changes are saved and applied automatically.");
        save_status.push_back(automatic);
        panel.Children().Append(automatic);
        auto card_stack = StackPanel{};
        card_stack.Spacing(4);
        for (auto const& item : section_cards) {
            card_stack.Children().Append(item);
        }
        panel.Children().Append(card_stack);
        auto scroll = ScrollViewer{};
        scroll.Content(panel);
        scroll.Padding(Thickness{36, 0, 36, 0});
        scroll.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        scroll.VerticalScrollBarVisibility(ScrollBarVisibility::Auto);
        return scroll;
    }

    ScrollViewer makeAppearance(std::map<std::string, std::string> const& values) {
        auto const scheme = value(values, "color_scheme", "system");
        color_scheme = combo("", {L"Use system setting", L"Light", L"Dark"});
        color_scheme.SelectedIndex(scheme == "light" ? 1 : scheme == "dark" ? 2 : 0);
        auto const material = value(values, "backdrop", "mica");
        backdrop = combo("", {L"None", L"Mica (recommended)", L"Mica Alt", L"Acrylic"});
        backdrop.SelectedIndex(material == "none" ? 0 : material == "mica_alt" ? 2 : material == "acrylic" ? 3 : 1);
        dark_theme = themeCombo(value(values, "dark_theme", value(values, "theme", "fluent-dark")));
        light_theme = themeCombo(value(values, "light_theme", "fluent-light"));
        opacity = numberBox(value(values, "background_opacity", "100"), 100, 0, 100);
        opacity_cells = toggle(value(values, "background_opacity_cells", "false"));
        random_background = toggle(value(values, "randomize_tab_background", "true"));
        font_family = fontCombo(value(values, "font_family", "Cascadia Mono"));
        auto const selected_family = unbox_value<hstring>(font_family.SelectedItem());
        font_weight = weightCombo(selected_family.c_str(), value(values, "font_weight", "regular"));
        intense_font_weight = weightCombo(selected_family.c_str(), value(values, "intense_font_weight", "bold"));
        intense_text_style = combo("", {L"Bold font", L"Bold font with bright colours", L"Bright colours"});
        auto const style = value(values, "intense_text_style", "all");
        intense_text_style.SelectedIndex(style == "bold" ? 0 : style == "bright" ? 2 : 1);
        font_size = numberBox(value(values, "font_size", "18"), 18, 6, 72);
        text_antialiasing = combo("", {L"Accelerated grayscale (recommended)", L"Native ClearType"});
        text_antialiasing.SelectedIndex(value(values, "text_antialiasing", "acceleratedGrayscale") == "nativeClearType" ? 1 : 0);

        auto theme_grid = StackPanel{};
        theme_grid.Spacing(8);
        appendLabeled(theme_grid, L"Dark theme", dark_theme);
        appendLabeled(theme_grid, L"Light theme", light_theme);
        auto font = StackPanel{}; font.Spacing(8);
        appendLabeled(font, L"Font family", font_family);
        appendLabeled(font, L"Normal weight", font_weight);
        appendLabeled(font, L"Intense weight", intense_font_weight);
        appendLabeled(font, L"Intense text style", intense_text_style);
        appendLabeled(font, L"Size (points)", font_size);
        appendLabeled(font, L"Text antialiasing", text_antialiasing);
        return page(L"Appearance", L"Choose how Zigonaut and terminal sessions look.", {
            card(L"Application theme", L"Follow Windows or always use a light or dark color scheme.", color_scheme),
            card(L"Window material", L"Choose the Fluent backdrop used behind the terminal.", backdrop),
            card(L"Terminal themes", L"Theme names are loaded from the themes folder beside Zigonaut.", theme_grid, true),
            card(L"Font", L"Use an installed monospace font family.", font, true),
            card(L"Background opacity", L"Percentage opacity for the terminal background.", opacity),
            card(L"Transparent cell colors", L"Apply background opacity to explicitly colored terminal cells.", opacity_cells),
            card(L"Random tab colors", L"Gently tint each new tab's background while keeping it close to the selected theme.", random_background),
        });
    }

    ComboBox themeCombo(std::string const& selected) {
        auto found = std::find_if(themes.begin(), themes.end(), [&](auto const& theme) { return theme.name == selected; });
        if (found == themes.end()) {
            themes.push_back(rasmusTheme(selected));
            found = themes.end() - 1;
        }
        auto result = ComboBox{};
        result.HorizontalAlignment(HorizontalAlignment::Stretch);
        for (size_t index = 0; index < themes.size(); ++index) {
            result.Items().Append(themeItem(themes[index]));
            if (themes[index].name == selected) result.SelectedIndex(static_cast<int32_t>(index));
        }
        return result;
    }

    ScrollViewer makeTerminal(std::map<std::string, std::string> const& values) {
        scrollback_size = numberBox(value(values, "scrollback_size", "10000"), 10000, 0, 1000000, 1000);
        initial_columns = numberBox(value(values, "initial_columns", "80"), 80, 10, 1000);
        initial_rows = numberBox(value(values, "initial_rows", "24"), 24, 4, 1000);
        padding_horizontal = numberBox(value(values, "padding_horizontal", "8"), 8, 0, 128);
        padding_vertical = numberBox(value(values, "padding_vertical", "8"), 8, 0, 128);
        padding_balance = combo("", {L"Top left", L"Centered"});
        padding_balance.SelectedIndex(value(values, "padding_balance", "none") == "equal" ? 1 : 0);
        padding_color = combo("", {L"Terminal background", L"Extend edge colors", L"Always extend edge colors"});
        auto const padding_color_value = value(values, "padding_color", "background");
        padding_color.SelectedIndex(padding_color_value == "extend" ? 1 : padding_color_value == "extendAlways" ? 2 : 0);
        auto padding = StackPanel{}; padding.Spacing(8);
        appendLabeled(padding, L"Horizontal (pixels)", padding_horizontal);
        appendLabeled(padding, L"Vertical (pixels)", padding_vertical);
        appendLabeled(padding, L"Terminal alignment", padding_balance);
        appendLabeled(padding, L"Padding color", padding_color);
        auto initial_size = StackPanel{}; initial_size.Spacing(8);
        appendLabeled(initial_size, L"Columns", initial_columns);
        appendLabeled(initial_size, L"Rows", initial_rows);

        colors.reserve(19);
        auto palette = StackPanel{}; palette.Spacing(8);
        static wchar_t const* names[] = { L"Foreground", L"Background", L"Cursor", L"ANSI 0 \u00B7 Black", L"ANSI 1 \u00B7 Red", L"ANSI 2 \u00B7 Green", L"ANSI 3 \u00B7 Yellow", L"ANSI 4 \u00B7 Blue", L"ANSI 5 \u00B7 Magenta", L"ANSI 6 \u00B7 Cyan", L"ANSI 7 \u00B7 White", L"ANSI 8 \u00B7 Bright black", L"ANSI 9 \u00B7 Bright red", L"ANSI 10 \u00B7 Bright green", L"ANSI 11 \u00B7 Bright yellow", L"ANSI 12 \u00B7 Bright blue", L"ANSI 13 \u00B7 Bright magenta", L"ANSI 14 \u00B7 Bright cyan", L"ANSI 15 \u00B7 Bright white" };
        for (size_t index = 0; index < 19; ++index) {
            auto const key = index == 0 ? "foreground" : index == 1 ? "background" : index == 2 ? "cursor" : "ansi" + std::to_string(index - 3);
            auto editor = textBox(colorOrEmpty(values, key), L"Use theme default (#RRGGBB)");
            auto row = Grid{};
            auto editor_column = ColumnDefinition{};
            editor_column.Width(GridLength{1, GridUnitType::Star});
            row.ColumnDefinitions().Append(editor_column);
            auto preview_column = ColumnDefinition{};
            preview_column.Width(GridLength{1, GridUnitType::Auto});
            row.ColumnDefinitions().Append(preview_column);
            row.ColumnSpacing(8);
            row.Children().Append(editor);
            auto preview = Border{};
            preview.Width(32);
            preview.Height(32);
            preview.CornerRadius(CornerRadius{4});
            preview.BorderThickness(Thickness{1});
            preview.BorderBrush(Application::Current().Resources().Lookup(box_value(L"ControlStrokeColorDefaultBrush"))
                .as<Microsoft::UI::Xaml::Media::Brush>());
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetAccessibilityView(
                preview, Microsoft::UI::Xaml::Automation::Peers::AccessibilityView::Raw);
            Grid::SetColumn(preview, 1);
            row.Children().Append(preview);
            auto update_preview = [editor, preview] {
                auto const value = trim(to_string(editor.Text()));
                if (!validColor(value) || value.empty()) {
                    preview.Background(nullptr);
                    ToolTipService::SetToolTip(preview, box_value(value.empty() ? L"Theme default" : L"Invalid color"));
                    return;
                }
                auto component = [&value](size_t offset) {
                    return static_cast<uint8_t>(std::stoul(value.substr(offset, 2), nullptr, 16));
                };
                preview.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{
                    Windows::UI::Color{255, component(1), component(3), component(5)}});
                ToolTipService::SetToolTip(preview, box_value(editor.Text()));
            };
            editor.TextChanged([update_preview](auto const&, auto const&) { update_preview(); });
            update_preview();
            auto heading = label(names[index]);
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetLabeledBy(editor, heading);
            palette.Children().Append(heading);
            palette.Children().Append(row);
            colors.push_back(editor);
        }
        auto palette_expander = Expander{};
        palette_expander.Header(box_value(L"Edit palette overrides"));
        palette_expander.Content(palette);
        palette_expander.IsExpanded(false);
        return page(L"Terminal", L"Configure terminal history, dimensions, spacing, and optional palette overrides.", {
            card(L"Scrollback size", L"Maximum number of history lines kept for new terminal sessions.", scrollback_size),
            card(L"Initial window size", L"Terminal columns and rows used when opening a new window.", initial_size, true),
            card(L"Padding", L"Position the terminal grid and optionally continue application edge colors to the pane boundary.", padding, true),
            card(L"Palette overrides", L"Leave a field empty to use the selected theme. Colors use #RRGGBB.", palette_expander, true),
        });
    }

    void updateProfileButtons() {
        auto const count = profile_editors.size();
        for (auto const& editor : profile_editors) editor.remove.IsEnabled(count > 1);
        add_profile.IsEnabled(count < 32);
    }

    void refreshDefaultProfiles(std::string preferred = {}) {
        updating_profiles = true;
        if (preferred.empty() && default_profile.SelectedItem())
            preferred = trim(to_string(unbox_value<hstring>(default_profile.SelectedItem())));
        default_profile.Items().Clear();
        int32_t selected = -1;
        for (size_t index = 0; index < profile_editors.size(); ++index) {
            auto const name = trim(to_string(profile_editors[index].name.Text()));
            default_profile.Items().Append(box_value(to_hstring(name)));
            if (_stricmp(name.c_str(), preferred.c_str()) == 0) selected = static_cast<int32_t>(index);
        }
        default_profile.SelectedIndex(selected >= 0 ? selected : profile_editors.empty() ? -1 : 0);
        updating_profiles = false;
    }

    void appendProfile(ProfileValue const& profile) {
        auto const id = next_profile_id++;
        auto name = textBox(profile.name, L"Profile name");
        auto shell = combo("", {L"PowerShell", L"Command Prompt", L"WSL"});
        shell.SelectedIndex(profile.shell == "powershell" ? 0 : profile.shell == "wsl" ? 2 : 1);
        auto command = textBox(profile.command, L"Executable or command line");
        auto working_directory = textBox(profile.working_directory, L"User home directory");

        auto identity = Grid{};
        identity.ColumnSpacing(12);
        auto name_column = ColumnDefinition{};
        name_column.Width(GridLength{1, GridUnitType::Star});
        identity.ColumnDefinitions().Append(name_column);
        auto shell_column = ColumnDefinition{};
        shell_column.Width(GridLength{180, GridUnitType::Pixel});
        identity.ColumnDefinitions().Append(shell_column);
        auto name_field = StackPanel{};
        name_field.Spacing(4);
        appendLabeled(name_field, L"Name", name);
        identity.Children().Append(name_field);
        auto shell_field = StackPanel{};
        shell_field.Spacing(4);
        appendLabeled(shell_field, L"Shell type", shell);
        Grid::SetColumn(shell_field, 1);
        identity.Children().Append(shell_field);

        auto fields = StackPanel{};
        fields.Spacing(10);
        fields.Children().Append(identity);
        appendLabeled(fields, L"Command", command);
        auto working_directory_panel = Grid{};
        working_directory_panel.ColumnSpacing(8);
        auto path_column = ColumnDefinition{};
        path_column.Width(GridLength{1, GridUnitType::Star});
        working_directory_panel.ColumnDefinitions().Append(path_column);
        auto browse_column = ColumnDefinition{};
        browse_column.Width(GridLength{1, GridUnitType::Auto});
        working_directory_panel.ColumnDefinitions().Append(browse_column);
        working_directory_panel.Children().Append(working_directory);
        auto browse = Button{};
        browse.Content(actionContent(Symbol::Folder, L"Browse..."));
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(browse, L"Browse for profile working directory");
        browse.Click([this, id](auto const&, auto const&) { pickWorkingDirectory(shared_from_this(), id); });
        Grid::SetColumn(browse, 1);
        working_directory_panel.Children().Append(browse);
        appendLabeled(fields, L"Working directory", working_directory_panel, L"Leave empty to use your Windows home directory.");
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(working_directory, L"Profile working directory");
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(working_directory, L"Leave empty to use your Windows home directory.");
        auto remove = Button{};
        remove.Content(actionContent(Symbol::Delete, L"Remove profile"));
        remove.HorizontalAlignment(HorizontalAlignment::Right);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(remove, L"Remove profile");
        fields.Children().Append(remove);

        auto expander = Expander{};
        expander.Header(box_value(to_hstring(profile.name)));
        expander.Content(fields);
        expander.IsExpanded(false);
        auto container = Border{};
        container.Style(Application::Current().Resources().Lookup(box_value(L"ZigonautSettingsCardStyle")).as<Style>());
        container.Child(expander);
        profile_list.Children().Append(container);
        profile_editors.push_back({id, name, shell, command, working_directory, remove, expander, container});

        name.LostFocus([this, id](auto const&, auto const&) {
            auto const found = std::find_if(profile_editors.begin(), profile_editors.end(),
                [id](auto const& editor) { return editor.id == id; });
            if (found != profile_editors.end()) {
                found->expander.Header(box_value(found->name.Text()));
                auto const renamed_default = default_profile.SelectedIndex() == std::distance(profile_editors.begin(), found);
                refreshDefaultProfiles(renamed_default ? trim(to_string(found->name.Text())) : std::string{});
            }
            save();
        });
        auto committed = [this](auto const&, auto const&) { save(); };
        command.LostFocus(committed);
        working_directory.LostFocus(committed);
        shell.SelectionChanged([this](auto const&, auto const&) { save(); });
        remove.Click([this, id](auto const&, auto const&) { confirmRemoveProfile(shared_from_this(), id); });
    }

    fire_and_forget confirmRemoveProfile(std::shared_ptr<Dialog> lifetime, uint64_t id) {
        (void)lifetime;
        try {
            auto found = std::find_if(profile_editors.begin(), profile_editors.end(),
                [id](auto const& editor) { return editor.id == id; });
            if (found == profile_editors.end() || profile_editors.size() == 1) co_return;
            ContentDialog confirmation{};
            confirmation.XamlRoot(root.XamlRoot());
            confirmation.Title(box_value(L"Remove profile?"));
            confirmation.Content(box_value(L"This profile will be removed from the new-tab menu."));
            confirmation.PrimaryButtonText(L"Remove");
            confirmation.CloseButtonText(L"Cancel");
            confirmation.DefaultButton(ContentDialogButton::Close);
            if (co_await confirmation.ShowAsync() != ContentDialogResult::Primary || !open) co_return;
            found = std::find_if(profile_editors.begin(), profile_editors.end(),
                [id](auto const& editor) { return editor.id == id; });
            if (found == profile_editors.end() || profile_editors.size() == 1) co_return;
            auto const removed_name = trim(to_string(found->name.Text()));
            uint32_t index{};
            if (profile_list.Children().IndexOf(found->container, index)) profile_list.Children().RemoveAt(index);
            profile_editors.erase(found);
            auto selected_default = default_profile.SelectedItem()
                ? trim(to_string(unbox_value<hstring>(default_profile.SelectedItem()))) : std::string{};
            refreshDefaultProfiles(_stricmp(selected_default.c_str(), removed_name.c_str()) == 0
                ? trim(to_string(profile_editors.front().name.Text())) : selected_default);
            updateProfileButtons();
            save();
        } catch (hresult_error const& exception) {
            if (open) {
                error.Message(L"Unable to confirm profile removal: " + exception.message());
                error.IsOpen(true);
            }
        }
    }

    ScrollViewer makeProfiles(std::map<std::string, std::string> const& values, std::vector<ProfileValue> profile_values) {
        default_profile = ComboBox{};
        default_profile.HorizontalAlignment(HorizontalAlignment::Stretch);
        auto const selected_default = value(values, "default_profile", "PowerShell");
        if (profile_values.empty()) profile_values = {
            {"PowerShell", "powershell", "powershell.exe", ""},
            {"WSL", "wsl", "wsl.exe", ""},
            {"Command Prompt", "windows", "cmd.exe", ""},
        };
        profile_list = StackPanel{};
        profile_list.Spacing(8);
        profile_list.ChildrenTransitions().Append(Microsoft::UI::Xaml::Media::Animation::RepositionThemeTransition{});
        for (auto const& profile : profile_values) appendProfile(profile);
        refreshDefaultProfiles(selected_default);
        add_profile = Button{};
        add_profile.Content(actionContent(Symbol::Add, L"Add profile"));
        add_profile.HorizontalAlignment(HorizontalAlignment::Left);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(add_profile, L"Add profile");
        add_profile.Click([this](auto const&, auto const&) {
            auto suffix = profile_editors.size() + 1;
            std::string name;
            do {
                name = "Profile " + std::to_string(suffix++);
            } while (std::any_of(profile_editors.begin(), profile_editors.end(), [&](auto const& editor) {
                return _stricmp(trim(to_string(editor.name.Text())).c_str(), name.c_str()) == 0;
            }));
            appendProfile({name, "windows", "cmd.exe", ""});
            refreshDefaultProfiles();
            updateProfileButtons();
            save();
        });
        auto profile_panel = StackPanel{};
        profile_panel.Spacing(10);
        profile_panel.Children().Append(profile_list);
        profile_panel.Children().Append(add_profile);
        updateProfileButtons();
        hold_on_exit = toggle(value(values, "hold_on_exit", "false"));
        auto default_terminal = HyperlinkButton{};
        default_terminal.Content(box_value(L"Open Windows default terminal settings"));
        default_terminal.NavigateUri(Windows::Foundation::Uri{L"ms-settings:developers"});
        default_terminal.HorizontalAlignment(HorizontalAlignment::Left);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(default_terminal, L"Open Windows default terminal settings");
        auto explorer = ToggleSwitch{};
        explorer.IsOn(explorerIntegrationInstalled());
        explorer.OnContent(box_value(L"On"));
        explorer.OffContent(box_value(L"Off"));
        explorer.Toggled([this](auto const& sender, auto const&) {
            if (updating_explorer) return;
            auto const toggle = sender.as<ToggleSwitch>();
            try {
                if (toggle.IsOn()) installExplorerIntegration(); else removeExplorerIntegration();
                error.IsOpen(false);
            } catch (hresult_error const& exception) {
                error.Severity(InfoBarSeverity::Error);
                error.Message(L"Unable to update Explorer context menus: " + exception.message());
                error.IsOpen(true);
                updating_explorer = true;
                toggle.IsOn(explorerIntegrationInstalled());
                updating_explorer = false;
            }
        });
        return page(L"Profiles", L"Manage the shells available from the new-tab menu.", {
            card(L"Default profile", L"The profile opened at startup and by Ctrl+Shift+T.", default_profile),
            card(L"Launch profiles", L"Choose a name, shell type, command, and working directory for each new-tab option.", profile_panel, true),
            card(L"Keep tabs open", L"Keep a new tab open after its process exits cleanly.", hold_on_exit),
            card(L"Windows default terminal", L"Open the Windows selector for apps that implement the native terminal-host handoff.", default_terminal),
            card(L"File Explorer", L"Add or remove \u201COpen in Zigonaut\u201D for folders and folder backgrounds for this executable location.", explorer),
        });
    }

    fire_and_forget pickWorkingDirectory(std::shared_ptr<Dialog> lifetime, uint64_t profile_id) {
        (void)lifetime;
        try {
            Microsoft::Windows::Storage::Pickers::FolderPicker picker{window.AppWindow().Id()};
            picker.CommitButtonText(L"Select folder");
            auto const result = co_await picker.PickSingleFolderAsync();
            if (result && open) {
                auto const editor = std::find_if(profile_editors.begin(), profile_editors.end(),
                    [profile_id](auto const& item) { return item.id == profile_id; });
                if (editor != profile_editors.end()) {
                    editor->working_directory.Text(result.Path());
                    save();
                }
            }
        } catch (hresult_error const& exception) {
            if (open) {
                error.Message(L"Unable to open the folder picker: " + exception.message());
                error.IsOpen(true);
            }
        }
    }

    ScrollViewer makeAdvanced(std::map<std::string, std::string> const& values) {
        clipboard_write = toggle(value(values, "osc52_clipboard_write", "false"));
        double clipboard_kib = 1024;
        try { clipboard_kib = std::stod(value(values, "osc52_clipboard_max_bytes", "1048576")) / 1024; } catch (...) {}
        clipboard_limit = numberBox(std::to_string(clipboard_kib), 1024, 1.0 / 1024, 16384);
        pipe_command = textBox(value(values, "pipe_command_output"), L"Copy output to the clipboard");
        clipboard_limit_card = card(L"Clipboard payload limit (KiB)", L"Maximum decoded terminal clipboard payload, in kibibytes.", clipboard_limit);
        clipboard_limit.IsEnabled(clipboard_write.IsOn());
        return page(L"Advanced", L"Security-sensitive terminal integration settings.", {
            card(L"Terminal clipboard writes", L"Allow OSC 52 and OSC 1337 Copy sequences to write to the Windows clipboard.", clipboard_write),
            clipboard_limit_card,
            card(L"Pipe command output", L"Windows command that receives the latest OSC 133 command output on stdin. Leave empty to copy it.", pipe_command),
            makeAbout(),
        });
    }

    Border makeAbout() {
        auto image_path = executablePath();
        auto const separator = image_path.find_last_of(L"\\/");
        image_path.resize(separator == std::wstring::npos ? 0 : separator + 1);
        image_path += L"zigonaut-about-1024.png";
        std::replace(image_path.begin(), image_path.end(), L'\\', L'/');
        auto bitmap = Microsoft::UI::Xaml::Media::Imaging::BitmapImage{};
        bitmap.UriSource(Windows::Foundation::Uri{hstring{L"file:///" + image_path}});
        auto image = Image{};
        image.Source(bitmap);
        image.Width(40);
        image.Height(40);
        image.Stretch(Microsoft::UI::Xaml::Media::Stretch::Uniform);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(image, L"Zigonaut app icon");

        auto name = TextBlock{};
        name.Text(L"Zigonaut");
        name.FontWeight(Windows::UI::Text::FontWeights::SemiBold());

        auto version = TextBlock{};
        version.Text(hstring{L"Version " + app_version});
        version.Style(Application::Current().Resources().Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());

        auto title = StackPanel{};
        title.Spacing(2);
        title.Children().Append(name);
        title.Children().Append(version);

        auto header = Grid{};
        header.ColumnSpacing(12);
        auto icon_column = ColumnDefinition{};
        icon_column.Width(GridLength{1, GridUnitType::Auto});
        header.ColumnDefinitions().Append(icon_column);
        auto title_column = ColumnDefinition{};
        title_column.Width(GridLength{1, GridUnitType::Star});
        header.ColumnDefinitions().Append(title_column);
        header.Children().Append(image);
        Grid::SetColumn(title, 1);
        header.Children().Append(title);

        auto content = StackPanel{};
        content.Spacing(2);
        content.Padding(Thickness{0, 8, 0, 0});
        auto append_link = [&content](std::wstring_view text, std::wstring_view uri) {
            auto link = HyperlinkButton{};
            link.Content(box_value(text));
            link.NavigateUri(Windows::Foundation::Uri{uri});
            link.HorizontalAlignment(HorizontalAlignment::Left);
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(link, text);
            content.Children().Append(link);
        };
        append_link(L"Release notes", L"https://github.com/iainh/zigonaut/releases");
        append_link(L"Source code", L"https://github.com/iainh/zigonaut");
        append_link(L"Report a bug", L"https://github.com/iainh/zigonaut/issues/new?labels=bug");
        append_link(L"Request a feature", L"https://github.com/iainh/zigonaut/issues/new?labels=enhancement");
        append_link(L"MIT License", L"https://github.com/iainh/zigonaut/blob/main/LICENSE");
        append_link(L"Open-source notices", L"https://github.com/iainh/zigonaut/tree/main/licenses");

        auto hash = TextBlock{};
        hash.Style(Application::Current().Resources().Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
        hash.Margin(Thickness{8, 8, 8, 0});
        auto hash_label = Microsoft::UI::Xaml::Documents::Run{};
        hash_label.Text(L"Git commit ");
        hash.Inlines().Append(hash_label);
        auto hash_link = Microsoft::UI::Xaml::Documents::Hyperlink{};
        auto hash_text = Microsoft::UI::Xaml::Documents::Run{};
        auto const abbreviated_hash = std::wstring_view{git_hash}.substr(0, std::min<size_t>(12, git_hash.size()));
        hash_text.Text(hstring{abbreviated_hash});
        hash_link.Inlines().Append(hash_text);
        hash_link.NavigateUri(Windows::Foundation::Uri{
            hstring{L"https://github.com/iainh/zigonaut/commit/" + git_hash},
        });
        hash.Inlines().Append(hash_link);
        content.Children().Append(hash);

        auto copyright = TextBlock{};
        copyright.Text(L"Copyright \u00A9 2026 Iain H");
        copyright.Margin(Thickness{8, 0, 8, 0});
        copyright.Style(Application::Current().Resources().Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
        content.Children().Append(copyright);

        auto expander = Expander{};
        expander.Header(header);
        expander.Content(content);
        expander.IsExpanded(false);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(expander, L"About Zigonaut");

        auto information = Border{};
        information.Style(Application::Current().Resources().Lookup(box_value(L"ZigonautSettingsCardStyle")).as<Style>());
        information.Child(expander);
        return information;
    }

    std::string serialize() {
        auto string = [](TextBox const& box) { return trim(to_string(box.Text())); };
        auto selectedTheme = [](ComboBox const& box) {
            return trim(to_string(box.SelectedItem().as<ComboBoxItem>().Tag().as<hstring>()));
        };
        auto selectedWeight = [](ComboBox const& box) {
            return trim(to_string(box.SelectedItem().as<ComboBoxItem>().Tag().as<hstring>()));
        };
        auto const selected_font = trim(to_string(unbox_value<hstring>(font_family.SelectedItem())));
        auto const selected_font_weight = selectedWeight(font_weight);
        auto const selected_intense_font_weight = selectedWeight(intense_font_weight);
        auto const selected_intense_text_style = intense_text_style.SelectedIndex() == 0 ? "bold" : intense_text_style.SelectedIndex() == 2 ? "bright" : "all";
        auto const selected_dark_theme = selectedTheme(dark_theme);
        auto const selected_light_theme = selectedTheme(light_theme);
        auto integer = [](NumberBox const& box, double minimum, double maximum) {
            auto const value = box.Value();
            if (!std::isfinite(value) || std::trunc(value) != value || value < minimum || value > maximum)
                throw FieldValidationError("Enter a whole number within the displayed range.", box);
            return value;
        };
        auto const font_size_value = integer(font_size, 6, 72);
        auto const scrollback_value = integer(scrollback_size, 0, 1000000);
        auto const columns_value = integer(initial_columns, 10, 1000);
        auto const rows_value = integer(initial_rows, 4, 1000);
        auto const horizontal_padding_value = integer(padding_horizontal, 0, 128);
        auto const vertical_padding_value = integer(padding_vertical, 0, 128);
        auto const opacity_value = integer(opacity, 0, 100);
        auto const clipboard_kib_value = clipboard_limit.Value();
        if (!std::isfinite(clipboard_kib_value) || clipboard_kib_value < 1.0 / 1024 || clipboard_kib_value > 16384)
            throw FieldValidationError("Enter a clipboard limit between 1 byte and 16 MiB.", clipboard_limit);
        auto const clipboard_limit_value = std::round(clipboard_kib_value * 1024);
        if (selected_font.empty() || selected_font.size() >= 128) throw FieldValidationError("Choose a valid font family.", font_family);
        if (selected_dark_theme.empty() || selected_dark_theme.size() >= 64 || selected_light_theme.empty() || selected_light_theme.size() >= 64)
            throw std::runtime_error("Theme names must be between 1 and 63 UTF-8 bytes.");
        for (auto const& editor : colors) if (!validColor(string(editor))) throw FieldValidationError("Enter a color as #RRGGBB, or leave it empty.", editor);

        std::vector<ProfileValue> profile_values;
        for (auto const& editor : profile_editors) {
            auto name = string(editor.name);
            auto command = string(editor.command);
            auto working_directory = string(editor.working_directory);
            auto kind = editor.shell.SelectedIndex() == 0 ? "powershell" : editor.shell.SelectedIndex() == 2 ? "wsl" : "windows";
            if (name.empty() || name.size() >= 128 || name.find_first_of("|\r\n") != std::string::npos)
                throw FieldValidationError("Enter a profile name of 1\xE2\x80\x93" "127 bytes without | or line breaks.", editor.name);
            if (command.empty() || command.find('\r') != std::string::npos || command.find('\n') != std::string::npos || command.find('\0') != std::string::npos)
                throw FieldValidationError("Enter a command without line breaks or NUL characters.", editor.command);
            if (working_directory.find('\0') != std::string::npos)
                throw FieldValidationError("The working directory cannot contain NUL characters.", editor.working_directory);
            if (std::any_of(profile_values.begin(), profile_values.end(), [&](auto const& profile) { return _stricmp(profile.name.c_str(), name.c_str()) == 0; }))
                throw FieldValidationError("Enter a unique profile name.", editor.name);
            profile_values.push_back({std::move(name), kind, std::move(command), std::move(working_directory)});
        }
        if (profile_values.empty() || profile_values.size() > 32) throw std::runtime_error("Add between 1 and 32 profiles.");
        auto const selected_default = default_profile.SelectedItem()
            ? trim(to_string(unbox_value<hstring>(default_profile.SelectedItem()))) : std::string{};
        if (selected_default.empty() || selected_default.size() >= 128) throw std::runtime_error("Default profile must be between 1 and 127 UTF-8 bytes.");
        if (std::none_of(profile_values.begin(), profile_values.end(), [&](auto const& profile) { return _stricmp(profile.name.c_str(), selected_default.c_str()) == 0; }))
            throw std::runtime_error("The default profile must match a launch profile name.");
        auto const selected_pipe_command = string(pipe_command);
        if (selected_pipe_command.size() >= 4096 || selected_pipe_command.find('\0') != std::string::npos)
            throw FieldValidationError("Enter a pipe command shorter than 4096 bytes without NUL characters.", pipe_command);

        using Windows::Data::Json::JsonArray;
        using Windows::Data::Json::JsonObject;
        using Windows::Data::Json::JsonValue;
        auto text = [](std::string const& value) { return JsonValue::CreateStringValue(to_hstring(value)); };
        auto number = [](double value) { return JsonValue::CreateNumberValue(value); };
        auto boolean = [](bool value) { return JsonValue::CreateBooleanValue(value); };

        JsonObject root;
        root.Insert(L"version", number(1));
        JsonObject appearance;
        JsonObject font;
        font.Insert(L"family", text(selected_font));
        font.Insert(L"size", number(font_size_value));
        font.Insert(L"weight", text(selected_font_weight));
        font.Insert(L"intenseWeight", text(selected_intense_font_weight));
        font.Insert(L"intenseTextStyle", text(selected_intense_text_style));
        font.Insert(L"antialiasing", text(text_antialiasing.SelectedIndex() == 1 ? "nativeClearType" : "acceleratedGrayscale"));
        appearance.Insert(L"font", font);
        JsonObject selected_themes;
        selected_themes.Insert(L"dark", text(selected_dark_theme));
        selected_themes.Insert(L"light", text(selected_light_theme));
        selected_themes.Insert(L"colorScheme", text(color_scheme.SelectedIndex() == 1 ? "light" : color_scheme.SelectedIndex() == 2 ? "dark" : "system"));
        appearance.Insert(L"themes", selected_themes);
        JsonObject padding;
        padding.Insert(L"horizontal", number(horizontal_padding_value));
        padding.Insert(L"vertical", number(vertical_padding_value));
        padding.Insert(L"balance", text(padding_balance.SelectedIndex() == 1 ? "equal" : "none"));
        padding.Insert(L"color", text(padding_color.SelectedIndex() == 1 ? "extend" : padding_color.SelectedIndex() == 2 ? "extendAlways" : "background"));
        appearance.Insert(L"padding", padding);
        JsonObject terminal_background;
        terminal_background.Insert(L"opacity", number(opacity_value));
        terminal_background.Insert(L"opacityCells", JsonValue::CreateBooleanValue(opacity_cells.IsOn()));
        terminal_background.Insert(L"backdrop", text(backdrop.SelectedIndex() == 0 ? "none" : backdrop.SelectedIndex() == 2 ? "mica_alt" : backdrop.SelectedIndex() == 3 ? "acrylic" : "mica"));
        appearance.Insert(L"background", terminal_background);
        JsonObject palette;
        static wchar_t const* palette_keys[] = {L"foreground", L"background", L"cursor"};
        for (size_t index = 0; index < 3; ++index) if (!string(colors[index]).empty()) palette.Insert(palette_keys[index], text(string(colors[index])));
        auto has_ansi = std::any_of(colors.begin() + 3, colors.end(), [&](auto const& editor) { return !string(editor).empty(); });
        if (has_ansi) {
            JsonArray ansi;
            for (size_t index = 3; index < colors.size(); ++index)
                ansi.Append(string(colors[index]).empty() ? JsonValue::CreateNullValue() : text(string(colors[index])));
            palette.Insert(L"ansi", ansi);
        }
        appearance.Insert(L"palette", palette);
        appearance.Insert(L"randomizeTabBackground", boolean(random_background.IsOn()));
        root.Insert(L"appearance", appearance);

        JsonObject terminal;
        terminal.Insert(L"scrollbackSize", number(scrollback_value));
        JsonObject initial_size;
        initial_size.Insert(L"columns", number(columns_value));
        initial_size.Insert(L"rows", number(rows_value));
        terminal.Insert(L"initialSize", initial_size);
        root.Insert(L"terminal", terminal);

        JsonObject profile_settings;
        profile_settings.Insert(L"default", text(selected_default));
        JsonArray profile_items;
        for (auto const& profile_value : profile_values) {
            JsonObject profile;
            profile.Insert(L"name", text(profile_value.name));
            profile.Insert(L"shell", text(profile_value.shell));
            profile.Insert(L"command", text(profile_value.command));
            profile.Insert(L"workingDirectory", text(profile_value.working_directory));
            profile_items.Append(profile);
        }
        profile_settings.Insert(L"items", profile_items);
        profile_settings.Insert(L"holdOnExit", boolean(hold_on_exit.IsOn()));
        root.Insert(L"profiles", profile_settings);

        JsonObject advanced;
        JsonObject clipboard;
        clipboard.Insert(L"terminalWrites", boolean(clipboard_write.IsOn()));
        clipboard.Insert(L"maximumBytes", number(clipboard_limit_value));
        advanced.Insert(L"clipboard", clipboard);
        advanced.Insert(L"pipeCommandOutput", text(selected_pipe_command));
        root.Insert(L"advanced", advanced);
        auto output = to_string(root.Stringify());
        if (output.size() > 64 * 1024) throw std::runtime_error("Configuration must not exceed 64 KiB.");
        return output;
    }

    void save() noexcept {
        for (auto const& status : save_status) status.Text(L"Saving\u2026");
        try {
            auto output = serialize();
            auto temporary = path;
            temporary.concat(L".tmp");
            {
                std::ofstream file{temporary, std::ios::binary | std::ios::trunc};
                if (!file || !(file << output)) throw std::runtime_error("Unable to write the configuration file.");
            }
            if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                std::filesystem::remove(temporary);
                throw std::runtime_error("Unable to replace the configuration file.");
            }
            error.IsOpen(false);
            for (auto const& status : save_status) status.Text(L"Saved");
            if (saved) saved();
        } catch (FieldValidationError const& exception) {
            auto const message = to_hstring(exception.what());
            error.Message(message);
            error.IsOpen(true);
            exception.control.Focus(FocusState::Programmatic);
            for (auto const& status : save_status) status.Text(L"Couldn't save");
        } catch (std::exception const& exception) {
            error.Message(to_hstring(exception.what()));
            error.IsOpen(true);
            for (auto const& status : save_status) status.Text(L"Couldn't save");
        }
    }

    void registerAutoSave() {
        auto text_committed = [this](auto const&, auto const&) { save(); };
        pipe_command.LostFocus(text_committed);
        for (auto const& editor : colors) editor.LostFocus(text_committed);
        auto number_changed = [this](auto const&, auto const&) { save(); };
        for (auto const& editor : {font_size, scrollback_size, initial_columns, initial_rows, padding_horizontal, padding_vertical, opacity, clipboard_limit})
            editor.ValueChanged(number_changed);
        auto selection_changed = [this](auto const&, auto const&) { save(); };
        color_scheme.SelectionChanged(selection_changed);
        backdrop.SelectionChanged(selection_changed);
        dark_theme.SelectionChanged(selection_changed);
        light_theme.SelectionChanged(selection_changed);
        intense_text_style.SelectionChanged(selection_changed);
        text_antialiasing.SelectionChanged(selection_changed);
        padding_balance.SelectionChanged(selection_changed);
        padding_color.SelectionChanged(selection_changed);
        font_family.SelectionChanged([this](auto const&, auto const&) {
            auto const family = unbox_value<hstring>(font_family.SelectedItem());
            updating_font_weights = true;
            refreshWeightCombo(font_weight, family.c_str(), "regular");
            refreshWeightCombo(intense_font_weight, family.c_str(), "bold");
            updating_font_weights = false;
            save();
        });
        auto weight_changed = [this](auto const&, auto const&) {
            if (!updating_font_weights) save();
        };
        font_weight.SelectionChanged(weight_changed);
        intense_font_weight.SelectionChanged(weight_changed);
        default_profile.SelectionChanged([this](auto const&, auto const&) {
            if (!updating_profiles) save();
        });
        auto toggled = [this](auto const&, auto const&) { save(); };
        for (auto const& editor : {random_background, opacity_cells, hold_on_exit}) editor.Toggled(toggled);
        clipboard_write.Toggled([this](auto const&, auto const&) {
            clipboard_limit.IsEnabled(clipboard_write.IsOn());
            save();
        });
    }

    void applyTheme(bool high_contrast, bool dark_theme) {
        HWND settings_window{};
        check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&settings_window));
        BOOL const use_dark_frame = dark_theme && !high_contrast;
        DwmSetWindowAttribute(
            settings_window,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            &use_dark_frame,
            sizeof(use_dark_frame));
        root.RequestedTheme(high_contrast ? ElementTheme::Default : dark_theme ? ElementTheme::Dark : ElementTheme::Light);
        window.AppWindow().TitleBar().PreferredTheme(high_contrast
            ? Microsoft::UI::Windowing::TitleBarTheme::UseDefaultAppMode
            : dark_theme ? Microsoft::UI::Windowing::TitleBarTheme::Dark
                         : Microsoft::UI::Windowing::TitleBarTheme::Light);
    }
};

std::shared_ptr<Dialog> show(HWND owner, std::string_view path, std::string_view contents, std::wstring_view version,
                             std::wstring_view git_hash, bool high_contrast, bool dark_theme,
                             std::function<void()> saved) {
    auto result = std::make_shared<Dialog>(owner, path, contents, version, git_hash, high_contrast, dark_theme, std::move(saved));
    result->window.Activate();
    return result;
}

bool isOpen(std::shared_ptr<Dialog> const& dialog) noexcept {
    return dialog && dialog->open;
}

void activate(std::shared_ptr<Dialog> const& dialog) {
    if (isOpen(dialog)) dialog->window.Activate();
}

void setTheme(std::shared_ptr<Dialog> const& dialog, bool high_contrast, bool dark_theme) {
    if (isOpen(dialog)) dialog->applyTheme(high_contrast, dark_theme);
}

void close(std::shared_ptr<Dialog> const& dialog) {
    if (isOpen(dialog)) dialog->window.Close();
}

}
