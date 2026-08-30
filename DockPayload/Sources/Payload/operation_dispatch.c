#include "operation_dispatch.h"
#include "workspace_transition.h"

#include <errno.h>
#include <math.h>
#include <time.h>

#define HS2_DOCK_V2_COORDINATE_LIMIT 1000000.0

static bool valid_window_id(uint64_t window_id)
{
    return window_id != 0 && window_id <= UINT32_MAX;
}

static bool valid_coordinate(double value)
{
    return isfinite(value) && fabs(value) <= HS2_DOCK_V2_COORDINATE_LIMIT;
}

static bool valid_warp_value(float value)
{
    return isfinite(value) && fabsf(value) <= (float)HS2_DOCK_V2_COORDINATE_LIMIT;
}

/* Capability advertisement mirrors the exact handler set each operation needs:
 * a missing symbol removes the capability instead of failing at call time. */
uint64_t hs2_dock_active_capabilities(const hs2_dock_skylight_api *api)
{
    uint64_t capabilities = HS2_DOCK_V2_CAP_LEASES;
    if (api == NULL || api->main_connection_id == NULL) {
        return capabilities;
    }
    if (api->get_window_bounds != NULL) {
        capabilities |= HS2_DOCK_V2_CAP_QUERY_FRAME;
        if (api->move_window_with_group != NULL) {
            capabilities |= HS2_DOCK_V2_CAP_MOVE_REAL;
        }
    }
    if (api->get_window_bounds != NULL && api->get_window_transform != NULL &&
        api->set_window_transform != NULL) {
        capabilities |= HS2_DOCK_V2_CAP_SET_TRANSFORM;
    }
    if (api->set_window_warp != NULL) {
        capabilities |= HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP;
    }
    if (api->get_window_bounds != NULL && api->get_window_transform != NULL &&
        api->set_window_transform != NULL && api->transaction_create != NULL &&
        api->transaction_set_window_transform != NULL && api->transaction_commit != NULL &&
        api->transaction_release != NULL) {
        capabilities |= HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION;
    }
    return capabilities;
}

static void encode_frame_reply(hs2_dock_operation_reply *reply,
                               uint16_t error,
                               uint16_t detail,
                               CGRect frame)
{
    hs2_dock_v2_frame_response response = {
        .error = error,
        .detail = detail,
        .x = frame.origin.x,
        .y = frame.origin.y,
        .width = frame.size.width,
        .height = frame.size.height,
    };

    reply->message_type = HS2_DOCK_V2_FRAME_RESPONSE;
    reply->payload_bytes = HS2_DOCK_V2_FRAME_RESPONSE_BYTES;
    (void)hs2_dock_v2_encode_frame_response(&response, reply->payload);
}

static void encode_status_reply(hs2_dock_operation_reply *reply,
                                uint16_t error,
                                uint16_t detail,
                                uint64_t value)
{
    hs2_dock_v2_response response = {
        .error = error,
        .detail = detail,
        .value = value,
    };

    reply->message_type = HS2_DOCK_V2_RESPONSE;
    reply->payload_bytes = HS2_DOCK_V2_RESPONSE_BYTES;
    (void)hs2_dock_v2_encode_response(&response, reply->payload);
}

static uint16_t authorization_for_query(hs2_dock_v2_server *server,
                                        const hs2_dock_v2_peer *peer,
                                        const hs2_dock_v2_envelope *envelope,
                                        const hs2_dock_v2_query_request *request)
{
    return hs2_dock_v2_authorize_operation(server, peer, envelope, request->nonce,
                                           HS2_DOCK_V2_CAP_QUERY_FRAME);
}

static uint16_t authorization_for_move(hs2_dock_v2_server *server,
                                       const hs2_dock_v2_peer *peer,
                                       const hs2_dock_v2_envelope *envelope,
                                       const hs2_dock_v2_move_request *request)
{
    return hs2_dock_v2_authorize_move(server, peer, envelope, request->nonce,
                                      request->lease_id, request->window_id);
}

static void retain_transform_note(hs2_dock_v2_lease *lease,
                                  CGRect authoritative_frame,
                                  CGAffineTransform observed,
                                  bool observed_captured)
{
    /* Retained before the first mutating SkyLight call. The canonical restore
     * value is derived from the authoritative frame; the observed transform is
     * diagnostic only because the spike proved SLSGetWindowTransform is not a
     * reliable restoration value. */
    lease->note.frame_captured = true;
    lease->note.frame = (hs2_dock_v2_note_frame){
        .x = authoritative_frame.origin.x,
        .y = authoritative_frame.origin.y,
        .width = authoritative_frame.size.width,
        .height = authoritative_frame.size.height,
    };
    lease->note.observed_captured = observed_captured;
    lease->note.observed = (hs2_dock_v2_note_transform){
        .a = observed.a, .b = observed.b, .c = observed.c,
        .d = observed.d, .tx = observed.tx, .ty = observed.ty,
    };
}

/* Verified canonical presentation transform: translation of the authoritative
 * frame origin (DOCK_WINDOW_ANIMATION_FINDINGS.md, corrected probe). */
static CGAffineTransform canonical_transform(CGRect frame)
{
    return CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);
}

bool hs2_dock_cleanup_lease_residue(uint64_t window_id, uint16_t operation,
                                    const hs2_dock_v2_lease_note *note, void *context)
{
    const hs2_dock_skylight_api *api = context;
    bool restored = true;
    int connection;

    (void)operation;
    if (api == NULL || note == NULL || api->main_connection_id == NULL) {
        return false;
    }
    connection = api->main_connection_id();

    if (note->warp_pending) {
        /* Exact evidenced relinquish call: 0, 0, NULL. */
        if (api->set_window_warp == NULL ||
            api->set_window_warp(connection, (uint32_t)window_id, 0, 0, NULL) !=
                kCGErrorSuccess) {
            restored = false;
        }
    }
    if (note->transform_pending) {
        /* Prefer the fresh authoritative frame; fall back to the frame
         * retained before the first mutation. The observed transform kept on
         * the lease is diagnostic only and is never trusted for restore. */
        CGRect frame = CGRectMake(note->frame.x, note->frame.y,
                                  note->frame.width, note->frame.height);
        if (api->get_window_bounds == NULL || api->set_window_transform == NULL) {
            return false;
        }
        CGRect authoritative;
        if (api->get_window_bounds(connection, (uint32_t)window_id, &authoritative) ==
            kCGErrorSuccess) {
            frame = authoritative;
        }
        if (api->set_window_transform(connection, (uint32_t)window_id,
                                      canonical_transform(frame)) != kCGErrorSuccess) {
            restored = false;
        }
    }
    return restored;
}

static bool dispatch_set_transform(const hs2_dock_skylight_api *api,
                                   hs2_dock_v2_server *server,
                                   const hs2_dock_v2_peer *peer,
                                   const hs2_dock_v2_envelope *envelope,
                                   const uint8_t *payload,
                                   hs2_dock_operation_reply *reply)
{
    hs2_dock_v2_transform_request request;
    hs2_dock_v2_lease *lease = NULL;
    CGRect frame;
    CGAffineTransform observed = CGAffineTransformIdentity;
    CGAffineTransform requested;
    int connection;
    CGError error;

    if (!hs2_dock_v2_decode_transform_request(payload, envelope->payload_bytes, &request) ||
        !valid_window_id(request.window_id)) {
        encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
        return true;
    }
    const double decoded[6] = {request.a, request.b, request.c,
                               request.d, request.tx, request.ty};
    for (size_t index = 0; index < 6; index++) {
        if (!valid_coordinate(decoded[index])) {
            encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
            return true;
        }
    }

    uint16_t result = hs2_dock_v2_authorize_leased_operation(server, peer, envelope,
                                               request.nonce, HS2_DOCK_V2_CAP_SET_TRANSFORM,
                                               request.lease_id, request.window_id, &lease);
    if (result == HS2_DOCK_V2_OK &&
        (hs2_dock_active_capabilities(api) & HS2_DOCK_V2_CAP_SET_TRANSFORM) == 0) {
        result = HS2_DOCK_V2_CAPABILITY_REJECTED;
    }
    if (result != HS2_DOCK_V2_OK) {
        encode_status_reply(reply, result, 0, 0);
        return true;
    }

    connection = api->main_connection_id();
    error = api->get_window_bounds(connection, (uint32_t)request.window_id, &frame);
    if (error != kCGErrorSuccess) {
        /* Without the authoritative frame no safe canonical restore exists, so
         * the window is not mutated. */
        encode_status_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, 0);
        return true;
    }
    bool observed_captured =
        api->get_window_transform(connection, (uint32_t)request.window_id, &observed) ==
        kCGErrorSuccess;
    retain_transform_note(lease, frame, observed, observed_captured);

    requested = CGAffineTransformMake(decoded[0], decoded[1], decoded[2],
                                       decoded[3], decoded[4], decoded[5]);
    lease->note.transform_pending = true;
    error = api->set_window_transform(connection, (uint32_t)request.window_id, requested);
    if (error != kCGErrorSuccess) {
        /* Partial mutation failure: restore the canonical transform at once.
         * If the restore also fails the pending residue stays on the lease so
         * release, clear, disconnect, and unload retry it. */
        CGError restore_error = api->set_window_transform(
            connection, (uint32_t)request.window_id, canonical_transform(frame));
        if (restore_error != kCGErrorSuccess) {
            lease->note.cleanup_failed = true;
            server->cleanup_failed = true;
        } else {
            lease->note.transform_pending = false;
        }
        encode_status_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, 0);
        return true;
    }
    encode_status_reply(reply, HS2_DOCK_V2_OK, 0, request.lease_id);
    return true;
}

static bool dispatch_set_warp(const hs2_dock_skylight_api *api,
                             hs2_dock_v2_server *server,
                             const hs2_dock_v2_peer *peer,
                             const hs2_dock_v2_envelope *envelope,
                             const uint8_t *payload,
                             hs2_dock_operation_reply *reply)
{
    hs2_dock_v2_warp_request request;
    hs2_dock_v2_lease *lease = NULL;
    hs2_sls_warp_point mesh[HS2_DOCK_V2_WARP_POINTS];
    int connection;
    CGError error;

    if (!hs2_dock_v2_decode_warp_request(payload, envelope->payload_bytes, &request) ||
        !valid_window_id(request.window_id)) {
        encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
        return true;
    }
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        const hs2_dock_v2_warp_point *point = &request.points[index];
        if (!valid_warp_value(point->local_x) || !valid_warp_value(point->local_y) ||
            !valid_warp_value(point->global_x) || !valid_warp_value(point->global_y)) {
            encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
            return true;
        }
        mesh[index].local_x = point->local_x;
        mesh[index].local_y = point->local_y;
        mesh[index].global_x = point->global_x;
        mesh[index].global_y = point->global_y;
    }

    uint16_t result = hs2_dock_v2_authorize_leased_operation(server, peer, envelope,
                                               request.nonce, HS2_DOCK_V2_CAP_SET_WARP,
                                               request.lease_id, request.window_id, &lease);
    if (result == HS2_DOCK_V2_OK &&
        (hs2_dock_active_capabilities(api) & HS2_DOCK_V2_CAP_SET_WARP) == 0) {
        result = HS2_DOCK_V2_CAPABILITY_REJECTED;
    }
    if (result != HS2_DOCK_V2_OK) {
        encode_status_reply(reply, result, 0, 0);
        return true;
    }

    connection = api->main_connection_id();
    lease->note.warp_pending = true;
    error = api->set_window_warp(connection, (uint32_t)request.window_id,
                                 (int)request.columns, (int)request.rows, mesh);
    if (error != kCGErrorSuccess) {
        /* Partial mutation failure: clear immediately with the exact
         * evidenced relinquish call 0, 0, NULL. A failed clear stays pending. */
        CGError clear_error = api->set_window_warp(connection, (uint32_t)request.window_id,
                                                   0, 0, NULL);
        if (clear_error != kCGErrorSuccess) {
            lease->note.cleanup_failed = true;
            server->cleanup_failed = true;
        } else {
            lease->note.warp_pending = false;
        }
        encode_status_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, 0);
        return true;
    }
    encode_status_reply(reply, HS2_DOCK_V2_OK, 0, request.lease_id);
    return true;
}

static bool dispatch_clear_warp(const hs2_dock_skylight_api *api,
                                hs2_dock_v2_server *server,
                                const hs2_dock_v2_peer *peer,
                                const hs2_dock_v2_envelope *envelope,
                                const uint8_t *payload,
                                hs2_dock_operation_reply *reply)
{
    hs2_dock_v2_clear_warp_request request;
    hs2_dock_v2_lease *lease = NULL;
    int connection;
    CGError error;

    if (!hs2_dock_v2_decode_clear_warp_request(payload, envelope->payload_bytes, &request) ||
        !valid_window_id(request.window_id)) {
        encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
        return true;
    }

    uint16_t result = hs2_dock_v2_authorize_leased_operation(server, peer, envelope,
                                               request.nonce, HS2_DOCK_V2_CAP_CLEAR_WARP,
                                               request.lease_id, request.window_id, &lease);
    if (result == HS2_DOCK_V2_OK &&
        (hs2_dock_active_capabilities(api) & HS2_DOCK_V2_CAP_CLEAR_WARP) == 0) {
        result = HS2_DOCK_V2_CAPABILITY_REJECTED;
    }
    if (result != HS2_DOCK_V2_OK) {
        encode_status_reply(reply, result, 0, 0);
        return true;
    }

    connection = api->main_connection_id();
    /* Exact evidenced clear semantics: relinquish with 0, 0, NULL. */
    error = api->set_window_warp(connection, (uint32_t)request.window_id, 0, 0, NULL);
    if (error != kCGErrorSuccess) {
        /* The lease keeps warp_pending so a later cleanup retries the clear. */
        encode_status_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, 0);
        return true;
    }
    lease->note.warp_pending = false;
    encode_status_reply(reply, HS2_DOCK_V2_OK, 0, request.lease_id);
    return true;
}

static uint64_t monotonic_now_ns(void *context)
{
    struct timespec value;
    (void)context;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static void monotonic_wait_until_ns(uint64_t deadline_ns, void *context)
{
    (void)context;
    for (;;) {
        uint64_t now_ns = monotonic_now_ns(NULL);
        if (now_ns == 0 || now_ns >= deadline_ns) {
            return;
        }
        uint64_t remaining_ns = deadline_ns - now_ns;
        struct timespec remaining = {
            .tv_sec = (time_t)(remaining_ns / UINT64_C(1000000000)),
            .tv_nsec = (long)(remaining_ns % UINT64_C(1000000000)),
        };
        if (nanosleep(&remaining, NULL) == 0 || errno != EINTR) {
            return;
        }
    }
}

static bool dispatch_workspace_transition(const hs2_dock_skylight_api *api,
                                          hs2_dock_v2_server *server,
                                          const hs2_dock_v2_peer *peer,
                                          const hs2_dock_v2_envelope *envelope,
                                          const uint8_t *payload,
                                          hs2_dock_operation_reply *reply)
{
    hs2_dock_v2_workspace_transition_request wire;
    hs2_dock_workspace_transition_member members[HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS];
    hs2_dock_v2_lease *leases[HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS] = {0};
    CGRect frames[HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS] = {0};
    CGAffineTransform observed[HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS] = {0};
    bool observed_captured[HS2_DOCK_V2_WORKSPACE_TRANSITION_MAX_MEMBERS] = {0};

    if (!hs2_dock_v2_decode_workspace_transition_request(payload, envelope->payload_bytes,
                                                          &wire) ||
        wire.duration_ns == 0 || wire.duration_ns > HS2_DOCK_WORKSPACE_TRANSITION_MAX_DURATION_NS ||
        wire.frame_interval_ns < HS2_DOCK_WORKSPACE_TRANSITION_MIN_FRAME_INTERVAL_NS ||
        wire.frame_interval_ns > wire.duration_ns) {
        encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
        return true;
    }
    for (size_t index = 0; index < wire.member_count; index++) {
        if (!valid_window_id(wire.members[index].window_id)) {
            encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
            return true;
        }
        for (size_t value = 0; value < 6; value++) {
            if (!valid_coordinate(wire.members[index].from[value]) ||
                !valid_coordinate(wire.members[index].to[value])) {
                encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
                return true;
            }
        }
        for (size_t prior = 0; prior < index; prior++) {
            if (wire.members[prior].window_id == wire.members[index].window_id ||
                wire.members[prior].lease_id == wire.members[index].lease_id) {
                encode_status_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, 0);
                return true;
            }
        }
        const double *from = wire.members[index].from;
        const double *to = wire.members[index].to;
        members[index] = (hs2_dock_workspace_transition_member){
            .window_id = (uint32_t)wire.members[index].window_id,
            .from = CGAffineTransformMake(from[0], from[1], from[2], from[3], from[4], from[5]),
            .to = CGAffineTransformMake(to[0], to[1], to[2], to[3], to[4], to[5]),
        };
    }
    uint16_t result = hs2_dock_v2_authorize_workspace_transition(
        server, peer, envelope, wire.nonce, &wire, leases);
    if (result == HS2_DOCK_V2_OK &&
        (hs2_dock_active_capabilities(api) & HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION) == 0) {
        result = HS2_DOCK_V2_CAPABILITY_REJECTED;
    }
    if (result != HS2_DOCK_V2_OK) {
        encode_status_reply(reply, result, 0, 0);
        return true;
    }

    int connection = 0;
    connection = api->main_connection_id();
    /* Finish every fallible observation before retaining notes or allowing the
     * primitive to mutate WindowServer. */
    for (size_t index = 0; index < wire.member_count; index++) {
        uint32_t window_id = (uint32_t)wire.members[index].window_id;
        CGError error = api->get_window_bounds(connection, window_id, &frames[index]);
        if (error != kCGErrorSuccess) {
            encode_status_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, 0);
            return true;
        }
        observed_captured[index] = api->get_window_transform(
            connection, window_id, &observed[index]) == kCGErrorSuccess;
    }
    for (size_t index = 0; index < wire.member_count; index++) {
        retain_transform_note(leases[index], frames[index], observed[index],
                              observed_captured[index]);
        leases[index]->note.transform_pending = true;
    }

    hs2_dock_workspace_transition_request request = {
        .members = members, .member_count = wire.member_count,
        .duration_ns = wire.duration_ns, .frame_interval_ns = wire.frame_interval_ns,
    };
    hs2_dock_workspace_transition_clock clock = {
        .now_ns = monotonic_now_ns, .wait_until_ns = monotonic_wait_until_ns,
        .should_cancel = api->transition_should_cancel,
        .context = api->transition_context,
    };
    hs2_dock_workspace_transition_result transition =
        hs2_dock_run_workspace_transition(api, &request, &clock);
    switch (transition) {
    case HS2_DOCK_WORKSPACE_TRANSITION_COMPLETED:
        encode_status_reply(reply, HS2_DOCK_V2_OK, 0, wire.member_count); break;
    case HS2_DOCK_WORKSPACE_TRANSITION_COMMIT_UNCERTAIN:
        encode_status_reply(reply, HS2_DOCK_V2_COMMIT_UNCERTAIN, 0, 0); break;
    case HS2_DOCK_WORKSPACE_TRANSITION_CANCELLED:
        encode_status_reply(reply, HS2_DOCK_V2_CANCELLED, 0, 0); break;
    case HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED:
        encode_status_reply(reply, HS2_DOCK_V2_TIMEOUT, 0, 0); break;
    default:
        encode_status_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)transition, 0); break;
    }
    return true;
}

bool hs2_dock_dispatch_operation(const hs2_dock_skylight_api *api,
                                 hs2_dock_v2_server *server,
                                 const hs2_dock_v2_peer *peer,
                                 const hs2_dock_v2_envelope *envelope,
                                 const uint8_t *payload,
                                 hs2_dock_operation_reply *reply)
{
    CGRect frame = CGRectZero;
    uint16_t result;

    if (api == NULL || server == NULL || peer == NULL || envelope == NULL ||
        payload == NULL || reply == NULL) {
        return false;
    }

    if (envelope->type == HS2_DOCK_V2_QUERY_FRAME) {
        hs2_dock_v2_query_request request;
        if (!hs2_dock_v2_decode_query_request(payload, envelope->payload_bytes, &request) ||
            !valid_window_id(request.window_id)) {
            encode_frame_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, frame);
            return true;
        }
        result = authorization_for_query(server, peer, envelope, &request);
        if (result == HS2_DOCK_V2_OK &&
            (hs2_dock_active_capabilities(api) & HS2_DOCK_V2_CAP_QUERY_FRAME) == 0) {
            result = HS2_DOCK_V2_CAPABILITY_REJECTED;
        }
        if (result == HS2_DOCK_V2_OK) {
            int connection = api->main_connection_id();
            CGError error = api->get_window_bounds(connection, (uint32_t)request.window_id, &frame);
            if (error != kCGErrorSuccess) {
                frame = CGRectZero;
                encode_frame_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, frame);
                return true;
            }
        }
        encode_frame_reply(reply, result, 0, frame);
        return true;
    }

    if (envelope->type == HS2_DOCK_V2_MOVE_REAL) {
        hs2_dock_v2_move_request request;
        if (!hs2_dock_v2_decode_move_request(payload, envelope->payload_bytes, &request) ||
            !valid_window_id(request.window_id) || !valid_coordinate(request.x) ||
            !valid_coordinate(request.y)) {
            encode_frame_reply(reply, HS2_DOCK_V2_MALFORMED_ENVELOPE, 0, frame);
            return true;
        }
        result = authorization_for_move(server, peer, envelope, &request);
        if (result == HS2_DOCK_V2_OK &&
            (hs2_dock_active_capabilities(api) & HS2_DOCK_V2_CAP_MOVE_REAL) == 0) {
            result = HS2_DOCK_V2_CAPABILITY_REJECTED;
        }
        if (result == HS2_DOCK_V2_OK) {
            int connection = api->main_connection_id();
            CGPoint target = CGPointMake(request.x, request.y);
            CGError error = api->move_window_with_group(connection, (uint32_t)request.window_id,
                                                         &target);
            if (error != kCGErrorSuccess) {
                encode_frame_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, frame);
                return true;
            }
            error = api->get_window_bounds(connection, (uint32_t)request.window_id, &frame);
            if (error != kCGErrorSuccess) {
                frame = CGRectZero;
                encode_frame_reply(reply, HS2_DOCK_V2_OPERATION_FAILED, (uint16_t)error, frame);
                return true;
            }
        }
        encode_frame_reply(reply, result, 0, frame);
        return true;
    }

    if (envelope->type == HS2_DOCK_V2_SET_TRANSFORM) {
        return dispatch_set_transform(api, server, peer, envelope, payload, reply);
    }
    if (envelope->type == HS2_DOCK_V2_SET_WARP) {
        return dispatch_set_warp(api, server, peer, envelope, payload, reply);
    }
    if (envelope->type == HS2_DOCK_V2_CLEAR_WARP) {
        return dispatch_clear_warp(api, server, peer, envelope, payload, reply);
    }
    if (envelope->type == HS2_DOCK_V2_WORKSPACE_TRANSITION) {
        return dispatch_workspace_transition(api, server, peer, envelope, payload, reply);
    }

    return false;
}
