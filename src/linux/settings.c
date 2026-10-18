#include "settings.h"
#include <errno.h>
#include <stddef.h>
#include <unistd.h>

/* One table owns the persisted scalar contract and its preferences controls.
 * Platform-specific settings deliberately do not enter the shared engine. */
typedef struct {
    const char *key, *title;
    size_t offset;
    int minimum, maximum;
    const char *const *choices;
} Field;
static const char *const schemes[] = { "System", "Light", "Dark", NULL };
static const char *const themes[] = { "Rasmus", "Fluent Light", "Fluent Dark", NULL };
static const char *const intense_styles[] = { "Bold and bright", "Bold", "Bright", NULL };
#define FIELD(key, title, member, min, max, choices) { key, title, offsetof(Settings, member), min, max, choices }
static const Field fields[] = {
    FIELD("fontSize", "Font size (points)", font_size, 6, 40, NULL),
    FIELD("lineHeight", "Line height (%)", line_height, 100, 200, NULL),
    FIELD("padding", "Terminal padding (pixels)", padding, 0, 64, NULL),
    FIELD("colourScheme", "Colour scheme", scheme, 0, 2, schemes),
    FIELD("lightTheme", "Light terminal theme", light_theme, 0, 2, themes),
    FIELD("darkTheme", "Dark terminal theme", dark_theme, 0, 2, themes),
    FIELD("intenseText", "Intense text", intense, 0, 2, intense_styles),
    FIELD("scrollback", "Scrollback lines", scrollback, 0, 1000000, NULL),
    FIELD("columns", "Initial columns (new windows)", columns, 20, 500, NULL),
    FIELD("rows", "Initial rows (new windows)", rows, 5, 200, NULL),
    FIELD("terminalClipboardWrites", "Allow terminal clipboard writes", clipboard, 0, 1, NULL),
    FIELD("clipboardLimit", "Clipboard write limit (bytes)", clipboard_limit, 1, 16777216, NULL),
};

void settings_defaults(Settings *s) {
    memset(s, 0, sizeof *s);
    g_strlcpy(s->font, "Monospace", sizeof s->font);
    s->font_size = 12; s->line_height = 100; s->padding = 8;
    s->light_theme = 1; s->dark_theme = 2;
    s->scrollback = 10000; s->columns = 80; s->rows = 24;
    s->clipboard_limit = 1048576;
    s->profile_count = 1;
    g_strlcpy(s->profiles[0].name, "Default", sizeof s->profiles[0].name);
    const char *shell = g_getenv("SHELL");
    if (!shell || !g_path_is_absolute(shell) || access(shell, X_OK) != 0) shell = "/bin/sh";
    g_strlcpy(s->profiles[0].shell, shell, sizeof s->profiles[0].shell);
}

char *settings_path(void) {
    return g_build_filename(g_get_user_config_dir(), "zigonaut", "settings.ini", NULL);
}

static gboolean invalid(GError **error, const char *message) {
    g_set_error_literal(error, G_KEY_FILE_ERROR, G_KEY_FILE_ERROR_INVALID_VALUE, message);
    return FALSE;
}

static gboolean validate(const Settings *s, GError **error) {
    if (!*s->font || !g_utf8_validate(s->font, -1, NULL)) return invalid(error, "Enter a font family.");
    for (guint i = 0; i < G_N_ELEMENTS(fields); i++) {
        const Field *f = &fields[i];
        int value = *(const int *)((const char *)s + f->offset);
        if (value < f->minimum || value > f->maximum) return invalid(error, f->title);
    }
    if (s->profile_count < 1 || s->profile_count > ZGTK_MAX_PROFILES ||
        s->default_profile < 0 || s->default_profile >= s->profile_count)
        return invalid(error, "Keep at least one profile and choose a default.");
    for (int i = 0; i < s->profile_count; i++) {
        const Profile *p = &s->profiles[i];
        if (!*p->name || !g_utf8_validate(p->name, -1, NULL)) return invalid(error, "Each profile needs a name.");
        for (int j = 0; j < i; j++) {
            char *a = g_utf8_casefold(p->name, -1), *b = g_utf8_casefold(s->profiles[j].name, -1);
            gboolean equal = !strcmp(a, b);
            g_free(a); g_free(b);
            if (equal) return invalid(error, "Profile names must be unique (ignoring case).");
        }
        if (!g_path_is_absolute(p->shell) || access(p->shell, X_OK) != 0 ||
            !g_file_test(p->shell, G_FILE_TEST_IS_REGULAR))
            return invalid(error, "Each shell must be an absolute path to an executable file.");
        if (*p->directory && (!g_path_is_absolute(p->directory) ||
                             !g_file_test(p->directory, G_FILE_TEST_IS_DIR)))
            return invalid(error, "Working directories must be existing absolute paths, or empty to inherit the launcher directory.");
    }
    return TRUE;
}

static gboolean read_string(GKeyFile *file, const char *group, const char *key,
                            char *buffer, size_t capacity, GError **error) {
    if (!g_key_file_has_key(file, group, key, NULL)) return TRUE;
    char *value = g_key_file_get_string(file, group, key, error);
    if (!value) return FALSE;
    gboolean valid = strlen(value) < capacity && g_utf8_validate(value, -1, NULL);
    if (valid) g_strlcpy(buffer, value, capacity);
    g_free(value);
    return valid || invalid(error, "A settings string is too long or is not UTF-8.");
}

gboolean settings_load(Settings *s, GError **error) {
    settings_defaults(s);
    char *path = settings_path();
    GKeyFile *file = g_key_file_new();
    GError *local = NULL;
    gboolean loaded = g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, &local);
    g_free(path);
    if (!loaded) {
        g_key_file_unref(file);
        if (g_error_matches(local, G_FILE_ERROR, G_FILE_ERROR_NOENT)) { g_clear_error(&local); return TRUE; }
        g_propagate_error(error, local);
        return FALSE;
    }
    Settings *next = g_memdup2(s, sizeof *s);
    int version = g_key_file_get_integer(file, "Settings", "version", &local);
    if (!local && version != 1) invalid(&local, "Unsupported settings version.");
    if (!local) read_string(file, "Settings", "font", next->font, sizeof next->font, &local);
    for (guint i = 0; !local && i < G_N_ELEMENTS(fields); i++) {
        const Field *f = &fields[i];
        if (g_key_file_has_key(file, "Settings", f->key, NULL))
            *(int *)((char *)next + f->offset) = g_key_file_get_integer(file, "Settings", f->key, &local);
    }
    if (!local) next->profile_count = g_key_file_get_integer(file, "Settings", "profileCount", &local);
    if (!local) next->default_profile = g_key_file_get_integer(file, "Settings", "defaultProfile", &local);
    if (!local && (next->profile_count < 1 || next->profile_count > ZGTK_MAX_PROFILES)) invalid(&local, "Invalid profile count.");
    for (int i = 0; !local && i < next->profile_count; i++) {
        char group[32]; g_snprintf(group, sizeof group, "Profile %d", i);
        Profile *p = &next->profiles[i];
        memset(p, 0, sizeof *p);
        if (!read_string(file, group, "name", p->name, sizeof p->name, &local) ||
            !read_string(file, group, "shell", p->shell, sizeof p->shell, &local) ||
            !read_string(file, group, "command", p->command, sizeof p->command, &local) ||
            !read_string(file, group, "directory", p->directory, sizeof p->directory, &local)) break;
    }
    if (!local) validate(next, &local);
    if (!local) *s = *next;
    g_free(next); g_key_file_unref(file);
    if (local) { g_propagate_error(error, local); return FALSE; }
    return TRUE;
}

gboolean settings_save(const Settings *s, GError **error) {
    if (!validate(s, error)) return FALSE;
    GKeyFile *file = g_key_file_new();
    g_key_file_set_integer(file, "Settings", "version", 1);
    g_key_file_set_string(file, "Settings", "font", s->font);
    for (guint i = 0; i < G_N_ELEMENTS(fields); i++) {
        const Field *f = &fields[i];
        g_key_file_set_integer(file, "Settings", f->key, *(const int *)((const char *)s + f->offset));
    }
    g_key_file_set_integer(file, "Settings", "profileCount", s->profile_count);
    g_key_file_set_integer(file, "Settings", "defaultProfile", s->default_profile);
    for (int i = 0; i < s->profile_count; i++) {
        char group[32]; g_snprintf(group, sizeof group, "Profile %d", i);
        const Profile *p = &s->profiles[i];
        g_key_file_set_string(file, group, "name", p->name);
        g_key_file_set_string(file, group, "shell", p->shell);
        g_key_file_set_string(file, group, "command", p->command);
        g_key_file_set_string(file, group, "directory", p->directory);
    }
    gsize length;
    char *contents = g_key_file_to_data(file, &length, NULL), *path = settings_path();
    char *directory = g_path_get_dirname(path);
    gboolean saved = FALSE;
    if (g_mkdir_with_parents(directory, 0700) < 0)
        g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno), "Cannot create settings directory: %s", g_strerror(errno));
    else saved = g_file_set_contents_full(path, contents, length,
        G_FILE_SET_CONTENTS_CONSISTENT | G_FILE_SET_CONTENTS_DURABLE, 0600, error);
    g_free(directory); g_free(path); g_free(contents); g_key_file_unref(file);
    return saved;
}

typedef struct {
    Settings *settings;
    void (*applied)(gpointer);
    gpointer data;
    GtkWindow *window;
    GtkWidget *font, *controls[G_N_ELEMENTS(fields)];
    GtkWidget *names[ZGTK_MAX_PROFILES], *shells[ZGTK_MAX_PROFILES];
    GtkWidget *commands[ZGTK_MAX_PROFILES], *directories[ZGTK_MAX_PROFILES];
    AdwPreferencesGroup *groups[ZGTK_MAX_PROFILES];
    GtkStringList *profile_names;
    AdwComboRow *default_profile;
    AdwPreferencesPage *profiles_page;
    AdwPreferencesGroup *errors[3];
    GtkWidget *add;
    int count;
    gboolean updating;
} Editor;

static void changed(GtkWidget *widget, gpointer data);
static void property_changed(GObject *object, GParamSpec *property, gpointer data) {
    (void)object; (void)property;
    changed(NULL, data);
}

static GtkWidget *entry(AdwPreferencesGroup *group, const char *title, const char *text) {
    GtkWidget *row = adw_entry_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), title);
    gtk_editable_set_text(GTK_EDITABLE(row), text);
    adw_preferences_group_add(group, row);
    return row;
}

static void refresh_names(Editor *e) {
    gboolean updating = e->updating;
    e->updating = TRUE;
    guint selected = adw_combo_row_get_selected(e->default_profile);
    while (g_list_model_get_n_items(G_LIST_MODEL(e->profile_names))) gtk_string_list_remove(e->profile_names, 0);
    for (int i = 0; i < e->count; i++) gtk_string_list_append(e->profile_names, gtk_editable_get_text(GTK_EDITABLE(e->names[i])));
    adw_combo_row_set_selected(e->default_profile, MIN(selected, (guint)e->count - 1));
    gtk_widget_set_sensitive(e->add, e->count < ZGTK_MAX_PROFILES);
    e->updating = updating;
}

static void name_changed(GtkEditable *editable, gpointer data) {
    (void)editable;
    Editor *e = data;
    if (e->updating) return;
    refresh_names(e);
    changed(NULL, e);
}

static void remove_profile(GtkButton *button, gpointer data) {
    Editor *e = data;
    if (e->count == 1) {
        adw_preferences_window_add_toast(ADW_PREFERENCES_WINDOW(e->window), adw_toast_new("Keep at least one profile"));
        return;
    }
    /* Buttons carry their group instead of an index that could become stale. */
    int index;
    for (index = 0; index < e->count; index++)
        if (e->groups[index] == g_object_get_data(G_OBJECT(button), "group")) break;
    guint selected = adw_combo_row_get_selected(e->default_profile);
    e->updating = TRUE;
    adw_preferences_page_remove(e->profiles_page, e->groups[index]);
    for (int i = index; i + 1 < e->count; i++) {
        e->groups[i] = e->groups[i + 1]; e->names[i] = e->names[i + 1];
        e->shells[i] = e->shells[i + 1]; e->commands[i] = e->commands[i + 1];
        e->directories[i] = e->directories[i + 1];
    }
    e->count--;
    refresh_names(e);
    adw_combo_row_set_selected(e->default_profile, selected > (guint)index ? selected - 1 : MIN(selected, (guint)e->count - 1));
    e->updating = FALSE;
    changed(NULL, e);
}

static void append_profile(Editor *e, const Profile *p) {
    int i = e->count++;
    AdwPreferencesGroup *group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    e->groups[i] = group;
    adw_preferences_group_set_title(group, "Profile");
    GtkWidget *remove = gtk_button_new_from_icon_name("user-trash-symbolic");
    gtk_widget_add_css_class(remove, "flat");
    gtk_widget_set_tooltip_text(remove, "Remove profile");
    gtk_accessible_update_property(GTK_ACCESSIBLE(remove), GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove profile", -1);
    g_object_set_data(G_OBJECT(remove), "group", group);
    g_signal_connect(remove, "clicked", G_CALLBACK(remove_profile), e);
    adw_preferences_group_set_header_suffix(group, remove);
    e->names[i] = entry(group, "Name", p->name);
    e->shells[i] = entry(group, "Shell executable (absolute path)", p->shell);
    e->commands[i] = entry(group, "Command (empty for an interactive shell)", p->command);
    e->directories[i] = entry(group, "Working directory (empty to inherit)", p->directory);
    adw_preferences_page_add(e->profiles_page, group);
    g_signal_connect(e->names[i], "changed", G_CALLBACK(name_changed), e);
    g_signal_connect(e->shells[i], "changed", G_CALLBACK(changed), e);
    g_signal_connect(e->commands[i], "changed", G_CALLBACK(changed), e);
    g_signal_connect(e->directories[i], "changed", G_CALLBACK(changed), e);
    refresh_names(e);
}

static void add_profile(GtkButton *button, gpointer data) {
    (void)button;
    Editor *e = data;
    if (e->count == ZGTK_MAX_PROFILES) return;
    Profile p = {0};
    for (int suffix = 1; ; suffix++) {
        g_snprintf(p.name, sizeof p.name, "New profile %d", suffix);
        gboolean unique = TRUE;
        for (int i = 0; i < e->count; i++)
            if (!g_ascii_strcasecmp(p.name, gtk_editable_get_text(GTK_EDITABLE(e->names[i])))) unique = FALSE;
        if (unique) break;
    }
    g_strlcpy(p.shell, e->settings->profiles[0].shell, sizeof p.shell);
    append_profile(e, &p);
    changed(NULL, e);
    gtk_widget_grab_focus(e->names[e->count - 1]);
}

static gboolean collect(GtkWidget *widget, char *buffer, size_t capacity, GError **error) {
    const char *text = gtk_editable_get_text(GTK_EDITABLE(widget));
    if (strlen(text) >= capacity) return invalid(error, "A text field is too long.");
    g_strlcpy(buffer, text, capacity);
    return TRUE;
}

static void changed(GtkWidget *widget, gpointer data) {
    (void)widget;
    Editor *e = data;
    if (e->updating) return;
    Settings *s = g_new0(Settings, 1);
    GError *error = NULL;
    collect(e->font, s->font, sizeof s->font, &error);
    for (guint i = 0; i < G_N_ELEMENTS(fields); i++) {
        GtkWidget *control = e->controls[i];
        *(int *)((char *)s + fields[i].offset) = fields[i].choices ? (int)adw_combo_row_get_selected(ADW_COMBO_ROW(control)) :
            GTK_IS_SWITCH(control) ? gtk_switch_get_active(GTK_SWITCH(control)) : gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(control));
    }
    s->profile_count = e->count;
    s->default_profile = (int)adw_combo_row_get_selected(e->default_profile);
    for (int i = 0; !error && i < e->count; i++) {
        Profile *p = &s->profiles[i];
        if (!collect(e->names[i], p->name, sizeof p->name, &error) ||
            !collect(e->shells[i], p->shell, sizeof p->shell, &error) ||
            !collect(e->commands[i], p->command, sizeof p->command, &error) ||
            !collect(e->directories[i], p->directory, sizeof p->directory, &error)) break;
        g_strstrip(p->name);
    }
    if (!error && settings_save(s, &error)) {
        *e->settings = *s;
        e->applied(e->data);
    }
    for (guint i = 0; i < G_N_ELEMENTS(e->errors); i++) {
        adw_preferences_group_set_description(e->errors[i], error ? error->message : NULL);
        gtk_widget_set_visible(GTK_WIDGET(e->errors[i]), error != NULL);
    }
    g_clear_error(&error); g_free(s);
}

static AdwPreferencesPage *page(AdwPreferencesWindow *window, const char *title, const char *icon) {
    AdwPreferencesPage *p = ADW_PREFERENCES_PAGE(adw_preferences_page_new());
    adw_preferences_page_set_title(p, title);
    adw_preferences_page_set_icon_name(p, icon);
    adw_preferences_window_add(window, p);
    return p;
}

void settings_present(GtkWindow *parent, Settings *settings, void (*applied)(gpointer), gpointer data) {
    Editor *e = g_new0(Editor, 1);
    e->updating = TRUE;
    e->settings = settings; e->applied = applied; e->data = data;
    e->window = GTK_WINDOW(adw_preferences_window_new());
    g_object_set_data_full(G_OBJECT(e->window), "editor", e, g_free);
    gtk_window_set_title(e->window, "Settings");
    gtk_window_set_transient_for(e->window, parent);
    gtk_window_set_modal(e->window, TRUE);
    gtk_window_set_destroy_with_parent(e->window, TRUE);
    gtk_window_set_default_size(e->window, 660, 720);
    adw_preferences_window_set_search_enabled(ADW_PREFERENCES_WINDOW(e->window), FALSE);
    AdwPreferencesPage *appearance = page(ADW_PREFERENCES_WINDOW(e->window), "Appearance", "preferences-desktop-theme-symbolic");
    AdwPreferencesPage *terminal = page(ADW_PREFERENCES_WINDOW(e->window), "Terminal", "utilities-terminal-symbolic");
    e->profiles_page = page(ADW_PREFERENCES_WINDOW(e->window), "Profiles", "system-users-symbolic");
    AdwPreferencesPage *pages[] = { appearance, terminal, e->profiles_page };
    for (guint i = 0; i < G_N_ELEMENTS(pages); i++) {
        e->errors[i] = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
        adw_preferences_group_set_title(e->errors[i], "Changes not saved; previous settings remain active");
        gtk_widget_set_visible(GTK_WIDGET(e->errors[i]), FALSE);
        adw_preferences_page_add(pages[i], e->errors[i]);
    }
    AdwPreferencesGroup *look = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(look, "Text and colours");
    adw_preferences_group_set_description(look, "Changes are saved automatically and update all open terminals. Invalid edits keep the previous settings until corrected.");
    adw_preferences_page_add(appearance, look);
    e->font = entry(look, "Font family", settings->font);
    g_signal_connect(e->font, "changed", G_CALLBACK(changed), e);
    AdwPreferencesGroup *behaviour = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(behaviour, "Terminal behaviour");
    adw_preferences_group_set_description(behaviour, "Clipboard writes let terminal programs replace your clipboard. Disabled by default.");
    adw_preferences_page_add(terminal, behaviour);
    for (guint i = 0; i < G_N_ELEMENTS(fields); i++) {
        const Field *f = &fields[i];
        int value = *(int *)((char *)settings + f->offset);
        GtkWidget *row;
        if (f->choices) {
            row = adw_combo_row_new();
            GtkStringList *list = gtk_string_list_new(f->choices);
            adw_combo_row_set_model(ADW_COMBO_ROW(row), G_LIST_MODEL(list));
            g_object_unref(list);
            adw_combo_row_set_selected(ADW_COMBO_ROW(row), value);
            e->controls[i] = row;
            g_signal_connect(row, "notify::selected", G_CALLBACK(property_changed), e);
        } else {
            row = adw_action_row_new();
            GtkWidget *control = f->maximum == 1 ? gtk_switch_new() : gtk_spin_button_new_with_range(f->minimum, f->maximum, 1);
            if (GTK_IS_SWITCH(control)) gtk_switch_set_active(GTK_SWITCH(control), value);
            else gtk_spin_button_set_value(GTK_SPIN_BUTTON(control), value);
            gtk_widget_set_valign(control, GTK_ALIGN_CENTER);
            adw_action_row_add_suffix(ADW_ACTION_ROW(row), control);
            adw_action_row_set_activatable_widget(ADW_ACTION_ROW(row), control);
            gtk_accessible_update_property(GTK_ACCESSIBLE(control), GTK_ACCESSIBLE_PROPERTY_LABEL, f->title, -1);
            e->controls[i] = control;
            if (GTK_IS_SWITCH(control)) g_signal_connect(control, "notify::active", G_CALLBACK(property_changed), e);
            else g_signal_connect(control, "value-changed", G_CALLBACK(changed), e);
        }
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), f->title);
        adw_preferences_group_add(i < 7 ? look : behaviour, row);
    }
    AdwPreferencesGroup *profiles = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(profiles, "New sessions");
    adw_preferences_group_set_description(profiles, "The default opens at startup and with Ctrl+Shift+T. Choose other profiles from New Tab with Profile in the main menu. Commands run through the selected shell with -c; an empty command starts it with -i. Existing sessions never restart.");
    e->add = gtk_button_new_with_label("Add Profile");
    g_signal_connect(e->add, "clicked", G_CALLBACK(add_profile), e);
    GtkWidget *profile_actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_valign(profile_actions, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(profile_actions), e->add);
    e->profile_names = gtk_string_list_new(NULL);
    e->default_profile = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(e->default_profile), "Default profile");
    adw_combo_row_set_model(e->default_profile, G_LIST_MODEL(e->profile_names));
    g_object_unref(e->profile_names);
    adw_preferences_group_add(profiles, GTK_WIDGET(e->default_profile));
    adw_preferences_group_add(profiles, profile_actions);
    adw_preferences_page_add(e->profiles_page, profiles);
    for (int i = 0; i < settings->profile_count; i++) append_profile(e, &settings->profiles[i]);
    adw_combo_row_set_selected(e->default_profile, settings->default_profile);
    g_signal_connect(e->default_profile, "notify::selected", G_CALLBACK(property_changed), e);
    e->updating = FALSE;
    gtk_window_present(e->window);
}
