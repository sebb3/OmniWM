#include "protocol_v2.h"

#include <math.h>
#include <string.h>

/* Little-endian primitives. Every field goes through these, so no message
 * ever depends on host byte order, host struct padding, or compiler packing. */

static void put16(uint8_t *out, uint16_t value)
{
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
}

static void put32(uint8_t *out, uint32_t value)
{
    for (unsigned byte = 0; byte < 4; byte++) {
        out[byte] = (uint8_t)(value >> (8 * byte));
    }
}

static void put64(uint8_t *out, uint64_t value)
{
    for (unsigned byte = 0; byte < 8; byte++) {
        out[byte] = (uint8_t)(value >> (8 * byte));
    }
}

static uint16_t get16(const uint8_t *in)
{
    return (uint16_t)((uint16_t)in[0] | ((uint16_t)in[1] << 8));
}

static uint32_t get32(const uint8_t *in)
{
    uint32_t value = 0;
    for (unsigned byte = 0; byte < 4; byte++) {
        value |= (uint32_t)in[byte] << (8 * byte);
    }
    return value;
}

static uint64_t get64(const uint8_t *in)
{
    uint64_t value = 0;
    for (unsigned byte = 0; byte < 8; byte++) {
        value |= (uint64_t)in[byte] << (8 * byte);
    }
    return value;
}

static void put_double(uint8_t *out, double value)
{
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    put64(out, bits);
}

static double get_double(const uint8_t *in)
{
    uint64_t bits = get64(in);
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void put_float(uint8_t *out, float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    put32(out, bits);
}

static float get_float(const uint8_t *in)
{
    uint32_t bits = get32(in);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static bool known_message_type(uint16_t type)
{
    return type >= HS2_DOCK_V2_HANDSHAKE_REQUEST && type <= HS2_DOCK_V2_WORKSPACE_TRANSITION;
}

/* Envelope layout, little-endian:
 *   offset  0  uint32 magic 'H','S','2','D'
 *   offset  4  uint16 major          (exact protocol version)
 *   offset  6  uint16 minor          (exact protocol version)
 *   offset  8  uint16 message type   (known set only)
 *   offset 10  uint16 flags          (zero; none defined)
 *   offset 12  uint16 header bytes   (exactly 40)
 *   offset 14  uint16 payload bytes  (64 KiB protocol bound at decode,
 *                                     active-operation bound at encode)
 *   offset 16  uint64 request id     (nonzero, unique per session)
 *   offset 24  uint64 session id     (zero until the handshake completes)
 *   offset 32  uint64 reserved       (zero)
 */
bool hs2_dock_v2_encode_envelope(const hs2_dock_v2_envelope *message,
                                 uint8_t out[HS2_DOCK_V2_ENVELOPE_BYTES])
{
    if (message == NULL || out == NULL || message->request_id == 0 ||
        message->header_bytes != HS2_DOCK_V2_ENVELOPE_BYTES ||
        message->payload_bytes > HS2_DOCK_V2_MAX_PAYLOAD_BYTES ||
        message->reserved != 0) {
        return false;
    }
    put32(out, HS2_DOCK_V2_MAGIC);
    put16(out + 4, message->major);
    put16(out + 6, message->minor);
    put16(out + 8, message->type);
    put16(out + 10, message->flags);
    put16(out + 12, HS2_DOCK_V2_ENVELOPE_BYTES);
    put16(out + 14, message->payload_bytes);
    put64(out + 16, message->request_id);
    put64(out + 24, message->session_id);
    put64(out + 32, 0);
    return true;
}

bool hs2_dock_v2_decode_envelope(const uint8_t *bytes, size_t length,
                                 hs2_dock_v2_envelope *out)
{
    size_t payload_bytes;

    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_ENVELOPE_BYTES) {
        return false;
    }
    payload_bytes = get16(bytes + 14);
    if (get32(bytes) != HS2_DOCK_V2_MAGIC ||
        get16(bytes + 4) != HS2_DOCK_V2_MAJOR ||
        get16(bytes + 6) != HS2_DOCK_V2_MINOR ||
        get16(bytes + 10) != 0 ||
        get16(bytes + 12) != HS2_DOCK_V2_ENVELOPE_BYTES ||
        payload_bytes > HS2_DOCK_V2_PROTOCOL_MAX_PAYLOAD_BYTES ||
        get64(bytes + 16) == 0 ||
        get64(bytes + 32) != 0 ||
        !known_message_type(get16(bytes + 8))) {
        return false;
    }
    out->major = HS2_DOCK_V2_MAJOR;
    out->minor = HS2_DOCK_V2_MINOR;
    out->type = get16(bytes + 8);
    out->flags = 0;
    out->header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES;
    out->payload_bytes = get16(bytes + 14);
    out->request_id = get64(bytes + 16);
    out->session_id = get64(bytes + 24);
    out->reserved = 0;
    if (out->type == HS2_DOCK_V2_HANDSHAKE_REQUEST && out->session_id != 0) {
        return false;
    }
    return true;
}

/* Handshake request: version range, build range, capability asks, nonce. */
bool hs2_dock_v2_encode_handshake_request(const hs2_dock_v2_handshake_request *message,
                                          uint8_t out[HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES])
{
    if (message == NULL || out == NULL ||
        message->protocol_min_major > message->protocol_max_major ||
        message->build_min > message->build_max) {
        return false;
    }
    put16(out, message->protocol_min_major);
    put16(out + 2, message->protocol_max_major);
    put32(out + 4, message->build_min);
    put32(out + 8, message->build_max);
    put64(out + 12, message->required_capabilities);
    put64(out + 20, message->optional_capabilities);
    memcpy(out + 28, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    return true;
}

bool hs2_dock_v2_decode_handshake_request(const uint8_t *bytes, size_t length,
                                          hs2_dock_v2_handshake_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES) {
        return false;
    }
    out->protocol_min_major = get16(bytes);
    out->protocol_max_major = get16(bytes + 2);
    out->build_min = get32(bytes + 4);
    out->build_max = get32(bytes + 8);
    out->required_capabilities = get64(bytes + 12);
    out->optional_capabilities = get64(bytes + 20);
    memcpy(out->nonce, bytes + 28, HS2_DOCK_V2_NONCE_BYTES);
    return out->protocol_min_major <= out->protocol_max_major &&
           out->build_min <= out->build_max;
}

/* Handshake response: negotiated version/build, capability sets, the
 * payload-generated session id, the kernel-observed peer credentials, the
 * error/reason pair, the echoed nonce, and four reserved zero bytes. */
bool hs2_dock_v2_encode_handshake_response(const hs2_dock_v2_handshake_response *message,
                                           uint8_t out[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES])
{
    if (message == NULL || out == NULL) {
        return false;
    }
    put16(out, message->major);
    put16(out + 2, message->minor);
    put32(out + 4, message->build);
    put64(out + 8, message->available_capabilities);
    put64(out + 16, message->granted_capabilities);
    put64(out + 24, message->session_id);
    put32(out + 32, message->peer_uid);
    put32(out + 36, (uint32_t)message->peer_pid);
    put16(out + 40, message->error);
    put16(out + 42, message->reason);
    memcpy(out + 44, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    memset(out + 60, 0, 4);
    return true;
}

bool hs2_dock_v2_decode_handshake_response(const uint8_t *bytes, size_t length,
                                           hs2_dock_v2_handshake_response *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES ||
        get32(bytes + 60) != 0) {
        return false;
    }
    out->major = get16(bytes);
    out->minor = get16(bytes + 2);
    out->build = get32(bytes + 4);
    out->available_capabilities = get64(bytes + 8);
    out->granted_capabilities = get64(bytes + 16);
    out->session_id = get64(bytes + 24);
    out->peer_uid = get32(bytes + 32);
    out->peer_pid = (int32_t)get32(bytes + 36);
    out->error = get16(bytes + 40);
    out->reason = get16(bytes + 42);
    memcpy(out->nonce, bytes + 44, HS2_DOCK_V2_NONCE_BYTES);
    return true;
}

/* Lease create/release/clear share one payload: nonce, lease id, window id,
 * and the capability bitset the lease covers. */
bool hs2_dock_v2_encode_lease_request(const hs2_dock_v2_lease_request *message,
                                      uint8_t out[HS2_DOCK_V2_LEASE_REQUEST_BYTES])
{
    if (message == NULL || out == NULL || message->lease_id == 0 || message->window_id == 0) {
        return false;
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->lease_id);
    put64(out + 24, message->window_id);
    put16(out + 32, message->operation);
    return true;
}

bool hs2_dock_v2_decode_lease_request(const uint8_t *bytes, size_t length,
                                      hs2_dock_v2_lease_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_LEASE_REQUEST_BYTES) {
        return false;
    }
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->lease_id = get64(bytes + 16);
    out->window_id = get64(bytes + 24);
    out->operation = get16(bytes + 32);
    return out->lease_id != 0 && out->window_id != 0;
}

bool hs2_dock_v2_encode_query_request(const hs2_dock_v2_query_request *message,
                                      uint8_t out[HS2_DOCK_V2_QUERY_REQUEST_BYTES])
{
    if (message == NULL || out == NULL || message->window_id == 0) {
        return false;
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->window_id);
    return true;
}

bool hs2_dock_v2_decode_query_request(const uint8_t *bytes, size_t length,
                                      hs2_dock_v2_query_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_QUERY_REQUEST_BYTES) {
        return false;
    }
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->window_id = get64(bytes + 16);
    return out->window_id != 0;
}

bool hs2_dock_v2_encode_move_request(const hs2_dock_v2_move_request *message,
                                     uint8_t out[HS2_DOCK_V2_MOVE_REQUEST_BYTES])
{
    if (message == NULL || out == NULL || message->lease_id == 0 ||
        message->window_id == 0 || !isfinite(message->x) || !isfinite(message->y)) {
        return false;
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->lease_id);
    put64(out + 24, message->window_id);
    put_double(out + 32, message->x);
    put_double(out + 40, message->y);
    return true;
}

bool hs2_dock_v2_decode_move_request(const uint8_t *bytes, size_t length,
                                     hs2_dock_v2_move_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_MOVE_REQUEST_BYTES) {
        return false;
    }
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->lease_id = get64(bytes + 16);
    out->window_id = get64(bytes + 24);
    out->x = get_double(bytes + 32);
    out->y = get_double(bytes + 40);
    return out->lease_id != 0 && out->window_id != 0 &&
           isfinite(out->x) && isfinite(out->y);
}

/* Transform: the six affine values in a,b,c,d,tx,ty order. */
bool hs2_dock_v2_encode_transform_request(const hs2_dock_v2_transform_request *message,
                                          uint8_t out[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES])
{
    if (message == NULL || out == NULL || message->lease_id == 0 || message->window_id == 0) {
        return false;
    }
    const double values[6] = {message->a, message->b, message->c,
                              message->d, message->tx, message->ty};
    for (size_t index = 0; index < 6; index++) {
        if (!isfinite(values[index])) {
            return false;
        }
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->lease_id);
    put64(out + 24, message->window_id);
    for (size_t index = 0; index < 6; index++) {
        put_double(out + 32 + index * 8, values[index]);
    }
    return true;
}

bool hs2_dock_v2_decode_transform_request(const uint8_t *bytes, size_t length,
                                          hs2_dock_v2_transform_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES) {
        return false;
    }
    double *values[6] = {&out->a, &out->b, &out->c, &out->d, &out->tx, &out->ty};
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->lease_id = get64(bytes + 16);
    out->window_id = get64(bytes + 24);
    if (out->lease_id == 0 || out->window_id == 0) {
        return false;
    }
    for (size_t index = 0; index < 6; index++) {
        *values[index] = get_double(bytes + 32 + index * 8);
        if (!isfinite(*values[index])) {
            return false;
        }
    }
    return true;
}

/* Warp: exactly the 9x2 mesh, 18 points of four finite floats each. */
bool hs2_dock_v2_encode_warp_request(const hs2_dock_v2_warp_request *message,
                                     uint8_t out[HS2_DOCK_V2_WARP_REQUEST_BYTES])
{
    if (message == NULL || out == NULL || message->lease_id == 0 ||
        message->window_id == 0 || message->columns != HS2_DOCK_V2_MAX_WARP_COLUMNS ||
        message->rows != HS2_DOCK_V2_MAX_WARP_ROWS) {
        return false;
    }
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        const hs2_dock_v2_warp_point *point = &message->points[index];
        if (!isfinite(point->local_x) || !isfinite(point->local_y) ||
            !isfinite(point->global_x) || !isfinite(point->global_y)) {
            return false;
        }
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->lease_id);
    put64(out + 24, message->window_id);
    put16(out + 32, message->columns);
    put16(out + 34, message->rows);
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        const hs2_dock_v2_warp_point *point = &message->points[index];
        put_float(out + 36 + index * 16, point->local_x);
        put_float(out + 40 + index * 16, point->local_y);
        put_float(out + 44 + index * 16, point->global_x);
        put_float(out + 48 + index * 16, point->global_y);
    }
    return true;
}

bool hs2_dock_v2_decode_warp_request(const uint8_t *bytes, size_t length,
                                     hs2_dock_v2_warp_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_WARP_REQUEST_BYTES) {
        return false;
    }
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->lease_id = get64(bytes + 16);
    out->window_id = get64(bytes + 24);
    out->columns = get16(bytes + 32);
    out->rows = get16(bytes + 34);
    if (out->lease_id == 0 || out->window_id == 0 ||
        out->columns != HS2_DOCK_V2_MAX_WARP_COLUMNS ||
        out->rows != HS2_DOCK_V2_MAX_WARP_ROWS) {
        return false;
    }
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        hs2_dock_v2_warp_point *point = &out->points[index];
        point->local_x = get_float(bytes + 36 + index * 16);
        point->local_y = get_float(bytes + 40 + index * 16);
        point->global_x = get_float(bytes + 44 + index * 16);
        point->global_y = get_float(bytes + 48 + index * 16);
        if (!isfinite(point->local_x) || !isfinite(point->local_y) ||
            !isfinite(point->global_x) || !isfinite(point->global_y)) {
            return false;
        }
    }
    return true;
}

bool hs2_dock_v2_encode_clear_warp_request(const hs2_dock_v2_clear_warp_request *message,
                                           uint8_t out[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES])
{
    if (message == NULL || out == NULL || message->lease_id == 0 || message->window_id == 0) {
        return false;
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->lease_id);
    put64(out + 24, message->window_id);
    return true;
}

bool hs2_dock_v2_decode_clear_warp_request(const uint8_t *bytes, size_t length,
                                           hs2_dock_v2_clear_warp_request *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES) {
        return false;
    }
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->lease_id = get64(bytes + 16);
    out->window_id = get64(bytes + 24);
    return out->lease_id != 0 && out->window_id != 0;
}


/* Workspace transition: fixed prefix followed by member_count fixed records. */
bool hs2_dock_v2_encode_workspace_transition_request(
    const hs2_dock_v2_workspace_transition_request *message, uint8_t *out, size_t out_length)
{
    if (message == NULL || out == NULL || message->member_count == 0 ||
        message->member_count > HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS ||
        message->reserved != 0 ||
        out_length != HS2_DOCK_V2_WORKSPACE_TRANSITION_PREFIX_BYTES +
                          (size_t)message->member_count *
                              HS2_DOCK_V2_WORKSPACE_TRANSITION_MEMBER_BYTES) {
        return false;
    }
    memcpy(out, message->nonce, HS2_DOCK_V2_NONCE_BYTES);
    put64(out + 16, message->duration_ns);
    put64(out + 24, message->frame_interval_ns);
    put16(out + 32, message->member_count);
    put16(out + 34, 0);
    for (size_t index = 0; index < message->member_count; index++) {
        const hs2_dock_v2_workspace_transition_member *member = &message->members[index];
        uint8_t *record = out + HS2_DOCK_V2_WORKSPACE_TRANSITION_PREFIX_BYTES +
                          index * HS2_DOCK_V2_WORKSPACE_TRANSITION_MEMBER_BYTES;
        if (member->lease_id == 0 || member->window_id == 0) return false;
        put64(record, member->lease_id);
        put64(record + 8, member->window_id);
        for (size_t value = 0; value < 6; value++) {
            if (!isfinite(member->from[value]) || !isfinite(member->to[value])) return false;
            put_double(record + 16 + value * 8, member->from[value]);
            put_double(record + 64 + value * 8, member->to[value]);
        }
    }
    return true;
}

bool hs2_dock_v2_decode_workspace_transition_request(
    const uint8_t *bytes, size_t length, hs2_dock_v2_workspace_transition_request *out)
{
    if (bytes == NULL || out == NULL || length < HS2_DOCK_V2_WORKSPACE_TRANSITION_PREFIX_BYTES)
        return false;
    memcpy(out->nonce, bytes, HS2_DOCK_V2_NONCE_BYTES);
    out->duration_ns = get64(bytes + 16);
    out->frame_interval_ns = get64(bytes + 24);
    out->member_count = get16(bytes + 32);
    out->reserved = get16(bytes + 34);
    if (out->member_count == 0 || out->member_count > HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS ||
        out->reserved != 0 || length != HS2_DOCK_V2_WORKSPACE_TRANSITION_PREFIX_BYTES +
            (size_t)out->member_count * HS2_DOCK_V2_WORKSPACE_TRANSITION_MEMBER_BYTES) return false;
    for (size_t index = 0; index < out->member_count; index++) {
        hs2_dock_v2_workspace_transition_member *member = &out->members[index];
        const uint8_t *record = bytes + HS2_DOCK_V2_WORKSPACE_TRANSITION_PREFIX_BYTES +
                                index * HS2_DOCK_V2_WORKSPACE_TRANSITION_MEMBER_BYTES;
        member->lease_id = get64(record); member->window_id = get64(record + 8);
        if (member->lease_id == 0 || member->window_id == 0) return false;
        for (size_t value = 0; value < 6; value++) {
            member->from[value] = get_double(record + 16 + value * 8);
            member->to[value] = get_double(record + 64 + value * 8);
            if (!isfinite(member->from[value]) || !isfinite(member->to[value])) return false;
        }
    }
    return true;
}

/* Generic status reply. */
bool hs2_dock_v2_encode_response(const hs2_dock_v2_response *message,
                                 uint8_t out[HS2_DOCK_V2_RESPONSE_BYTES])
{
    if (message == NULL || out == NULL) {
        return false;
    }
    put16(out, message->error);
    put16(out + 2, message->detail);
    put64(out + 4, message->value);
    return true;
}

bool hs2_dock_v2_decode_response(const uint8_t *bytes, size_t length,
                                 hs2_dock_v2_response *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_RESPONSE_BYTES) {
        return false;
    }
    out->error = get16(bytes);
    out->detail = get16(bytes + 2);
    out->value = get64(bytes + 4);
    return true;
}

/* Frame reply: status plus the observed frame; all four doubles finite. */
bool hs2_dock_v2_encode_frame_response(const hs2_dock_v2_frame_response *message,
                                       uint8_t out[HS2_DOCK_V2_FRAME_RESPONSE_BYTES])
{
    if (message == NULL || out == NULL || !isfinite(message->x) || !isfinite(message->y) ||
        !isfinite(message->width) || !isfinite(message->height)) {
        return false;
    }
    put16(out, message->error);
    put16(out + 2, message->detail);
    put_double(out + 4, message->x);
    put_double(out + 12, message->y);
    put_double(out + 20, message->width);
    put_double(out + 28, message->height);
    return true;
}

bool hs2_dock_v2_decode_frame_response(const uint8_t *bytes, size_t length,
                                       hs2_dock_v2_frame_response *out)
{
    if (bytes == NULL || out == NULL || length != HS2_DOCK_V2_FRAME_RESPONSE_BYTES) {
        return false;
    }
    out->error = get16(bytes);
    out->detail = get16(bytes + 2);
    out->x = get_double(bytes + 4);
    out->y = get_double(bytes + 12);
    out->width = get_double(bytes + 20);
    out->height = get_double(bytes + 28);
    return isfinite(out->x) && isfinite(out->y) &&
           isfinite(out->width) && isfinite(out->height);
}
