#pragma once
#include <adwaita.h>

#define ZGTK_MAX_PROFILES 32
typedef struct {
    char name[128], shell[4096], command[4096], directory[4096];
} Profile;

typedef struct {
    char font[256];
    int font_size, line_height, padding, scheme, light_theme, dark_theme;
    int scrollback, columns, rows, intense, clipboard, clipboard_limit;
    int profile_count, default_profile;
    Profile profiles[ZGTK_MAX_PROFILES];
} Settings;

/* Failed loads leave defaults and never overwrite the original file. */
void settings_defaults(Settings *settings);
gboolean settings_load(Settings *settings, GError **error);
gboolean settings_save(const Settings *settings, GError **error);
char *settings_path(void);
void settings_present(GtkWindow *parent, Settings *settings,
                      void (*applied)(gpointer), gpointer data);
