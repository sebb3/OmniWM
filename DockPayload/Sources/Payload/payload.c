#include "operation_dispatch.h"
#include "payload_server.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define HS2_DOCK_V2_SOCKET_FORMAT "/tmp/hs2-dock-window-v2-%s.socket"
/* Test-only socket path override: when this variable is set at load the
 * payload serves exactly that path instead of the production per-user
 * socket, so process tests can run against a throwaway path they own.
 * Production never sets it; unset behavior is byte-for-byte the production
 * path. A value that cannot be a socket path refuses to start rather than
 * ever touching the production path. */
#define HS2_DOCK_V2_SOCKET_OVERRIDE_ENV "HS2_DOCK_V2_SOCKET_PATH"
#define HS2_SKYLIGHT_PATH "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

typedef struct {
    pthread_mutex_t lock;
    pthread_t thread;
    int listener;
    int active_client;
    bool started;
    bool stopping;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    hs2_dock_v2_server protocol;
    hs2_dock_skylight_api skylight;
} hs2_dock_payload_runtime;

static hs2_dock_payload_runtime g_runtime = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .listener = -1,
    .active_client = -1,
};

static void release_transaction(CFTypeRef transaction)
{
    CFRelease(transaction);
}

static void resolve_skylight(hs2_dock_skylight_api *api)
{
    void *skylight = dlopen(HS2_SKYLIGHT_PATH, RTLD_LAZY | RTLD_LOCAL);
    if (skylight == NULL) {
        return;
    }

    api->main_connection_id =
        (hs2_sls_main_connection_id_fn)dlsym(skylight, "SLSMainConnectionID");
    api->get_window_bounds =
        (hs2_sls_get_window_bounds_fn)dlsym(skylight, "SLSGetWindowBounds");
    api->move_window_with_group =
        (hs2_sls_move_window_with_group_fn)dlsym(skylight, "SLSMoveWindowWithGroup");
    api->get_window_transform =
        (hs2_sls_get_window_transform_fn)dlsym(skylight, "SLSGetWindowTransform");
    api->set_window_transform =
        (hs2_sls_set_window_transform_fn)dlsym(skylight, "SLSSetWindowTransform");
    api->set_window_warp =
        (hs2_sls_set_window_warp_fn)dlsym(skylight, "SLSSetWindowWarp");
    api->transaction_create =
        (hs2_sls_transaction_create_fn)dlsym(skylight, "SLSTransactionCreate");
    api->transaction_move_window_with_group =
        (hs2_sls_transaction_move_window_with_group_fn)dlsym(
            skylight, "SLSTransactionMoveWindowWithGroup");
    api->transaction_set_window_transform =
        (hs2_sls_transaction_set_window_transform_fn)dlsym(
            skylight, "SLSTransactionSetWindowTransform");
    api->transaction_commit =
        (hs2_sls_transaction_commit_fn)dlsym(skylight, "SLSTransactionCommit");
    api->transaction_release = release_transaction;
}

static void *server_main(void *unused)
{
    (void)unused;
    for (;;) {
        int listener;
        pthread_mutex_lock(&g_runtime.lock);
        listener = g_runtime.listener;
        bool stopping = g_runtime.stopping;
        pthread_mutex_unlock(&g_runtime.lock);
        if (stopping || listener < 0) {
            break;
        }

        int fd = accept(listener, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            continue;
        }

        pthread_mutex_lock(&g_runtime.lock);
        if (g_runtime.stopping) {
            pthread_mutex_unlock(&g_runtime.lock);
            close(fd);
            break;
        }
        g_runtime.active_client = fd;
        pthread_mutex_unlock(&g_runtime.lock);

        int no_sigpipe = 1;
        struct timeval timeout = { .tv_sec = 2, .tv_usec = 0 };
        (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
        (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        hs2_dock_v2_peer peer;
        if (hs2_dock_v2_capture_peer(fd, &peer) && peer.uid == geteuid()) {
            (void)hs2_dock_v2_serve_connection(fd, &g_runtime.protocol, &g_runtime.skylight,
                                                &peer, NULL, HS2_DOCK_V2_HANDSHAKE_TIMEOUT_MS);
        }

        pthread_mutex_lock(&g_runtime.lock);
        if (g_runtime.active_client == fd) {
            g_runtime.active_client = -1;
        }
        pthread_mutex_unlock(&g_runtime.lock);
        close(fd);
    }
    return NULL;
}

__attribute__((constructor))
static void hs2_dock_window_spike_load(void)
{
    const char *override = getenv(HS2_DOCK_V2_SOCKET_OVERRIDE_ENV);
    struct passwd *account = getpwuid(geteuid());
    if (account == NULL) {
        return;
    }

    pthread_mutex_lock(&g_runtime.lock);
    if (g_runtime.started) {
        pthread_mutex_unlock(&g_runtime.lock);
        return;
    }
    if (override != NULL && override[0] != '\0') {
        if (strlcpy(g_runtime.path, override, sizeof(g_runtime.path)) >=
            sizeof(g_runtime.path)) {
            pthread_mutex_unlock(&g_runtime.lock);
            return;
        }
    } else if (snprintf(g_runtime.path, sizeof(g_runtime.path), HS2_DOCK_V2_SOCKET_FORMAT,
                        account->pw_name) >= (int)sizeof(g_runtime.path)) {
        pthread_mutex_unlock(&g_runtime.lock);
        return;
    }

    resolve_skylight(&g_runtime.skylight);
    hs2_dock_v2_server_init(&g_runtime.protocol,
                            hs2_dock_active_capabilities(&g_runtime.skylight));
    hs2_dock_v2_server_set_cleanup(&g_runtime.protocol, hs2_dock_cleanup_lease_residue,
                                   &g_runtime.skylight);
    g_runtime.listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_runtime.listener < 0) {
        pthread_mutex_unlock(&g_runtime.lock);
        return;
    }

    int no_sigpipe = 1;
    (void)setsockopt(g_runtime.listener, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe,
                     sizeof(no_sigpipe));
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, g_runtime.path, sizeof(address.sun_path));
    unlink(g_runtime.path);
    if (bind(g_runtime.listener, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
        chmod(g_runtime.path, 0600) != 0 || listen(g_runtime.listener, 4) != 0) {
        close(g_runtime.listener);
        g_runtime.listener = -1;
        unlink(g_runtime.path);
        pthread_mutex_unlock(&g_runtime.lock);
        return;
    }

    g_runtime.stopping = false;
    if (pthread_create(&g_runtime.thread, NULL, server_main, NULL) == 0) {
        g_runtime.started = true;
    } else {
        close(g_runtime.listener);
        g_runtime.listener = -1;
        unlink(g_runtime.path);
    }
    pthread_mutex_unlock(&g_runtime.lock);
}

__attribute__((destructor))
static void hs2_dock_window_spike_unload(void)
{
    pthread_t thread;
    bool join = false;

    pthread_mutex_lock(&g_runtime.lock);
    g_runtime.stopping = true;
    if (g_runtime.listener >= 0) {
        (void)shutdown(g_runtime.listener, SHUT_RDWR);
        close(g_runtime.listener);
        g_runtime.listener = -1;
    }
    if (g_runtime.active_client >= 0) {
        /* The server thread owns close(); shutdown only interrupts any blocked I/O. */
        (void)shutdown(g_runtime.active_client, SHUT_RDWR);
    }
    if (g_runtime.started) {
        thread = g_runtime.thread;
        g_runtime.started = false;
        join = true;
    }
    pthread_mutex_unlock(&g_runtime.lock);

    if (join) {
        (void)pthread_join(thread, NULL);
    }
    (void)hs2_dock_v2_unload(&g_runtime.protocol);
    if (g_runtime.path[0] != '\0') {
        unlink(g_runtime.path);
    }
}
