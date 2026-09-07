#ifndef HS2_DOCK_PROTOCOL_V2_SERVER_H
#define HS2_DOCK_PROTOCOL_V2_SERVER_H

#include <sys/types.h>
#include "protocol_v2.h"

#define HS2_DOCK_V2_MAX_SESSIONS 8u
#define HS2_DOCK_V2_MAX_LEASES 32u

/* Bounded replay-detection window. A session remembers its most recent
 * request ids in a ring of this size; older ids are evicted, so the window
 * bounds replay detection without ever turning into a permanent failure
 * after a fixed request count. */
#define HS2_DOCK_V2_REQUEST_WINDOW 64u

typedef struct { uid_t uid; pid_t pid; } hs2_dock_v2_peer;

typedef struct {
    bool active;
    hs2_dock_v2_peer peer;
    uint64_t session_id;
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    uint64_t capabilities;
    /* Ring of the most recently seen request ids. */
    uint64_t request_ids[HS2_DOCK_V2_REQUEST_WINDOW];
    size_t request_next;  /* slot that receives the next remembered id */
    size_t request_count; /* ids currently retained, at most the window size */
} hs2_dock_v2_session;

/* Operation-specific cleanup data retained on a lease before the first mutating
 * SkyLight call. The protocol layer keeps these graphics-free doubles; the
 * payload converts them back to CoreGraphics types when it restores. */
typedef struct { double x, y, width, height; } hs2_dock_v2_note_frame;
typedef struct { double a, b, c, d, tx, ty; } hs2_dock_v2_note_transform;
typedef struct {
    bool transform_pending; /* a presentation transform residue needs canonical restore */
    bool warp_pending;      /* a warp residue needs an exact 0, 0, NULL clear */
    bool cleanup_failed;    /* the most recent cleanup attempt failed; retryable */
    bool frame_captured;    /* authoritative frame observed before the first mutation */
    bool observed_captured; /* observed transform retained for diagnostics only */
    hs2_dock_v2_note_frame frame;
    hs2_dock_v2_note_transform observed;
} hs2_dock_v2_lease_note;

typedef struct { bool active; uint64_t lease_id; uint64_t window_id; uint16_t operation; uint64_t session_id; hs2_dock_v2_lease_note note; } hs2_dock_v2_lease;
typedef bool (*hs2_dock_v2_cleanup_fn)(uint64_t window_id, uint16_t operation, const hs2_dock_v2_lease_note *note, void *context);
typedef struct { hs2_dock_v2_session sessions[HS2_DOCK_V2_MAX_SESSIONS]; hs2_dock_v2_lease leases[HS2_DOCK_V2_MAX_LEASES]; uint64_t next_session_id; uint64_t available_capabilities; bool loaded; bool cleanup_failed; hs2_dock_v2_cleanup_fn cleanup; void *cleanup_context; } hs2_dock_v2_server;

void hs2_dock_v2_server_init(hs2_dock_v2_server *, uint64_t capabilities);
void hs2_dock_v2_server_set_cleanup(hs2_dock_v2_server *, hs2_dock_v2_cleanup_fn, void *);
uint16_t hs2_dock_v2_handshake(hs2_dock_v2_server *, const hs2_dock_v2_peer *, const hs2_dock_v2_handshake_request *, hs2_dock_v2_handshake_response *);
uint16_t hs2_dock_v2_handle_lease(hs2_dock_v2_server *, const hs2_dock_v2_peer *, const hs2_dock_v2_envelope *, const hs2_dock_v2_lease_request *);
uint16_t hs2_dock_v2_authorize_operation(hs2_dock_v2_server *, const hs2_dock_v2_peer *, const hs2_dock_v2_envelope *, const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES], uint64_t capability);
uint16_t hs2_dock_v2_authorize_leased_operation(hs2_dock_v2_server *, const hs2_dock_v2_peer *, const hs2_dock_v2_envelope *, const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES], uint64_t capability, uint64_t lease_id, uint64_t window_id, hs2_dock_v2_lease **lease);
uint16_t hs2_dock_v2_authorize_move(hs2_dock_v2_server *, const hs2_dock_v2_peer *, const hs2_dock_v2_envelope *, const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES], uint64_t lease_id, uint64_t window_id);
uint16_t hs2_dock_v2_disconnect(hs2_dock_v2_server *, const hs2_dock_v2_peer *, uint64_t session_id, const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES]);
uint16_t hs2_dock_v2_unload(hs2_dock_v2_server *);
size_t hs2_dock_v2_active_leases(const hs2_dock_v2_server *);
size_t hs2_dock_v2_pending_cleanup_leases(const hs2_dock_v2_server *);

#endif
