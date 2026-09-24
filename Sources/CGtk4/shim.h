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

// Whether a key press arrived with Control held. The mask is an enumerator in
// a C flags enum, and how Swift imports one of those is not something worth
// depending on.
static inline int sensorium_modifier_has_control(GdkModifierType state) {
    return (state & GDK_CONTROL_MASK) != 0;
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

#endif
