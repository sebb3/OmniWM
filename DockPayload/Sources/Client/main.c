/* Development-only v2 status client: connects to the payload socket, runs one
 * handshake, prints the negotiated session, and exits. It never mutates a
 * window; a rejected or malformed handshake is a nonzero exit. */

#include "protocol_v2.h"

#include <errno.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCKET_FORMAT "/tmp/hs2-dock-window-v2-%s.socket"
/* Test-only socket path override mirroring the payload's: when set the
 * client connects to exactly that path instead of the production per-user
 * socket, so process tests can point the real binary at a throwaway
 * listener. Production never sets it; unset behavior is the production
 * path, and a value that cannot be a socket path is an error rather than a
 * silent fallback to production. */
#define SOCKET_OVERRIDE_ENV "HS2_DOCK_V2_SOCKET_PATH"
#define IO_TIMEOUT_SECONDS 2

/* True when the last I/O error was the payload peer disappearing. With
 * SO_NOSIGPIPE set this surfaces as EPIPE from send instead of a SIGPIPE
 * death, so the caller can report the loss and exit normally. */
static bool peer_lost(void)
{
    return errno == EPIPE || errno == ECONNRESET || errno == ECONNABORTED;
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

/* Sends one framed request and reads exactly one framed reply. The reply
 * envelope is fully validated -- request correlation, reply type, and the
 * exact payload size the reply type defines -- before any body byte is read,
 * so the fixed-size response buffer can never be overrun or starved. */
static bool exchange(int fd, const hs2_dock_v2_envelope *request, const uint8_t *payload,
                     size_t payload_bytes, hs2_dock_v2_envelope *reply,
                     uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES])
{
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    uint16_t expected_bytes;

    if (!hs2_dock_v2_encode_envelope(request, header) ||
        !transfer(fd, header, sizeof(header), true) ||
        !transfer(fd, (void *)payload, payload_bytes, true) ||
        !transfer(fd, header, sizeof(header), false) ||
        !hs2_dock_v2_decode_envelope(header, sizeof(header), reply) ||
        reply->request_id != request->request_id) {
        return false;
    }
    if (reply->type == HS2_DOCK_V2_HANDSHAKE_RESPONSE) {
        expected_bytes = HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES;
    } else if (reply->type == HS2_DOCK_V2_RESPONSE) {
        expected_bytes = HS2_DOCK_V2_RESPONSE_BYTES;
    } else if (reply->type == HS2_DOCK_V2_FRAME_RESPONSE) {
        expected_bytes = HS2_DOCK_V2_FRAME_RESPONSE_BYTES;
    } else {
        return false;
    }
    return reply->payload_bytes == expected_bytes &&
           transfer(fd, response, expected_bytes, false);
}

int main(int argc, char **argv)
{
    struct passwd *account;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int fd;
    struct timeval timeout = { .tv_sec = IO_TIMEOUT_SECONDS };
    struct sockaddr_un address = {0};
    hs2_dock_v2_handshake_request handshake = {
        .protocol_min_major = HS2_DOCK_V2_MAJOR,
        .protocol_max_major = HS2_DOCK_V2_MAJOR,
        .build_min = HS2_DOCK_V2_BUILD,
        .build_max = HS2_DOCK_V2_BUILD,
        .optional_capabilities = HS2_DOCK_V2_EVIDENCED_CAPABILITIES,
    };
    uint8_t request[HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES];
    uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES];
    hs2_dock_v2_envelope envelope = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = HS2_DOCK_V2_HANDSHAKE_REQUEST,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES,
        .request_id = 1,
    };
    hs2_dock_v2_envelope reply;
    hs2_dock_v2_handshake_response accepted;
    hs2_dock_v2_frame_response frame;
    uint64_t query_window_id = 0;
    bool query = false;
    bool ok;

    if (argc == 3 && strcmp(argv[1], "query") == 0) {
        char *end = NULL;
        query_window_id = strtoull(argv[2], &end, 10);
        query = end != argv[2] && *end == '\0' && query_window_id != 0;
    }
    if (!((argc == 2 && strcmp(argv[1], "status") == 0) || query)) {
        fprintf(stderr, "usage: %s status | query <window-id>\n", argv[0]);
        return 2;
    }
    const char *override = getenv(SOCKET_OVERRIDE_ENV);
    if (override != NULL && override[0] != '\0') {
        if (strlcpy(path, override, sizeof(path)) >= sizeof(path)) {
            return 3;
        }
    } else {
        account = getpwuid(geteuid());
        if (account == NULL) {
            return 3;
        }
        if (snprintf(path, sizeof(path), SOCKET_FORMAT, account->pw_name) >=
            (int)sizeof(path)) {
            return 3;
        }
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return 3;
    }
    /* A lost payload peer must become EPIPE from send, never SIGPIPE: this
     * client is a diagnostic tool and may not die by signal mid-report. */
    int no_sigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        fprintf(stderr, "could not connect to v2 Dock payload\n");
        return 3;
    }

    for (size_t index = 0; index < sizeof(handshake.nonce); index++) {
        handshake.nonce[index] = (uint8_t)(index + 1);
    }
    ok = hs2_dock_v2_encode_handshake_request(&handshake, request) &&
         exchange(fd, &envelope, request, sizeof(request), &reply, response) &&
         reply.type == HS2_DOCK_V2_HANDSHAKE_RESPONSE &&
         hs2_dock_v2_decode_handshake_response(response, reply.payload_bytes, &accepted) &&
         accepted.error == HS2_DOCK_V2_OK &&
         accepted.session_id != 0 &&
         accepted.major == HS2_DOCK_V2_MAJOR &&
         accepted.minor == HS2_DOCK_V2_MINOR &&
         accepted.build == HS2_DOCK_V2_BUILD &&
         memcmp(accepted.nonce, handshake.nonce, sizeof(handshake.nonce)) == 0 &&
         (handshake.required_capabilities & accepted.granted_capabilities) ==
             handshake.required_capabilities &&
         (accepted.granted_capabilities & ~accepted.available_capabilities) == 0 &&
         accepted.peer_uid == geteuid() && accepted.peer_pid == getpid();
    if (!ok) {
        bool lost = peer_lost();
        close(fd);
        fprintf(stderr, lost ? "v2 payload connection lost before the handshake reply\n"
                             : "v2 handshake rejected or malformed\n");
        return 4;
    }
    if (query) {
        hs2_dock_v2_query_request query_request = { .window_id = query_window_id };
        uint8_t query_bytes[HS2_DOCK_V2_QUERY_REQUEST_BYTES];
        memcpy(query_request.nonce, handshake.nonce, sizeof(query_request.nonce));
        envelope.type = HS2_DOCK_V2_QUERY_FRAME;
        envelope.payload_bytes = HS2_DOCK_V2_QUERY_REQUEST_BYTES;
        envelope.request_id = 2;
        envelope.session_id = accepted.session_id;
        ok = hs2_dock_v2_encode_query_request(&query_request, query_bytes) &&
             exchange(fd, &envelope, query_bytes, sizeof(query_bytes), &reply, response) &&
             reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
             hs2_dock_v2_decode_frame_response(response, reply.payload_bytes, &frame) &&
             frame.error == HS2_DOCK_V2_OK;
        bool lost = peer_lost();
        close(fd);
        if (!ok) {
            fprintf(stderr, lost ? "v2 payload connection lost before the frame reply\n"
                                 : "v2 frame query rejected or malformed\n");
            return 4;
        }
        printf("window=%llu frame={x=%.3f,y=%.3f,width=%.3f,height=%.3f}\n",
               (unsigned long long)query_window_id, frame.x, frame.y, frame.width, frame.height);
        return 0;
    }
    close(fd);
    printf("protocol=2 build=%u session=%llu capabilities=0x%llx peer={uid=%u,pid=%d}\n",
           accepted.build, (unsigned long long)accepted.session_id,
           (unsigned long long)accepted.granted_capabilities,
           accepted.peer_uid, accepted.peer_pid);
    return 0;
}
