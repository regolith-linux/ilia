/*
 * Serve text on the clipboard of a Wayland compositor until something else is copied, for the
 * clipboard keeper (see ClipboardKeeper.vala).
 *
 * The core protocol only lets a client with keyboard focus set the clipboard, in answer to an
 * input event. The keeper has no window, so it uses the ext-data-control protocol, made for
 * clipboard tools, which needs neither.
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>

#include "ext-data-control-v1-client-protocol.h"

typedef void (*ReadyFunc)(void);

// The types the text is offered as, as GTK and wl-copy offer text
static const char *const TEXT_MIME_TYPES[] = {
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
};

struct keeper {
    struct wl_seat *seat;
    struct ext_data_control_manager_v1 *manager;
    const uint8_t *text;
    size_t length;
    // The text is no longer on the clipboard, or can no longer be served
    int done;
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct keeper *keeper = data;

    // The clipboard of the first seat, as GTK uses
    if (keeper->seat == NULL && strcmp(interface, wl_seat_interface.name) == 0)
        keeper->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    else if (keeper->manager == NULL && strcmp(interface, ext_data_control_manager_v1_interface.name) == 0)
        keeper->manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

// A client pastes: write the text to it
static void source_send(void *data, struct ext_data_control_source_v1 *source, const char *mime_type, int32_t fd) {
    struct keeper *keeper = data;
    size_t written = 0;

    while (written < keeper->length) {
        ssize_t count = write(fd, keeper->text + written, keeper->length - written);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        written += (size_t) count;
    }
    close(fd);
}

// Something else was copied
static void source_cancelled(void *data, struct ext_data_control_source_v1 *source) {
    ((struct keeper *) data)->done = 1;
}

static const struct ext_data_control_source_v1_listener source_listener = {
    .send = source_send,
    .cancelled = source_cancelled,
};

// The compositor offers the keeper every new clipboard content; it reads none
static void device_data_offer(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *offer) {
}

static void device_selection(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *offer) {
    if (offer != NULL)
        ext_data_control_offer_v1_destroy(offer);
}

static void device_finished(void *data, struct ext_data_control_device_v1 *device) {
    ((struct keeper *) data)->done = 1;
}

static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = device_data_offer,
    .selection = device_selection,
    .finished = device_finished,
    .primary_selection = device_selection,
};

/*
 * Put text on the clipboard of the compositor in WAYLAND_DISPLAY, call ready once it is there,
 * and serve it until something else is copied. Returns 0 then, or 1 when the text could not
 * be put on the clipboard (no compositor, or no ext-data-control support).
 */
int ilia_wayland_clipboard_serve(const uint8_t *text, size_t length, ReadyFunc ready) {
    struct keeper keeper = { .text = text, .length = length };
    struct ext_data_control_device_v1 *device = NULL;
    struct ext_data_control_source_v1 *source = NULL;
    int status = 1;

    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL)
        return 1;

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &keeper);
    if (wl_display_roundtrip(display) < 0 || keeper.seat == NULL || keeper.manager == NULL)
        goto out;

    device = ext_data_control_manager_v1_get_data_device(keeper.manager, keeper.seat);
    ext_data_control_device_v1_add_listener(device, &device_listener, &keeper);
    source = ext_data_control_manager_v1_create_data_source(keeper.manager);
    ext_data_control_source_v1_add_listener(source, &source_listener, &keeper);
    for (size_t i = 0; i < sizeof(TEXT_MIME_TYPES) / sizeof(TEXT_MIME_TYPES[0]); i++)
        ext_data_control_source_v1_offer(source, TEXT_MIME_TYPES[i]);
    ext_data_control_device_v1_set_selection(device, source);

    // Once the compositor has answered, the text is on the clipboard
    if (wl_display_roundtrip(display) < 0 || keeper.done)
        goto out;
    ready();
    status = 0;

    while (!keeper.done && wl_display_dispatch(display) >= 0)
        ;

out:
    if (source != NULL)
        ext_data_control_source_v1_destroy(source);
    if (device != NULL)
        ext_data_control_device_v1_destroy(device);
    if (keeper.manager != NULL)
        ext_data_control_manager_v1_destroy(keeper.manager);
    if (keeper.seat != NULL)
        wl_seat_destroy(keeper.seat);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return status;
}
