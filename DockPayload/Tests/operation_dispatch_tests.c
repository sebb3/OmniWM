#include "operation_dispatch.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int main_calls;
    int bounds_calls;
    int move_calls;
    int get_transform_calls;
    int set_transform_calls;
    int set_warp_calls;
    CGError bounds_result;
    CGError move_result;
    bool get_transform_fails;
    int set_transform_fail_remaining; /* fail the first N set calls */
    int set_warp_fail_remaining;      /* fail the first N warp calls */
    CGRect frame;
    CGAffineTransform observed; /* fake value returned by SLSGetWindowTransform */
    CGAffineTransform last_transform;
    uint32_t window_id;
    CGPoint target;
    int transaction_create_calls;
    int transaction_set_calls;
    int transaction_commit_calls;
    int transaction_release_calls;
    int first_transaction_event;
    int event_counter;
    struct {
        uint32_t window_id;
        CGAffineTransform transform;
    } transaction_sets[16];
    struct {
        int columns;
        int rows;
        bool null_mesh;
        hs2_sls_warp_point mesh[HS2_DOCK_V2_WARP_POINTS];
    } last_warp;
} fake_skylight;

static fake_skylight g_fake;

static int fake_main_connection_id(void)
{
    g_fake.main_calls++;
    return 42;
}

static CGError fake_get_window_bounds(int connection, uint32_t window_id, CGRect *frame)
{
    assert(connection == 42);
    g_fake.bounds_calls++;
    g_fake.event_counter++;
    g_fake.window_id = window_id;
    if (g_fake.bounds_result == kCGErrorSuccess) {
        *frame = g_fake.frame;
    }
    return g_fake.bounds_result;
}

static CGError fake_move_window_with_group(int connection, uint32_t window_id, CGPoint *target)
{
    assert(connection == 42);
    g_fake.move_calls++;
    g_fake.window_id = window_id;
    g_fake.target = *target;
    return g_fake.move_result;
}

static CGError fake_get_window_transform(int connection, uint32_t window_id,
                                         CGAffineTransform *transform)
{
    assert(connection == 42);
    g_fake.get_transform_calls++;
    g_fake.event_counter++;
    g_fake.window_id = window_id;
    if (g_fake.get_transform_fails) {
        return kCGErrorFailure;
    }
    *transform = g_fake.observed;
    return kCGErrorSuccess;
}

static CGError fake_set_window_transform(int connection, uint32_t window_id,
                                         CGAffineTransform transform)
{
    assert(connection == 42);
    g_fake.set_transform_calls++;
    g_fake.window_id = window_id;
    g_fake.last_transform = transform;
    if (g_fake.set_transform_fail_remaining > 0) {
        g_fake.set_transform_fail_remaining--;
        return kCGErrorFailure;
    }
    return kCGErrorSuccess;
}

static CGError fake_set_window_warp(int connection, uint32_t window_id, int columns, int rows,
                                    const hs2_sls_warp_point *mesh)
{
    assert(connection == 42);
    g_fake.set_warp_calls++;
    g_fake.window_id = window_id;
    g_fake.last_warp.columns = columns;
    g_fake.last_warp.rows = rows;
    g_fake.last_warp.null_mesh = mesh == NULL;
    if (mesh != NULL) {
        memcpy(g_fake.last_warp.mesh, mesh, sizeof(g_fake.last_warp.mesh));
    }
    if (g_fake.set_warp_fail_remaining > 0) {
        g_fake.set_warp_fail_remaining--;
        return kCGErrorFailure;
    }
    return kCGErrorSuccess;
}

static CFTypeRef fake_transaction_create(int connection)
{
    assert(connection == 42);
    g_fake.transaction_create_calls++;
    g_fake.first_transaction_event = g_fake.first_transaction_event == 0
        ? ++g_fake.event_counter : g_fake.first_transaction_event;
    return (CFTypeRef)(uintptr_t)g_fake.transaction_create_calls;
}

static void fake_transaction_set(CFTypeRef transaction, uint32_t window_id,
                                 int32_t unknown1, int32_t unknown2,
                                 CGAffineTransform transform)
{
    assert(transaction != NULL && unknown1 == 0 && unknown2 == 0);
    assert(g_fake.transaction_set_calls < 16);
    size_t index = (size_t)g_fake.transaction_set_calls++;
    g_fake.transaction_sets[index].window_id = window_id;
    g_fake.transaction_sets[index].transform = transform;
}

static void fake_transaction_commit(CFTypeRef transaction, int32_t synchronous)
{
    assert(transaction != NULL && synchronous == 0);
    g_fake.transaction_commit_calls++;
}

static void fake_transaction_release(CFTypeRef transaction)
{
    assert(transaction != NULL);
    g_fake.transaction_release_calls++;
}

static hs2_dock_skylight_api complete_api(void)
{
    return (hs2_dock_skylight_api){
        .main_connection_id = fake_main_connection_id,
        .get_window_bounds = fake_get_window_bounds,
        .move_window_with_group = fake_move_window_with_group,
        .get_window_transform = fake_get_window_transform,
        .set_window_transform = fake_set_window_transform,
        .set_window_warp = fake_set_window_warp,
        .transaction_create = fake_transaction_create,
        .transaction_set_window_transform = fake_transaction_set,
        .transaction_commit = fake_transaction_commit,
        .transaction_release = fake_transaction_release,
    };
}

static hs2_dock_v2_handshake_request handshake_request(uint64_t optional_capabilities)
{
    hs2_dock_v2_handshake_request request = {
        .protocol_min_major = HS2_DOCK_V2_MAJOR,
        .protocol_max_major = HS2_DOCK_V2_MAJOR,
        .build_min = HS2_DOCK_V2_BUILD,
        .build_max = HS2_DOCK_V2_BUILD,
        .optional_capabilities = optional_capabilities,
    };
    for (size_t index = 0; index < HS2_DOCK_V2_NONCE_BYTES; index++) {
        request.nonce[index] = (uint8_t)(0x80u + index);
    }
    return request;
}

static hs2_dock_v2_handshake_response establish(hs2_dock_v2_server *server,
                                                 const hs2_dock_v2_peer *peer,
                                                 uint64_t optional_capabilities,
                                                 hs2_dock_v2_handshake_request *request)
{
    *request = handshake_request(optional_capabilities);
    hs2_dock_v2_handshake_response response;
    assert(hs2_dock_v2_handshake(server, peer, request, &response) == HS2_DOCK_V2_OK);
    return response;
}

static hs2_dock_v2_envelope envelope_for(uint16_t type, uint16_t payload_bytes,
                                         uint64_t request_id, uint64_t session_id)
{
    return (hs2_dock_v2_envelope){
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = type,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = payload_bytes,
        .request_id = request_id,
        .session_id = session_id,
    };
}

static hs2_dock_v2_frame_response dispatch_and_decode(const hs2_dock_skylight_api *api,
                                                       hs2_dock_v2_server *server,
                                                       const hs2_dock_v2_peer *peer,
                                                       const hs2_dock_v2_envelope *envelope,
                                                       const uint8_t *payload)
{
    hs2_dock_operation_reply reply;
    hs2_dock_v2_frame_response response;
    assert(hs2_dock_dispatch_operation(api, server, peer, envelope, payload, &reply));
    assert(reply.message_type == HS2_DOCK_V2_FRAME_RESPONSE);
    assert(reply.payload_bytes == HS2_DOCK_V2_FRAME_RESPONSE_BYTES);
    assert(hs2_dock_v2_decode_frame_response(reply.payload, reply.payload_bytes, &response));
    return response;
}

static hs2_dock_v2_response dispatch_status_and_decode(const hs2_dock_skylight_api *api,
                                                       hs2_dock_v2_server *server,
                                                       const hs2_dock_v2_peer *peer,
                                                       const hs2_dock_v2_envelope *envelope,
                                                       const uint8_t *payload)
{
    hs2_dock_operation_reply reply;
    hs2_dock_v2_response response;
    assert(hs2_dock_dispatch_operation(api, server, peer, envelope, payload, &reply));
    assert(reply.message_type == HS2_DOCK_V2_RESPONSE);
    assert(reply.payload_bytes == HS2_DOCK_V2_RESPONSE_BYTES);
    assert(hs2_dock_v2_decode_response(reply.payload, reply.payload_bytes, &response));
    return response;
}

static void create_lease(hs2_dock_v2_server *server, const hs2_dock_v2_peer *peer,
                         const hs2_dock_v2_handshake_response *accepted,
                         const hs2_dock_v2_handshake_request *handshake,
                         uint64_t lease_id, uint64_t window_id, uint64_t operation,
                         uint64_t request_id)
{
    hs2_dock_v2_lease_request lease = {
        .lease_id = lease_id,
        .window_id = window_id,
        .operation = operation,
    };
    memcpy(lease.nonce, handshake->nonce, sizeof(lease.nonce));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_LEASE_CREATE,
        HS2_DOCK_V2_LEASE_REQUEST_BYTES, request_id, accepted->session_id);
    assert(hs2_dock_v2_handle_lease(server, peer, &envelope, &lease) == HS2_DOCK_V2_OK);
}

static uint16_t release_lease(hs2_dock_v2_server *server, const hs2_dock_v2_peer *peer,
                              const hs2_dock_v2_handshake_response *accepted,
                              const hs2_dock_v2_handshake_request *handshake,
                              uint64_t lease_id, uint64_t window_id, uint64_t operation,
                              uint64_t request_id)
{
    hs2_dock_v2_lease_request lease = {
        .lease_id = lease_id,
        .window_id = window_id,
        .operation = operation,
    };
    memcpy(lease.nonce, handshake->nonce, sizeof(lease.nonce));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_LEASE_RELEASE,
        HS2_DOCK_V2_LEASE_REQUEST_BYTES, request_id, accepted->session_id);
    return hs2_dock_v2_handle_lease(server, peer, &envelope, &lease);
}

static void test_capability_correspondence(void)
{
    hs2_dock_skylight_api api = {0};
    assert(hs2_dock_active_capabilities(&api) == HS2_DOCK_V2_CAP_LEASES);
    api.main_connection_id = fake_main_connection_id;
    assert(hs2_dock_active_capabilities(&api) == HS2_DOCK_V2_CAP_LEASES);
    api.get_window_bounds = fake_get_window_bounds;
    assert(hs2_dock_active_capabilities(&api) ==
           (HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_QUERY_FRAME));
    api.move_window_with_group = fake_move_window_with_group;
    assert(hs2_dock_active_capabilities(&api) ==
           (HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_QUERY_FRAME |
            HS2_DOCK_V2_CAP_MOVE_REAL));

    /* Transform needs bounds + get-transform + set-transform; partial sets remove it. */
    api.get_window_transform = fake_get_window_transform;
    assert(hs2_dock_active_capabilities(&api) ==
           (HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_QUERY_FRAME |
            HS2_DOCK_V2_CAP_MOVE_REAL));
    api.set_window_transform = fake_set_window_transform;
    assert(hs2_dock_active_capabilities(&api) ==
           (HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_QUERY_FRAME |
            HS2_DOCK_V2_CAP_MOVE_REAL | HS2_DOCK_V2_CAP_SET_TRANSFORM));
    hs2_dock_skylight_api missing_bounds = api;
    missing_bounds.get_window_bounds = NULL;
    assert((hs2_dock_active_capabilities(&missing_bounds) &
            (HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_QUERY_FRAME)) == 0);

    /* Warp and clear-warp both need the single warp handler. */
    hs2_dock_v2_warp_point unused;
    (void)unused;
    hs2_dock_skylight_api warp_only = { .main_connection_id = fake_main_connection_id };
    assert(hs2_dock_active_capabilities(&warp_only) == HS2_DOCK_V2_CAP_LEASES);
    warp_only.set_window_warp = fake_set_window_warp;
    assert(hs2_dock_active_capabilities(&warp_only) ==
           (HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_WARP |
            HS2_DOCK_V2_CAP_CLEAR_WARP));
}

static void test_query_success_and_failure(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_QUERY_FRAME, &handshake);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);

    hs2_dock_v2_query_request query = { .window_id = 7 };
    memcpy(query.nonce, handshake.nonce, sizeof(query.nonce));
    uint8_t payload[HS2_DOCK_V2_QUERY_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_QUERY_FRAME, sizeof(payload),
                                                  1, accepted.session_id);
    hs2_dock_v2_frame_response response = dispatch_and_decode(&api, &server, &peer,
                                                               &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK && response.x == 10.0 && response.height == 40.0);
    assert(g_fake.main_calls == 1 && g_fake.bounds_calls == 1 && g_fake.move_calls == 0);

    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_QUERY_FRAME, &handshake);
    memcpy(query.nonce, handshake.nonce, sizeof(query.nonce));
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    envelope = envelope_for(HS2_DOCK_V2_QUERY_FRAME, sizeof(payload), 2, accepted.session_id);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorFailure;
    response = dispatch_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED && response.detail == kCGErrorFailure);
    assert(response.x == 0.0 && response.y == 0.0 && g_fake.bounds_calls == 1);
}

static void test_move_success_failure_and_validation(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_MOVE_REAL, &handshake);
    create_lease(&server, &peer, &accepted, &handshake, 9, 7, HS2_DOCK_V2_CAP_MOVE_REAL, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.move_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(100.0, 200.0, 30.0, 40.0);

    hs2_dock_v2_move_request move = { .lease_id = 9, .window_id = 7, .x = 100.0, .y = 200.0 };
    memcpy(move.nonce, handshake.nonce, sizeof(move.nonce));
    uint8_t payload[HS2_DOCK_V2_MOVE_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_move_request(&move, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_MOVE_REAL, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_frame_response response = dispatch_and_decode(&api, &server, &peer,
                                                               &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK && response.x == 100.0 && response.y == 200.0);
    assert(g_fake.move_calls == 1 && g_fake.bounds_calls == 1 && g_fake.target.x == 100.0);

    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_MOVE_REAL,
                         &handshake);
    create_lease(&server, &peer, &accepted, &handshake, 9, 7, HS2_DOCK_V2_CAP_MOVE_REAL, 1);
    memcpy(move.nonce, handshake.nonce, sizeof(move.nonce));
    assert(hs2_dock_v2_encode_move_request(&move, payload));
    envelope = envelope_for(HS2_DOCK_V2_MOVE_REAL, sizeof(payload), 2, accepted.session_id);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.move_result = kCGErrorFailure;
    response = dispatch_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED && response.detail == kCGErrorFailure);
    assert(g_fake.move_calls == 1 && g_fake.bounds_calls == 0);

    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_MOVE_REAL,
                         &handshake);
    create_lease(&server, &peer, &accepted, &handshake, 9, 7, HS2_DOCK_V2_CAP_MOVE_REAL, 1);
    memcpy(move.nonce, handshake.nonce, sizeof(move.nonce));
    move.window_id = UINT64_C(0x100000000);
    memset(&g_fake, 0, sizeof(g_fake));
    assert(hs2_dock_v2_encode_move_request(&move, payload));
    envelope = envelope_for(HS2_DOCK_V2_MOVE_REAL, sizeof(payload), 2, accepted.session_id);
    response = dispatch_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE);
    assert(g_fake.main_calls == 0 && g_fake.bounds_calls == 0 && g_fake.move_calls == 0);

    move.window_id = 7;
    move.x = 1000001.0;
    assert(hs2_dock_v2_encode_move_request(&move, payload));
    envelope.request_id = 3;
    response = dispatch_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE);
    assert(g_fake.main_calls == 0 && g_fake.bounds_calls == 0 && g_fake.move_calls == 0);
}

static void test_missing_handler_and_session_validation(void)
{
    hs2_dock_skylight_api missing = {0};
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&missing));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer, 0, &handshake);
    hs2_dock_v2_query_request query = { .window_id = 1 };
    memcpy(query.nonce, handshake.nonce, sizeof(query.nonce));
    uint8_t payload[HS2_DOCK_V2_QUERY_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_QUERY_FRAME, sizeof(payload), 1,
                                                  accepted.session_id);
    hs2_dock_v2_frame_response response = dispatch_and_decode(&missing, &server, &peer,
                                                               &envelope, payload);
    assert(response.error == HS2_DOCK_V2_CAPABILITY_REJECTED);

    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_QUERY_FRAME, &handshake);
    query.nonce[0] = 0;
    assert(hs2_dock_v2_encode_query_request(&query, payload));
    envelope.session_id = accepted.session_id;
    envelope.request_id = 1;
    memset(&g_fake, 0, sizeof(g_fake));
    response = dispatch_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_SESSION_REJECTED);
    assert(g_fake.main_calls == 0 && g_fake.bounds_calls == 0);
}

/* SET_TRANSFORM: capture-before-mutate, exact payload routing, canonical
 * restore on lease release using the fresh authoritative frame. */
static void test_transform_success_and_release_cleanup(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 11, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);

    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);
    g_fake.observed = CGAffineTransformMake(2.0, 0.5, 0.0, 2.0, 99.0, 98.0);

    hs2_dock_v2_transform_request transform = {
        .lease_id = 11, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK && response.value == 11);
    assert(g_fake.bounds_calls == 1 && g_fake.get_transform_calls == 1);
    assert(g_fake.set_transform_calls == 1 && g_fake.set_warp_calls == 0);
    assert(g_fake.last_transform.tx == -160.0 && g_fake.last_transform.a == 1.0);

    /* Cleanup data retained on the lease before the mutating call. */
    bool found = false;
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        if (server.leases[index].active && server.leases[index].lease_id == 11) {
            found = true;
            assert(server.leases[index].note.transform_pending);
            assert(server.leases[index].note.frame_captured);
            assert(server.leases[index].note.frame.x == 10.0 &&
                   server.leases[index].note.frame.y == 20.0);
            assert(server.leases[index].note.observed_captured);
            assert(server.leases[index].note.observed.tx == 99.0); /* diagnostic only */
        }
    }
    assert(found);

    /* Release: canonical restore derived from the fresh authoritative frame. */
    g_fake.frame = CGRectMake(70.0, 82.0, 30.0, 40.0);
    assert(release_lease(&server, &peer, &accepted, &handshake, 11, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 3) == HS2_DOCK_V2_OK);
    assert(g_fake.set_transform_calls == 2);
    assert(g_fake.last_transform.tx == -70.0 && g_fake.last_transform.ty == -82.0);
    assert(g_fake.last_transform.a == 1.0 && g_fake.last_transform.d == 1.0);
    assert(hs2_dock_v2_active_leases(&server) == 0);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);
}

/* The observed SLSGetWindowTransform value is never trusted for restore even
 * when bounds fails at cleanup time: the retained frame still drives the
 * canonical restore. */
static void test_transform_restore_never_uses_observed_value(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 12, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(100.0, 200.0, 50.0, 60.0);
    g_fake.observed = CGAffineTransformMake(9.0, 9.0, 9.0, 9.0, -123.0, -456.0);

    hs2_dock_v2_transform_request transform = {
        .lease_id = 12, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = 0.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    assert(dispatch_status_and_decode(&api, &server, &peer, &envelope, payload).error ==
           HS2_DOCK_V2_OK);

    g_fake.bounds_result = kCGErrorFailure; /* cleanup cannot refresh bounds */
    assert(release_lease(&server, &peer, &accepted, &handshake, 12, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 3) == HS2_DOCK_V2_OK);
    assert(g_fake.set_transform_calls == 2);
    /* retained authoritative frame, not the observed diagnostic transform */
    assert(g_fake.last_transform.tx == -100.0 && g_fake.last_transform.ty == -200.0);
    assert(g_fake.last_transform.a == 1.0 && g_fake.last_transform.b == 0.0);
    assert(hs2_dock_v2_active_leases(&server) == 0);
}

/* Mutation failure restores immediately; a failing restore stays retryable. */
static void test_transform_partial_failure_and_retry(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 13, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);
    g_fake.set_transform_fail_remaining = 1; /* mutation fails, restore succeeds */

    hs2_dock_v2_transform_request transform = {
        .lease_id = 13, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED &&
           response.detail == kCGErrorFailure);
    assert(g_fake.set_transform_calls == 2); /* mutation + immediate restore */
    assert(g_fake.last_transform.tx == -10.0 && g_fake.last_transform.ty == -20.0);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);
    /* release has no residue to restore */
    int calls = g_fake.set_transform_calls;
    assert(release_lease(&server, &peer, &accepted, &handshake, 13, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 3) == HS2_DOCK_V2_OK);
    assert(g_fake.set_transform_calls == calls);
    assert(hs2_dock_v2_active_leases(&server) == 0);

    /* mutation and restore both fail: residue stays identified and retryable */
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM,
                         &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 14, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);
    g_fake.set_transform_fail_remaining = 3; /* mutation, restore, release retry */
    transform.lease_id = 14;
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                            accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED);
    assert(g_fake.set_transform_calls == 2);
    assert(hs2_dock_v2_active_leases(&server) == 1);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 1);

    /* release fails, keeps the lease for retry */
    assert(release_lease(&server, &peer, &accepted, &handshake, 14, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 3) == HS2_DOCK_V2_CLEANUP_FAILED);
    assert(hs2_dock_v2_active_leases(&server) == 1);
    assert(g_fake.set_transform_calls == 3); /* failed retry inside release */

    /* the retry now succeeds and deactivates the lease */
    assert(release_lease(&server, &peer, &accepted, &handshake, 14, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 4) == HS2_DOCK_V2_OK);
    assert(hs2_dock_v2_active_leases(&server) == 0);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);
    assert(g_fake.set_transform_calls == 4);
}

/* SET_TRANSFORM refuses to mutate when the authoritative frame is unavailable:
 * no canonical restore would exist. */
static void test_transform_requires_authoritative_frame(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 15, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorFailure;

    hs2_dock_v2_transform_request transform = {
        .lease_id = 15, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED &&
           response.detail == kCGErrorFailure);
    assert(g_fake.bounds_calls == 1 && g_fake.set_transform_calls == 0);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);
    assert(release_lease(&server, &peer, &accepted, &handshake, 15, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 3) == HS2_DOCK_V2_OK);
}

/* A failing diagnostic SLSGetWindowTransform read does not block the mutation:
 * restoration never depended on the observed value. */
static void test_transform_observed_read_failure_is_non_fatal(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 16, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);
    g_fake.get_transform_fails = true;

    hs2_dock_v2_transform_request transform = {
        .lease_id = 16, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK);
    assert(g_fake.get_transform_calls == 1 && g_fake.set_transform_calls == 1);
    bool found = false;
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        if (server.leases[index].active && server.leases[index].lease_id == 16) {
            found = true;
            assert(server.leases[index].note.frame_captured);
            assert(!server.leases[index].note.observed_captured);
            assert(server.leases[index].note.transform_pending);
        }
    }
    assert(found);
    assert(release_lease(&server, &peer, &accepted, &handshake, 16, 7,
                         HS2_DOCK_V2_CAP_SET_TRANSFORM, 3) == HS2_DOCK_V2_OK);
    assert(g_fake.set_transform_calls == 2);
    assert(g_fake.last_transform.tx == -10.0 && g_fake.last_transform.ty == -20.0);
}

/* SET_WARP routes exactly the bounded 9x2 mesh; CLEAR_WARP and cleanup use the
 * exact 0, 0, NULL relinquish call. */
static void test_warp_clear_and_cleanup(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
        &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 21, 7,
                 HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP, 1);
    memset(&g_fake, 0, sizeof(g_fake));

    hs2_dock_v2_warp_request warp = { .lease_id = 21, .window_id = 7, .columns = 9, .rows = 2 };
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        warp.points[index] = (hs2_dock_v2_warp_point){
            .local_x = (float)(index * 10), .local_y = (float)(index % 2),
            .global_x = (float)(1000 + index), .global_y = (float)(-2000 - (double)index),
        };
    }
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_WARP, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK && response.value == 21);
    assert(g_fake.set_warp_calls == 1 && g_fake.window_id == 7);
    assert(g_fake.last_warp.columns == 9 && g_fake.last_warp.rows == 2);
    assert(!g_fake.last_warp.null_mesh);
    assert(g_fake.last_warp.mesh[4].local_x == 40.0f && g_fake.last_warp.mesh[4].local_y == 0.0f);
    assert(g_fake.last_warp.mesh[4].global_x == 1004.0f &&
           g_fake.last_warp.mesh[4].global_y == -2004.0f);
    assert(g_fake.set_transform_calls == 0 && g_fake.bounds_calls == 0);

    /* explicit clear with the exact evidenced call */
    hs2_dock_v2_clear_warp_request clear = { .lease_id = 21, .window_id = 7 };
    memcpy(clear.nonce, handshake.nonce, sizeof(clear.nonce));
    uint8_t clear_payload[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_clear_warp_request(&clear, clear_payload));
    hs2_dock_v2_envelope clear_envelope = envelope_for(HS2_DOCK_V2_CLEAR_WARP,
        sizeof(clear_payload), 3, accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &clear_envelope,
                                          clear_payload);
    assert(response.error == HS2_DOCK_V2_OK);
    assert(g_fake.set_warp_calls == 2);
    assert(g_fake.last_warp.columns == 0 && g_fake.last_warp.rows == 0 &&
           g_fake.last_warp.null_mesh);

    /* nothing pending: release performs no further SkyLight calls */
    assert(release_lease(&server, &peer, &accepted, &handshake, 21, 7,
                         HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
                         4) == HS2_DOCK_V2_OK);
    assert(g_fake.set_warp_calls == 2);
    assert(hs2_dock_v2_active_leases(&server) == 0);

    /* warp without explicit clear: release cleanup clears with 0, 0, NULL */
    create_lease(&server, &peer, &accepted, &handshake, 22, 7,
                 HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP, 5);
    warp.lease_id = 22;
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    envelope = envelope_for(HS2_DOCK_V2_SET_WARP, sizeof(payload), 6, accepted.session_id);
    assert(dispatch_status_and_decode(&api, &server, &peer, &envelope, payload).error ==
           HS2_DOCK_V2_OK);
    assert(release_lease(&server, &peer, &accepted, &handshake, 22, 7,
                         HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
                         7) == HS2_DOCK_V2_OK);
    assert(g_fake.set_warp_calls == 4);
    assert(g_fake.last_warp.columns == 0 && g_fake.last_warp.rows == 0 &&
           g_fake.last_warp.null_mesh);
}

/* Warp mutation failure clears immediately; a failing clear stays retryable;
 * clear-warp failure also stays retryable through the lease. */
static void test_warp_failure_and_retry(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
        &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 31, 7,
                 HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP, 1);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.set_warp_fail_remaining = 1; /* mutation fails, immediate clear succeeds */

    hs2_dock_v2_warp_request warp = { .lease_id = 31, .window_id = 7, .columns = 9, .rows = 2 };
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    uint8_t payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_WARP, sizeof(payload), 2,
                                                  accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED &&
           response.detail == kCGErrorFailure);
    assert(g_fake.set_warp_calls == 2);
    assert(g_fake.last_warp.columns == 0 && g_fake.last_warp.rows == 0 &&
           g_fake.last_warp.null_mesh);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);

    /* mutation and clear both fail: residue stays retryable via release */
    create_lease(&server, &peer, &accepted, &handshake, 32, 7,
                 HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP, 3);
    g_fake.set_warp_fail_remaining = 3; /* mutation, immediate clear, release retry */
    warp.lease_id = 32;
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    envelope = envelope_for(HS2_DOCK_V2_SET_WARP, sizeof(payload), 4, accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED);
    assert(hs2_dock_v2_active_leases(&server) == 2);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 1);
    int calls = g_fake.set_warp_calls;
    assert(release_lease(&server, &peer, &accepted, &handshake, 32, 7,
                         HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
                         5) == HS2_DOCK_V2_CLEANUP_FAILED);
    assert(g_fake.set_warp_calls == calls + 1); /* retried clear failed again */
    assert(hs2_dock_v2_active_leases(&server) == 2);
    assert(release_lease(&server, &peer, &accepted, &handshake, 32, 7,
                         HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
                         6) == HS2_DOCK_V2_OK);
    assert(g_fake.last_warp.columns == 0 && g_fake.last_warp.rows == 0 &&
           g_fake.last_warp.null_mesh);
    assert(hs2_dock_v2_active_leases(&server) == 1);

    /* an explicit CLEAR_WARP failure also leaves retryable residue */
    create_lease(&server, &peer, &accepted, &handshake, 33, 8,
                 HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP, 7);
    memset(&g_fake, 0, sizeof(g_fake));
    warp.lease_id = 33;
    warp.window_id = 8;
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    assert(hs2_dock_v2_encode_warp_request(&warp, payload));
    envelope = envelope_for(HS2_DOCK_V2_SET_WARP, sizeof(payload), 8, accepted.session_id);
    assert(dispatch_status_and_decode(&api, &server, &peer, &envelope, payload).error ==
           HS2_DOCK_V2_OK);
    g_fake.set_warp_fail_remaining = 1;
    hs2_dock_v2_clear_warp_request clear = { .lease_id = 33, .window_id = 8 };
    memcpy(clear.nonce, handshake.nonce, sizeof(clear.nonce));
    uint8_t clear_payload[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_clear_warp_request(&clear, clear_payload));
    hs2_dock_v2_envelope clear_envelope = envelope_for(HS2_DOCK_V2_CLEAR_WARP,
        sizeof(clear_payload), 9, accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &clear_envelope,
                                          clear_payload);
    assert(response.error == HS2_DOCK_V2_OPERATION_FAILED);
    assert(release_lease(&server, &peer, &accepted, &handshake, 33, 8,
                         HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP,
                         10) == HS2_DOCK_V2_OK);
    assert(g_fake.last_warp.null_mesh);
    assert(hs2_dock_v2_active_leases(&server) == 1);
}

/* Validation and lease/session gating must reject before any SkyLight call. */
static void test_transform_warp_validation_and_lease_gating(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_SET_WARP |
        HS2_DOCK_V2_CAP_CLEAR_WARP, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);

    hs2_dock_v2_transform_request transform = {
        .lease_id = 41, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);

    /* no lease exists yet */
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_LEASE_REJECTED);
    assert(g_fake.main_calls == 0 && g_fake.bounds_calls == 0 &&
           g_fake.set_transform_calls == 0);

    /* lease exists but for a different operation bit */
    create_lease(&server, &peer, &accepted, &handshake, 41, 7, HS2_DOCK_V2_CAP_SET_WARP, 1);
    envelope.request_id = 3;
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_LEASE_REJECTED);
    assert(g_fake.main_calls == 0 && g_fake.set_transform_calls == 0);

    /* over-range transform component */
    create_lease(&server, &peer, &accepted, &handshake, 42, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 4);
    transform.lease_id = 42;
    transform.tx = 1000001.0;
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 5,
                            accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE);
    assert(g_fake.main_calls == 0 && g_fake.set_transform_calls == 0);

    /* warp: non-9x2 mesh is rejected by the codec, over-range points by dispatch */
    hs2_dock_v2_warp_request warp = { .lease_id = 42, .window_id = 7, .columns = 9, .rows = 2 };
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        warp.points[index] = (hs2_dock_v2_warp_point){ .local_x = (float)index, .local_y = 0,
                                                        .global_x = 1, .global_y = 2 };
    }
    warp.rows = 3;
    uint8_t warp_payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    assert(!hs2_dock_v2_encode_warp_request(&warp, warp_payload));
    warp.rows = 2;
    warp.points[7].global_x = 1000001.0f;
    assert(hs2_dock_v2_encode_warp_request(&warp, warp_payload));
    hs2_dock_v2_envelope warp_envelope = envelope_for(HS2_DOCK_V2_SET_WARP,
        sizeof(warp_payload), 6, accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &warp_envelope, warp_payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE);
    assert(g_fake.set_warp_calls == 0);

    /* clear warp without a clear-capable lease */
    hs2_dock_v2_clear_warp_request clear = { .lease_id = 42, .window_id = 7 };
    memcpy(clear.nonce, handshake.nonce, sizeof(clear.nonce));
    uint8_t clear_payload[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_clear_warp_request(&clear, clear_payload));
    hs2_dock_v2_envelope clear_envelope = envelope_for(HS2_DOCK_V2_CLEAR_WARP,
        sizeof(clear_payload), 7, accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &clear_envelope,
                                          clear_payload);
    assert(response.error == HS2_DOCK_V2_LEASE_REJECTED);
    assert(g_fake.set_warp_calls == 0);

    /* wrong window id */
    clear.window_id = UINT64_C(0x100000000);
    assert(hs2_dock_v2_encode_clear_warp_request(&clear, clear_payload));
    clear_envelope = envelope_for(HS2_DOCK_V2_CLEAR_WARP, sizeof(clear_payload), 8,
                                  accepted.session_id);
    response = dispatch_status_and_decode(&api, &server, &peer, &clear_envelope,
                                          clear_payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE);
    assert(g_fake.set_warp_calls == 0);
}

/* Missing symbols remove capabilities: no handler is ever called. */
static void test_missing_symbol_removes_capabilities(void)
{
    hs2_dock_skylight_api partial = complete_api();
    hs2_dock_skylight_api warpless = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;

    partial.set_window_transform = NULL;
    warpless.set_window_warp = NULL;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&partial));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_SET_WARP |
        HS2_DOCK_V2_CAP_CLEAR_WARP, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &partial);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);

    hs2_dock_v2_transform_request transform = {
        .lease_id = 51, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    /* the session cannot grant an unavailable capability */
    hs2_dock_v2_response response = dispatch_status_and_decode(&partial, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_CAPABILITY_REJECTED);
    assert(g_fake.set_transform_calls == 0);

    /* warp symbols missing on an otherwise authorized connection */
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&warpless));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_WARP |
                         HS2_DOCK_V2_CAP_CLEAR_WARP, &handshake);
    hs2_dock_v2_warp_request warp = { .lease_id = 51, .window_id = 7, .columns = 9, .rows = 2 };
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    uint8_t warp_payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_warp_request(&warp, warp_payload));
    hs2_dock_v2_envelope warp_envelope = envelope_for(HS2_DOCK_V2_SET_WARP,
        sizeof(warp_payload), 3, accepted.session_id);
    response = dispatch_status_and_decode(&warpless, &server, &peer, &warp_envelope,
                                          warp_payload);
    assert(response.error == HS2_DOCK_V2_CAPABILITY_REJECTED);
    assert(g_fake.set_warp_calls == 0);
}

/* Disconnect and unload run the lease-backed cleanup for every mutated lease. */
static void test_disconnect_and_unload_cleanup(void)
{
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_peer peer = { .uid = geteuid(), .pid = getpid() };
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_SET_WARP |
        HS2_DOCK_V2_CAP_CLEAR_WARP, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);

    create_lease(&server, &peer, &accepted, &handshake, 61, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 1);
    hs2_dock_v2_transform_request transform = {
        .lease_id = 61, .window_id = 7,
        .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -160.0, .ty = 0.0,
    };
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    uint8_t payload[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 2,
                                                  accepted.session_id);
    assert(dispatch_status_and_decode(&api, &server, &peer, &envelope, payload).error ==
           HS2_DOCK_V2_OK);

    create_lease(&server, &peer, &accepted, &handshake, 62, 8,
                 HS2_DOCK_V2_CAP_SET_WARP | HS2_DOCK_V2_CAP_CLEAR_WARP, 3);
    hs2_dock_v2_warp_request warp = { .lease_id = 62, .window_id = 8, .columns = 9, .rows = 2 };
    memcpy(warp.nonce, handshake.nonce, sizeof(warp.nonce));
    uint8_t warp_payload[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    assert(hs2_dock_v2_encode_warp_request(&warp, warp_payload));
    hs2_dock_v2_envelope warp_envelope = envelope_for(HS2_DOCK_V2_SET_WARP,
        sizeof(warp_payload), 4, accepted.session_id);
    assert(dispatch_status_and_decode(&api, &server, &peer, &warp_envelope, warp_payload).error
           == HS2_DOCK_V2_OK);

    assert(g_fake.set_transform_calls == 1 && g_fake.set_warp_calls == 1);
    assert(hs2_dock_v2_disconnect(&server, &peer, accepted.session_id,
                                  handshake.nonce) == HS2_DOCK_V2_OK);
    assert(g_fake.set_transform_calls == 2); /* canonical restore */
    assert(g_fake.last_transform.tx == -10.0 && g_fake.last_transform.ty == -20.0);
    assert(g_fake.set_warp_calls == 2); /* exact 0, 0, NULL clear */
    assert(g_fake.last_warp.null_mesh && g_fake.last_warp.columns == 0);
    assert(hs2_dock_v2_active_leases(&server) == 0);

    /* unload retries residue left by a failed disconnect cleanup */
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    accepted = establish(&server, &peer, HS2_DOCK_V2_CAP_LEASES |
                         HS2_DOCK_V2_CAP_SET_TRANSFORM | HS2_DOCK_V2_CAP_SET_WARP |
                         HS2_DOCK_V2_CAP_CLEAR_WARP, &handshake);
    hs2_dock_v2_server_set_cleanup(&server, hs2_dock_cleanup_lease_residue, &api);
    create_lease(&server, &peer, &accepted, &handshake, 63, 7,
                 HS2_DOCK_V2_CAP_SET_TRANSFORM, 5);
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.bounds_result = kCGErrorSuccess;
    g_fake.frame = CGRectMake(10.0, 20.0, 30.0, 40.0);
    transform.lease_id = 63;
    memcpy(transform.nonce, handshake.nonce, sizeof(transform.nonce));
    assert(hs2_dock_v2_encode_transform_request(&transform, payload));
    envelope = envelope_for(HS2_DOCK_V2_SET_TRANSFORM, sizeof(payload), 6,
                            accepted.session_id);
    assert(dispatch_status_and_decode(&api, &server, &peer, &envelope, payload).error ==
           HS2_DOCK_V2_OK);
    g_fake.set_transform_fail_remaining = 1; /* disconnect restore fails */
    assert(hs2_dock_v2_disconnect(&server, &peer, accepted.session_id,
                                  handshake.nonce) == HS2_DOCK_V2_CLEANUP_FAILED);
    assert(g_fake.set_transform_calls == 2); /* mutation + failed disconnect restore */
    assert(hs2_dock_v2_active_leases(&server) == 1);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 1);
    assert(hs2_dock_v2_unload(&server) == HS2_DOCK_V2_OK); /* unload retries */
    assert(g_fake.set_transform_calls == 3);
    assert(g_fake.last_transform.tx == -10.0 && g_fake.last_transform.ty == -20.0);
    assert(hs2_dock_v2_active_leases(&server) == 0);
    assert(!server.loaded);
}

static void encode_transition(const hs2_dock_v2_handshake_request *handshake,
                              uint64_t lease1, uint64_t window1,
                              uint64_t lease2, uint64_t window2,
                              uint8_t *payload, uint16_t *payload_bytes)
{
    hs2_dock_v2_workspace_transition_request request = {
        .duration_ns = UINT64_C(1000000),
        .frame_interval_ns = UINT64_C(1000000),
        .member_count = 2,
        .members = {
            { .lease_id = lease1, .window_id = window1,
              .from = {1, 0, 0, 1, 10, 20}, .to = {1, 0, 0, 1, 110, 120} },
            { .lease_id = lease2, .window_id = window2,
              .from = {1, 0, 0, 1, -5, -6}, .to = {2, 0, 0, 2, 205, 206} },
        },
    };
    memcpy(request.nonce, handshake->nonce, sizeof(request.nonce));
    *payload_bytes = HS2_DOCK_V2_WORKSPACE_TRANSITION_PREFIX_BYTES +
        2 * HS2_DOCK_V2_WORKSPACE_TRANSITION_MEMBER_BYTES;
    assert(hs2_dock_v2_encode_workspace_transition_request(&request, payload, *payload_bytes));
}

static void test_transition_capability_exact_requirements(void)
{
    hs2_dock_skylight_api api = complete_api();
    assert((hs2_dock_active_capabilities(&api) & HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION) != 0);
    hs2_dock_skylight_api partial = api;
    void **required[] = { (void **)&partial.main_connection_id, (void **)&partial.get_window_bounds,
        (void **)&partial.get_window_transform, (void **)&partial.set_window_transform,
        (void **)&partial.transaction_create, (void **)&partial.transaction_set_window_transform,
        (void **)&partial.transaction_commit, (void **)&partial.transaction_release };
    for (size_t index = 0; index < sizeof(required) / sizeof(required[0]); index++) {
        partial = api;
        void **slot = (void **)((char *)&partial + ((char *)required[index] - (char *)&partial));
        *slot = NULL;
        assert((hs2_dock_active_capabilities(&partial) & HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION) == 0);
    }
    partial = api;
    partial.move_window_with_group = NULL;
    partial.set_window_warp = NULL;
    assert((hs2_dock_active_capabilities(&partial) & HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION) != 0);
}

static void test_transition_route_success_validation_and_commit_failure(void)
{
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.frame = CGRectMake(7, 8, 300, 400);
    g_fake.observed = CGAffineTransformMake(1, 0, 0, 1, 9, 10);
    hs2_dock_skylight_api api = complete_api();
    hs2_dock_v2_server server;
    hs2_dock_v2_server_init(&server, hs2_dock_active_capabilities(&api));
    hs2_dock_v2_peer peer = {.uid = getuid(), .pid = getpid()};
    hs2_dock_v2_handshake_request handshake;
    hs2_dock_v2_handshake_response accepted = establish(&server, &peer,
        HS2_DOCK_V2_CAP_LEASES | HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION, &handshake);
    create_lease(&server, &peer, &accepted, &handshake, 101, 11,
                 HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION, 1);
    create_lease(&server, &peer, &accepted, &handshake, 102, 12,
                 HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION, 2);
    uint8_t payload[HS2_DOCK_V2_WORKSPACE_TRANSITION_REQUEST_BYTES];
    uint16_t bytes;
    encode_transition(&handshake, 101, 11, 102, 12, payload, &bytes);
    hs2_dock_v2_envelope envelope = envelope_for(HS2_DOCK_V2_WORKSPACE_TRANSITION,
                                                  bytes, 3, accepted.session_id);
    hs2_dock_v2_response response = dispatch_status_and_decode(&api, &server, &peer,
                                                                &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK && response.value == 2);
    assert(g_fake.bounds_calls == 2 && g_fake.get_transform_calls == 2);
    assert(g_fake.first_transaction_event > 4);
    assert(g_fake.transaction_commit_calls == 2 && g_fake.transaction_release_calls == 2);
    assert(g_fake.transaction_set_calls == 4);
    assert(g_fake.transaction_sets[2].window_id == 11 &&
           memcmp(&g_fake.transaction_sets[2].transform,
                  &(CGAffineTransform){1, 0, 0, 1, 110, 120}, sizeof(CGAffineTransform)) == 0);
    assert(g_fake.transaction_sets[3].window_id == 12 &&
           memcmp(&g_fake.transaction_sets[3].transform,
                  &(CGAffineTransform){2, 0, 0, 2, 205, 206}, sizeof(CGAffineTransform)) == 0);
    assert(hs2_dock_v2_pending_cleanup_leases(&server) == 0);
    assert(server.leases[0].note.transform_pending && server.leases[1].note.transform_pending);
    assert(server.leases[0].note.frame_captured && server.leases[1].note.frame_captured);
    assert(server.leases[0].note.observed_captured && server.leases[1].note.observed_captured);

    memset(&g_fake, 0, sizeof(g_fake));
    encode_transition(&handshake, 101, 11, 999, 12, payload, &bytes);
    envelope.request_id = 4;
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_LEASE_REJECTED && g_fake.main_calls == 0);
    create_lease(&server, &peer, &accepted, &handshake, 999, 12,
                 HS2_DOCK_V2_CAP_WORKSPACE_TRANSITION, 5);
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_DUPLICATE_REQUEST);
    envelope.request_id = 6;
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_OK);

    memset(&g_fake, 0, sizeof(g_fake));
    encode_transition(&handshake, 101, 11, 101, 12, payload, &bytes);
    envelope.request_id = 7;
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE && g_fake.main_calls == 0);
    encode_transition(&handshake, 101, 11, 999, 11, payload, &bytes);
    envelope.request_id = 8;
    response = dispatch_status_and_decode(&api, &server, &peer, &envelope, payload);
    assert(response.error == HS2_DOCK_V2_MALFORMED_ENVELOPE && g_fake.main_calls == 0);

}

int main(void)
{
    test_capability_correspondence();
    test_transition_capability_exact_requirements();
    test_transition_route_success_validation_and_commit_failure();
    test_query_success_and_failure();
    test_move_success_failure_and_validation();
    test_missing_handler_and_session_validation();
    test_transform_success_and_release_cleanup();
    test_transform_restore_never_uses_observed_value();
    test_transform_partial_failure_and_retry();
    test_transform_requires_authoritative_frame();
    test_transform_observed_read_failure_is_non_fatal();
    test_warp_clear_and_cleanup();
    test_warp_failure_and_retry();
    test_transform_warp_validation_and_lease_gating();
    test_missing_symbol_removes_capabilities();
    test_disconnect_and_unload_cleanup();
    return EXIT_SUCCESS;
}
