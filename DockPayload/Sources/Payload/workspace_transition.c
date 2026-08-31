#include "workspace_transition.h"

#include <math.h>

static bool finite_transform(CGAffineTransform transform)
{
    const double values[] = {
        transform.a, transform.b, transform.c,
        transform.d, transform.tx, transform.ty,
    };
    for (size_t index = 0; index < sizeof(values) / sizeof(values[0]); index++) {
        if (!isfinite(values[index]) ||
            fabs(values[index]) > HS2_DOCK_WORKSPACE_TRANSITION_VALUE_LIMIT) {
            return false;
        }
    }
    return true;
}

static bool valid_request(const hs2_dock_skylight_api *api,
                          const hs2_dock_workspace_transition_request *request,
                          const hs2_dock_workspace_transition_clock *clock)
{
    if (api == NULL || api->main_connection_id == NULL ||
        api->transaction_create == NULL ||
        api->transaction_move_window_with_group == NULL ||
        api->transaction_commit == NULL || api->transaction_release == NULL ||
        request == NULL || request->members == NULL ||
        request->member_count == 0 ||
        request->member_count > HS2_DOCK_WORKSPACE_TRANSITION_MAX_WINDOWS ||
        request->duration_ns == 0 ||
        request->duration_ns > HS2_DOCK_WORKSPACE_TRANSITION_MAX_DURATION_NS ||
        request->frame_interval_ns < HS2_DOCK_WORKSPACE_TRANSITION_MIN_FRAME_INTERVAL_NS ||
        request->frame_interval_ns > request->duration_ns ||
        clock == NULL || clock->now_ns == NULL || clock->wait_until_ns == NULL) {
        return false;
    }

    for (size_t index = 0; index < request->member_count; index++) {
        const hs2_dock_workspace_transition_member *member = &request->members[index];
        if (member->window_id == 0 ||
            !finite_transform(member->from) || !finite_transform(member->to)) {
            return false;
        }
        for (size_t prior = 0; prior < index; prior++) {
            if (request->members[prior].window_id == member->window_id) {
                return false;
            }
        }
    }
    return true;
}

static double eased_progress(double progress)
{
    if (progress <= 0.0) {
        return 0.0;
    }
    if (progress >= 1.0) {
        return 1.0;
    }
    return progress * progress * (3.0 - 2.0 * progress);
}

static double interpolate(double from, double to, double progress)
{
    return from + (to - from) * progress;
}

static CGAffineTransform interpolated_transform(
    const hs2_dock_workspace_transition_member *member,
    double progress)
{
    if (progress >= 1.0) {
        return member->to;
    }
    return CGAffineTransformMake(
        interpolate(member->from.a, member->to.a, progress),
        interpolate(member->from.b, member->to.b, progress),
        interpolate(member->from.c, member->to.c, progress),
        interpolate(member->from.d, member->to.d, progress),
        interpolate(member->from.tx, member->to.tx, progress),
        interpolate(member->from.ty, member->to.ty, progress));
}

static CGPoint position_for_transform(CGAffineTransform transform)
{
    return CGPointMake(-transform.tx, -transform.ty);
}

static hs2_dock_workspace_transition_result apply_frame(
    const hs2_dock_skylight_api *api,
    int connection,
    const hs2_dock_workspace_transition_request *request,
    double progress)
{
    CFTypeRef transaction = api->transaction_create(connection);
    if (transaction == NULL) {
        return HS2_DOCK_WORKSPACE_TRANSITION_APPLY_FAILED;
    }

    for (size_t index = 0; index < request->member_count; index++) {
        const hs2_dock_workspace_transition_member *member = &request->members[index];
        CGAffineTransform transform = interpolated_transform(member, progress);
        CGPoint position = position_for_transform(transform);
        api->transaction_move_window_with_group(
            transaction, member->window_id, position.x, position.y);
    }
    api->transaction_commit(transaction, 0);
    api->transaction_release(transaction);
    return HS2_DOCK_WORKSPACE_TRANSITION_COMPLETED;
}

hs2_dock_workspace_transition_result hs2_dock_run_workspace_transition(
    const hs2_dock_skylight_api *api,
    const hs2_dock_workspace_transition_request *request,
    const hs2_dock_workspace_transition_clock *clock)
{
    if (!valid_request(api, request, clock)) {
        return HS2_DOCK_WORKSPACE_TRANSITION_INVALID;
    }

    uint64_t start = clock->now_ns(clock->context);
    bool initially_cancelled =
        clock->should_cancel != NULL && clock->should_cancel(clock->context);
    if (start == 0 || initially_cancelled) {
        return initially_cancelled
            ? HS2_DOCK_WORKSPACE_TRANSITION_CANCELLED
            : HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED;
    }
    uint64_t end = start + request->duration_ns;
    if (end < start) {
        return HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED;
    }

    int connection = api->main_connection_id();
    if (connection <= 0) {
        return HS2_DOCK_WORKSPACE_TRANSITION_INVALID;
    }

    uint64_t frame = 0;
    uint64_t previous_now = start;
    uint64_t maximum_frames =
        request->duration_ns / request->frame_interval_ns + 2;
    for (;;) {
        if (clock->should_cancel != NULL && clock->should_cancel(clock->context)) {
            return HS2_DOCK_WORKSPACE_TRANSITION_CANCELLED;
        }
        uint64_t now = clock->now_ns(clock->context);
        if (now < previous_now || frame >= maximum_frames) {
            return HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED;
        }
        double linear = now >= end
            ? 1.0
            : now <= start
                ? 0.0
                : (double)(now - start) / (double)request->duration_ns;
        hs2_dock_workspace_transition_result frame_result =
            apply_frame(api, connection, request, eased_progress(linear));
        if (frame_result != HS2_DOCK_WORKSPACE_TRANSITION_COMPLETED) {
            return frame_result;
        }
        if (now >= end) {
            return HS2_DOCK_WORKSPACE_TRANSITION_COMPLETED;
        }

        frame++;
        uint64_t deadline = start + frame * request->frame_interval_ns;
        if (deadline < start || deadline > end) {
            deadline = end;
        }
        clock->wait_until_ns(deadline, clock->context);
        if (clock->should_cancel != NULL && clock->should_cancel(clock->context)) {
            return HS2_DOCK_WORKSPACE_TRANSITION_CANCELLED;
        }
        uint64_t after_wait = clock->now_ns(clock->context);
        if (after_wait <= now || after_wait < deadline) {
            return HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED;
        }
        previous_now = after_wait;
    }
}
