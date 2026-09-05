# Windows keyboard shortcuts

These shortcuts apply to Zigonaut on Windows. Shortcuts that operate on terminal content require a terminal pane to have focus.

## Windows, tabs, and panes

| Shortcut | Description |
| --- | --- |
| `Ctrl+Shift+T` | Open a tab with the default profile. |
| `Ctrl+Shift+N` | Open a new Zigonaut window. |
| `Ctrl+Shift+W` | Close the focused pane. If it is the last pane, close its tab; if it is the last tab, close the window. |
| `Ctrl+Tab` | Select the next tab. |
| `Ctrl+Shift+Tab` | Select the previous tab. |
| `Ctrl+1`–`Ctrl+9` | Select the tab at the corresponding position. |
| `Ctrl+Shift+O` | Split the focused pane to the right. |
| `Ctrl+Shift+E` | Split the focused pane downward. |
| `Ctrl+Alt+Left` / `Right` / `Up` / `Down` | Move focus to the pane in that direction. |
| `Ctrl+Alt+Page Up` / `Page Down` | Move focus to the previous or next pane. |
| `Ctrl+Alt+Shift+Left` / `Right` / `Up` / `Down` | Move the nearest pane divider in that direction by 5%. |
| `Ctrl+Alt+=` | Make all panes equal in size. |
| `Ctrl+Shift+Enter` | Toggle zoom for the focused pane. |
| `Alt+F4` | Close the window. |

## Terminal content

| Shortcut | Description |
| --- | --- |
| `Ctrl+Shift+C` / `Ctrl+Insert` | Copy the current selection. |
| `Ctrl+Shift+V` / `Shift+Insert` | Paste text from the clipboard. |
| `Ctrl+Shift+F` | Open scrollback search for the focused pane. |
| `Shift+Page Up` / `Shift+Page Down` | Scroll history up or down by one page. |
| `Shift+Home` / `Shift+End` | Jump to the beginning or end of history. |
| `Ctrl+Shift+Up` / `Ctrl+Shift+Down` | Move to the previous or next shell prompt. This requires OSC 133 shell integration. |
| `Ctrl+Shift+G` | Copy the latest command output, or send it to the command configured under **Settings > Advanced**. This requires OSC 133 shell integration. |
| `Application` / `Shift+F10` | Open the terminal context menu. |

History shortcuts are passed through to applications using the alternate screen, such as editors and full-screen terminal interfaces.

## Scrollback search

These shortcuts apply while the search box is open.

| Shortcut | Description |
| --- | --- |
| `Enter` / `Ctrl+N` | Select the next match. |
| `Shift+Enter` / `Ctrl+P` | Select the previous match. |
| `Ctrl+U` | Clear the search query. |
| `Esc` / `Ctrl+G` | Close search and return focus to the terminal. |

## Font size

| Shortcut | Description |
| --- | --- |
| `Ctrl+=` / `Ctrl++` / `Ctrl+Numpad +` | Increase the font size. |
| `Ctrl+-` / `Ctrl+Numpad -` | Decrease the font size. |
| `Ctrl+0` / `Ctrl+Numpad 0` | Reset the font size. |

Shortcuts not listed here are sent to the running terminal application. The application may interpret them according to its own key bindings and the active terminal keyboard protocol.
