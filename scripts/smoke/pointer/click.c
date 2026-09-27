/* One pointer click on the Wayland display WAYLAND_DISPLAY names, through
 * the compositor's virtual pointer protocol, so the seat it moves is the
 * nested compositor's and never the live session's: the helper connects to
 * the socket it is given and to nothing else.
 *
 *   click X Y WIDTH HEIGHT [move]
 *
 * Moves the pointer to (X, Y) on a layout WIDTH by HEIGHT, presses and
 * releases the left button, and prints `clicked X Y`. With `move` it only
 * moves the pointer and prints `moved X Y`, so a row can hover an item.
 * Exit 2 on a bad invocation, 1 when the display cannot be opened or lacks
 * the protocol, printed as `click: refused: <key>=<value>`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#define BTN_LEFT 0x110

static struct wl_seat *seat = NULL;
static struct zwlr_virtual_pointer_manager_v1 *manager = NULL;

static void on_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(interface, wl_seat_interface.name) == 0 && seat == NULL)
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0 && manager == NULL)
        manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int number(const char *text, uint32_t *out) {
    char *end = NULL;
    long value = strtol(text, &end, 10);
    if (*text == '\0' || *end != '\0' || value < 0) return 0;
    *out = (uint32_t)value;
    return 1;
}

int main(int argc, char **argv) {
    uint32_t x, y, width, height;
    int move_only = argc == 6 && strcmp(argv[5], "move") == 0;
    if ((argc != 5 && !move_only) || !number(argv[1], &x) || !number(argv[2], &y) || !number(argv[3], &width) || !number(argv[4], &height) || width == 0 || height == 0) {
        fprintf(stderr, "click: refused: usage=X Y WIDTH HEIGHT [move]\n");
        return 2;
    }
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "click: refused: display=%s\n", getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "unset");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (seat == NULL || manager == NULL) {
        fprintf(stderr, "click: refused: protocol=zwlr_virtual_pointer_manager_v1 seat=%d manager=%d\n", seat != NULL, manager != NULL);
        wl_display_disconnect(display);
        return 1;
    }
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), x, y, width, height);
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_roundtrip(display);
    if (!move_only) {
        zwlr_virtual_pointer_v1_button(pointer, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
        zwlr_virtual_pointer_v1_button(pointer, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    printf("%s %u %u\n", move_only ? "moved" : "clicked", x, y);
    return 0;
}
