#include "core.h"
#include "settings.h"
#include <adwaita.h>
#include <glib-unix.h>
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static Settings settings;
static char *settings_warning;

typedef struct {
    GtkWindow *window;
    AdwTabView *tabs;
    AdwToastOverlay *toasts;
    GMenu *profile_menu;
    gboolean closing;
    guint pane_keys[16];
} Window;

typedef struct {
    PaneLayout *tree;
    GtkWidget *content;
    GPtrArray *panes;
    Profile profile; /* Snapshot: splits retain this tab's launch choices. */
    gboolean rebuilding;
} Layout;

/* One terminal/PTY session. A tab's Layout owns one or more sessions. */
typedef struct {
    Layout *owner;
    uint64_t id;
    char *title;
    Window *window;
    GApplication *application;
    GtkWidget *area, *content;
    GtkSearchBar *search_bar;
    GtkWidget *search_entry, *search_count, *search_previous, *search_next;
    AdwTabPage *page;
    GtkIMContext *im;
    GdkEvent *key_event;
    PangoLayout *layout;
    PangoFontDescription *font;
    TerminalCore *core;
    cairo_t *cr; /* Borrowed only inside the drawing callback. */
    GByteArray *pending;
    GCancellable *clipboard_read;
    int master, columns, rows, cell_width, cell_height, font_size;
    pid_t child;
    guint read_source, write_source, child_source, search_source;
    guint prompt_keys[2];
    double drag_x, drag_y;
    gboolean rectangle;
} Tab;

static void new_tab(Window *window);
static void new_profile_tab(Window *window, const Profile *profile);
static Window *new_window(GtkApplication *app);
static void schedule_search(Tab *tab);
static void rebuild_layout(Layout *layout);
static void focus_layout(Layout *layout);

static Tab *pane_by_id(Layout *layout, uint64_t id) {
    for (guint i = 0; i < layout->panes->len; i++) {
        Tab *pane = g_ptr_array_index(layout->panes, i);
        if (pane->id == id) return pane;
    }
    return NULL;
}

static Layout *page_layout(AdwTabPage *page) {
    return g_object_get_data(G_OBJECT(adw_tab_page_get_child(page)), "layout");
}

static Tab *selected_pane(Window *window) {
    AdwTabPage *page = adw_tab_view_get_selected_page(window->tabs);
    if (!page) return NULL;
    Layout *layout = page_layout(page);
    return pane_by_id(layout, zgtk_layout_focused(layout->tree));
}

static void colour(cairo_t *cr, uint32_t rgb, double alpha) {
    cairo_set_source_rgba(cr, ((rgb >> 16) & 255) / 255.,
                          ((rgb >> 8) & 255) / 255., (rgb & 255) / 255., alpha);
}

void zgtk_begin_frame(void *host, uint32_t background) {
    Tab *tab = host;
    colour(tab->cr, background, 1);
    cairo_paint(tab->cr);
}

void zgtk_draw_cell(void *host, uint16_t x, uint16_t y, uint8_t columns,
                    const char *text, size_t length, uint32_t foreground,
                    uint32_t background, uint32_t underline, uint16_t flags) {
    Tab *tab = host;
    double left = settings.padding + x * tab->cell_width, top = settings.padding + y * tab->cell_height;
    double width = columns * tab->cell_width;
    cairo_t *cr = tab->cr;
    cairo_save(cr);
    cairo_rectangle(cr, left, top, width, tab->cell_height);
    cairo_clip(cr);
    colour(cr, flags & 32 ? 0x365880 : flags & 256 ? 0xc8a15a : flags & 128 ? 0x625022 : background, 1);
    cairo_paint(cr);
    if (length) {
        pango_font_description_set_weight(tab->font, flags & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
        pango_font_description_set_style(tab->font, flags & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
        pango_layout_set_font_description(tab->layout, tab->font);
        pango_layout_set_text(tab->layout, text, (int)length);
        colour(cr, (flags & 256) && !(flags & 32) ? 0x141414 : foreground, flags & 16 ? 0.5 : 1);
        cairo_move_to(cr, left, top);
        pango_cairo_show_layout(cr, tab->layout);
    }
    colour(cr, underline, 1);
    if (flags & 4) cairo_rectangle(cr, left, top + tab->cell_height - 2, width, 1);
    if (flags & 8) cairo_rectangle(cr, left, top + tab->cell_height / 2., width, 1);
    if (flags & 64) cairo_rectangle(cr, left, top, width, 1);
    cairo_fill(cr);
    cairo_restore(cr);
}

void zgtk_draw_cursor(void *host, uint16_t x, uint16_t y, uint8_t columns,
                      uint8_t style, uint32_t rgb) {
    Tab *tab = host;
    double left = settings.padding + x * tab->cell_width, top = settings.padding + y * tab->cell_height;
    double width = columns * tab->cell_width, height = tab->cell_height;
    GdkRectangle location = { (int)left, (int)top, (int)width, (int)height };
    gtk_im_context_set_cursor_location(tab->im, &location);
    if (!gtk_widget_has_focus(tab->area)) style = 3;
    colour(tab->cr, rgb, style == 1 ? 0.45 : 1);
    if (style == 0) width = 2;
    if (style == 2) { top += height - 2; height = 2; }
    cairo_rectangle(tab->cr, left + 0.5, top + 0.5, width - 1, height - 1);
    if (style == 3) cairo_stroke(tab->cr); else cairo_fill(tab->cr);
}

void zgtk_title(void *host, const char *bytes, size_t length) {
    Tab *tab = host;
    char *text = g_utf8_make_valid(bytes, (gssize)MIN(length, 1024));
    g_free(tab->title);
    tab->title = g_strdup(text);
    if (!tab->page || tab->id != zgtk_layout_focused(tab->owner->tree)) { g_free(text); return; }
    /* Tab titles are plain text; the tooltip property, unlike the title,
     * accepts markup and must be escaped. */
    adw_tab_page_set_title(tab->page, text);
    char *escaped = g_markup_escape_text(text, -1);
    adw_tab_page_set_tooltip(tab->page, escaped);
    g_free(escaped);
    if (adw_tab_page_get_selected(tab->page)) gtk_window_set_title(tab->window->window, text);
    g_free(text);
}

void zgtk_clipboard(void *host, const char *bytes, size_t length) {
    Tab *tab = host;
    char *text = g_strndup(bytes, length);
    gdk_clipboard_set_text(gtk_widget_get_clipboard(tab->area), text);
    g_free(text);
}

static gboolean flush_output(gint fd, GIOCondition condition, gpointer data) {
    Tab *tab = data;
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        g_byte_array_set_size(tab->pending, 0);
        tab->write_source = 0;
        return G_SOURCE_REMOVE;
    }
    while (tab->pending->len) {
        ssize_t count = write(fd, tab->pending->data, tab->pending->len);
        if (count > 0) g_byte_array_remove_range(tab->pending, 0, (guint)count);
        else if (count < 0 && errno == EINTR) continue;
        else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return G_SOURCE_CONTINUE;
        else { g_byte_array_set_size(tab->pending, 0); break; }
    }
    tab->write_source = 0;
    return G_SOURCE_REMOVE;
}

void zgtk_write(void *host, const char *bytes, size_t length) {
    Tab *tab = host;
    if (tab->master < 0 || !length) return;
    /* Bound queued paste while a foreground program is not reading. */
    if (length > 16 * 1024 * 1024 - tab->pending->len) {
        adw_toast_overlay_add_toast(tab->window->toasts, adw_toast_new("Paste exceeds the 16 MiB input queue limit"));
        return;
    }
    g_byte_array_append(tab->pending, (const guint8 *)bytes, (guint)length);
    if (!tab->write_source && flush_output(tab->master, G_IO_OUT, tab))
        tab->write_source = g_unix_fd_add(tab->master, G_IO_OUT | G_IO_HUP | G_IO_ERR, flush_output, tab);
}

static gboolean read_output(gint fd, GIOCondition condition, gpointer data) {
    Tab *tab = data;
    char buffer[16384];
    gboolean ended = FALSE;
    /* Yield to GTK even when a process continuously floods the PTY. */
    for (int iteration = 0; iteration < 16; iteration++) {
        ssize_t count = read(fd, buffer, sizeof buffer);
        if (count > 0) {
            zgtk_feed(tab->core, buffer, (size_t)count);
        } else if (count < 0 && errno == EINTR) continue;
        else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            ended = (condition & (G_IO_HUP | G_IO_ERR)) != 0;
            break;
        } else { ended = TRUE; break; } /* Linux PTYs return EIO at EOF. */
    }
    gtk_widget_queue_draw(tab->area);
    schedule_search(tab);
    if (!ended) return G_SOURCE_CONTINUE;
    tab->read_source = 0;
    if (tab->write_source) { g_source_remove(tab->write_source); tab->write_source = 0; }
    close(tab->master);
    tab->master = -1;
    zgtk_title(tab, "Shell exited", strlen("Shell exited"));
    return G_SOURCE_REMOVE;
}

static void child_exited(GPid pid, gint status, gpointer data) {
    (void)status;
    Tab *tab = data;
    tab->child = 0;
    tab->child_source = 0;
    g_spawn_close_pid(pid);
}

/* Once its tab is gone, a child still needs reaping. A bounded grace period
 * prevents a shell ignoring SIGHUP from leaking after its window closes. */
typedef struct { pid_t pid; guint timer; GApplication *application; } Reaper;
static gboolean kill_child(gpointer data) {
    Reaper *reaper = data;
    kill(reaper->pid, SIGKILL);
    reaper->timer = 0;
    return G_SOURCE_REMOVE;
}
static void reap_child(GPid pid, gint status, gpointer data) {
    (void)status;
    Reaper *reaper = data;
    if (reaper->timer) g_source_remove(reaper->timer);
    g_spawn_close_pid(pid);
    g_application_release(reaper->application);
    g_free(reaper);
}

static void stop_session(Tab *tab) {
    g_cancellable_cancel(tab->clipboard_read);
    if (tab->read_source) g_source_remove(tab->read_source);
    if (tab->write_source) g_source_remove(tab->write_source);
    if (tab->search_source) g_source_remove(tab->search_source);
    if (tab->master >= 0) close(tab->master);
    tab->read_source = tab->write_source = tab->search_source = 0;
    tab->master = -1;
    if (tab->child) {
        g_source_remove(tab->child_source);
        kill(-tab->child, SIGHUP);
        kill(tab->child, SIGHUP);
        Reaper *reaper = g_new0(Reaper, 1);
        reaper->pid = tab->child;
        reaper->application = tab->application;
        g_application_hold(reaper->application);
        reaper->timer = g_timeout_add(1000, kill_child, reaper);
        g_child_watch_add(tab->child, reap_child, reaper);
        tab->child = 0;
        tab->child_source = 0;
    }
}

static void destroy_tab(gpointer data) {
    Tab *tab = data;
    stop_session(tab);
    g_object_unref(tab->clipboard_read);
    zgtk_destroy(tab->core);
    g_byte_array_unref(tab->pending);
    g_object_unref(tab->im);
    g_object_unref(tab->layout);
    pango_font_description_free(tab->font);
    g_free(tab->title);
    g_free(tab);
}

static void show_search_status(Tab *tab, SearchStatus status) {
    char text[64];
    const char *query = gtk_editable_get_text(GTK_EDITABLE(tab->search_entry));
    if (status.failed) g_strlcpy(text, strlen(query) > 256 ? "Query too long" : "Search failed", sizeof text);
    else if (!*query) text[0] = 0;
    else if (!status.matches && !status.scanning) g_strlcpy(text, "No matches", sizeof text);
    else g_snprintf(text, sizeof text, "%d / %u%s", status.active + 1, status.matches, status.scanning ? "+" : "");
    gtk_label_set_text(GTK_LABEL(tab->search_count), text);
    gtk_widget_set_sensitive(tab->search_previous, status.matches > 0 && !status.failed);
    gtk_widget_set_sensitive(tab->search_next, status.matches > 0 && !status.failed);
    if (status.failed) gtk_widget_add_css_class(tab->search_entry, "error");
    else gtk_widget_remove_css_class(tab->search_entry, "error");
    gtk_widget_queue_draw(tab->area);
}

static gboolean search_tick(gpointer data) {
    Tab *tab = data;
    SearchStatus status = zgtk_search_tick(tab->core);
    show_search_status(tab, status);
    if (status.scanning) return G_SOURCE_CONTINUE;
    tab->search_source = 0;
    return G_SOURCE_REMOVE;
}

static void schedule_search(Tab *tab) {
    if (gtk_search_bar_get_search_mode(tab->search_bar) && !tab->search_source)
        tab->search_source = g_idle_add(search_tick, tab);
}

static void search_changed(GtkSearchEntry *entry, gpointer data) {
    Tab *tab = data;
    if (!gtk_search_bar_get_search_mode(tab->search_bar)) return;
    const char *query = gtk_editable_get_text(GTK_EDITABLE(entry));
    zgtk_search_set(tab->core, query, strlen(query));
    schedule_search(tab);
}

static void search_mode_changed(GtkSearchBar *bar, GParamSpec *property, gpointer data) {
    (void)property;
    Tab *tab = data;
    if (gtk_search_bar_get_search_mode(bar)) search_changed(GTK_SEARCH_ENTRY(tab->search_entry), tab);
    else {
        if (tab->search_source) { g_source_remove(tab->search_source); tab->search_source = 0; }
        zgtk_search_clear(tab->core);
        gtk_widget_queue_draw(tab->area);
        gtk_widget_grab_focus(tab->area);
    }
}

static void search_stop(GtkSearchEntry *entry, gpointer data) {
    (void)entry;
    gtk_search_bar_set_search_mode(((Tab *)data)->search_bar, FALSE);
}
static void search_next(GtkWidget *widget, gpointer data) {
    (void)widget;
    Tab *tab = data;
    show_search_status(tab, zgtk_search_navigate(tab->core, TRUE));
}
static void search_previous(GtkWidget *widget, gpointer data) {
    (void)widget;
    Tab *tab = data;
    show_search_status(tab, zgtk_search_navigate(tab->core, FALSE));
}
static gboolean search_key(GtkEventControllerKey *controller, guint keyval,
                           guint keycode, GdkModifierType state, gpointer data) {
    (void)controller; (void)keycode;
    if ((state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter)) {
        search_previous(NULL, data);
        return TRUE;
    }
    return FALSE;
}

static void resize(GtkDrawingArea *area, int width, int height, gpointer data) {
    (void)area;
    Tab *tab = data;
    int columns = CLAMP((width - 2 * settings.padding) / tab->cell_width, 1, 65535);
    int rows = CLAMP((height - 2 * settings.padding) / tab->cell_height, 1, 65535);
    if (columns == tab->columns && rows == tab->rows) return;
    if (!zgtk_resize(tab->core, (uint16_t)columns, (uint16_t)rows,
                       (uint32_t)tab->cell_width, (uint32_t)tab->cell_height)) return;
    tab->columns = columns;
    tab->rows = rows;
    schedule_search(tab);
    struct winsize size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns };
    if (tab->master >= 0) ioctl(tab->master, TIOCSWINSZ, &size);
}

static void draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    Tab *tab = data;
    tab->cr = cr;
    if (!zgtk_render(tab->core)) g_warning("Unable to render terminal");
    if (tab->owner->panes->len > 1 && tab->id == zgtk_layout_focused(tab->owner->tree)) {
        GdkRGBA accent;
        if (!gtk_style_context_lookup_color(gtk_widget_get_style_context(tab->area), "accent_color", &accent))
            gdk_rgba_parse(&accent, "#3584e4");
        gdk_cairo_set_source_rgba(cr, &accent);
        cairo_set_line_width(cr, 2);
        cairo_rectangle(cr, 1, 1, width - 2, height - 2);
        cairo_stroke(cr);
    }
    tab->cr = NULL;
}

static uint16_t modifiers(GdkModifierType state) {
    return (state & GDK_SHIFT_MASK ? 1 : 0) | (state & GDK_CONTROL_MASK ? 2 : 0) |
           (state & GDK_ALT_MASK ? 4 : 0) | (state & GDK_SUPER_MASK ? 8 : 0);
}

static void paste_ready(GObject *object, GAsyncResult *result, gpointer data) {
    /* The weak reference avoids keeping a closed tab alive during a slow
     * clipboard transfer. Cancellation alone does not prevent its callback. */
    GWeakRef *weak = data;
    GtkWidget *area = g_weak_ref_get(weak);
    GError *error = NULL;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(object), result, &error);
    if (area) {
        Tab *tab = g_object_get_data(G_OBJECT(area), "terminal");
        if (tab && !g_cancellable_is_cancelled(tab->clipboard_read)) {
            if (text) zgtk_paste(tab->core, text, strlen(text));
            if (error && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
                adw_toast_overlay_add_toast(tab->window->toasts, adw_toast_new("Clipboard does not contain readable text"));
        }
        g_object_unref(area);
    }
    g_clear_error(&error);
    g_free(text);
    g_weak_ref_clear(weak);
    g_free(weak);
}

static void paste(Tab *tab) {
    GWeakRef *weak = g_new0(GWeakRef, 1);
    g_weak_ref_init(weak, tab->area);
    gdk_clipboard_read_text_async(gtk_widget_get_clipboard(tab->area), tab->clipboard_read, paste_ready, weak);
}

static void set_font(Tab *tab, int size) {
    tab->font_size = CLAMP(size, 6, 40);
    pango_font_description_set_size(tab->font, tab->font_size * PANGO_SCALE);
    pango_font_description_set_weight(tab->font, PANGO_WEIGHT_NORMAL);
    pango_font_description_set_style(tab->font, PANGO_STYLE_NORMAL);
    pango_layout_set_font_description(tab->layout, tab->font);
    pango_layout_set_text(tab->layout, "M", 1);
    pango_layout_get_pixel_size(tab->layout, &tab->cell_width, &tab->cell_height);
    tab->cell_height = (tab->cell_height * settings.line_height + 99) / 100;
    if (gtk_widget_get_width(tab->area) > 0) {
        tab->columns = 0; /* Refresh pixel metrics even if the grid size is unchanged. */
        resize(GTK_DRAWING_AREA(tab->area), gtk_widget_get_width(tab->area), gtk_widget_get_height(tab->area), tab);
    }
    gtk_widget_queue_draw(tab->area);
}

static gboolean key_pressed(GtkEventControllerKey *controller, guint keyval,
                            guint keycode, GdkModifierType state, gpointer data) {
    (void)keycode;
    Tab *tab = data;
    guint lower = gdk_keyval_to_lower(keyval);
    if ((state & (GDK_CONTROL_MASK | GDK_SHIFT_MASK)) == (GDK_CONTROL_MASK | GDK_SHIFT_MASK)) {
        if (lower == GDK_KEY_c) { zgtk_copy(tab->core); return TRUE; }
        if (lower == GDK_KEY_v) { paste(tab); return TRUE; }
        if (keyval == GDK_KEY_Up || keyval == GDK_KEY_Down) {
            tab->prompt_keys[keyval == GDK_KEY_Down] = keycode;
            zgtk_navigate_prompt(tab->core, keyval == GDK_KEY_Down);
            gtk_widget_queue_draw(tab->area);
            return TRUE;
        }
    }
    if ((state & GDK_SHIFT_MASK) && keyval == GDK_KEY_Insert) { paste(tab); return TRUE; }
    if (state & GDK_CONTROL_MASK) {
        if (keyval == GDK_KEY_plus || keyval == GDK_KEY_equal) { set_font(tab, tab->font_size + 1); return TRUE; }
        if (keyval == GDK_KEY_minus) { set_font(tab, tab->font_size - 1); return TRUE; }
        if (keyval == GDK_KEY_0) { set_font(tab, settings.font_size); return TRUE; }
    }
    GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
    GdkModifierType consumed = gdk_key_event_get_consumed_modifiers(event);
    if (!((state & ~consumed) & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK))) {
        tab->key_event = event;
        gboolean handled = gtk_im_context_filter_keypress(tab->im, event);
        tab->key_event = NULL;
        if (handled) return TRUE;
    }
    char text[8] = {0};
    gunichar unicode = gdk_keyval_to_unicode(keyval);
    int length = unicode >= 32 && unicode != 127 ? g_unichar_to_utf8(unicode, text) : 0;
    const char *name = gdk_keyval_name(keyval);
    zgtk_key(tab->core, name ? name : "", modifiers(state),
             modifiers(gdk_key_event_get_consumed_modifiers(event)), text, (size_t)length, false);
    gtk_widget_queue_draw(tab->area);
    return TRUE;
}

static void key_released(GtkEventControllerKey *controller, guint keyval,
                         guint keycode, GdkModifierType state, gpointer data) {
    (void)controller; (void)keycode;
    Tab *tab = data;
    for (int i = 0; i < 2; i++) if (tab->prompt_keys[i] == keycode && keycode) {
        tab->prompt_keys[i] = 0;
        return;
    }
    const char *name = gdk_keyval_name(keyval);
    zgtk_key(tab->core, name ? name : "", modifiers(state), 0, "", 0, true);
}

static void commit(GtkIMContext *im, const char *text, gpointer data) {
    (void)im;
    Tab *tab = data;
    /* IME commits are typed text, not bracketed paste. */
    GdkEvent *event = tab->key_event;
    const char *name = event ? gdk_keyval_name(gdk_key_event_get_keyval(event)) : "";
    zgtk_key(tab->core, name ? name : "", event ? modifiers(gdk_event_get_modifier_state(event)) : 0,
             event ? modifiers(gdk_key_event_get_consumed_modifiers(event)) : 0, text, strlen(text), false);
    gtk_widget_queue_draw(tab->area);
}

static void pane_enter(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    Tab *tab = data;
    if (!tab->owner->rebuilding) {
        zgtk_layout_focus(tab->owner->tree, tab->id);
        zgtk_title(tab, tab->title ? tab->title : "Terminal", strlen(tab->title ? tab->title : "Terminal"));
        for (guint i = 0; i < tab->owner->panes->len; i++)
            gtk_widget_queue_draw(((Tab *)g_ptr_array_index(tab->owner->panes, i))->area);
    }
}
static void focus_enter(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    Tab *tab = data;
    gtk_im_context_focus_in(tab->im);
    zgtk_focus(tab->core, true);
    gtk_widget_queue_draw(tab->area);
}
static void focus_leave(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    Tab *tab = data;
    gtk_im_context_focus_out(tab->im);
    zgtk_focus(tab->core, false);
    gtk_widget_queue_draw(tab->area);
}

static void select_at(Tab *tab, double x, double y, bool begin) {
    zgtk_select(tab->core, (uint16_t)CLAMP((x - settings.padding) / tab->cell_width, 0, tab->columns - 1),
                (uint16_t)CLAMP((y - settings.padding) / tab->cell_height, 0, tab->rows - 1), begin, tab->rectangle);
    gtk_widget_queue_draw(tab->area);
}
static void drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer data) {
    Tab *tab = data;
    gtk_widget_grab_focus(tab->area);
    tab->drag_x = x; tab->drag_y = y;
    tab->rectangle = (gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture)) & GDK_ALT_MASK) != 0;
    select_at(tab, x, y, true);
}
static void drag_update(GtkGestureDrag *gesture, double x, double y, gpointer data) {
    (void)gesture;
    Tab *tab = data;
    select_at(tab, tab->drag_x + x, tab->drag_y + y, false);
}
static gboolean scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer data) {
    (void)controller; (void)dx;
    Tab *tab = data;
    zgtk_scroll(tab->core, dy > 0 ? 3 : -3);
    gtk_widget_queue_draw(tab->area);
    return TRUE;
}

static void new_tab_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    new_tab(data);
}
static void new_window_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    Window *window = data;
    g_application_activate(G_APPLICATION(gtk_window_get_application(window->window)));
}
static void copy_command_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    Window *window = data;
    Tab *tab = selected_pane(window);
    if (tab && !zgtk_copy_last_command(tab->core))
        adw_toast_overlay_add_toast(window->toasts, adw_toast_new("No command output available"));
}
static void profile_tab_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action;
    int index = g_variant_get_int32(parameter);
    if (index >= 0 && index < settings.profile_count) new_profile_tab(data, &settings.profiles[index]);
}

static void apply_tab_settings(Tab *tab) {
    pango_font_description_set_family(tab->font, settings.font);
    set_font(tab, settings.font_size);
    int theme = adw_style_manager_get_dark(adw_style_manager_get_default()) ? settings.dark_theme : settings.light_theme;
    if (!zgtk_configure(tab->core, theme, settings.scrollback, settings.intense,
                        settings.clipboard, settings.clipboard_limit))
        adw_toast_overlay_add_toast(tab->window->toasts, adw_toast_new("Unable to apply terminal settings"));
    schedule_search(tab);
    gtk_widget_queue_draw(tab->area);
}

static void update_profile_menu(Window *window) {
    g_menu_remove_all(window->profile_menu);
    for (int i = 0; i < settings.profile_count; i++) {
        GMenuItem *item = g_menu_item_new(settings.profiles[i].name, NULL);
        g_menu_item_set_action_and_target(item, "win.profile-tab", "i", i);
        g_menu_append_item(window->profile_menu, item);
        g_object_unref(item);
    }
}

static void apply_settings(gpointer data) {
    GtkApplication *app = data;
    adw_style_manager_set_color_scheme(adw_style_manager_get_default(), settings.scheme == 1 ?
        ADW_COLOR_SCHEME_FORCE_LIGHT : settings.scheme == 2 ? ADW_COLOR_SCHEME_FORCE_DARK : ADW_COLOR_SCHEME_DEFAULT);
    for (GList *it = gtk_application_get_windows(app); it; it = it->next) {
        Window *window = g_object_get_data(G_OBJECT(it->data), "window");
        if (!window) continue;
        update_profile_menu(window);
        for (int i = 0; i < adw_tab_view_get_n_pages(window->tabs); i++) {
            Layout *layout = page_layout(adw_tab_view_get_nth_page(window->tabs, i));
            for (guint j = 0; j < layout->panes->len; j++)
                apply_tab_settings(g_ptr_array_index(layout->panes, j));
        }
    }
}

static void appearance_changed(AdwStyleManager *manager, GParamSpec *property, gpointer data) {
    (void)manager; (void)property;
    apply_settings(data);
}

static void settings_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    Window *window = data;
    settings_present(window->window, &settings, apply_settings, gtk_window_get_application(window->window));
}

static void close_tab_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    Window *window = data;
    AdwTabPage *page = adw_tab_view_get_selected_page(window->tabs);
    if (page) adw_tab_view_close_page(window->tabs, page);
}
static void close_pane_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    Tab *pane = selected_pane(data);
    if (!pane) return;
    Layout *layout = pane->owner;
    if (layout->panes->len == 1) { close_tab_action(action, parameter, data); return; }
    zgtk_layout_close(layout->tree, pane->id);
    stop_session(pane);
    /* Remove from the tree before releasing the widget-owned session. */
    g_ptr_array_remove(layout->panes, pane);
    rebuild_layout(layout);
    g_object_unref(pane->content);
}
static void find_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    Window *window = data;
    Tab *tab = selected_pane(window);
    if (!tab) return;
    gtk_search_bar_set_search_mode(tab->search_bar, TRUE);
    gtk_widget_grab_focus(tab->search_entry);
    gtk_editable_select_region(GTK_EDITABLE(tab->search_entry), 0, -1);
}
static void switched(AdwTabView *view, GParamSpec *property, gpointer data) {
    (void)property;
    Window *window = data;
    AdwTabPage *page = adw_tab_view_get_selected_page(view);
    if (page) {
        focus_layout(page_layout(page));
        gtk_window_set_title(window->window, adw_tab_page_get_title(page));
    }
}

static void page_attached(AdwTabView *view, AdwTabPage *page, int position, gpointer data) {
    (void)view; (void)position;
    Layout *layout = page_layout(page);
    for (guint i = 0; i < layout->panes->len; i++) {
        Tab *tab = g_ptr_array_index(layout->panes, i);
        tab->window = data;
        tab->page = page;
    }
}

static void page_detached(AdwTabView *view, AdwTabPage *page, int position, gpointer data) {
    (void)page; (void)position;
    Window *window = data;
    /* Transfers retain the child and its live PTY. */
    if (window->closing) return;
    if (!adw_tab_view_get_n_pages(view)) gtk_window_close(window->window);
    else switched(view, NULL, window);
}

static gboolean close_page(AdwTabView *view, AdwTabPage *page, gpointer data) {
    (void)view; (void)data;
    /* Stop callbacks now: Adwaita can retain a closing page for animation. */
    Layout *layout = page_layout(page);
    for (guint i = 0; i < layout->panes->len; i++) stop_session(g_ptr_array_index(layout->panes, i));
    return FALSE;
}

static gboolean close_window(GtkWindow *widget, gpointer data) {
    (void)widget;
    Window *window = data;
    window->closing = TRUE;
    for (int i = 0; i < adw_tab_view_get_n_pages(window->tabs); i++) {
        AdwTabPage *page = adw_tab_view_get_nth_page(window->tabs, i);
        Layout *layout = page_layout(page);
        for (guint j = 0; j < layout->panes->len; j++) stop_session(g_ptr_array_index(layout->panes, j));
    }
    return FALSE;
}

static AdwTabView *create_window(AdwTabView *view, gpointer data) {
    (void)view;
    Window *source = data;
    Window *destination = new_window(gtk_window_get_application(source->window));
    gtk_window_present(destination->window);
    return destination->tabs;
}

static void move_tab_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    Window *source = data;
    AdwTabPage *page = adw_tab_view_get_selected_page(source->tabs);
    if (!page) return;
    Window *destination = new_window(gtk_window_get_application(source->window));
    adw_tab_view_transfer_page(source->tabs, page, destination->tabs, 0);
    gtk_window_present(destination->window);
}

static gboolean spawn_shell(Tab *tab, const Profile *profile, GError **error) {
    int slave;
    struct winsize size = { .ws_row = (unsigned short)tab->rows, .ws_col = (unsigned short)tab->columns };
    if (openpty(&tab->master, &slave, NULL, NULL, &size) < 0) goto fail;
    fcntl(tab->master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    for (int fd = 0; fd < 3; fd++) posix_spawn_file_actions_adddup2(&actions, slave, fd);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t signals;
    sigfillset(&signals);
    posix_spawnattr_setsigdefault(&attributes, &signals);
    sigemptyset(&signals);
    posix_spawnattr_setsigmask(&attributes, &signals);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    /* Re-exec before setting up the child: no GTK or GLib code after fork. */
    char *argv[] = { (char *)"zigonaut", (char *)"--pty-child", (char *)profile->shell,
                     (char *)profile->directory, (char *)profile->command, NULL };
    char **env = g_get_environ();
    env = g_environ_setenv(env, "TERM", "xterm-256color", TRUE);
    env = g_environ_setenv(env, "COLORTERM", "truecolor", TRUE);
    int result = posix_spawn(&tab->child, "/proc/self/exe", &actions, &attributes, argv, env);
    g_strfreev(env);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(slave);
    if (result) { close(tab->master); tab->master = -1; errno = result; goto fail; }
    fcntl(tab->master, F_SETFL, O_NONBLOCK);
    tab->read_source = g_unix_fd_add(tab->master, G_IO_IN | G_IO_HUP | G_IO_ERR, read_output, tab);
    tab->child_source = g_child_watch_add(tab->child, child_exited, tab);
    return TRUE;
fail:
    g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno), "Unable to start shell: %s", g_strerror(errno));
    return FALSE;
}

static Tab *new_pane(Window *window, Layout *owner, uint64_t id, AdwTabPage *page) {
    Tab *tab = g_new0(Tab, 1);
    tab->owner = owner;
    tab->id = id;
    tab->page = page;
    tab->window = window;
    tab->application = G_APPLICATION(gtk_window_get_application(window->window));
    tab->master = -1;
    tab->columns = settings.columns; tab->rows = settings.rows;
    tab->area = gtk_drawing_area_new();
    tab->content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    g_object_ref_sink(tab->content); /* Retained even when hidden by pane zoom. */
    g_ptr_array_add(owner->panes, tab);
    g_object_set_data(G_OBJECT(tab->content), "terminal", tab);
    tab->search_bar = GTK_SEARCH_BAR(gtk_search_bar_new());
    gtk_search_bar_set_show_close_button(tab->search_bar, TRUE);
    GtkWidget *search_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    tab->search_entry = gtk_search_entry_new();
    gtk_editable_set_width_chars(GTK_EDITABLE(tab->search_entry), 8);
    gtk_widget_set_hexpand(tab->search_entry, TRUE);
    gtk_widget_set_tooltip_text(tab->search_entry, "Search scrollback (smart case; maximum 256 UTF-8 bytes)");
    gtk_accessible_update_property(GTK_ACCESSIBLE(tab->search_entry), GTK_ACCESSIBLE_PROPERTY_LABEL, "Search scrollback", -1);
    tab->search_count = gtk_label_new("");
    gtk_widget_add_css_class(tab->search_count, "dim-label");
    gtk_accessible_update_property(GTK_ACCESSIBLE(tab->search_count), GTK_ACCESSIBLE_PROPERTY_LABEL, "Search results", -1);
    tab->search_previous = gtk_button_new_from_icon_name("go-up-symbolic");
    tab->search_next = gtk_button_new_from_icon_name("go-down-symbolic");
    gtk_widget_set_tooltip_text(tab->search_previous, "Previous match (Shift+Enter)");
    gtk_widget_set_tooltip_text(tab->search_next, "Next match (Enter)");
    gtk_widget_set_sensitive(tab->search_previous, FALSE);
    gtk_widget_set_sensitive(tab->search_next, FALSE);
    gtk_box_append(GTK_BOX(search_box), tab->search_entry);
    gtk_box_append(GTK_BOX(search_box), tab->search_count);
    gtk_box_append(GTK_BOX(search_box), tab->search_previous);
    gtk_box_append(GTK_BOX(search_box), tab->search_next);
    gtk_search_bar_set_child(tab->search_bar, search_box);
    gtk_search_bar_connect_entry(tab->search_bar, GTK_EDITABLE(tab->search_entry));
    g_signal_connect(tab->search_bar, "notify::search-mode-enabled", G_CALLBACK(search_mode_changed), tab);
    g_signal_connect(tab->search_entry, "search-changed", G_CALLBACK(search_changed), tab);
    g_signal_connect(tab->search_entry, "activate", G_CALLBACK(search_next), tab);
    g_signal_connect(tab->search_entry, "next-match", G_CALLBACK(search_next), tab);
    g_signal_connect(tab->search_entry, "previous-match", G_CALLBACK(search_previous), tab);
    g_signal_connect(tab->search_entry, "stop-search", G_CALLBACK(search_stop), tab);
    g_signal_connect(tab->search_previous, "clicked", G_CALLBACK(search_previous), tab);
    g_signal_connect(tab->search_next, "clicked", G_CALLBACK(search_next), tab);
    GtkEventController *search_keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(search_keys, GTK_PHASE_CAPTURE);
    g_signal_connect(search_keys, "key-pressed", G_CALLBACK(search_key), tab);
    gtk_widget_add_controller(tab->search_entry, search_keys);
    gtk_box_append(GTK_BOX(tab->content), GTK_WIDGET(tab->search_bar));
    gtk_box_append(GTK_BOX(tab->content), tab->area);
    tab->pending = g_byte_array_new();
    tab->clipboard_read = g_cancellable_new();
    tab->im = gtk_im_multicontext_new();
    gtk_im_context_set_client_widget(tab->im, tab->area);
    g_signal_connect(tab->im, "commit", G_CALLBACK(commit), tab);
    tab->layout = gtk_widget_create_pango_layout(tab->area, NULL);
    pango_layout_set_single_paragraph_mode(tab->layout, TRUE);
    tab->font = pango_font_description_new();
    tab->core = zgtk_create(tab);
    if (!tab->core) g_error("Unable to initialize terminal engine");
    apply_tab_settings(tab);
    g_object_set_data_full(G_OBJECT(tab->area), "terminal", tab, destroy_tab);
    gtk_widget_set_focusable(tab->area, TRUE);
    gtk_widget_set_size_request(tab->area, 80, 48);
    gtk_widget_set_hexpand(tab->area, TRUE);
    gtk_widget_set_vexpand(tab->area, TRUE);
    gtk_widget_set_cursor_from_name(tab->area, "text");
    gtk_widget_set_tooltip_text(tab->area, NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(tab->area), GTK_ACCESSIBLE_PROPERTY_LABEL, "Terminal", -1);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(tab->area), draw, tab, NULL);
    g_signal_connect(tab->area, "resize", G_CALLBACK(resize), tab);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), tab);
    g_signal_connect(keys, "key-released", G_CALLBACK(key_released), tab);
    gtk_widget_add_controller(tab->area, keys);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(focus_enter), tab);
    g_signal_connect(focus, "leave", G_CALLBACK(focus_leave), tab);
    gtk_widget_add_controller(tab->area, focus);
    GtkEventController *pane_focus = gtk_event_controller_focus_new();
    g_signal_connect(pane_focus, "enter", G_CALLBACK(pane_enter), tab);
    gtk_widget_add_controller(tab->content, pane_focus);
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(drag_begin), tab);
    g_signal_connect(drag, "drag-update", G_CALLBACK(drag_update), tab);
    gtk_widget_add_controller(tab->area, GTK_EVENT_CONTROLLER(drag));
    GtkEventController *wheel = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(wheel, "scroll", G_CALLBACK(scroll), tab);
    gtk_widget_add_controller(tab->area, wheel);
    zgtk_title(tab, "Terminal", strlen("Terminal"));
    GError *error = NULL;
    if (!spawn_shell(tab, &owner->profile, &error)) {
        zgtk_title(tab, "Shell failed", strlen("Shell failed"));
        zgtk_feed(tab->core, error->message, strlen(error->message));
        adw_toast_overlay_add_toast(window->toasts, adw_toast_new(error->message));
        g_error_free(error);
    }
    return tab;
}

static void focus_layout(Layout *layout) {
    Tab *pane = pane_by_id(layout, zgtk_layout_focused(layout->tree));
    if (!pane) return;
    gtk_widget_grab_focus(gtk_search_bar_get_search_mode(pane->search_bar) ? pane->search_entry : pane->area);
    zgtk_title(pane, pane->title, strlen(pane->title));
    for (guint i = 0; i < layout->panes->len; i++)
        gtk_widget_queue_draw(((Tab *)g_ptr_array_index(layout->panes, i))->area);
}

typedef struct {
    Layout *layout;
    uint64_t id;
    uint16_t ratio;
    int extent;
    gboolean vertical, applying;
} Divider;

static int divider_extent(GtkPaned *paned, Divider *divider) {
    return divider->vertical ? gtk_widget_get_height(GTK_WIDGET(paned)) : gtk_widget_get_width(GTK_WIDGET(paned));
}

static void divider_size(GObject *object, GParamSpec *property, gpointer data) {
    (void)property;
    GtkPaned *paned = GTK_PANED(object);
    Divider *divider = data;
    int extent = divider_extent(paned, divider);
    if (extent <= 1 || extent == divider->extent) return;
    divider->extent = extent;
    divider->applying = TRUE;
    gtk_paned_set_position(paned, (int)((int64_t)extent * divider->ratio / 65535));
    divider->applying = FALSE;
}

static gboolean divider_initial(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    (void)clock;
    divider_size(G_OBJECT(widget), NULL, data);
    return ((Divider *)data)->extent > 1 ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}

static void divider_position(GObject *object, GParamSpec *property, gpointer data) {
    (void)property;
    GtkPaned *paned = GTK_PANED(object);
    Divider *divider = data;
    int extent = divider_extent(paned, divider);
    if (divider->applying || extent <= 1 || extent != divider->extent) return;
    int position = gtk_paned_get_position(paned);
    /* Snap the terminal interior to its cell grid; GtkPaned keeps native
     * pointer, keyboard and accessibility handling for the divider. */
    Tab *focused = pane_by_id(divider->layout, zgtk_layout_focused(divider->layout->tree));
    int cell = divider->vertical ? focused->cell_height : focused->cell_width;
    int padding = 2 * settings.padding;
    position = padding + ((MAX(0, position - padding) + cell / 2) / cell) * cell;
    position = CLAMP(position, MAX(1, extent / 10), MAX(1, extent * 9 / 10));
    divider->ratio = (uint16_t)CLAMP((int64_t)position * 65535 / extent, 1, 65534);
    zgtk_layout_ratio(divider->layout->tree, divider->id, divider->ratio);
    divider->applying = TRUE;
    gtk_paned_set_position(paned, position);
    divider->applying = FALSE;
}

static GtkWidget *layout_widget(Layout *layout, PaneNode *nodes, size_t *index) {
    PaneNode node = nodes[(*index)++];
    if (!node.split) return pane_by_id(layout, node.id)->content;
    GtkWidget *paned = gtk_paned_new(node.vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_wide_handle(GTK_PANED(paned), TRUE);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), TRUE);
    gtk_paned_set_resize_end_child(GTK_PANED(paned), TRUE);
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_end_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_start_child(GTK_PANED(paned), layout_widget(layout, nodes, index));
    gtk_paned_set_end_child(GTK_PANED(paned), layout_widget(layout, nodes, index));
    Divider *divider = g_new0(Divider, 1);
    *divider = (Divider){ .layout = layout, .id = node.id, .ratio = node.ratio,
        .vertical = node.vertical };
    g_object_set_data_full(G_OBJECT(paned), "divider", divider, g_free);
    g_signal_connect(paned, "notify::max-position", G_CALLBACK(divider_size), divider);
    g_signal_connect(paned, "notify::position", G_CALLBACK(divider_position), divider);
    gtk_widget_add_tick_callback(paned, divider_initial, divider, NULL);
    return paned;
}

static void detach_pane(GtkWidget *content) {
    GtkWidget *parent = gtk_widget_get_parent(content);
    if (GTK_IS_PANED(parent)) {
        if (gtk_paned_get_start_child(GTK_PANED(parent)) == content) gtk_paned_set_start_child(GTK_PANED(parent), NULL);
        else gtk_paned_set_end_child(GTK_PANED(parent), NULL);
    } else if (GTK_IS_BOX(parent)) gtk_box_remove(GTK_BOX(parent), content);
}

static void rebuild_layout(Layout *layout) {
    layout->rebuilding = TRUE;
    for (guint i = 0; i < layout->panes->len; i++)
        detach_pane(((Tab *)g_ptr_array_index(layout->panes, i))->content);
    GtkWidget *old = gtk_widget_get_first_child(layout->content);
    if (old) gtk_box_remove(GTK_BOX(layout->content), old);
    PaneNode nodes[127];
    size_t count = zgtk_layout_nodes(layout->tree, nodes, G_N_ELEMENTS(nodes)), index = 0;
    if (count) gtk_box_append(GTK_BOX(layout->content), layout_widget(layout, nodes, &index));
    layout->rebuilding = FALSE;
    focus_layout(layout);
}

static void destroy_layout(gpointer data) {
    Layout *layout = data;
    for (guint i = 0; i < layout->panes->len; i++)
        g_object_unref(((Tab *)g_ptr_array_index(layout->panes, i))->content);
    g_ptr_array_unref(layout->panes);
    zgtk_layout_destroy(layout->tree);
    g_free(layout);
}

static void new_tab(Window *window) {
    new_profile_tab(window, &settings.profiles[settings.default_profile]);
}

static void new_profile_tab(Window *window, const Profile *profile) {
    Layout *layout = g_new0(Layout, 1);
    layout->profile = *profile;
    layout->tree = zgtk_layout_create();
    if (!layout->tree) g_error("Unable to initialize pane layout");
    layout->panes = g_ptr_array_new();
    layout->content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    g_object_set_data_full(G_OBJECT(layout->content), "layout", layout, destroy_layout);
    new_pane(window, layout, 1, NULL);
    AdwTabPage *page = adw_tab_view_append(window->tabs, layout->content);
    rebuild_layout(layout);
    adw_tab_view_set_selected_page(window->tabs, page);
}

static void split_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)parameter;
    Tab *pane = selected_pane(data);
    if (!pane) return;
    Layout *layout = pane->owner;
    uint64_t id = zgtk_layout_split(layout->tree, strcmp(g_action_get_name(G_ACTION(action)), "split-down") == 0);
    if (!id) {
        adw_toast_overlay_add_toast(pane->window->toasts, adw_toast_new("Unable to split pane (maximum 64 panes per tab)"));
        return;
    }
    Tab *created = new_pane(data, layout, id, pane->page);
    set_font(created, pane->font_size);
    rebuild_layout(layout);
}

static void pane_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action;
    Tab *pane = selected_pane(data);
    if (!pane) return;
    Layout *layout = pane->owner;
    int operation = g_variant_get_int32(parameter);
    gboolean zoomed = zgtk_layout_zoomed(layout->tree);
    if (!zgtk_layout_action(layout->tree, operation)) return;
    if (operation >= PANE_RESIZE_LEFT || zoomed) rebuild_layout(layout);
    else focus_layout(layout);
}

/* Capture both halves of pane shortcuts at the window. Focus can change (or
 * a pane can disappear) between press and release, including in Kitty mode. */
static gboolean pane_shortcut(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data) {
    (void)controller;
    Window *window = data;
    GdkEventType type = gdk_event_get_event_type(event);
    if (type != GDK_KEY_PRESS && type != GDK_KEY_RELEASE) return FALSE;
    guint code = gdk_key_event_get_keycode(event);
    for (guint i = 0; i < G_N_ELEMENTS(window->pane_keys); i++) if (window->pane_keys[i] == code && code) {
        if (type == GDK_KEY_RELEASE) { window->pane_keys[i] = 0; return TRUE; }
        break;
    }
    if (type == GDK_KEY_RELEASE) return FALSE;
    guint key = gdk_keyval_to_lower(gdk_key_event_get_keyval(event));
    GdkModifierType state = gdk_event_get_modifier_state(event) & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK | GDK_SUPER_MASK);
    const char *action = NULL;
    int operation = -1;
    if (state == (GDK_CONTROL_MASK | GDK_SHIFT_MASK)) {
        if (key == GDK_KEY_o) action = "split-right";
        if (key == GDK_KEY_e) action = "split-down";
        if (key == GDK_KEY_w) action = "close-pane";
        if (key == GDK_KEY_n) action = "new-window";
        if (key == GDK_KEY_g) action = "copy-command";
        if (key == GDK_KEY_Return) operation = PANE_ZOOM;
    }
    if (state == (GDK_CONTROL_MASK | GDK_ALT_MASK) || state == (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SHIFT_MASK)) {
        if (key == GDK_KEY_Left) operation = PANE_LEFT;
        if (key == GDK_KEY_Right) operation = PANE_RIGHT;
        if (key == GDK_KEY_Up) operation = PANE_UP;
        if (key == GDK_KEY_Down) operation = PANE_DOWN;
        if (operation >= 0 && (state & GDK_SHIFT_MASK)) operation += PANE_RESIZE_LEFT;
        if (!(state & GDK_SHIFT_MASK)) {
            if (key == GDK_KEY_Page_Up) operation = PANE_PREVIOUS;
            if (key == GDK_KEY_Page_Down) operation = PANE_NEXT;
            if (key == GDK_KEY_equal) operation = PANE_EQUALIZE;
        }
    }
    if (!action && operation < 0) return FALSE;
    for (guint i = 0; i < G_N_ELEMENTS(window->pane_keys); i++) {
        if (window->pane_keys[i] == code) break;
        if (!window->pane_keys[i]) { window->pane_keys[i] = code; break; }
    }
    g_action_group_activate_action(G_ACTION_GROUP(window->window), action ? action : "pane", action ? NULL : g_variant_new_int32(operation));
    return TRUE;
}

static void about(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter;
    GtkWindow *parent = gtk_application_get_active_window(GTK_APPLICATION(data));
    const char *developers[] = { "Iain H", NULL };
    adw_show_about_window(parent,
        "application-name", "Zigonaut",
        "application-icon", "com.spiralpoint.zigonaut",
        "developer-name", "Iain H",
        "developers", developers,
        "version", ZIGONAUT_VERSION,
        "comments", "A native terminal built with Zig",
        "website", "https://github.com/iainh/zigonaut",
        "issue-url", "https://github.com/iainh/zigonaut/issues",
        "license-type", GTK_LICENSE_MIT_X11,
        NULL);
}

static Window *new_window(GtkApplication *app) {
    Window *window = g_new0(Window, 1);
    window->window = GTK_WINDOW(adw_application_window_new(app));
    g_object_set_data_full(G_OBJECT(window->window), "window", window, g_free);
    gtk_window_set_title(window->window, "Zigonaut");
    PangoLayout *measure = gtk_widget_create_pango_layout(GTK_WIDGET(window->window), "M");
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, settings.font);
    pango_font_description_set_size(font, settings.font_size * PANGO_SCALE);
    pango_layout_set_font_description(measure, font);
    int width, height;
    pango_layout_get_pixel_size(measure, &width, &height);
    pango_font_description_free(font);
    g_object_unref(measure);
    const GActionEntry actions[] = {
        { .name = "new-tab", .activate = new_tab_action },
        { .name = "new-window", .activate = new_window_action },
        { .name = "copy-command", .activate = copy_command_action },
        { .name = "profile-tab", .activate = profile_tab_action, .parameter_type = "i" },
        { .name = "settings", .activate = settings_action },
        { .name = "close-tab", .activate = close_tab_action },
        { .name = "close-pane", .activate = close_pane_action },
        { .name = "split-right", .activate = split_action },
        { .name = "split-down", .activate = split_action },
        { .name = "pane", .activate = pane_action, .parameter_type = "i" },
        { .name = "move-tab", .activate = move_tab_action },
        { .name = "find", .activate = find_action },
    };
    g_action_map_add_action_entries(G_ACTION_MAP(window->window), actions, G_N_ELEMENTS(actions), window);
    window->tabs = ADW_TAB_VIEW(adw_tab_view_new());
    adw_tab_view_set_shortcuts(window->tabs,
        ADW_TAB_VIEW_SHORTCUT_CONTROL_PAGE_UP | ADW_TAB_VIEW_SHORTCUT_CONTROL_PAGE_DOWN |
        ADW_TAB_VIEW_SHORTCUT_CONTROL_SHIFT_PAGE_UP | ADW_TAB_VIEW_SHORTCUT_CONTROL_SHIFT_PAGE_DOWN);
    g_signal_connect(window->tabs, "notify::selected-page", G_CALLBACK(switched), window);
    g_signal_connect(window->tabs, "page-attached", G_CALLBACK(page_attached), window);
    g_signal_connect(window->tabs, "page-detached", G_CALLBACK(page_detached), window);
    g_signal_connect(window->tabs, "close-page", G_CALLBACK(close_page), window);
    g_signal_connect(window->tabs, "create-window", G_CALLBACK(create_window), window);
    g_signal_connect(window->window, "close-request", G_CALLBACK(close_window), window);
    GtkEventController *pane_keys = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(pane_keys, GTK_PHASE_CAPTURE);
    g_signal_connect(pane_keys, "event", G_CALLBACK(pane_shortcut), window);
    gtk_widget_add_controller(GTK_WIDGET(window->window), pane_keys);
    /* Keep tab DND outside a GtkWindowHandle: on GTK 4.8, denying the tab
     * reorder gesture to begin DND otherwise also starts a window move. */
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(header, "titlebar");
    gtk_widget_add_css_class(header, "toolbar");
    gtk_box_append(GTK_BOX(header), gtk_window_controls_new(GTK_PACK_START));
    GtkWidget *bar = GTK_WIDGET(adw_tab_bar_new());
    adw_tab_bar_set_view(ADW_TAB_BAR(bar), window->tabs);
    adw_tab_bar_set_autohide(ADW_TAB_BAR(bar), FALSE);
    adw_tab_bar_set_expand_tabs(ADW_TAB_BAR(bar), FALSE);
    gtk_widget_add_css_class(bar, "inline");
    gtk_widget_set_hexpand(bar, TRUE);
    GtkWidget *add = gtk_button_new_from_icon_name("tab-new-symbolic");
    gtk_widget_set_tooltip_text(add, "New tab (Ctrl+Shift+T)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(add), "win.new-tab");
    gtk_box_append(GTK_BOX(header), add);
    gtk_box_append(GTK_BOX(header), bar);
    GtkWidget *split = gtk_button_new_from_icon_name("view-dual-symbolic");
    gtk_widget_set_tooltip_text(split, "Split right (Ctrl+Shift+O)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(split), "win.split-right");
    gtk_box_append(GTK_BOX(header), split);
    GtkWidget *handle = gtk_window_handle_new();
    gtk_widget_set_size_request(handle, 48, -1);
    gtk_box_append(GTK_BOX(header), handle);
    GMenu *menu = g_menu_new();
    g_menu_append(menu, "New Tab", "win.new-tab");
    g_menu_append(menu, "Move Tab to New Window", "win.move-tab");
    g_menu_append(menu, "Find", "win.find");
    window->profile_menu = g_menu_new();
    update_profile_menu(window);
    g_menu_append_submenu(menu, "New Tab with Profile", G_MENU_MODEL(window->profile_menu));
    g_object_unref(window->profile_menu); /* Retained by the parent menu. */
    g_menu_append(menu, "Settings", "win.settings");
    GMenu *panes = g_menu_new();
    g_menu_append(panes, "Split Right", "win.split-right");
    g_menu_append(panes, "Split Down", "win.split-down");
    g_menu_append(panes, "Focus Previous Pane", "win.pane(4)");
    g_menu_append(panes, "Focus Next Pane", "win.pane(5)");
    g_menu_append(panes, "Equalize Panes", "win.pane(10)");
    g_menu_append(panes, "Zoom / Restore Pane", "win.pane(11)");
    g_menu_append(panes, "Close Pane", "win.close-pane");
    g_menu_append(panes, "Close Tab", "win.close-tab");
    g_menu_append_submenu(menu, "Panes", G_MENU_MODEL(panes));
    g_object_unref(panes);
    g_menu_append(menu, "New Window", "win.new-window");
    g_menu_append(menu, "Copy Last Command Output", "win.copy-command");
    g_menu_append(menu, "About Zigonaut", "app.about");
    GtkWidget *menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button), "open-menu-symbolic");
    gtk_menu_button_set_primary(GTK_MENU_BUTTON(menu_button), TRUE);
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button), G_MENU_MODEL(menu));
    gtk_widget_set_tooltip_text(menu_button, "Main menu");
    g_object_unref(menu);
    gtk_box_append(GTK_BOX(header), menu_button);
    gtk_box_append(GTK_BOX(header), gtk_window_controls_new(GTK_PACK_END));
    window->toasts = ADW_TOAST_OVERLAY(adw_toast_overlay_new());
    adw_toast_overlay_set_child(window->toasts, GTK_WIDGET(window->tabs));
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(content), header);
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(window->toasts));
    gtk_widget_set_vexpand(GTK_WIDGET(window->toasts), TRUE);
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(window->window), content);
    /* Account for the actual header and client border rather than stealing a
     * row/column from the requested initial grid with guessed chrome metrics. */
    GtkBorder border, padding;
    GtkStyleContext *style = gtk_widget_get_style_context(GTK_WIDGET(window->window));
    gtk_style_context_get_border(style, &border);
    gtk_style_context_get_padding(style, &padding);
    int header_height;
    gtk_widget_measure(header, GTK_ORIENTATION_VERTICAL, -1, NULL, &header_height, NULL, NULL);
    gtk_window_set_default_size(window->window,
        settings.columns * width + 2 * settings.padding + border.left + border.right + padding.left + padding.right,
        settings.rows * ((height * settings.line_height + 99) / 100) + 2 * settings.padding +
            header_height + border.top + border.bottom + padding.top + padding.bottom);
    return window;
}

static void activate(GtkApplication *app, gpointer data) {
    (void)data;
    Window *window = new_window(app);
    new_tab(window);
    gtk_window_present(window->window);
    if (settings_warning) {
        adw_toast_overlay_add_toast(window->toasts, adw_toast_new(settings_warning));
        g_clear_pointer(&settings_warning, g_free);
    }
}

static gboolean integration_file(const char *path) {
    return g_file_test(path, G_FILE_TEST_IS_REGULAR) && access(path, R_OK) == 0;
}

/* Runs only in the fresh --pty-child process, never in a post-fork GTK child.
 * Resolve relative to the executable so installations remain relocatable. */
static void exec_shell(const char *shell) {
    char *executable = g_file_read_link("/proc/self/exe", NULL);
    char *bin = executable ? g_path_get_dirname(executable) : NULL;
    char *root = bin ? g_build_filename(bin, "..", "share", "zigonaut", "shell-integration", NULL) : NULL;
    const char *name = strrchr(shell, '/');
    name = name ? name + 1 : shell;
    if (root && !getenv("ZIGONAUT_SHELL_INTEGRATION")) {
        if (strcmp(name, "bash") == 0) {
            char *script = g_build_filename(root, "bash", "zigonaut.bash", NULL);
            char *startup = g_build_filename(root, "bash", "linux.bash", NULL);
            if (integration_file(script) && integration_file(startup)) {
                g_setenv("ZIGONAUT_BASH_INTEGRATION", script, TRUE);
                g_setenv("ZIGONAUT_SHELL_INTEGRATION", "1", TRUE);
                execl(shell, shell, "--rcfile", startup, "-i", (char *)NULL);
                goto failed;
            }
            g_free(script);
            g_free(startup);
        } else if (strcmp(name, "zsh") == 0) {
            char *directory = g_build_filename(root, "zsh", NULL);
            char *startup = g_build_filename(directory, ".zshenv", NULL);
            char *script = g_build_filename(directory, "zigonaut.zsh", NULL);
            if (integration_file(startup) && integration_file(script)) {
                const char *original = getenv("ZDOTDIR");
                if (original) g_setenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR", original, TRUE);
                else g_unsetenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR");
                g_setenv("ZDOTDIR", directory, TRUE);
                g_setenv("ZIGONAUT_SHELL_INTEGRATION", "1", TRUE);
            }
            g_free(directory);
            g_free(startup);
            g_free(script);
        } else if (strcmp(name, "fish") == 0) {
            char *script = g_build_filename(root, "fish", "zigonaut.fish", NULL);
            if (integration_file(script)) {
                g_setenv("ZIGONAUT_FISH_INTEGRATION", script, TRUE);
                g_setenv("ZIGONAUT_SHELL_INTEGRATION", "1", TRUE);
                execl(shell, shell, "-i", "--init-command=test -r \"$ZIGONAUT_FISH_INTEGRATION\"; and source \"$ZIGONAUT_FISH_INTEGRATION\" 2>/dev/null", (char *)NULL);
                goto failed;
            }
            g_free(script);
        }
    }
    g_free(root);
    g_free(bin);
    g_free(executable);
    execl(shell, shell, "-i", (char *)NULL);
failed:
    perror("Unable to execute shell");
}

int main(int argc, char **argv) {
    if ((argc == 2 || argc == 5) && strcmp(argv[1], "--pty-child") == 0) {
        if (setsid() < 0 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0) return 126;
        const char *shell = argc == 5 ? argv[2] : getenv("SHELL");
        if (!shell || shell[0] != '/') shell = "/bin/sh";
        if (argc == 5) {
            if (*argv[3] && chdir(argv[3]) < 0) { perror("Unable to change directory"); return 126; }
            if (*argv[4]) {
                execl(shell, shell, "-c", argv[4], (char *)NULL);
                perror("Unable to execute shell");
                return 127;
            }
        }
        exec_shell(shell);
        return 127;
    }
    AdwApplication *app = adw_application_new("com.spiralpoint.zigonaut", G_APPLICATION_NON_UNIQUE);
    GError *error = NULL;
    if (!settings_load(&settings, &error)) {
        settings_warning = g_strdup_printf("Settings could not be loaded; using defaults: %s", error->message);
        g_clear_error(&error);
    }
    apply_settings(app);
    g_signal_connect(adw_style_manager_get_default(), "notify::dark", G_CALLBACK(appearance_changed), app);
    g_set_application_name("Zigonaut");
    gtk_window_set_default_icon_name("com.spiralpoint.zigonaut");
    const GActionEntry actions[] = { { .name = "about", .activate = about } };
    g_action_map_add_action_entries(G_ACTION_MAP(app), actions, G_N_ELEMENTS(actions), app);
    const char *new_tab_keys[] = { "<Control><Shift>t", NULL };
    const char *new_window_keys[] = { "<Control><Shift>n", NULL };
    const char *copy_command_keys[] = { "<Control><Shift>g", NULL };
    const char *find_keys[] = { "<Control><Shift>f", NULL };
    const char *settings_keys[] = { "<Control>comma", NULL };
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.new-tab", new_tab_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.new-window", new_window_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.copy-command", copy_command_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.find", find_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.settings", settings_keys);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int result = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return result;
}
