/* One xdg toplevel on the Wayland display WAYLAND_DISPLAY names, with the
 * app-id it is given, so a row can read back where and how large the
 * compositor maps a window of that class: the helper connects to the
 * socket it is given and to nothing else.
 *
 *   toplevel APP_ID [TITLE]
 *
 * Maps a toplevel whose app-id is APP_ID and whose title is TITLE, APP_ID
 * when it is absent, and answers every
 * configure with a new wl_shm buffer of the configured size, 320 by 240
 * when the compositor leaves the size to the client, so the window takes
 * whatever size the compositor asks. It answers the compositor's ping,
 * prints `mapped APP_ID` once its first buffer is committed, and exits 0
 * when the compositor closes the toplevel or on SIGTERM, SIGINT or SIGHUP.
 * Exit 2 on a bad invocation, 1 when the display cannot be opened, lacks a
 * global the helper needs or fails, or a buffer cannot be made, printed as
 * `toplevel: refused: <key>=<value>`.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define FREE_WIDTH 320
#define FREE_HEIGHT 240

static struct wl_compositor *compositor = NULL;
static struct wl_shm *shm = NULL;
static struct xdg_wm_base *wm_base = NULL;
static struct wl_surface *surface = NULL;
static const char *app_id = NULL;
static const char *title = NULL;
/* The size the last toplevel configure asked, 0 for the client's choice. */
static int32_t asked_width = 0, asked_height = 0;
static int closed = 0, mapped = 0, buffer_failed = 0;

static void on_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(interface, wl_compositor_interface.name) == 0 && compositor == NULL)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
    else if (strcmp(interface, wl_shm_interface.name) == 0 && shm == NULL)
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (strcmp(interface, xdg_wm_base_interface.name) == 0 && wm_base == NULL)
        wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

static void on_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { on_ping };

/* The compositor holds a buffer until it releases it; after that the
 * surface keeps what it drew, so the buffer is no longer needed. */
static void on_release(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}

static const struct wl_buffer_listener buffer_listener = { on_release };

/* A WIDTH by HEIGHT opaque buffer, or NULL with errno set. */
static struct wl_buffer *buffer_of(int32_t width, int32_t height) {
    int32_t stride = width * 4;
    size_t size = (size_t)stride * (size_t)height;
    int fd = memfd_create("vgs-smoke-toplevel", MFD_CLOEXEC);
    if (fd < 0) return NULL;
    if (ftruncate(fd, (off_t)size) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return NULL;
    }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        int saved = errno;
        close(fd);
        errno = saved;
        return NULL;
    }
    for (size_t i = 0; i < size / 4; i++) pixels[i] = 0xff336699;
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    return buffer;
}

static void on_surface_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial) {
    (void)data;
    int32_t width = asked_width > 0 ? asked_width : FREE_WIDTH;
    int32_t height = asked_height > 0 ? asked_height : FREE_HEIGHT;
    xdg_surface_ack_configure(xdg_surface, serial);
    struct wl_buffer *buffer = buffer_of(width, height);
    if (buffer == NULL) {
        fprintf(stderr, "toplevel: refused: buffer=%dx%d errno=%d\n", width, height, errno);
        buffer_failed = 1;
        return;
    }
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    if (!mapped) {
        printf("mapped %s\n", app_id);
        fflush(stdout);
        mapped = 1;
    }
}

static const struct xdg_surface_listener surface_listener = { on_surface_configure };

static void on_toplevel_configure(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height, struct wl_array *states) {
    (void)data;
    (void)toplevel;
    (void)states;
    asked_width = width;
    asked_height = height;
}

static void on_close(void *data, struct xdg_toplevel *toplevel) {
    (void)data;
    (void)toplevel;
    closed = 1;
}

/* Events of later protocol versions; the helper binds version 1, which
 * sends neither. */
static void on_configure_bounds(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height) {
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
}

static void on_wm_capabilities(void *data, struct xdg_toplevel *toplevel, struct wl_array *capabilities) {
    (void)data;
    (void)toplevel;
    (void)capabilities;
}

static const struct xdg_toplevel_listener toplevel_listener = { on_toplevel_configure, on_close, on_configure_bounds, on_wm_capabilities };

static int broken(struct wl_display *display) {
    fprintf(stderr, "toplevel: refused: display=broken error=%d\n", wl_display_get_error(display));
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 || argv[1][0] == '\0' || (argc == 3 && argv[2][0] == '\0')) {
        fprintf(stderr, "toplevel: refused: usage=APP_ID [TITLE]\n");
        return 2;
    }
    app_id = argv[1];
    title = argc == 3 ? argv[2] : argv[1];
    /* The signals arrive on a descriptor the event loop polls beside the
     * display's, so a signal never interrupts a Wayland call half done. */
    sigset_t stops;
    sigemptyset(&stops);
    sigaddset(&stops, SIGTERM);
    sigaddset(&stops, SIGINT);
    sigaddset(&stops, SIGHUP);
    int signals = -1;
    if (sigprocmask(SIG_BLOCK, &stops, NULL) != 0 || (signals = signalfd(-1, &stops, SFD_CLOEXEC)) < 0) {
        fprintf(stderr, "toplevel: refused: signalfd=%d\n", errno);
        return 1;
    }
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "toplevel: refused: display=%s\n", getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "unset");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (compositor == NULL || shm == NULL || wm_base == NULL) {
        fprintf(stderr, "toplevel: refused: protocol=xdg_wm_base compositor=%d shm=%d xdg_wm_base=%d\n", compositor != NULL, shm != NULL, wm_base != NULL);
        wl_display_disconnect(display);
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &surface_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, app_id);
    xdg_toplevel_set_title(toplevel, title);
    /* The first commit carries no buffer: it asks for the first configure. */
    wl_surface_commit(surface);

    int status = 0;
    int stopped = 0;
    struct pollfd fds[2] = { { wl_display_get_fd(display), POLLIN, 0 }, { signals, POLLIN, 0 } };
    while (!closed && !stopped) {
        while (wl_display_prepare_read(display) != 0)
            if (wl_display_dispatch_pending(display) < 0) return broken(display);
        if (closed || buffer_failed) {
            wl_display_cancel_read(display);
            break;
        }
        if (wl_display_flush(display) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(display);
            return broken(display);
        }
        if (poll(fds, 2, -1) < 0) {
            wl_display_cancel_read(display);
            if (errno == EINTR) continue;
            fprintf(stderr, "toplevel: refused: poll=%d\n", errno);
            return 1;
        }
        if (fds[0].revents != 0) {
            if (wl_display_read_events(display) < 0) return broken(display);
        } else {
            wl_display_cancel_read(display);
        }
        if (wl_display_dispatch_pending(display) < 0) return broken(display);
        if (fds[1].revents != 0) stopped = 1;
    }
    if (buffer_failed) status = 1;
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg_surface);
    wl_surface_destroy(surface);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return status;
}
