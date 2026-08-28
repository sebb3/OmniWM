#ifndef HS2_DOCK_OPERATION_DISPATCH_H
#define HS2_DOCK_OPERATION_DISPATCH_H

#include <CoreGraphics/CoreGraphics.h>

#include "protocol_v2_server.h"

/* WarpPoint ABI recovered from a live Dock minimize: four floats mapping one
 * source-local window coordinate to one arbitrary global desktop coordinate. */
typedef struct {
    float local_x;
    float local_y;
    float global_x;
    float global_y;
} hs2_sls_warp_point;

/* Evidenced SkyLight private ABI (spike evidence: wa-window-runtime.txt and
 * warp-abi-trace.txt; verified payload at git b725ac2). */
typedef int (*hs2_sls_main_connection_id_fn)(void);
typedef CGError (*hs2_sls_get_window_bounds_fn)(int, uint32_t, CGRect *);
typedef CGError (*hs2_sls_move_window_with_group_fn)(int, uint32_t, CGPoint *);
typedef CGError (*hs2_sls_get_window_transform_fn)(int, uint32_t, CGAffineTransform *);
typedef CGError (*hs2_sls_set_window_transform_fn)(int, uint32_t, CGAffineTransform);
typedef CGError (*hs2_sls_set_window_warp_fn)(int, uint32_t, int, int,
                                              const hs2_sls_warp_point *);
typedef CFTypeRef (*hs2_sls_transaction_create_fn)(int);
typedef CGError (*hs2_sls_transaction_set_window_transform_fn)(
    CFTypeRef, uint32_t, int32_t, int32_t, CGAffineTransform);
typedef CGError (*hs2_sls_transaction_commit_fn)(CFTypeRef, int32_t);
typedef void (*hs2_sls_transaction_release_fn)(CFTypeRef);
typedef bool (*hs2_dock_transition_cancel_fn)(void *);

typedef struct {
    hs2_sls_main_connection_id_fn main_connection_id;
    hs2_sls_get_window_bounds_fn get_window_bounds;
    hs2_sls_move_window_with_group_fn move_window_with_group;
    hs2_sls_get_window_transform_fn get_window_transform;
    hs2_sls_set_window_transform_fn set_window_transform;
    hs2_sls_set_window_warp_fn set_window_warp;
    hs2_sls_transaction_create_fn transaction_create;
    hs2_sls_transaction_set_window_transform_fn transaction_set_window_transform;
    hs2_sls_transaction_commit_fn transaction_commit;
    hs2_sls_transaction_release_fn transaction_release;
    hs2_dock_transition_cancel_fn transition_should_cancel;
    void *transition_context;
} hs2_dock_skylight_api;

typedef struct {
    uint16_t message_type;
    uint16_t payload_bytes;
    uint8_t payload[HS2_DOCK_V2_FRAME_RESPONSE_BYTES];
} hs2_dock_operation_reply;

uint64_t hs2_dock_active_capabilities(const hs2_dock_skylight_api *api);
bool hs2_dock_dispatch_operation(const hs2_dock_skylight_api *api,
                                 hs2_dock_v2_server *server,
                                 const hs2_dock_v2_peer *peer,
                                 const hs2_dock_v2_envelope *envelope,
                                 const uint8_t *payload,
                                 hs2_dock_operation_reply *reply);

/* hs2_dock_v2_cleanup_fn-compatible residue cleanup. The context is the
 * resolved SkyLight api. Returns false when residue remains so the protocol
 * layer keeps the lease active and retryable. */
bool hs2_dock_cleanup_lease_residue(uint64_t window_id, uint16_t operation,
                                    const hs2_dock_v2_lease_note *note, void *context);

#endif
