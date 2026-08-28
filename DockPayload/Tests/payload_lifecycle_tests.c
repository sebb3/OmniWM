/* Lifecycle process test for the real payload dylib.
 *
 * Loads the built payload (never the Dock) behind the test-only socket-path
 * override, so the live server binds a throwaway path in a directory this
 * test owns and the production per-user socket is never created, unlinked,
 * or bound. Against that live serialized server it proves the two sides of
 * the handshake-deadline contract: a same-UID client that connects and stays
 * silent is dropped once the absolute pre-handshake deadline expires, while
 * an established session that has completed its handshake may idle well past
 * that deadline and stay connected. Unload must still interrupt the server's
 * blocking receive, join the thread, and remove the socket. The production
 * socket path is checked before and after the whole run: whatever its prior
 * state, this test leaves it untouched. */

#include "protocol_v2.h"

#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define PAYLOAD_PATH "build/libHS2DockWindowSpike.dylib"
#define SOCKET_FORMAT "/tmp/hs2-dock-window-v2-%s.socket"
#define SOCKET_OVERRIDE_ENV "HS2_DOCK_V2_SOCKET_PATH"

static void deadline_expired(int signal_number)
{
    (void)signal_number;
    _exit(124);
}

static int connect_when_ready(const char *path)
{
    for (int attempt = 0; attempt < 200; attempt++) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        assert(fd >= 0);
        struct sockaddr_un address = { .sun_family = AF_UNIX };
        strlcpy(address.sun_path, path, sizeof(address.sun_path));
        if (connect(fd, (const struct sockaddr *)&address, sizeof(address)) == 0) {
            return fd;
        }
        close(fd);
        usleep(10 * 1000);
    }
    return -1;
}

static bool transfer(int fd, void *bytes, size_t count, bool writing)
{
    uint8_t *cursor = bytes;
    while (count > 0) {
        ssize_t result = writing ? send(fd, cursor, count, 0) : recv(fd, cursor, count, 0);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            return false;
        }
        cursor += result;
        count -= (size_t)result;
    }
    return true;
}

/* Polls for the server-initiated close of a silent connection. The payload's
 * default pre-handshake bound is two seconds; anything past four means the
 * bound was not armed and the silent client is monopolizing the server. */
static bool dropped_within(int fd, long timeout_ms)
{
    for (long waited = 0; waited < timeout_ms; waited += 50) {
        uint8_t byte;
        ssize_t result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
        if (result == 0) {
            return true;
        }
        if (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            return true;
        }
        usleep(50 * 1000);
    }
    return false;
}

/* One full handshake against the live payload; the reply must negotiate. */
static uint64_t handshake(int fd)
{
    hs2_dock_v2_handshake_request request = {
        .protocol_min_major = HS2_DOCK_V2_MAJOR,
        .protocol_max_major = HS2_DOCK_V2_MAJOR,
        .build_min = HS2_DOCK_V2_BUILD,
        .build_max = HS2_DOCK_V2_BUILD,
        .optional_capabilities = HS2_DOCK_V2_EVIDENCED_CAPABILITIES,
    };
    for (size_t index = 0; index < sizeof(request.nonce); index++) {
        request.nonce[index] = (uint8_t)(index + 1);
    }
    uint8_t payload[HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_handshake_request(&request, payload));
    hs2_dock_v2_envelope envelope = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = HS2_DOCK_V2_HANDSHAKE_REQUEST,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES,
        .request_id = 1,
    };
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    assert(hs2_dock_v2_encode_envelope(&envelope, header));
    assert(transfer(fd, header, sizeof(header), true));
    assert(transfer(fd, payload, sizeof(payload), true));
    assert(transfer(fd, header, sizeof(header), false));
    hs2_dock_v2_envelope reply;
    assert(hs2_dock_v2_decode_envelope(header, sizeof(header), &reply) &&
           reply.type == HS2_DOCK_V2_HANDSHAKE_RESPONSE);
    uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES];
    assert(transfer(fd, response, reply.payload_bytes, false));
    hs2_dock_v2_handshake_response accepted;
    assert(hs2_dock_v2_decode_handshake_response(response, reply.payload_bytes, &accepted));
    assert(accepted.error == HS2_DOCK_V2_OK && accepted.session_id != 0);
    return accepted.session_id;
}

int main(void)
{
    struct passwd *account = getpwuid(geteuid());
    assert(account != NULL);
    char production[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    assert(snprintf(production, sizeof(production), SOCKET_FORMAT, account->pw_name) <
           (int)sizeof(production));

    /* An isolated socket path behind the test-only override: the payload's
     * constructor serves this throwaway path, never the production one. */
    char directory[] = "/tmp/hs2-dock-v2-lifecycle.XXXXXX";
    assert(mkdtemp(directory) != NULL);
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    assert(snprintf(socket_path, sizeof(socket_path), "%s/socket", directory) <
           (int)sizeof(socket_path));
    assert(setenv(SOCKET_OVERRIDE_ENV, socket_path, 1) == 0);

    /* Production-path isolation proof: whatever state the production socket
     * is in before the run, it must be in exactly that state after it. */
    bool production_existed = access(production, F_OK) == 0;

    signal(SIGALRM, deadline_expired);
    alarm(30);
    void *payload = dlopen(PAYLOAD_PATH, RTLD_NOW | RTLD_LOCAL);
    assert(payload != NULL);

    /* A silent same-UID client never handshakes: the absolute pre-handshake
     * deadline drops it so the serialized server stays available. */
    int silent = connect_when_ready(socket_path);
    assert(silent >= 0);
    assert(dropped_within(silent, 4000));
    close(silent);

    /* An established Core session may be idle indefinitely between commands:
     * every receive bound was removed after negotiation, so idling past the
     * two-second deadline leaves the connection open. */
    int client = connect_when_ready(socket_path);
    assert(client >= 0);
    (void)handshake(client);
    sleep(3);
    char byte;
    errno = 0;
    assert(recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == -1 &&
           (errno == EAGAIN || errno == EWOULDBLOCK));

    /* Leave the client idle in a blocked-read state; unload must interrupt it and join. */
    assert(dlclose(payload) == 0);
    close(client);
    alarm(0);

    errno = 0;
    assert(access(socket_path, F_OK) == -1 && errno == ENOENT);
    assert(rmdir(directory) == 0);
    if (production_existed) {
        /* a live production socket is left exactly as found */
        assert(access(production, F_OK) == 0);
    } else {
        errno = 0;
        assert(access(production, F_OK) == -1 && errno == ENOENT);
    }
    return 0;
}
