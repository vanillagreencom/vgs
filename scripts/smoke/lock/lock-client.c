/* A second session-lock client on the Wayland display WAYLAND_DISPLAY
 * names, standing in for another locker such as hyprlock, so a row reads
 * how the shell's lock behaves while another client holds the session. It
 * connects to the socket it is given and to nothing else, and it runs no
 * authentication: it unlocks on a signal.
 *
 *   lock-client
 *
 * Takes the session lock through ext-session-lock-v1 and answers each lock
 * surface's configure with a wl_shm buffer of the configured size, one
 * surface per output. It prints `locked` when the compositor confirms the
 * lock and `finished` when the compositor refuses or ends it, then exits
 * 1. On SIGTERM, SIGINT or SIGHUP it unlocks, prints `unlocked` and exits
 * 0, or exits 0 at once while the lock was never confirmed.
 * Exit 2 on a bad invocation, 1 when the display cannot be opened, lacks a
 * global the helper needs or fails, or a buffer cannot be made, printed as
 * `lock-client: refused: <key>=<value>`.
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
#include "ext-session-lock-v1-client-protocol.h"

#define MAX_OUTPUTS 16

static struct wl_compositor *compositor = NULL;
static struct wl_shm *shm = NULL;
static struct ext_session_lock_manager_v1 *manager = NULL;
static struct wl_output *outputs[MAX_OUTPUTS];
static int output_count = 0;
static int locked = 0, finished = 0, buffer_failed = 0;

struct lock_surface {
    struct wl_surface *surface;
    struct ext_session_lock_surface_v1 *lock_surface;
};
static struct lock_surface surfaces[MAX_OUTPUTS];

static void on_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(interface, wl_compositor_interface.name) == 0 && compositor == NULL)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
    else if (strcmp(interface, wl_shm_interface.name) == 0 && shm == NULL)
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (strcmp(interface, ext_session_lock_manager_v1_interface.name) == 0 && manager == NULL)
        manager = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
    else if (strcmp(interface, wl_output_interface.name) == 0 && output_count < MAX_OUTPUTS)
        outputs[output_count++] = wl_registry_bind(registry, name, &wl_output_interface, 1);
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

static void on_release(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}

static const struct wl_buffer_listener buffer_listener = { on_release };

/* A WIDTH by HEIGHT opaque buffer, or NULL with errno set. */
static struct wl_buffer *buffer_of(int32_t width, int32_t height) {
    int32_t stride = width * 4;
    size_t size = (size_t)stride * (size_t)height;
    int fd = memfd_create("vgs-smoke-lock-client", MFD_CLOEXEC);
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
    for (size_t i = 0; i < size / 4; i++) pixels[i] = 0xff663399;
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    return buffer;
}

static void on_surface_configure(void *data, struct ext_session_lock_surface_v1 *lock_surface, uint32_t serial, uint32_t width, uint32_t height) {
    struct lock_surface *entry = data;
    ext_session_lock_surface_v1_ack_configure(lock_surface, serial);
    struct wl_buffer *buffer = buffer_of((int32_t)width, (int32_t)height);
    if (buffer == NULL) {
        fprintf(stderr, "lock-client: refused: buffer=%ux%u errno=%d\n", width, height, errno);
        buffer_failed = 1;
        return;
    }
    wl_surface_attach(entry->surface, buffer, 0, 0);
    wl_surface_damage(entry->surface, 0, 0, (int32_t)width, (int32_t)height);
    wl_surface_commit(entry->surface);
}

static const struct ext_session_lock_surface_v1_listener surface_listener = { on_surface_configure };

static void on_locked(void *data, struct ext_session_lock_v1 *lock) {
    (void)data;
    (void)lock;
    locked = 1;
    printf("locked\n");
    fflush(stdout);
}

static void on_finished(void *data, struct ext_session_lock_v1 *lock) {
    (void)data;
    (void)lock;
    finished = 1;
    printf("finished\n");
    fflush(stdout);
}

static const struct ext_session_lock_v1_listener lock_listener = { on_locked, on_finished };

static int broken(struct wl_display *display) {
    fprintf(stderr, "lock-client: refused: display=broken error=%d\n", wl_display_get_error(display));
    return 1;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) {
        fprintf(stderr, "lock-client: refused: usage=no-arguments\n");
        return 2;
    }
    /* The signals arrive on a descriptor the event loop polls beside the
     * display's, so a signal never interrupts a Wayland call half done. */
    sigset_t stops;
    sigemptyset(&stops);
    sigaddset(&stops, SIGTERM);
    sigaddset(&stops, SIGINT);
    sigaddset(&stops, SIGHUP);
    int signals = -1;
    if (sigprocmask(SIG_BLOCK, &stops, NULL) != 0 || (signals = signalfd(-1, &stops, SFD_CLOEXEC)) < 0) {
        fprintf(stderr, "lock-client: refused: signalfd=%d\n", errno);
        return 1;
    }
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "lock-client: refused: display=%s\n", getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "unset");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (compositor == NULL || shm == NULL || manager == NULL || output_count == 0) {
        fprintf(stderr, "lock-client: refused: protocol=ext_session_lock_v1 compositor=%d shm=%d manager=%d outputs=%d\n", compositor != NULL, shm != NULL, manager != NULL, output_count);
        wl_display_disconnect(display);
        return 1;
    }
    struct ext_session_lock_v1 *lock = ext_session_lock_manager_v1_lock(manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    for (int i = 0; i < output_count; i++) {
        surfaces[i].surface = wl_compositor_create_surface(compositor);
        surfaces[i].lock_surface = ext_session_lock_v1_get_lock_surface(lock, surfaces[i].surface, outputs[i]);
        ext_session_lock_surface_v1_add_listener(surfaces[i].lock_surface, &surface_listener, &surfaces[i]);
    }

    int stopped = 0;
    struct pollfd fds[2] = { { wl_display_get_fd(display), POLLIN, 0 }, { signals, POLLIN, 0 } };
    while (!finished && !stopped && !buffer_failed) {
        while (wl_display_prepare_read(display) != 0)
            if (wl_display_dispatch_pending(display) < 0) return broken(display);
        if (wl_display_flush(display) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(display);
            return broken(display);
        }
        if (poll(fds, 2, -1) < 0) {
            wl_display_cancel_read(display);
            if (errno == EINTR) continue;
            fprintf(stderr, "lock-client: refused: poll=%d\n", errno);
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
    for (int i = 0; i < output_count; i++) {
        ext_session_lock_surface_v1_destroy(surfaces[i].lock_surface);
        wl_surface_destroy(surfaces[i].surface);
    }
    int status = finished || buffer_failed ? 1 : 0;
    if (locked && !finished) {
        ext_session_lock_v1_unlock_and_destroy(lock);
        wl_display_roundtrip(display);
        printf("unlocked\n");
        fflush(stdout);
    } else {
        ext_session_lock_v1_destroy(lock);
        wl_display_roundtrip(display);
    }
    wl_display_disconnect(display);
    return status;
}
