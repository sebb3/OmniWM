#include "payload_server.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

bool hs2_dock_v2_capture_peer(int fd, hs2_dock_v2_peer *peer)
{
    gid_t gid = (gid_t)-1;
    uid_t uid = (uid_t)-1;
    pid_t pid = 0;
    socklen_t length = sizeof(pid);

    if (peer == NULL || getpeereid(fd, &uid, &gid) != 0) {
        return false;
    }
#if defined(LOCAL_PEERPID)
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 &&
        length == sizeof(pid) && pid > 0) {
        peer->uid = uid;
        peer->pid = pid;
        return true;
    }
#endif
#if defined(LOCAL_PEEREPID)
    length = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEEREPID, &pid, &length) == 0 &&
        length == sizeof(pid) && pid > 0) {
        peer->uid = uid;
        peer->pid = pid;
        return true;
    }
#endif
    return false;
}

/* Bounds (or, with 0, unbounds) every blocked receive on the connection.
 * While a handshake is still pending each receive is armed with only the
 * time left until the absolute deadline below; once negotiation succeeds
 * the bound is removed so the session may idle indefinitely. */
static void set_receive_bound(int fd, long timeout_ms)
{
    struct timeval bound = {
        .tv_sec = timeout_ms / 1000,
        .tv_usec = (suseconds_t)((timeout_ms % 1000) * 1000),
    };
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &bound, sizeof(bound));
}

/* Absolute pre-handshake deadline on the monotonic clock. It is fixed once,
 * when the connection is accepted, and is never extended: a client that
 * trickles bytes to keep every individual read inside a per-receive bound
 * still crosses this instant, and the connection is dropped. A successful
 * handshake retires it entirely. */
typedef struct {
    bool active;
    struct timespec when;
} hs2_dock_handshake_deadline;

static void deadline_after(hs2_dock_handshake_deadline *deadline, long timeout_ms)
{
    (void)clock_gettime(CLOCK_MONOTONIC, &deadline->when);
    deadline->when.tv_sec += timeout_ms / 1000;
    deadline->when.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (deadline->when.tv_nsec >= 1000000000L) {
        deadline->when.tv_sec += 1;
        deadline->when.tv_nsec -= 1000000000L;
    }
    deadline->active = true;
}

/* Milliseconds from now until the deadline; an expired deadline reads 0. */
static long deadline_remaining_ms(const hs2_dock_handshake_deadline *deadline)
{
    struct timespec now;
    (void)clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t remaining = (int64_t)(deadline->when.tv_sec - now.tv_sec) * 1000 +
                        (deadline->when.tv_nsec - now.tv_nsec) / 1000000;
    return remaining < 0 ? 0 : (long)remaining;
}

static bool send_all(int fd, const void *bytes, size_t count)
{
    const uint8_t *cursor = bytes;
    while (count > 0) {
        ssize_t result = send(fd, cursor, count, 0);
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

/* Receives exactly count bytes. While the handshake deadline is active every
 * recv is armed with only the time remaining until that fixed instant, so no
 * pattern of partial deliveries -- not even one byte at a time -- can keep
 * the pre-handshake phase alive past it; an expired slice (EAGAIN) fails the
 * read. Once the deadline is retired the receives are unbounded. */
static bool receive(int fd, void *bytes, size_t count, const hs2_dock_handshake_deadline *deadline)
{
    uint8_t *cursor = bytes;
    while (count > 0) {
        if (deadline->active) {
            long remaining = deadline_remaining_ms(deadline);
            if (remaining <= 0) {
                return false;
            }
            set_receive_bound(fd, remaining);
        }
        ssize_t result = recv(fd, cursor, count, 0);
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

static bool write_encoded(int fd,
                          const hs2_dock_v2_envelope *envelope,
                          const uint8_t *payload)
{
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    return hs2_dock_v2_encode_envelope(envelope, header) &&
           send_all(fd, header, sizeof(header)) &&
           send_all(fd, payload, envelope->payload_bytes);
}

static bool write_response(int fd,
                           uint64_t request_id,
                           uint64_t session_id,
                           uint16_t error,
                           uint64_t value)
{
    uint8_t payload[HS2_DOCK_V2_RESPONSE_BYTES];
    hs2_dock_v2_response response = { .error = error, .value = value };
    hs2_dock_v2_envelope envelope = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = HS2_DOCK_V2_RESPONSE,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = HS2_DOCK_V2_RESPONSE_BYTES,
        .request_id = request_id,
        .session_id = session_id,
    };
    return hs2_dock_v2_encode_response(&response, payload) &&
           write_encoded(fd, &envelope, payload);
}

static bool write_operation_reply(int fd,
                                  const hs2_dock_v2_envelope *request,
                                  const hs2_dock_operation_reply *reply)
{
    hs2_dock_v2_envelope envelope = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = reply->message_type,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = reply->payload_bytes,
        .request_id = request->request_id,
        .session_id = request->session_id,
    };
    return write_encoded(fd, &envelope, reply->payload);
}

static bool transition_peer_disconnected(void *context)
{
    int fd = *(const int *)context;
    uint8_t byte;
    ssize_t result = recv(fd, &byte, sizeof(byte), MSG_PEEK | MSG_DONTWAIT);
    if (result == 0) {
        return true;
    }
    if (result > 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return false;
    }
    return true;
}

static bool handle_handshake(int fd,
                             hs2_dock_v2_server *server,
                             const hs2_dock_v2_peer *peer,
                             const hs2_dock_v2_envelope *envelope,
                             const uint8_t *payload,
                             uint64_t *session_id,
                             uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES])
{
    hs2_dock_v2_handshake_request request;
    hs2_dock_v2_handshake_response response;
    uint8_t response_payload[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES];

    if (envelope->session_id != 0 ||
        !hs2_dock_v2_decode_handshake_request(payload, envelope->payload_bytes, &request)) {
        return write_response(fd, envelope->request_id, 0, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0);
    }

    uint16_t result = hs2_dock_v2_handshake(server, peer, &request, &response);
    response.error = result;
    hs2_dock_v2_envelope reply = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = HS2_DOCK_V2_HANDSHAKE_RESPONSE,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES,
        .request_id = envelope->request_id,
        .session_id = response.session_id,
    };
    if (!hs2_dock_v2_encode_handshake_response(&response, response_payload) ||
        !write_encoded(fd, &reply, response_payload)) {
        return false;
    }
    if (result != HS2_DOCK_V2_OK) {
        return false;
    }
    *session_id = response.session_id;
    memcpy(nonce, request.nonce, HS2_DOCK_V2_NONCE_BYTES);
    return true;
}

bool hs2_dock_v2_serve_connection(int fd,
                                  hs2_dock_v2_server *server,
                                  const hs2_dock_skylight_api *api,
                                  const hs2_dock_v2_peer *peer,
                                  const volatile bool *stopping,
                                  long handshake_timeout_ms)
{
    hs2_dock_skylight_api connection_api = *api;
    connection_api.transition_should_cancel = transition_peer_disconnected;
    connection_api.transition_context = &fd;
    uint64_t session_id = 0;
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES] = {0};
    hs2_dock_handshake_deadline deadline = {0};
    bool connected = true;

    if (handshake_timeout_ms > 0) {
        deadline_after(&deadline, handshake_timeout_ms);
    }

    while (connected && (stopping == NULL || !*stopping)) {
        uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
        uint8_t payload[HS2_DOCK_V2_MAX_PAYLOAD_BYTES];
        hs2_dock_v2_envelope envelope;

        if (!receive(fd, header, sizeof(header), &deadline) ||
            !hs2_dock_v2_decode_envelope(header, sizeof(header), &envelope)) {
            break;
        }
        /* Active-operation bound: reject a payload the current v2 message set
         * can never carry before any byte of it is read, so the fixed-size
         * buffer below is never overrun or starved waiting for body bytes
         * that a well-formed peer would have sent. */
        if (envelope.payload_bytes > HS2_DOCK_V2_MAX_PAYLOAD_BYTES) {
            (void)write_response(fd, envelope.request_id, envelope.session_id,
                                 HS2_DOCK_V2_UNSUPPORTED_MESSAGE, envelope.payload_bytes);
            break;
        }
        if (!receive(fd, payload, envelope.payload_bytes, &deadline)) {
            break;
        }
        if (envelope.type == HS2_DOCK_V2_HANDSHAKE_REQUEST) {
            if (session_id != 0) {
                /* One handshake per connection: a second handshake is a
                 * protocol violation, not a renegotiation. Reply, then close;
                 * the loop exit below still disconnects the live session and
                 * runs its lease cleanup. */
                (void)write_response(fd, envelope.request_id, session_id,
                                     HS2_DOCK_V2_SESSION_REJECTED, session_id);
                break;
            }
            connected = handle_handshake(fd, server, peer, &envelope, payload, &session_id, nonce);
            if (connected) {
                /* Negotiation succeeded: retire the handshake deadline and
                 * remove every receive bound, so the established session may
                 * idle indefinitely. Only a peer disconnect, an I/O error, or
                 * the unload shutdown() (or the stopping flag) ends the wait
                 * from here on. */
                deadline.active = false;
                set_receive_bound(fd, 0);
            }
            continue;
        }
        if (envelope.type == HS2_DOCK_V2_HANDSHAKE_RESPONSE ||
            envelope.type == HS2_DOCK_V2_RESPONSE ||
            envelope.type == HS2_DOCK_V2_FRAME_RESPONSE) {
            /* Server-to-client message types are never valid from a client. */
            (void)write_response(fd, envelope.request_id, envelope.session_id,
                                 HS2_DOCK_V2_UNSUPPORTED_MESSAGE, envelope.type);
            break;
        }

        hs2_dock_operation_reply operation_reply;
        if (envelope.type == HS2_DOCK_V2_QUERY_FRAME || envelope.type == HS2_DOCK_V2_MOVE_REAL ||
            envelope.type == HS2_DOCK_V2_SET_TRANSFORM || envelope.type == HS2_DOCK_V2_SET_WARP ||
            envelope.type == HS2_DOCK_V2_CLEAR_WARP ||
            envelope.type == HS2_DOCK_V2_WORKSPACE_TRANSITION) {
            if (!hs2_dock_dispatch_operation(&connection_api, server, peer, &envelope, payload,
                                             &operation_reply) ||
                !write_operation_reply(fd, &envelope, &operation_reply)) {
                break;
            }
            continue;
        }

        hs2_dock_v2_lease_request request;
        if (session_id == 0 || envelope.session_id != session_id ||
            !hs2_dock_v2_decode_lease_request(payload, envelope.payload_bytes, &request)) {
            (void)write_response(fd, envelope.request_id, envelope.session_id,
                                 HS2_DOCK_V2_SESSION_REJECTED, 0);
            break;
        }
        uint16_t result = hs2_dock_v2_handle_lease(server, peer, &envelope, &request);
        if (!write_response(fd, envelope.request_id, session_id, result, request.lease_id)) {
            break;
        }
    }

    if (session_id != 0) {
        (void)hs2_dock_v2_disconnect(server, peer, session_id, nonce);
    }
    return connected;
}
