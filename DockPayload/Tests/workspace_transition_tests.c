#include "workspace_transition.h"

#include <assert.h>
#include <math.h>
#include <string.h>

#define MAX_RECORDED_FRAMES 16u

typedef struct {
    int connection_calls;
    int create_calls;
    int set_calls;
    int commit_calls;
    int release_calls;
    bool stall_clock;
    bool cancelled;
    uint64_t now;
    uint64_t deadlines[MAX_RECORDED_FRAMES];
    size_t deadline_count;
    struct {
        uint32_t window_ids[HS2_DOCK_WORKSPACE_TRANSITION_MAX_WINDOWS];
        CGAffineTransform transforms[HS2_DOCK_WORKSPACE_TRANSITION_MAX_WINDOWS];
        size_t count;
    } frames[MAX_RECORDED_FRAMES];
    size_t frame_count;
} transition_fake;

static transition_fake g_fake;

static int fake_main_connection(void)
{
    g_fake.connection_calls++;
    return 42;
}

static CFTypeRef fake_create_transaction(int connection)
{
    assert(connection == 42);
    g_fake.create_calls++;
    assert(g_fake.frame_count < MAX_RECORDED_FRAMES);
    return (CFTypeRef)(uintptr_t)(g_fake.frame_count + 1);
}

static void fake_set_transform(CFTypeRef transaction, uint32_t window_id,
                               int32_t unknown_a, int32_t unknown_b,
                               CGAffineTransform transform)
{
    assert(transaction != NULL);
    assert(unknown_a == 0 && unknown_b == 0);
    g_fake.set_calls++;
    size_t index = g_fake.frames[g_fake.frame_count].count++;
    assert(index < HS2_DOCK_WORKSPACE_TRANSITION_MAX_WINDOWS);
    g_fake.frames[g_fake.frame_count].window_ids[index] = window_id;
    g_fake.frames[g_fake.frame_count].transforms[index] = transform;
}

static void fake_commit(CFTypeRef transaction, int32_t synchronous)
{
    assert(transaction != NULL);
    assert(synchronous == 0);
    g_fake.commit_calls++;
    g_fake.frame_count++;
}

static void fake_release(CFTypeRef transaction)
{
    assert(transaction != NULL);
    g_fake.release_calls++;
}

static uint64_t fake_now(void *context)
{
    transition_fake *fake = context;
    return fake->now;
}

static void fake_wait(uint64_t deadline, void *context)
{
    transition_fake *fake = context;
    assert(fake->deadline_count < MAX_RECORDED_FRAMES);
    fake->deadlines[fake->deadline_count++] = deadline;
    if (!fake->stall_clock) {
        fake->now = deadline;
    }
}

static bool fake_should_cancel(void *context)
{
    transition_fake *fake = context;
    return fake->cancelled;
}

static hs2_dock_skylight_api complete_api(void)
{
    return (hs2_dock_skylight_api){
        .main_connection_id = fake_main_connection,
        .transaction_create = fake_create_transaction,
        .transaction_set_window_transform = fake_set_transform,
        .transaction_commit = fake_commit,
        .transaction_release = fake_release,
    };
}

static hs2_dock_workspace_transition_clock clock_for(transition_fake *fake)
{
    return (hs2_dock_workspace_transition_clock){
        .now_ns = fake_now,
        .wait_until_ns = fake_wait,
        .should_cancel = fake_should_cancel,
        .context = fake,
    };
}

static void test_initial_clock_failure_and_cancellation_do_not_mutate(void)
{
    hs2_dock_workspace_transition_member member = {
        .window_id = 1,
        .from = CGAffineTransformIdentity,
        .to = CGAffineTransformMakeTranslation(0, 100),
    };
    hs2_dock_workspace_transition_request request = {
        .members = &member,
        .member_count = 1,
        .duration_ns = UINT64_C(10000000),
        .frame_interval_ns = UINT64_C(1000000),
    };
    hs2_dock_skylight_api api = complete_api();

    memset(&g_fake, 0, sizeof(g_fake));
    hs2_dock_workspace_transition_clock clock = clock_for(&g_fake);
    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED);
    assert(g_fake.connection_calls == 0 && g_fake.create_calls == 0);

    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.now = 1;
    g_fake.cancelled = true;
    clock = clock_for(&g_fake);
    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_CANCELLED);
    assert(g_fake.connection_calls == 0 && g_fake.create_calls == 0);
}

static void assert_transform(CGAffineTransform value, CGAffineTransform expected)
{
    assert(fabs(value.a - expected.a) < 0.000001);
    assert(fabs(value.b - expected.b) < 0.000001);
    assert(fabs(value.c - expected.c) < 0.000001);
    assert(fabs(value.d - expected.d) < 0.000001);
    assert(fabs(value.tx - expected.tx) < 0.000001);
    assert(fabs(value.ty - expected.ty) < 0.000001);
}

static void test_shared_clock_atomic_frames_and_exact_endpoint(void)
{
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.now = UINT64_C(1000000000);
    hs2_dock_workspace_transition_member members[] = {
        {
            .window_id = 11,
            .from = CGAffineTransformMake(1, 0, 0, 1, -100, -900),
            .to = CGAffineTransformMake(1, 0, 0, 1, -100, -100),
        },
        {
            .window_id = 12,
            .from = CGAffineTransformMake(1, 0, 0, 1, -400, 500),
            .to = CGAffineTransformMake(1, 0, 0, 1, -400, -300),
        },
    };
    hs2_dock_workspace_transition_request request = {
        .members = members,
        .member_count = 2,
        .duration_ns = UINT64_C(100000000),
        .frame_interval_ns = UINT64_C(25000000),
    };
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_workspace_transition_clock clock = clock_for(&g_fake);

    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_COMPLETED);
    assert(g_fake.connection_calls == 1);
    assert(g_fake.create_calls == 5 && g_fake.commit_calls == 5 &&
           g_fake.release_calls == 5);
    assert(g_fake.set_calls == 10 && g_fake.frame_count == 5);
    for (size_t frame = 0; frame < g_fake.frame_count; frame++) {
        assert(g_fake.frames[frame].count == 2);
        assert(g_fake.frames[frame].window_ids[0] == 11);
        assert(g_fake.frames[frame].window_ids[1] == 12);
    }
    assert_transform(g_fake.frames[0].transforms[0], members[0].from);
    assert(g_fake.frames[2].transforms[0].ty == -500.0);
    assert(g_fake.frames[2].transforms[1].ty == 100.0);
    assert(memcmp(&g_fake.frames[4].transforms[0], &members[0].to,
                  sizeof(CGAffineTransform)) == 0);
    assert(memcmp(&g_fake.frames[4].transforms[1], &members[1].to,
                  sizeof(CGAffineTransform)) == 0);
    assert(g_fake.deadline_count == 4);
    assert(g_fake.deadlines[0] == UINT64_C(1025000000));
    assert(g_fake.deadlines[3] == UINT64_C(1100000000));
}

static void test_stalled_clock_stops_after_one_frame(void)
{
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.now = 1;
    g_fake.stall_clock = true;
    hs2_dock_workspace_transition_member member = {
        .window_id = 1,
        .from = CGAffineTransformIdentity,
        .to = CGAffineTransformMakeTranslation(0, 100),
    };
    hs2_dock_workspace_transition_request request = {
        .members = &member,
        .member_count = 1,
        .duration_ns = UINT64_C(10000000),
        .frame_interval_ns = UINT64_C(1000000),
    };
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_workspace_transition_clock clock = clock_for(&g_fake);

    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_CLOCK_FAILED);
    assert(g_fake.commit_calls == 1 && g_fake.deadline_count == 1);
}

static void test_validation_has_no_side_effects(void)
{
    memset(&g_fake, 0, sizeof(g_fake));
    hs2_dock_workspace_transition_member members[] = {
        { .window_id = 1, .from = CGAffineTransformIdentity, .to = CGAffineTransformIdentity },
        { .window_id = 1, .from = CGAffineTransformIdentity, .to = CGAffineTransformIdentity },
    };
    hs2_dock_workspace_transition_request request = {
        .members = members,
        .member_count = 2,
        .duration_ns = UINT64_C(10000000),
        .frame_interval_ns = UINT64_C(1000000),
    };
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_workspace_transition_clock clock = clock_for(&g_fake);

    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_INVALID);
    members[1].window_id = 2;
    members[1].to.tx = NAN;
    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_INVALID);
    members[1].to.tx = 0;
    members[1].to.ty = HS2_DOCK_WORKSPACE_TRANSITION_VALUE_LIMIT + 1;
    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_INVALID);
    members[1].to.ty = 0;
    request.frame_interval_ns = 1;
    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_INVALID);
    request.frame_interval_ns = UINT64_C(1000000);
    request.member_count = HS2_DOCK_WORKSPACE_TRANSITION_MAX_WINDOWS + 1;
    assert(hs2_dock_run_workspace_transition(&api, &request, &clock) ==
           HS2_DOCK_WORKSPACE_TRANSITION_INVALID);
    assert(g_fake.connection_calls == 0 && g_fake.create_calls == 0 &&
           g_fake.set_calls == 0 && g_fake.commit_calls == 0);
}

int main(void)
{
    test_shared_clock_atomic_frames_and_exact_endpoint();
    test_stalled_clock_stops_after_one_frame();
    test_initial_clock_failure_and_cancellation_do_not_mutate();
    test_validation_has_no_side_effects();
    return 0;
}
