/* Physical XKB keycodes through the nested compositor's virtual keyboard.
 * keyboard FIFO [LAYOUT [OPTIONS]]
 * Commands: `down CODE`, `up CODE`, `sync`, `quit`. CODE is 8..255.
 * Prints `ready`, then each command after a Wayland round trip. A row uses
 * `sync` as a transport barrier, not as proof the shell handled the key.
 * Key events use evdev codes (XKB minus 8); the map and modifiers come from
 * xkbcommon, so code:108 remains Right Alt on us, AltGr and swapped layouts.
 * Every key still down is released at EOF or quit. Exit 2 for bad input,
 * 1 for a missing protocol, failed keymap or broken display.
 * The harness alone supplies the nested socket and owns this process.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!seat && strcmp(interface, wl_seat_interface.name) == 0)
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    else if (!manager && strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0)
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener listener = { global, removed };

static int send_key(struct wl_display *display, struct zwp_virtual_keyboard_v1 *keyboard,
                    struct xkb_state *state, uint32_t code, int pressed, int *down) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    uint32_t ms = (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
    zwp_virtual_keyboard_v1_key(keyboard, ms, code - 8, pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    if (down[code] != pressed) {
        xkb_state_update_key(state, code, pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
        down[code] = pressed;
    }
    zwp_virtual_keyboard_v1_modifiers(keyboard,
        xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
        xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
        xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
        xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
    return wl_display_roundtrip(display);
}

int main(int argc, char **argv) {
    int status = 1, fd = -1, down[256] = {0};
    FILE *commands = NULL;
    char *map = NULL;
    struct xkb_context *context = NULL;
    struct xkb_keymap *keymap = NULL;
    struct xkb_state *state = NULL;
    struct zwp_virtual_keyboard_v1 *keyboard = NULL;
    struct wl_display *display = NULL;
    const char *failure = "display-connect";
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "keyboard: refused: usage=FIFO [LAYOUT [OPTIONS]]\n");
        return 2;
    }
    display = wl_display_connect(NULL);
    if (!display) goto done;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    failure = "keyboard-protocol";
    if (wl_display_roundtrip(display) < 0 || !seat || !manager) goto done;
    context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    failure = "xkb-context";
    if (!context) goto done;
    struct xkb_rule_names names = { .rules = "evdev", .model = "pc105", .layout = argc >= 3 ? argv[2] : "us", .options = argc == 4 ? argv[3] : "" };
    failure = "xkb-keymap";
    keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap || !(state = xkb_state_new(keymap))) goto done;
    map = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (!map) goto done;
    size_t size = strlen(map) + 1;
    failure = "keymap-file";
    fd = memfd_create("vgs-smoke-keymap", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size) != 0 || write(fd, map, size) != (ssize_t)size) goto done;
    keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    failure = "keymap-delivery";
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)size);
    if (wl_display_roundtrip(display) < 0) goto done;
    puts("ready"); fflush(stdout);
    failure = "command-file";
    commands = fopen(argv[1], "r");
    if (!commands) goto done;
    char line[128], verb[16], extra;
    unsigned code;
    status = 0;
    failure = "key-delivery";
    while (fgets(line, sizeof(line), commands)) {
        if (strcmp(line, "quit\n") == 0) break;
        if (strcmp(line, "sync\n") == 0) {
            if (wl_display_roundtrip(display) < 0) { status = 1; break; }
            puts("sync"); fflush(stdout);
            continue;
        }
        if (sscanf(line, "%15s %u %c", verb, &code, &extra) != 2 || code < 8 || code > 255 ||
            (strcmp(verb, "down") != 0 && strcmp(verb, "up") != 0)) {
            fprintf(stderr, "keyboard: refused: command=%s", line);
            status = 2; break;
        }
        if (send_key(display, keyboard, state, code, strcmp(verb, "down") == 0, down) < 0) { status = 1; break; }
        printf("%s %u\n", verb, code); fflush(stdout);
    }
    if (ferror(commands)) status = 1;
    for (unsigned code = 8; code < 256; code++)
        if (down[code] && send_key(display, keyboard, state, code, 0, down) < 0) status = 1;
done:
    if (status == 1) fprintf(stderr, "keyboard: refused: operation=%s errno=%d display-error=%d\n", failure, errno, display ? wl_display_get_error(display) : 0);
    if (commands) fclose(commands);
    if (keyboard) zwp_virtual_keyboard_v1_destroy(keyboard);
    if (display) { wl_display_flush(display); wl_display_disconnect(display); }
    if (fd >= 0) close(fd);
    free(map);
    if (state) xkb_state_unref(state);
    if (keymap) xkb_keymap_unref(keymap);
    if (context) xkb_context_unref(context);
    return status;
}
