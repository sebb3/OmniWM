#ifndef HS2_DOCK_PROTOCOL_V2_H
#define HS2_DOCK_PROTOCOL_V2_H

/* Dock companion protocol v2 wire codecs.
 *
 * Every message is one 40-byte little-endian envelope followed by exactly the
 * payload byte count the envelope declares. All multibyte integers and both
 * float formats are little-endian on the wire; nothing is compiler-packed and
 * nothing depends on host struct layout. The C codecs in protocol_v2.c and the
 * Swift codecs in DockProtocolV2.swift are exact mirrors and are pinned by the
 * shared golden byte vectors in Tests/protocol_v2_tests.c and
 * Tests/protocol_v2_swift_tests.swift.
 *
 * Development-only spike surface: these codecs exist to prove the transport
 * contract; nothing here authorizes attaching to or mutating the live Dock.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Envelope magic: the bytes 'H', 'S', '2', 'D' on the wire, read as a
 * little-endian uint32. Both language implementations and the golden vectors
 * agree on this exact value. */
#define HS2_DOCK_V2_MAGIC UINT32_C(0x44325348)

/* Exact protocol version every envelope must carry. */
#define HS2_DOCK_V2_MAJOR 2u
#define HS2_DOCK_V2_MINOR 0u
#define HS2_DOCK_V2_BUILD 1u

/* Frame geometry. */
#define HS2_DOCK_V2_ENVELOPE_BYTES 40u
#define HS2_DOCK_V2_NONCE_BYTES 16u

/* Absolute protocol payload bound: 65,535 bytes. With the 40-byte envelope,
 * the largest representable complete frame is 65,575 bytes. The active v2
 * message bound below is much smaller and is enforced before payload reads. */
#define HS2_DOCK_V2_PROTOCOL_MAX_PAYLOAD_BYTES 65535u
#define HS2_DOCK_V2_PROTOCOL_MAX_FRAME_BYTES \
    (HS2_DOCK_V2_ENVELOPE_BYTES + HS2_DOCK_V2_PROTOCOL_MAX_PAYLOAD_BYTES)

/* Current active-operation bound: the largest payload any v2 message defined
 * today carries (the 9x2 warp request). Servers reject anything larger after
 * envelope decode and before reading a payload into the fixed-size buffer,
 * and clients never allocate a response body larger than the largest reply. */
#define HS2_DOCK_V2_MAX_PAYLOAD_BYTES 324u

/* Exact payload sizes, by message. */
#define HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES 44u
#define HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES 64u
#define HS2_DOCK_V2_LEASE_REQUEST_BYTES 34u
#define HS2_DOCK_V2_RESPONSE_BYTES 12u
#define HS2_DOCK_V2_QUERY_REQUEST_BYTES 24u
#define HS2_DOCK_V2_FRAME_RESPONSE_BYTES 36u
#define HS2_DOCK_V2_MOVE_REQUEST_BYTES 48u
#define HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES 80u
#define HS2_DOCK_V2_WARP_REQUEST_BYTES 324u
#define HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES 32u

/* The only routable warp mesh is exactly 9 columns by 2 rows (18 points). */
#define HS2_DOCK_V2_MAX_WARP_COLUMNS 9u
#define HS2_DOCK_V2_MAX_WARP_ROWS 2u
#define HS2_DOCK_V2_WARP_POINTS 18u

/* Evidenced capability bits. A bit is advertised only when the spike evidence
 * backs the underlying SkyLight call (see DEVELOPMENT.md). */
enum hs2_dock_v2_capability {
    HS2_DOCK_V2_CAP_QUERY_FRAME = UINT64_C(1) << 0,
    HS2_DOCK_V2_CAP_MOVE_REAL = UINT64_C(1) << 1,
    HS2_DOCK_V2_CAP_SET_TRANSFORM = UINT64_C(1) << 2,
    HS2_DOCK_V2_CAP_SET_WARP = UINT64_C(1) << 3,
    HS2_DOCK_V2_CAP_CLEAR_WARP = UINT64_C(1) << 4,
    HS2_DOCK_V2_CAP_LEASES = UINT64_C(1) << 5,
};
#define HS2_DOCK_V2_EVIDENCED_CAPABILITIES \
    (HS2_DOCK_V2_CAP_QUERY_FRAME | HS2_DOCK_V2_CAP_MOVE_REAL | \
     HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_SET_WARP | \
     HS2_DOCK_V2_CAP_CLEAR_WARP | HS2_DOCK_V2_CAP_LEASES)

enum hs2_dock_v2_message {
    HS2_DOCK_V2_HANDSHAKE_REQUEST = 1,
    HS2_DOCK_V2_HANDSHAKE_RESPONSE = 2,
    HS2_DOCK_V2_LEASE_CREATE = 3,
    HS2_DOCK_V2_LEASE_RELEASE = 4,
    HS2_DOCK_V2_LEASE_CLEAR = 5,
    HS2_DOCK_V2_QUERY_FRAME = 6,
    HS2_DOCK_V2_MOVE_REAL = 7,
    HS2_DOCK_V2_SET_TRANSFORM = 8,
    HS2_DOCK_V2_SET_WARP = 9,
    HS2_DOCK_V2_CLEAR_WARP = 10,
    HS2_DOCK_V2_RESPONSE = 11,
    HS2_DOCK_V2_FRAME_RESPONSE = 12,
};

enum hs2_dock_v2_error {
    HS2_DOCK_V2_OK = 0,
    HS2_DOCK_V2_MALFORMED_ENVELOPE = 1,
    HS2_DOCK_V2_UNSUPPORTED_VERSION = 2,
    HS2_DOCK_V2_BUILD_REJECTED = 3,
    HS2_DOCK_V2_CAPABILITY_REJECTED = 4,
    HS2_DOCK_V2_CREDENTIAL_REJECTED = 5,
    HS2_DOCK_V2_SESSION_REJECTED = 6,
    HS2_DOCK_V2_DUPLICATE_REQUEST = 7,
    HS2_DOCK_V2_LEASE_REJECTED = 8,
    HS2_DOCK_V2_UNSUPPORTED_MESSAGE = 9,
    HS2_DOCK_V2_CLEANUP_FAILED = 10,
    HS2_DOCK_V2_TIMEOUT = 11,
    HS2_DOCK_V2_OPERATION_FAILED = 12,
};

/* Wire structs. Field order below matches wire order; the codecs, not the
 * compiler, lay bytes out. */

typedef struct {
    uint16_t major;
    uint16_t minor;
    uint16_t type;
    uint16_t flags;
    uint16_t header_bytes;
    uint16_t payload_bytes;
    uint64_t request_id;
    uint64_t session_id;
    uint64_t reserved;
} hs2_dock_v2_envelope;

typedef struct {
    uint16_t protocol_min_major;
    uint16_t protocol_max_major;
    uint32_t build_min;
    uint32_t build_max;
    uint64_t required_capabilities;
    uint64_t optional_capabilities;
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
} hs2_dock_v2_handshake_request;

typedef struct {
    uint16_t major;
    uint16_t minor;
    uint32_t build;
    uint64_t available_capabilities;
    uint64_t granted_capabilities;
    uint64_t session_id;
    uint32_t peer_uid;
    int32_t peer_pid;
    uint16_t error;
    uint16_t reason;
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
} hs2_dock_v2_handshake_response;

typedef struct {
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t lease_id;
    uint64_t window_id;
    uint16_t operation;
} hs2_dock_v2_lease_request;

typedef struct {
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t window_id;
} hs2_dock_v2_query_request;

typedef struct {
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t lease_id;
    uint64_t window_id;
    double x;
    double y;
} hs2_dock_v2_move_request;

typedef struct {
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t lease_id;
    uint64_t window_id;
    double a;
    double b;
    double c;
    double d;
    double tx;
    double ty;
} hs2_dock_v2_transform_request;

typedef struct {
    float local_x;
    float local_y;
    float global_x;
    float global_y;
} hs2_dock_v2_warp_point;

typedef struct {
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t lease_id;
    uint64_t window_id;
    uint16_t columns;
    uint16_t rows;
    hs2_dock_v2_warp_point points[HS2_DOCK_V2_WARP_POINTS];
} hs2_dock_v2_warp_request;

typedef struct {
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t lease_id;
    uint64_t window_id;
} hs2_dock_v2_clear_warp_request;

typedef struct {
    uint16_t error;
    uint16_t detail;
    uint64_t value;
} hs2_dock_v2_response;

typedef struct {
    uint16_t error;
    uint16_t detail;
    double x;
    double y;
    double width;
    double height;
} hs2_dock_v2_frame_response;

/* Envelope codec. Encode refuses non-v2 requests: a zero request id, a wrong
 * header size, a payload beyond the active-operation bound, or a nonzero
 * reserved word. Decode additionally enforces the exact protocol version,
 * zero flags, a known message type, a nonzero request id, a zero reserved
 * word, the 64 KiB protocol bound, and a zero session id on handshake
 * requests. */
bool hs2_dock_v2_encode_envelope(const hs2_dock_v2_envelope *message,
                                 uint8_t out[HS2_DOCK_V2_ENVELOPE_BYTES]);
bool hs2_dock_v2_decode_envelope(const uint8_t *bytes,
                                 size_t length,
                                 hs2_dock_v2_envelope *out);

/* Payload codecs. Every decoder takes the exact expected byte length and
 * returns false for any other length, any non-finite float, or any zero
 * required identifier. */
bool hs2_dock_v2_encode_handshake_request(const hs2_dock_v2_handshake_request *message,
                                          uint8_t out[HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES]);
bool hs2_dock_v2_decode_handshake_request(const uint8_t *bytes,
                                          size_t length,
                                          hs2_dock_v2_handshake_request *out);
bool hs2_dock_v2_encode_handshake_response(const hs2_dock_v2_handshake_response *message,
                                           uint8_t out[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES]);
bool hs2_dock_v2_decode_handshake_response(const uint8_t *bytes,
                                           size_t length,
                                           hs2_dock_v2_handshake_response *out);
bool hs2_dock_v2_encode_lease_request(const hs2_dock_v2_lease_request *message,
                                      uint8_t out[HS2_DOCK_V2_LEASE_REQUEST_BYTES]);
bool hs2_dock_v2_decode_lease_request(const uint8_t *bytes,
                                      size_t length,
                                      hs2_dock_v2_lease_request *out);
bool hs2_dock_v2_encode_query_request(const hs2_dock_v2_query_request *message,
                                      uint8_t out[HS2_DOCK_V2_QUERY_REQUEST_BYTES]);
bool hs2_dock_v2_decode_query_request(const uint8_t *bytes,
                                      size_t length,
                                      hs2_dock_v2_query_request *out);
bool hs2_dock_v2_encode_move_request(const hs2_dock_v2_move_request *message,
                                     uint8_t out[HS2_DOCK_V2_MOVE_REQUEST_BYTES]);
bool hs2_dock_v2_decode_move_request(const uint8_t *bytes,
                                     size_t length,
                                     hs2_dock_v2_move_request *out);
bool hs2_dock_v2_encode_transform_request(const hs2_dock_v2_transform_request *message,
                                          uint8_t out[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES]);
bool hs2_dock_v2_decode_transform_request(const uint8_t *bytes,
                                          size_t length,
                                          hs2_dock_v2_transform_request *out);
bool hs2_dock_v2_encode_warp_request(const hs2_dock_v2_warp_request *message,
                                     uint8_t out[HS2_DOCK_V2_WARP_REQUEST_BYTES]);
bool hs2_dock_v2_decode_warp_request(const uint8_t *bytes,
                                     size_t length,
                                     hs2_dock_v2_warp_request *out);
bool hs2_dock_v2_encode_clear_warp_request(const hs2_dock_v2_clear_warp_request *message,
                                           uint8_t out[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES]);
bool hs2_dock_v2_decode_clear_warp_request(const uint8_t *bytes,
                                           size_t length,
                                           hs2_dock_v2_clear_warp_request *out);
bool hs2_dock_v2_encode_response(const hs2_dock_v2_response *message,
                                 uint8_t out[HS2_DOCK_V2_RESPONSE_BYTES]);
bool hs2_dock_v2_decode_response(const uint8_t *bytes,
                                 size_t length,
                                 hs2_dock_v2_response *out);
bool hs2_dock_v2_encode_frame_response(const hs2_dock_v2_frame_response *message,
                                       uint8_t out[HS2_DOCK_V2_FRAME_RESPONSE_BYTES]);
bool hs2_dock_v2_decode_frame_response(const uint8_t *bytes,
                                       size_t length,
                                       hs2_dock_v2_frame_response *out);

#endif
