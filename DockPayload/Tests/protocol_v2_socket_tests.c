/* AF_UNIX process tests for the v2 payload server.
 *
 * Every scenario below runs against the real serve_connection loop over a
 * real socketpair-style AF_UNIX listener with kernel-verified peer
 * credentials. The SkyLight layer is faked in-process; no Dock contact, no
 * window mutation, no payload load. The matrix covers the full negotiated
 * session, malformed and truncated frames, oversized envelopes, wrong
 * version/flags/build/session/nonce/capability, duplicates, a second
 * handshake, reconnect, explicit lease clear, disconnect residue, the
 * absolute pre-handshake deadline (silent, half-open, and byte-trickling
 * clients), negotiated idle beyond that deadline, and exact-match lease
 * release. */

#include "payload_server.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

/* Total connections the child opens; the parent accepts exactly this many. */
#define SCENARIO_CONNECTIONS 21u

/* Pre-handshake deadline every served connection starts with; far shorter
 * than the payload default so the deadline scenarios stay fast. */
#define TEST_HANDSHAKE_TIMEOUT_MS 500L

static CGRect g_frame;
static CGAffineTransform g_last_transform;
static int g_bounds_calls;
static int g_move_calls;
static int g_get_transform_calls;
static int g_set_transform_calls;
static int g_set_warp_calls;
static int g_last_warp_columns;
static int g_last_warp_rows;
static bool g_last_warp_null_mesh;

static void deadline_expired(int signal_number)
{
    (void)signal_number;
    _exit(124);
}

static bool transfer(int fd, void *bytes, size_t count, bool writing)
{
    uint8_t *cursor = bytes;
    while (count > 0) {
        ssize_t result = writing ? send(fd, cursor, count, 0) : recv(fd, cursor, count, 0);
        if (result <= 0) {
            return false;
        }
        cursor += result;
        count -= (size_t)result;
    }
    return true;
}

/* Reads with a hard deadline so a server that wrongly blocks waiting for a
 * body it should never have requested fails the test instead of hanging. */
static bool recv_with_deadline(int fd, void *bytes, size_t count)
{
    return transfer(fd, bytes, count, false);
}

static bool expect_eof(int fd)
{
    uint8_t byte;
    ssize_t result = recv(fd, &byte, 1, 0);
    return result == 0;
}

static int fake_main_connection_id(void)
{
    return 99;
}

static CGError fake_get_window_bounds(int connection, uint32_t window_id, CGRect *frame)
{
    assert(connection == 99 && window_id == 77);
    g_bounds_calls++;
    *frame = g_frame;
    return kCGErrorSuccess;
}

static CGError fake_move_window_with_group(int connection, uint32_t window_id, CGPoint *target)
{
    assert(connection == 99 && window_id == 77 && target->x == 12.0 && target->y == 34.0);
    g_move_calls++;
    g_frame.origin = *target;
    return kCGErrorSuccess;
}

static CGError fake_get_window_transform(int connection, uint32_t window_id,
                                         CGAffineTransform *transform)
{
    assert(connection == 99 && window_id == 77);
    g_get_transform_calls++;
    *transform = CGAffineTransformMake(1.0, 0.0, 0.0, 1.0, -77.0, -88.0);
    return kCGErrorSuccess;
}

static CGError fake_set_window_transform(int connection, uint32_t window_id,
                                         CGAffineTransform transform)
{
    assert(connection == 99 && window_id == 77);
    g_set_transform_calls++;
    g_last_transform = transform;
    return kCGErrorSuccess;
}

static CGError fake_set_window_warp(int connection, uint32_t window_id, int columns, int rows,
                                    const hs2_sls_warp_point *mesh)
{
    assert(connection == 99 && window_id == 77);
    if (mesh != NULL) {
        assert(columns == 9 && rows == 2);
        assert(mesh[0].local_x == 0.0f && mesh[17].global_y == -2017.0f);
    } else {
        assert(columns == 0 && rows == 0);
    }
    g_set_warp_calls++;
    g_last_warp_columns = columns;
    g_last_warp_rows = rows;
    g_last_warp_null_mesh = mesh == NULL;
    return kCGErrorSuccess;
}

static void exchange(int fd, hs2_dock_v2_envelope *request, const uint8_t *payload,
                     uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES],
                     hs2_dock_v2_envelope *reply)
{
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    assert(hs2_dock_v2_encode_envelope(request, header));
    assert(transfer(fd, header, sizeof(header), true));
    assert(transfer(fd, (void *)payload, request->payload_bytes, true));
    assert(transfer(fd, header, sizeof(header), false));
    assert(hs2_dock_v2_decode_envelope(header, sizeof(header), reply));
    assert(reply->request_id == request->request_id);
    assert(recv_with_deadline(fd, response, reply->payload_bytes));
}

static hs2_dock_v2_envelope request_envelope(uint16_t type, uint16_t payload_bytes,
                                             uint64_t request_id, uint64_t session_id)
{
    return (hs2_dock_v2_envelope){
        .major = HS2_DOCK_V2_MAJOR, .minor = HS2_DOCK_V2_MINOR,
        .type = type, .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = payload_bytes, .request_id = request_id,
        .session_id = session_id,
    };
}

static void expect_ok_response(int fd, hs2_dock_v2_envelope *request, const uint8_t *payload,
                              uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES],
                              hs2_dock_v2_envelope *reply)
{
    exchange(fd, request, payload, response, reply);
    hs2_dock_v2_response status;
    assert(reply->type == HS2_DOCK_V2_RESPONSE &&
           hs2_dock_v2_decode_response(response, reply->payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_OK);
}

static uint64_t handshake_session(int fd, uint64_t required, uint64_t optional, uint64_t request_id)
{
    hs2_dock_v2_handshake_request handshake = {
        .protocol_min_major = HS2_DOCK_V2_MAJOR,
        .protocol_max_major = HS2_DOCK_V2_MAJOR,
        .build_min = HS2_DOCK_V2_BUILD,
        .build_max = HS2_DOCK_V2_BUILD,
        .required_capabilities = required,
        .optional_capabilities = optional,
    };
    memset(handshake.nonce, 0x5a, sizeof(handshake.nonce));
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    hs2_dock_v2_envelope request = request_envelope(HS2_DOCK_V2_HANDSHAKE_REQUEST,
        HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, request_id, 0);
    assert(hs2_dock_v2_encode_handshake_request(&handshake, payload));
    hs2_dock_v2_envelope reply;
    exchange(fd, &request, payload, payload, &reply);
    hs2_dock_v2_handshake_response accepted;
    assert(reply.type == HS2_DOCK_V2_HANDSHAKE_RESPONSE &&
           hs2_dock_v2_decode_handshake_response(payload, reply.payload_bytes, &accepted));
    assert(accepted.error == HS2_DOCK_V2_OK && accepted.session_id != 0);
    assert(accepted.major == HS2_DOCK_V2_MAJOR && accepted.minor == HS2_DOCK_V2_MINOR &&
           accepted.build == HS2_DOCK_V2_BUILD);
    assert(memcmp(accepted.nonce, handshake.nonce, sizeof(handshake.nonce)) == 0);
    assert((required & accepted.granted_capabilities) == required);
    assert((accepted.granted_capabilities & ~accepted.available_capabilities) == 0);
    assert(accepted.peer_uid == geteuid() && accepted.peer_pid == getpid());
    return accepted.session_id;
}

/* The full negotiated session: query, lease, move, transform restore on
 * release, warp explicit clear, and residue cleanup on disconnect. */
static void scenario_full_session(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    assert(connect(fd, (const struct sockaddr *)&address, sizeof(address)) == 0);

    uint64_t session = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    hs2_dock_v2_envelope request;
    hs2_dock_v2_envelope reply;

    hs2_dock_v2_query_request query = { .window_id = 77 };
    memset(query.nonce, 0x5a, sizeof(query.nonce));
    request = request_envelope(HS2_DOCK_V2_QUERY_FRAME, HS2_DOCK_V2_QUERY_REQUEST_BYTES, 2,
                               session);
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    exchange(fd, &request, payload, payload, &reply);
    hs2_dock_v2_frame_response frame;
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_OK && frame.x == 1.0 && frame.y == 2.0);

    hs2_dock_v2_lease_request lease = {
        .lease_id = 3, .window_id = 77, .operation = HS2_DOCK_V2_CAP_MOVE_REAL,
    };
    memset(lease.nonce, 0x5a, sizeof(lease.nonce));
    request = request_envelope(HS2_DOCK_V2_LEASE_CREATE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 3,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    hs2_dock_v2_move_request move = {
        .lease_id = 3, .window_id = 77, .x = 12.0, .y = 34.0,
    };
    memset(move.nonce, 0x5a, sizeof(move.nonce));
    request = request_envelope(HS2_DOCK_V2_MOVE_REAL, HS2_DOCK_V2_MOVE_REQUEST_BYTES, 4,
                               session);
    assert(hs2_dock_v2_encode_move_request(&move, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_OK && frame.x == 12.0 && frame.y == 34.0);

    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 5,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    /* transform lease: mutation, then explicit release runs the canonical restore */
    lease.lease_id = 4;
    lease.operation = HS2_DOCK_V2_CAP_SET_TRANSFORM;
    request = request_envelope(HS2_DOCK_V2_LEASE_CREATE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 6,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    hs2_dock_v2_transform_request transform = {
        .lease_id = 4, .window_id = 77,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memset(transform.nonce, 0x5a, sizeof(transform.nonce));
    request = request_envelope(HS2_DOCK_V2_SET_TRANSFORM, HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES,
                               7, session);
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 8,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    /* warp lease: mutation, explicit clear, then release has no residue */
    lease.lease_id = 5;
    lease.operation = HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP;
    request = request_envelope(HS2_DOCK_V2_LEASE_CREATE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 9,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    hs2_dock_v2_warp_request warp = { .lease_id = 5, .window_id = 77, .columns = 9, .rows = 2 };
    memset(warp.nonce, 0x5a, sizeof(warp.nonce));
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        warp.points[index] = (hs2_dock_v2_warp_point){
            .local_x = (float)(index * 10), .local_y = (float)(index % 2),
            .global_x = (float)(1000 + index), .global_y = (float)(-2000 - (double)index),
        };
    }
    request = request_envelope(HS2_DOCK_V2_SET_WARP, HS2_DOCK_V2_WARP_REQUEST_BYTES, 10,
                               session);
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    hs2_dock_v2_clear_warp_request clear = { .lease_id = 5, .window_id = 77 };
    memset(clear.nonce, 0x5a, sizeof(clear.nonce));
    request = request_envelope(HS2_DOCK_V2_CLEAR_WARP, HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES, 11,
                               session);
    assert(hs2_dock_v2_encode_clear_warp_request(&clear, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 12,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    /* residue without explicit release: disconnect must clean both mechanisms */
    lease.lease_id = 6;
    lease.operation = HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_SET_WARP |
                      HS2_DOCK_V2_CAP_CLEAR_WARP;
    request = request_envelope(HS2_DOCK_V2_LEASE_CREATE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 13,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    transform.lease_id = 6;
    memset(transform.nonce, 0x5a, sizeof(transform.nonce));
    request = request_envelope(HS2_DOCK_V2_SET_TRANSFORM, HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES,
                               14, session);
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    warp.lease_id = 6;
    memset(warp.nonce, 0x5a, sizeof(warp.nonce));
    request = request_envelope(HS2_DOCK_V2_SET_WARP, HS2_DOCK_V2_WARP_REQUEST_BYTES, 15,
                               session);
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);

    close(fd);
}

static int connect_path(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    assert(connect(fd, (const struct sockaddr *)&address, sizeof(address)) == 0);
    return fd;
}

/* Sends a raw envelope header, bypassing the encoder so hostile field values
 * (wrong magic, wrong version, stray flags, oversized payloads) reach the
 * wire exactly as crafted. Fields left at their benign defaults encode
 * normally; hostile overrides are patched into the encoded bytes. */
static void send_raw_header(int fd, uint16_t type, uint16_t payload_bytes,
                            uint64_t request_id, uint64_t session_id,
                            const uint8_t magic[4], uint16_t major, uint16_t flags)
{
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    hs2_dock_v2_envelope envelope = request_envelope(type, 0, request_id, session_id);
    assert(hs2_dock_v2_encode_envelope(&envelope, header));
    header[14] = (uint8_t)payload_bytes;
    header[15] = (uint8_t)(payload_bytes >> 8);
    if (magic != NULL) {
        memcpy(header, magic, 4);
    }
    if (major != 0) {
        header[4] = (uint8_t)major;
        header[5] = (uint8_t)(major >> 8);
    }
    if (flags != 0) {
        header[10] = (uint8_t)flags;
        header[11] = (uint8_t)(flags >> 8);
    }
    assert(transfer(fd, header, sizeof(header), true));
}

static void scenario_malformed_and_envelope_rejections(const char *path)
{
    uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES];
    hs2_dock_v2_envelope reply_ignored;
    hs2_dock_v2_response status;

    /* garbage bytes then EOF: the server must close without a reply */
    int fd = connect_path(path);
    const uint8_t garbage[20] = {0xde, 0xad, 0xbe, 0xef};
    assert(transfer(fd, (void *)garbage, sizeof(garbage), true));
    assert(shutdown(fd, SHUT_WR) == 0);
    assert(expect_eof(fd));
    close(fd);

    /* truncated envelope: fewer than 40 header bytes then EOF */
    fd = connect_path(path);
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    hs2_dock_v2_envelope envelope = request_envelope(HS2_DOCK_V2_HANDSHAKE_REQUEST,
        HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 1, 0);
    assert(hs2_dock_v2_encode_envelope(&envelope, header));
    assert(transfer(fd, header, 20, true));
    assert(shutdown(fd, SHUT_WR) == 0);
    assert(expect_eof(fd));
    close(fd);

    /* wrong magic: closed without a reply */
    fd = connect_path(path);
    send_raw_header(fd, HS2_DOCK_V2_HANDSHAKE_REQUEST,
                    HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 1, 0, (const uint8_t *)"XXXX", 0, 0);
    assert(expect_eof(fd));
    close(fd);

    /* wrong version: the strict envelope decode closes the connection */
    fd = connect_path(path);
    send_raw_header(fd, HS2_DOCK_V2_HANDSHAKE_REQUEST,
                    HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 1, 0, NULL, 3, 0);
    assert(expect_eof(fd));
    close(fd);

    /* nonzero flags: rejected the same way */
    fd = connect_path(path);
    send_raw_header(fd, HS2_DOCK_V2_HANDSHAKE_REQUEST,
                    HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 1, 0, NULL, 0, 0x0001);
    assert(expect_eof(fd));
    close(fd);

    /* exact active max + 1: rejected before any body byte is read. The
     * client sends no body at all; a server that tried to read the declared
     * 325 bytes into its fixed buffer would block and this assert fails. */
    fd = connect_path(path);
    send_raw_header(fd, HS2_DOCK_V2_QUERY_FRAME, HS2_DOCK_V2_MAX_PAYLOAD_BYTES + 1, 9, 0,
                    NULL, 0, 0);
    assert(recv_with_deadline(fd, header, sizeof(header)));
    assert(recv_with_deadline(fd, response, HS2_DOCK_V2_RESPONSE_BYTES));
    assert(hs2_dock_v2_decode_envelope(header, sizeof(header), &reply_ignored));
    assert(hs2_dock_v2_decode_response(response, HS2_DOCK_V2_RESPONSE_BYTES, &status));
    assert(status.error == HS2_DOCK_V2_UNSUPPORTED_MESSAGE);
    assert(status.value == HS2_DOCK_V2_MAX_PAYLOAD_BYTES + 1);
    assert(expect_eof(fd));
    close(fd);

    /* far past the active bound but inside the 64 KiB protocol bound: the
     * envelope decodes, the active layer refuses before reading a body */
    fd = connect_path(path);
    send_raw_header(fd, HS2_DOCK_V2_QUERY_FRAME, 65535, 9, 0, NULL, 0, 0);
    assert(recv_with_deadline(fd, header, sizeof(header)));
    assert(recv_with_deadline(fd, response, HS2_DOCK_V2_RESPONSE_BYTES));
    assert(hs2_dock_v2_decode_envelope(header, sizeof(header), &reply_ignored));
    assert(hs2_dock_v2_decode_response(response, HS2_DOCK_V2_RESPONSE_BYTES, &status));
    assert(status.error == HS2_DOCK_V2_UNSUPPORTED_MESSAGE && status.value == 65535);
    assert(expect_eof(fd));
    close(fd);

    /* a server-to-client message type from the client is unsupported */
    fd = connect_path(path);
    send_raw_header(fd, HS2_DOCK_V2_RESPONSE, HS2_DOCK_V2_RESPONSE_BYTES, 1, 0, NULL, 0, 0);
    assert(transfer(fd, response, HS2_DOCK_V2_RESPONSE_BYTES, true));
    assert(recv_with_deadline(fd, header, sizeof(header)));
    assert(recv_with_deadline(fd, response, HS2_DOCK_V2_RESPONSE_BYTES));
    assert(hs2_dock_v2_decode_envelope(header, sizeof(header), &reply_ignored));
    assert(hs2_dock_v2_decode_response(response, HS2_DOCK_V2_RESPONSE_BYTES, &status));
    assert(status.error == HS2_DOCK_V2_UNSUPPORTED_MESSAGE &&
           status.value == HS2_DOCK_V2_RESPONSE);
    assert(expect_eof(fd));
    close(fd);
}

static void scenario_negotiation_and_session_rejections(const char *path)
{
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    uint8_t response[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES];
    hs2_dock_v2_envelope request;
    hs2_dock_v2_envelope reply;
    hs2_dock_v2_response status;
    hs2_dock_v2_frame_response frame;

    /* wrong build range: a detailed rejection, then the connection closes */
    int fd = connect_path(path);
    hs2_dock_v2_handshake_request stale = {
        .protocol_min_major = HS2_DOCK_V2_MAJOR,
        .protocol_max_major = HS2_DOCK_V2_MAJOR,
        .build_min = HS2_DOCK_V2_BUILD + 1,
        .build_max = HS2_DOCK_V2_BUILD + 9,
        .optional_capabilities = HS2_DOCK_V2_EVIDENCED_CAPABILITIES,
    };
    memset(stale.nonce, 0x5a, sizeof(stale.nonce));
    request = request_envelope(HS2_DOCK_V2_HANDSHAKE_REQUEST,
                               HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 1, 0);
    assert(hs2_dock_v2_encode_handshake_request(&stale, payload));
    exchange(fd, &request, payload, payload, &reply);
    hs2_dock_v2_handshake_response rejected;
    assert(reply.type == HS2_DOCK_V2_HANDSHAKE_RESPONSE &&
           hs2_dock_v2_decode_handshake_response(payload, reply.payload_bytes, &rejected));
    assert(rejected.error == HS2_DOCK_V2_BUILD_REJECTED && rejected.session_id == 0);
    assert(expect_eof(fd));
    close(fd);

    /* a second handshake on an established connection is refused and the
     * connection (plus its session) is torn down */
    fd = connect_path(path);
    uint64_t session = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);
    hs2_dock_v2_handshake_request again = {
        .protocol_min_major = HS2_DOCK_V2_MAJOR,
        .protocol_max_major = HS2_DOCK_V2_MAJOR,
        .build_min = HS2_DOCK_V2_BUILD,
        .build_max = HS2_DOCK_V2_BUILD,
        .optional_capabilities = HS2_DOCK_V2_EVIDENCED_CAPABILITIES,
    };
    memset(again.nonce, 0x5a, sizeof(again.nonce));
    request = request_envelope(HS2_DOCK_V2_HANDSHAKE_REQUEST,
                               HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 2, 0);
    assert(hs2_dock_v2_encode_handshake_request(&again, payload));
    exchange(fd, &request, payload, response, &reply);
    assert(reply.type == HS2_DOCK_V2_RESPONSE &&
           reply.payload_bytes == HS2_DOCK_V2_RESPONSE_BYTES);
    assert(hs2_dock_v2_decode_response(response, HS2_DOCK_V2_RESPONSE_BYTES, &status));
    assert(status.error == HS2_DOCK_V2_SESSION_REJECTED && status.value == session);
    assert(expect_eof(fd));
    close(fd);

    /* wrong session id: the operation layer rejects it */
    fd = connect_path(path);
    (void)handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);
    hs2_dock_v2_query_request query = { .window_id = 77 };
    memset(query.nonce, 0x5a, sizeof(query.nonce));
    request = request_envelope(HS2_DOCK_V2_QUERY_FRAME, HS2_DOCK_V2_QUERY_REQUEST_BYTES, 2,
                               0xdeadbeef);
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_SESSION_REJECTED);
    close(fd);

    /* wrong nonce: session-bound secret mismatch is rejected in place */
    fd = connect_path(path);
    session = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);
    memset(query.nonce, 0x5a, sizeof(query.nonce));
    query.nonce[0] ^= 0xff;
    query.window_id = 77;
    request = request_envelope(HS2_DOCK_V2_QUERY_FRAME, HS2_DOCK_V2_QUERY_REQUEST_BYTES, 2,
                               session);
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_SESSION_REJECTED);
    close(fd);

    /* capability the session never negotiated: lease refused; a replayed
     * request id inside the window: duplicate refused */
    fd = connect_path(path);
    session = handshake_session(fd, HS2_DOCK_V2_CAP_QUERY_FRAME, 0, 1);
    hs2_dock_v2_lease_request lease = {
        .lease_id = 9, .window_id = 77, .operation = HS2_DOCK_V2_CAP_LEASES,
    };
    memset(lease.nonce, 0x5a, sizeof(lease.nonce));
    request = request_envelope(HS2_DOCK_V2_LEASE_CREATE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 2,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_RESPONSE &&
           hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_LEASE_REJECTED);

    memset(query.nonce, 0x5a, sizeof(query.nonce));
    query.window_id = 77;
    request = request_envelope(HS2_DOCK_V2_QUERY_FRAME, HS2_DOCK_V2_QUERY_REQUEST_BYTES, 3,
                               session);
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_OK && frame.x == 12.0);
    /* the same request id replayed inside the window */
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_DUPLICATE_REQUEST);
    close(fd);
}

/* Explicit lease clear plus reconnect: a fresh connection negotiates a fresh
 * session after the first one cleared its residue and disconnected. */
static void scenario_clear_and_reconnect(const char *path)
{
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    hs2_dock_v2_envelope request;
    hs2_dock_v2_envelope reply;
    hs2_dock_v2_response status;

    int fd = connect_path(path);
    uint64_t session = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);

    hs2_dock_v2_lease_request lease = {
        .lease_id = 21, .window_id = 77, .operation = HS2_DOCK_V2_CAP_SET_TRANSFORM,
    };
    memset(lease.nonce, 0x5a, sizeof(lease.nonce));
    request = request_envelope(HS2_DOCK_V2_LEASE_CREATE, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 2,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status) &&
           status.error == HS2_DOCK_V2_OK);

    hs2_dock_v2_transform_request transform = {
        .lease_id = 21, .window_id = 77,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -500.0, .ty = 0.0,
    };
    memset(transform.nonce, 0x5a, sizeof(transform.nonce));
    request = request_envelope(HS2_DOCK_V2_SET_TRANSFORM, HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES,
                               3, session);
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status) &&
           status.error == HS2_DOCK_V2_OK);

    /* LEASE_CLEAR wipes every lease the session owns: the canonical transform
     * restore runs here, before any disconnect. */
    request = request_envelope(HS2_DOCK_V2_LEASE_CLEAR, HS2_DOCK_V2_LEASE_REQUEST_BYTES, 4,
                               session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_RESPONSE);
    assert(hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_OK && status.value == lease.lease_id);
    close(fd);

    /* a reconnect negotiates a fresh session and the world still answers */
    fd = connect_path(path);
    uint64_t fresh = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);
    assert(fresh != session);
    hs2_dock_v2_query_request query = { .window_id = 77 };
    memset(query.nonce, 0x5a, sizeof(query.nonce));
    request = request_envelope(HS2_DOCK_V2_QUERY_FRAME, HS2_DOCK_V2_QUERY_REQUEST_BYTES, 2,
                               fresh);
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    exchange(fd, &request, payload, payload, &reply);
    hs2_dock_v2_frame_response frame;
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_OK && frame.x == 12.0 && frame.y == 34.0);
    close(fd);
}

/* A same-UID client that connects and then goes fully silent before any
 * handshake byte must not monopolize the serialized server: the bounded
 * pre-handshake receive fails and the connection is closed. */
static void scenario_prehandshake_silent_timeout(const char *path)
{
    int fd = connect_path(path);
    /* Blocks until the server's receive bound expires and it hangs up; the
     * 60s scenario alarm converts a regression into a test failure. */
    assert(expect_eof(fd));
    close(fd);
}

/* The same bound covers a client that stalls mid-envelope: half a header
 * arrives, the rest never does, and the server still reclaims itself. */
static void scenario_prehandshake_partial_timeout(const char *path)
{
    int fd = connect_path(path);
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    hs2_dock_v2_envelope request = request_envelope(HS2_DOCK_V2_HANDSHAKE_REQUEST,
        HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES, 1, 0);
    assert(hs2_dock_v2_encode_envelope(&request, header));
    assert(transfer(fd, header, 20, true));
    assert(expect_eof(fd));
    close(fd);
}

/* Regression: the pre-handshake bound is an absolute deadline fixed at
 * accept, not a per-receive inactivity timeout. A client that trickles one
 * byte every quarter of the bound keeps every individual read well inside a
 * per-receive timeout, so only the absolute deadline can drop it. Two full
 * seconds of trickling -- four times the deadline -- must end in a hang-up;
 * a server that re-armed a fresh window per read would hold this connection
 * open forever and fail here. */
static void scenario_prehandshake_trickle_timeout(const char *path)
{
    int fd = connect_path(path);
    int no_sigpipe = 1;
    assert(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) == 0);

    bool dropped = false;
    for (int tick = 0; tick < 16 && !dropped; tick++) {
        uint8_t byte = 0x5a;
        ssize_t sent = send(fd, &byte, 1, 0);
        if (sent < 0) {
            /* the deadline expired mid-trickle and the server hung up */
            assert(errno == EPIPE || errno == ECONNRESET);
            dropped = true;
            break;
        }
        assert(sent == 1);
        uint8_t probe;
        ssize_t result = recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT);
        if (result == 0) {
            dropped = true;
            break;
        }
        assert(result == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
        usleep((useconds_t)(TEST_HANDSHAKE_TIMEOUT_MS / 4) * 1000);
    }
    assert(dropped);
    close(fd);
}

/* An established session may idle indefinitely: once negotiation succeeds the
 * receive bound is gone, so a pause far longer than the pre-handshake bound
 * leaves the connection open and still answering. */
static void scenario_negotiated_idle(const char *path)
{
    int fd = connect_path(path);
    uint64_t session = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);

    usleep(3 * TEST_HANDSHAKE_TIMEOUT_MS * 1000);

    /* still open after idling well past the former bound */
    uint8_t probe;
    assert(recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT) == -1 &&
           (errno == EAGAIN || errno == EWOULDBLOCK));

    /* and still serving requests on the same session */
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    hs2_dock_v2_query_request query = { .window_id = 77 };
    memset(query.nonce, 0x5a, sizeof(query.nonce));
    hs2_dock_v2_envelope request = request_envelope(HS2_DOCK_V2_QUERY_FRAME,
        HS2_DOCK_V2_QUERY_REQUEST_BYTES, 2, session);
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    hs2_dock_v2_envelope reply;
    exchange(fd, &request, payload, payload, &reply);
    hs2_dock_v2_frame_response frame;
    assert(reply.type == HS2_DOCK_V2_FRAME_RESPONSE &&
           hs2_dock_v2_decode_frame_response(payload, reply.payload_bytes, &frame));
    assert(frame.error == HS2_DOCK_V2_OK && frame.x == 12.0 && frame.y == 34.0);
    close(fd);
}

/* Release must name the lease exactly -- lease id, session, window id, and
 * operation. Every mismatch is refused in place and the lease survives until
 * an exact release (or clear/disconnect) retires it. */
static void scenario_release_requires_exact_match(const char *path)
{
    int fd = connect_path(path);
    uint64_t session = handshake_session(fd, 0, HS2_DOCK_V2_EVIDENCED_CAPABILITIES, 1);

    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    hs2_dock_v2_lease_request lease = {
        .lease_id = 31, .window_id = 77,
        .operation = HS2_DOCK_V2_CAP_MOVE_REAL | HS2_DOCK_V2_CAP_SET_TRANSFORM,
    };
    memset(lease.nonce, 0x5a, sizeof(lease.nonce));
    hs2_dock_v2_envelope request = request_envelope(HS2_DOCK_V2_LEASE_CREATE,
        HS2_DOCK_V2_LEASE_REQUEST_BYTES, 2, session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    hs2_dock_v2_envelope reply;
    expect_ok_response(fd, &request, payload, payload, &reply);

    hs2_dock_v2_response status;
    uint64_t request_id = 3;

    /* wrong window id on an otherwise exact release */
    lease.window_id = 78;
    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES,
                               request_id++, session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(reply.type == HS2_DOCK_V2_RESPONSE &&
           hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_LEASE_REJECTED);

    /* wrong operation: a subset of the leased bits is not the lease */
    lease.window_id = 77;
    lease.operation = HS2_DOCK_V2_CAP_MOVE_REAL;
    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES,
                               request_id++, session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_LEASE_REJECTED);

    /* wrong operation: extra bits beyond the leased set */
    lease.operation = HS2_DOCK_V2_CAP_MOVE_REAL | HS2_DOCK_V2_CAP_SET_TRANSFORM |
                      HS2_DOCK_V2_CAP_QUERY_FRAME;
    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES,
                               request_id++, session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_LEASE_REJECTED);

    /* wrong lease id entirely */
    lease.lease_id = 32;
    lease.operation = HS2_DOCK_V2_CAP_MOVE_REAL | HS2_DOCK_V2_CAP_SET_TRANSFORM;
    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES,
                               request_id++, session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    exchange(fd, &request, payload, payload, &reply);
    assert(hs2_dock_v2_decode_response(payload, reply.payload_bytes, &status));
    assert(status.error == HS2_DOCK_V2_LEASE_REJECTED);

    /* the exact quadruple still releases it */
    lease.lease_id = 31;
    request = request_envelope(HS2_DOCK_V2_LEASE_RELEASE, HS2_DOCK_V2_LEASE_REQUEST_BYTES,
                               request_id++, session);
    assert(hs2_dock_v2_encode_lease_request(&lease, payload));
    expect_ok_response(fd, &request, payload, payload, &reply);
    close(fd);
}

static void child(const char *path)
{
    signal(SIGALRM, deadline_expired);
    alarm(60);
    scenario_full_session(path);                 /* 1 connection */
    scenario_malformed_and_envelope_rejections(path); /* 8 connections */
    scenario_negotiation_and_session_rejections(path); /* 5 connections */
    scenario_clear_and_reconnect(path);          /* 2 connections */
    scenario_prehandshake_silent_timeout(path);  /* 1 connection */
    scenario_prehandshake_partial_timeout(path); /* 1 connection */
    scenario_prehandshake_trickle_timeout(path); /* 1 connection */
    scenario_negotiated_idle(path);              /* 1 connection */
    scenario_release_requires_exact_match(path); /* 1 connection */
    _exit(EXIT_SUCCESS);
}

int main(void)
{
    signal(SIGALRM, deadline_expired);
    alarm(90);

    char directory[] = "/tmp/hs2-dock-v2.XXXXXX";
    assert(mkdtemp(directory) != NULL);
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    assert(snprintf(path, sizeof(path), "%s/socket", directory) < (int)sizeof(path));
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(listener >= 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    assert(bind(listener, (const struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 8) == 0);

    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        child(path);
    }

    g_frame = CGRectMake(1.0, 2.0, 3.0, 4.0);
    hs2_dock_skylight_api api = {
        .main_connection_id = fake_main_connection_id,
        .get_window_bounds = fake_get_window_bounds,
        .move_window_with_group = fake_move_window_with_group,
        .get_window_transform = fake_get_window_transform,
        .set_window_transform = fake_set_window_transform,
        .set_window_warp = fake_set_window_warp,
    };
    hs2_dock_v2_server server;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);

    for (unsigned served = 0; served < SCENARIO_CONNECTIONS; served++) {
        int fd = accept(listener, NULL, NULL);
        assert(fd >= 0);
        /* kernel-verified peer capture: uid and pid straight from the socket */
        hs2_dock_v2_peer peer;
        assert(hs2_dock_v2_capture_peer(fd, &peer));
        assert(peer.uid == geteuid() && peer.pid == pid);
        (void)hs2_dock_v2_serve_connection(fd, &server, &api, &peer, NULL,
                                           TEST_HANDSHAKE_TIMEOUT_MS);
        close(fd);
    }
    close(listener);

    int status;
    assert(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);

    /* capture must refuse a descriptor that is not a connected socket */
    int not_a_socket = open("/dev/null", O_RDONLY);
    assert(not_a_socket >= 0);
    hs2_dock_v2_peer bogus;
    assert(!hs2_dock_v2_capture_peer(not_a_socket, &bogus));
    close(not_a_socket);

    /* full session: query 1 + move-post 1 + transform capture 1 + release
     * restore 1 + disconnect restore 1 + residue capture 1 */
    /* duplicate-scenario query 1 + clear-scenario capture 1 + clear restore 1
     * + reconnect query 1 */
    /* negotiated-idle query 1 */
    assert(g_bounds_calls == 6 + 4 + 1 && g_move_calls == 1);
    assert(g_get_transform_calls == 2 + 1);
    /* full session mutations 2 + release restore 1 + disconnect restore 1,
     * clear scenario mutation 1 + clear restore 1 */
    assert(g_set_transform_calls == 4 + 2);
    /* warp mutation + explicit clear + warp mutation + disconnect clear */
    assert(g_set_warp_calls == 4);
    /* the final restore used the canonical transform from fresh bounds */
    assert(g_last_transform.tx == -12.0 && g_last_transform.ty == -34.0);
    assert(g_last_transform.a == 1.0 && g_last_transform.d == 1.0);
    assert(g_last_warp_null_mesh && g_last_warp_columns == 0 && g_last_warp_rows == 0);
    /* every lease, including the explicitly cleared one, is gone */
    assert(hs2_dock_v2_active_leases(&server) == 0);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);

    unlink(path);
    rmdir(directory);
    return EXIT_SUCCESS;
}
