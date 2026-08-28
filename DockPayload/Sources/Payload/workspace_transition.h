#ifndef HS2_DOCK_WORKSPACE_TRANSITION_H
#define HS2_DOCK_WORKSPACE_TRANSITION_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "operation_dispatch.h"

#define HS2_DOCK_WORKSPACE_TRANSITION_MAX_WINDOWS 32u
#define HS2_DOCK_WORKSPACE_TRANSITION_MAX_DURATION_NS UINT64_C(2000000000)
#define HS2_DOCK_WORKSPACE_TRANSITION_MIN_FRAME_INTERVAL_NS UINT64_C(1000000)
#define HS2_DOCK_WORKSPACE_TRANSITION_VALUE_LIMIT 1000000.0

typedef struct {
    uint32_t window_id;
    CGAffineTransform from;
    CGAffineTransform to;
} hs2_dock_workspace_transition_member;

typedef struct {
    const hs2_dock_workspace_transition_member *members;
    size_t member_count;
    uint64_t duration_ns;
    uint64_t frame_interval_ns;
} hs2_dock_workspace_transition_request;

typedef struct {
    uint64_t (*now_ns)(void *context);
    void (*wait_until_ns)(uint64_t deadline_ns, void *context);
    bool (*should_cancel)(void *context);
    void *context;
} hs2_dock_workspace_transition_clock;

typedef enum {
    HS2_DOCK_WORKSPACE_TRANSITION_COMPLETED = 0,
    HS2_DOCK_WORKSPACE_TRANSITION_INVALID,
    HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED,
    HS2_DOCK_WORKSPACE_TRANSITION_APPLY_FAILED,
    HS2_DOCK_WORKSPACE_TRANSITION_COMMIT_UNCERTAIN,
    HS2_DOCK_WORKSPACE_TRANSITION_CANCELLED,
} hs2_dock_workspace_transition_result;

/* Runs one bounded multi-window presentation transition on Dock's privileged
 * connection. Every frame is one WindowServer transaction, so all member
 * transforms share both a clock sample and a commit. The caller owns leases
 * and endpoint/rollback policy; this primitive only advances the leased
 * presentation transforms. A failed transform enqueue is definitely
 * uncommitted; a failed commit is reported separately because WindowServer may
 * already have applied some or all of that transaction.
 *
 * The final frame always writes each exact `to` transform. No SkyLight call is
 * made when request or clock validation fails. */
hs2_dock_workspace_transition_result hs2_dock_run_workspace_transition(
    const hs2_dock_skylight_api *api,
    const hs2_dock_workspace_transition_request *request,
    const hs2_dock_workspace_transition_clock *clock);

#endif
