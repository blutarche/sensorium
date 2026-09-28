#ifndef SENSORIUM_CGTK4_SHIM_H
#define SENSORIUM_CGTK4_SHIM_H

#include <gtk/gtk.h>
#include <gdk/gdkkeysyms.h>

// GTK's object model is reached through C macros -- the `GTK_WINDOW(...)`
// family of casts, `G_CALLBACK` and `g_signal_connect` -- and a macro is not
// something Swift can import. Each one below is the macro it is named after
// and nothing else, so the Swift side holds plain pointers and every cast
// happens here, in the one translation unit that has the macros.
//
// Every wrapper takes `gpointer`, which Swift sees as a raw pointer, and hands
// back the concrete type the matching GTK function expects. That keeps the
// Swift side free of guesses about which GTK types this release declares
// publicly and which it keeps opaque.

static inline GtkWidget *sensorium_gtk_widget(gpointer object) {
    return GTK_WIDGET(object);
}

static inline GtkWindow *sensorium_gtk_window(gpointer object) {
    return GTK_WINDOW(object);
}

static inline GtkBox *sensorium_gtk_box(gpointer object) {
    return GTK_BOX(object);
}

static inline GtkLabel *sensorium_gtk_label(gpointer object) {
    return GTK_LABEL(object);
}

static inline GtkButton *sensorium_gtk_button(gpointer object) {
    return GTK_BUTTON(object);
}

static inline GtkEntry *sensorium_gtk_entry(gpointer object) {
    return GTK_ENTRY(object);
}

static inline GtkPasswordEntry *sensorium_gtk_password_entry(gpointer object) {
    return GTK_PASSWORD_ENTRY(object);
}

static inline GtkScrolledWindow *sensorium_gtk_scrolled_window(gpointer object) {
    return GTK_SCROLLED_WINDOW(object);
}

static inline GtkEditable *sensorium_gtk_editable(gpointer object) {
    return GTK_EDITABLE(object);
}

static inline GtkStack *sensorium_gtk_stack(gpointer object) {
    return GTK_STACK(object);
}

static inline GtkMenuButton *sensorium_gtk_menu_button(gpointer object) {
    return GTK_MENU_BUTTON(object);
}

static inline GtkPopover *sensorium_gtk_popover(gpointer object) {
    return GTK_POPOVER(object);
}

static inline GtkImage *sensorium_gtk_image(gpointer object) {
    return GTK_IMAGE(object);
}

static inline GtkOverlay *sensorium_gtk_overlay(gpointer object) {
    return GTK_OVERLAY(object);
}

static inline GtkDrawingArea *sensorium_gtk_drawing_area(gpointer object) {
    return GTK_DRAWING_AREA(object);
}

static inline int sensorium_is_drawing_area(gpointer object) {
    return GTK_IS_DRAWING_AREA(object);
}

// `gtk_accessible_update_property` takes its property/value pairs as
// varargs, which Swift cannot call.
static inline void sensorium_accessible_set_label(gpointer object, const char *label) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(object), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

static inline GtkGestureSingle *sensorium_gtk_gesture_single(gpointer object) {
    return GTK_GESTURE_SINGLE(object);
}

static inline GtkEventController *sensorium_gtk_event_controller(gpointer object) {
    return GTK_EVENT_CONTROLLER(object);
}

static inline GtkCssProvider *sensorium_gtk_css_provider(gpointer object) {
    return GTK_CSS_PROVIDER(object);
}

static inline GtkStyleProvider *sensorium_gtk_style_provider(gpointer object) {
    return GTK_STYLE_PROVIDER(object);
}

static inline GtkAlertDialog *sensorium_gtk_alert_dialog(gpointer object) {
    return GTK_ALERT_DIALOG(object);
}

static inline GMenu *sensorium_g_menu(gpointer object) {
    return G_MENU(object);
}

static inline GMenuModel *sensorium_g_menu_model(gpointer object) {
    return G_MENU_MODEL(object);
}

static inline GAction *sensorium_g_action(gpointer object) {
    return G_ACTION(object);
}

static inline GActionMap *sensorium_g_action_map(gpointer object) {
    return G_ACTION_MAP(object);
}

static inline GActionGroup *sensorium_g_action_group(gpointer object) {
    return G_ACTION_GROUP(object);
}

static inline GObject *sensorium_g_object(gpointer object) {
    return G_OBJECT(object);
}

// `g_signal_connect` is a macro over `g_signal_connect_data`, and `G_CALLBACK`
// is the cast it puts around the handler. The handler arrives here as a
// pointer to a function of no arguments, which is exactly what `G_CALLBACK`
// produces, so the Swift caller states the real signature at the point it
// writes the handler.
static inline gulong sensorium_signal_connect(
    gpointer instance,
    const char *detailed_signal,
    void (*handler)(void),
    gpointer data) {
    return g_signal_connect_data(instance, detailed_signal, G_CALLBACK(handler), data, NULL, (GConnectFlags)0);
}

// An alert's own message is a printf format string, and a variadic function
// cannot be called from Swift. The message is always a finished sentence here,
// never a format.
static inline GtkAlertDialog *sensorium_alert_dialog_new(const char *message) {
    return gtk_alert_dialog_new("%s", message);
}

// An alert's buttons arrive as a NULL-terminated array of C strings, which is
// easier to build here than to assemble on the Swift side. Two is all this
// viewer ever asks for.
static inline void sensorium_alert_dialog_set_two_buttons(
    GtkAlertDialog *dialog,
    const char *first,
    const char *second) {
    const char *labels[] = { first, second, NULL };
    gtk_alert_dialog_set_buttons(dialog, labels);
}

// `GAsyncReadyCallback` is a typed function pointer, and the handler is
// written on the Swift side, so it crosses as an untyped one the same way a
// signal handler does.
static inline void sensorium_alert_dialog_choose(
    GtkAlertDialog *dialog,
    GtkWindow *parent,
    void (*callback)(void),
    gpointer data) {
    gtk_alert_dialog_choose(dialog, parent, NULL, (GAsyncReadyCallback)callback, data);
}

// Which button was pressed, by index. A cancelled choice reports the cancel
// button the dialog was given, so the error is not this caller's business.
static inline int sensorium_alert_dialog_choose_finish(gpointer source, gpointer result) {
    return gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), G_ASYNC_RESULT(result), NULL);
}

// `G_VARIANT_TYPE_INT32` is a macro that casts a string literal, which is how
// a menu action says it carries a row number.
static inline const GVariantType *sensorium_variant_type_int32(void) {
    return G_VARIANT_TYPE_INT32;
}

static inline GtkPopoverMenuBar *sensorium_gtk_popover_menu_bar(gpointer object) {
    return GTK_POPOVER_MENU_BAR(object);
}

static inline const GVariantType *sensorium_variant_type_string(void) {
    return G_VARIANT_TYPE_STRING;
}

static inline int sensorium_is_about_dialog(gpointer object) {
    return object != NULL && GTK_IS_ABOUT_DIALOG(object);
}

static inline int sensorium_is_editable(gpointer object) {
    return object != NULL && GTK_IS_EDITABLE(object);
}

// Keeps `target` shown exactly while `source` is. The binding flags are an
// enum this module's Swift import does not see.
static inline void sensorium_bind_visible(gpointer source, gpointer target) {
    g_object_bind_property(source, "visible", target, "visible", G_BINDING_SYNC_CREATE);
}

// Dark chrome, asked of the toolkit itself so the widgets this viewer does not
// restyle -- scrollbars, the text caret, the selection -- are dark too.
// `g_object_set` is variadic.
static inline void sensorium_prefer_dark_theme(void) {
    GtkSettings *settings = gtk_settings_get_default();
    if (settings != NULL) {
        g_object_set(settings, "gtk-application-prefer-dark-theme", TRUE, NULL);
    }
}

// Draws what `window` currently shows inside its content -- the child's own
// box plus its margins, over the window's own background, without the title
// bar or any client-side shadow -- at the scale the window's surface has, and
// writes it to `path` as a PNG. Returns that scale, which is fractional on a
// fractionally scaled output, or 0 when the window has not been laid out or
// the file could not be written.
static inline double sensorium_window_content_write_png(gpointer object, const char *path) {
    GtkWidget *window = GTK_WIDGET(object);
    GtkWidget *content = gtk_window_get_child(GTK_WINDOW(object));
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(object));
    if (content == NULL || surface == NULL) {
        return 0;
    }
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(content, window, &bounds)) {
        return 0;
    }
    double scale = gdk_surface_get_scale(surface);
    float x = bounds.origin.x - gtk_widget_get_margin_start(content);
    float y = bounds.origin.y - gtk_widget_get_margin_top(content);
    float width = bounds.size.width + gtk_widget_get_margin_start(content) + gtk_widget_get_margin_end(content);
    float height = bounds.size.height + gtk_widget_get_margin_top(content) + gtk_widget_get_margin_bottom(content);
    if (width <= 0 || height <= 0) {
        return 0;
    }

    GdkPaintable *paintable = gtk_widget_paintable_new(window);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gdk_paintable_snapshot(
        paintable, GDK_SNAPSHOT(snapshot),
        gtk_widget_get_width(window) * scale, gtk_widget_get_height(window) * scale
    );
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    g_object_unref(paintable);
    if (node == NULL) {
        return 0;
    }
    graphene_rect_t viewport = GRAPHENE_RECT_INIT(x * scale, y * scale, width * scale, height * scale);
    GdkTexture *texture = gsk_renderer_render_texture(gtk_native_get_renderer(GTK_NATIVE(object)), node, &viewport);
    gsk_render_node_unref(node);
    gboolean written = gdk_texture_save_to_png(texture, path);
    g_object_unref(texture);
    return written ? scale : 0;
}

// The colour at one pixel of a PNG, as 0xRRGGBB, or -1 when the file cannot
// be read or the point lies outside it.
static inline gint64 sensorium_png_pixel(const char *path, int x, int y) {
    GdkTexture *texture = gdk_texture_new_from_filename(path, NULL);
    if (texture == NULL) {
        return -1;
    }
    int width = gdk_texture_get_width(texture);
    int height = gdk_texture_get_height(texture);
    if (x < 0 || y < 0 || x >= width || y >= height) {
        g_object_unref(texture);
        return -1;
    }
    gsize stride = (gsize)width * 4;
    guchar *pixels = g_malloc(stride * height);
    // Premultiplied BGRA on little-endian, which is what an opaque render
    // comes back as.
    gdk_texture_download(texture, pixels, stride);
    guchar *pixel = pixels + (gsize)y * stride + (gsize)x * 4;
    gint64 rgb = ((gint64)pixel[2] << 16) | ((gint64)pixel[1] << 8) | (gint64)pixel[0];
    g_free(pixels);
    g_object_unref(texture);
    return rgb;
}

// Copies the `width` by `height` block of a PNG whose top left is at `x`,
// `y` into `out`, row by row, each pixel as 0xRRGGBB. Returns 0 when the file
// cannot be read or the block does not lie inside it.
static inline int sensorium_png_region(const char *path, int x, int y, int width, int height, guint32 *out) {
    GdkTexture *texture = gdk_texture_new_from_filename(path, NULL);
    if (texture == NULL) {
        return 0;
    }
    int textureWidth = gdk_texture_get_width(texture);
    int textureHeight = gdk_texture_get_height(texture);
    if (x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > textureWidth || y + height > textureHeight) {
        g_object_unref(texture);
        return 0;
    }
    gsize stride = (gsize)textureWidth * 4;
    guchar *pixels = g_malloc(stride * textureHeight);
    gdk_texture_download(texture, pixels, stride);
    for (int row = 0; row < height; row++) {
        for (int column = 0; column < width; column++) {
            guchar *pixel = pixels + (gsize)(y + row) * stride + (gsize)(x + column) * 4;
            out[row * width + column] = ((guint32)pixel[2] << 16) | ((guint32)pixel[1] << 8) | (guint32)pixel[0];
        }
    }
    g_free(pixels);
    g_object_unref(texture);
    return 1;
}

#endif
