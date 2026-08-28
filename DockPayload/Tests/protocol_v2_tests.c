#include "protocol_v2.h"
#include "protocol_v2_server.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static hs2_dock_v2_handshake_request request_with_nonce(void) {
    hs2_dock_v2_handshake_request request = { .protocol_min_major=2,.protocol_max_major=2,.build_min=HS2_DOCK_V2_BUILD,.build_max=HS2_DOCK_V2_BUILD,.required_capabilities=HS2_DOCK_V2_CAP_LEASES };
    for (size_t i=0;i<sizeof(request.nonce);i++) request.nonce[i]=(uint8_t)(0xa0u+i);
    return request;
}
static void test_golden_vectors(void) {
    assert(HS2_DOCK_V2_PROTOCOL_MAX_FRAME_BYTES == 65575u);
    /* Approved HS2D magic: bytes 'H','S','2','D' lead the wire envelope.
     * This vector is shared byte-for-byte with protocol_v2_swift_tests.swift. */
    const uint8_t golden[40]={0x48,0x53,0x32,0x44,0x02,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x28,0x00,0x2c,0x00,0x08,0x07,0x06,0x05,0x04,0x03,0x02,0x01,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    uint8_t encoded[40]; hs2_dock_v2_envelope envelope={.major=2,.minor=0,.type=HS2_DOCK_V2_HANDSHAKE_REQUEST,.header_bytes=40,.payload_bytes=44,.request_id=UINT64_C(0x0102030405060708)}; hs2_dock_v2_envelope decoded;
    assert(hs2_dock_v2_encode_envelope(&envelope,encoded)); assert(memcmp(encoded,golden,sizeof(golden))==0); assert(hs2_dock_v2_decode_envelope(encoded,sizeof(encoded),&decoded)); encoded[32]=1; assert(!hs2_dock_v2_decode_envelope(encoded,sizeof(encoded),&decoded));
}

static void test_transform_codec_rejects_null_pointers(void) {
    hs2_dock_v2_transform_request message = {
        .lease_id = 1,
        .window_id = 1,
        .a = 1,
        .d = 1,
    };
    uint8_t bytes[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES] = {0};

    assert(!hs2_dock_v2_encode_transform_request(NULL, bytes));
    assert(!hs2_dock_v2_encode_transform_request(&message, NULL));
    assert(!hs2_dock_v2_decode_transform_request(NULL, sizeof(bytes), &message));
    assert(!hs2_dock_v2_decode_transform_request(bytes, sizeof(bytes), NULL));
}

/* Envelope validation is exact: version, flags, type, request id, session
 * binding for the handshake, header size, and the reserved word. */
static void test_envelope_strict_validation(void) {
    hs2_dock_v2_envelope envelope={.major=HS2_DOCK_V2_MAJOR,.minor=HS2_DOCK_V2_MINOR,.type=HS2_DOCK_V2_QUERY_FRAME,.header_bytes=HS2_DOCK_V2_ENVELOPE_BYTES,.payload_bytes=HS2_DOCK_V2_QUERY_REQUEST_BYTES,.request_id=7,.session_id=9};
    uint8_t bytes[HS2_DOCK_V2_ENVELOPE_BYTES]; hs2_dock_v2_envelope decoded;
    uint8_t tweaked[HS2_DOCK_V2_ENVELOPE_BYTES];
    assert(hs2_dock_v2_encode_envelope(&envelope,bytes));
    assert(hs2_dock_v2_decode_envelope(bytes,sizeof(bytes),&decoded));

    /* every single-field corruption below must fail decode */
    struct { size_t offset; uint8_t value; } rejections[]={
        {0,0x99},   /* magic byte */
        {3,0x00},   /* magic byte */
        {4,0x03},   /* major: unsupported version */
        {5,0x01},   /* major: nonzero high byte */
        {6,0x01},   /* minor: exact-version mismatch */
        {8,0x00},   /* type: zero is unknown */
        {8,0x0e},   /* type: past the known set */
        {10,0x01},  /* flags: no flags are defined */
        {12,0x29},  /* header bytes: not 40 */
        {33,0x01},  /* reserved word nonzero */
    };
    for (size_t index=0;index<sizeof(rejections)/sizeof(rejections[0]);index++) {
        memcpy(tweaked,bytes,sizeof(tweaked));
        tweaked[rejections[index].offset]=rejections[index].value;
        assert(!hs2_dock_v2_decode_envelope(tweaked,sizeof(tweaked),&decoded));
    }
    /* zero request id */
    memcpy(tweaked,bytes,sizeof(tweaked));
    memset(tweaked+16,0,8);
    assert(!hs2_dock_v2_decode_envelope(tweaked,sizeof(tweaked),&decoded));

    /* a session-bound handshake request is rejected */
    envelope.type=HS2_DOCK_V2_HANDSHAKE_REQUEST; envelope.session_id=1;
    assert(hs2_dock_v2_encode_envelope(&envelope,bytes));
    assert(!hs2_dock_v2_decode_envelope(bytes,sizeof(bytes),&decoded));
    /* encode refuses non-v2 shapes outright */
    envelope.session_id=0; envelope.payload_bytes=HS2_DOCK_V2_MAX_PAYLOAD_BYTES+1;
    assert(!hs2_dock_v2_encode_envelope(&envelope,bytes));
    envelope.payload_bytes=HS2_DOCK_V2_QUERY_REQUEST_BYTES; envelope.request_id=0;
    assert(!hs2_dock_v2_encode_envelope(&envelope,bytes));
}

/* The replay window is a bounded ring: recent duplicates are refused, more
 * than a window of fresh requests keeps succeeding, and an id older than the
 * window is no longer remembered. */
static void test_request_replay_window(void) {
    hs2_dock_v2_server server; hs2_dock_v2_server_init(&server,HS2_DOCK_V2_CAP_QUERY_FRAME);
    hs2_dock_v2_peer peer={.uid=geteuid(),.pid=getpid()};
    hs2_dock_v2_handshake_request request=request_with_nonce();
    request.required_capabilities=HS2_DOCK_V2_CAP_QUERY_FRAME;
    hs2_dock_v2_handshake_response response;
    assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_OK);

    hs2_dock_v2_envelope envelope={.major=HS2_DOCK_V2_MAJOR,.minor=HS2_DOCK_V2_MINOR,.type=HS2_DOCK_V2_QUERY_FRAME,.header_bytes=HS2_DOCK_V2_ENVELOPE_BYTES,.payload_bytes=HS2_DOCK_V2_QUERY_REQUEST_BYTES,.session_id=response.session_id};
    /* well past the 64-entry window: every fresh id still succeeds */
    for (uint64_t id=1;id<=HS2_DOCK_V2_REQUEST_WINDOW+36;id++) {
        envelope.request_id=id;
        assert(hs2_dock_v2_authorize_operation(&server,&peer,&envelope,request.nonce,HS2_DOCK_V2_CAP_QUERY_FRAME)==HS2_DOCK_V2_OK);
    }
    /* a recent id is still inside the window and is refused */
    envelope.request_id=HS2_DOCK_V2_REQUEST_WINDOW+36;
    assert(hs2_dock_v2_authorize_operation(&server,&peer,&envelope,request.nonce,HS2_DOCK_V2_CAP_QUERY_FRAME)==HS2_DOCK_V2_DUPLICATE_REQUEST);
    /* the very first id was evicted by newer work: the bounded window does
     * not remember it forever and does not fail the session */
    envelope.request_id=1;
    assert(hs2_dock_v2_authorize_operation(&server,&peer,&envelope,request.nonce,HS2_DOCK_V2_CAP_QUERY_FRAME)==HS2_DOCK_V2_OK);
}
static void test_handshake_session_and_cleanup(void) {
    hs2_dock_v2_server server; hs2_dock_v2_server_init(&server,HS2_DOCK_V2_EVIDENCED_CAPABILITIES); hs2_dock_v2_peer peer={.uid=geteuid(),.pid=getpid()}; hs2_dock_v2_handshake_request request=request_with_nonce(); hs2_dock_v2_handshake_response response;
    assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_OK); assert(response.session_id && response.granted_capabilities==HS2_DOCK_V2_CAP_LEASES && memcmp(response.nonce,request.nonce,16)==0);
    hs2_dock_v2_envelope envelope={.major=2,.minor=0,.type=HS2_DOCK_V2_LEASE_CREATE,.header_bytes=40,.payload_bytes=34,.request_id=1,.session_id=response.session_id}; hs2_dock_v2_lease_request lease={.lease_id=17,.window_id=99,.operation=HS2_DOCK_V2_CAP_LEASES}; memcpy(lease.nonce,request.nonce,16);
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_OK); assert(hs2_dock_v2_active_leases(&server)==1); assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_DUPLICATE_REQUEST);
    envelope.request_id=2; lease.nonce[0]^=1; assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_SESSION_REJECTED); lease.nonce[0]^=1; hs2_dock_v2_peer impostor=peer;impostor.pid++;assert(hs2_dock_v2_handle_lease(&server,&impostor,&envelope,&lease)==HS2_DOCK_V2_SESSION_REJECTED);
    assert(hs2_dock_v2_disconnect(&server,&peer,response.session_id,request.nonce)==HS2_DOCK_V2_OK);assert(hs2_dock_v2_active_leases(&server)==0);assert(hs2_dock_v2_unload(&server)==HS2_DOCK_V2_OK&&!server.loaded);
}
static bool fail_cleanup(uint64_t window_id,uint16_t operation,const hs2_dock_v2_lease_note *note,void *context) { (void)window_id;(void)operation;(void)note;(void)context;return false; }
static void test_rejections_and_cleanup_failure(void) {
    hs2_dock_v2_server server; hs2_dock_v2_server_init(&server,HS2_DOCK_V2_CAP_LEASES); hs2_dock_v2_peer peer={.uid=geteuid(),.pid=getpid()}; hs2_dock_v2_handshake_request request=request_with_nonce();hs2_dock_v2_handshake_response response;request.protocol_min_major=3;request.protocol_max_major=3;assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_UNSUPPORTED_VERSION);request=request_with_nonce();request.required_capabilities=HS2_DOCK_V2_CAP_QUERY_FRAME;assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_CAPABILITY_REJECTED);request=request_with_nonce();assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_OK);
    hs2_dock_v2_server_set_cleanup(&server,fail_cleanup,NULL);hs2_dock_v2_envelope envelope={.major=2,.minor=0,.type=HS2_DOCK_V2_LEASE_CREATE,.header_bytes=40,.payload_bytes=34,.request_id=1,.session_id=response.session_id};hs2_dock_v2_lease_request lease={.lease_id=1,.window_id=2,.operation=HS2_DOCK_V2_CAP_LEASES};memcpy(lease.nonce,request.nonce,16);assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_OK);assert(hs2_dock_v2_disconnect(&server,&peer,response.session_id,request.nonce)==HS2_DOCK_V2_CLEANUP_FAILED&&server.cleanup_failed);
    assert(hs2_dock_v2_active_leases(&server)==1&&hs2_dock_v2_pending_cleanup_leases(&server)==1); /* failed cleanup keeps the identified lease for retry */
    assert(hs2_dock_v2_unload(&server)==HS2_DOCK_V2_CLEANUP_FAILED); /* unload retries the orphaned residue */
    uint8_t fuzz[40]={0};for(size_t i=0;i<sizeof(fuzz);i++){hs2_dock_v2_envelope decoded;fuzz[i]^=0xff;assert(!hs2_dock_v2_decode_envelope(fuzz,i,&decoded));fuzz[i]^=0xff;}
}
static int g_retry_cleanup_calls;
static bool retry_cleanup(uint64_t window_id,uint16_t operation,const hs2_dock_v2_lease_note *note,void *context) { (void)window_id;(void)operation;(void)note;(void)context;g_retry_cleanup_calls++;return g_retry_cleanup_calls>1; }
static void test_retryable_release_and_unload(void) {
    hs2_dock_v2_server server; hs2_dock_v2_server_init(&server,HS2_DOCK_V2_CAP_LEASES); hs2_dock_v2_peer peer={.uid=geteuid(),.pid=getpid()}; hs2_dock_v2_handshake_request request=request_with_nonce(); hs2_dock_v2_handshake_response response;
    assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_OK);
    g_retry_cleanup_calls=0;hs2_dock_v2_server_set_cleanup(&server,retry_cleanup,NULL);
    hs2_dock_v2_envelope envelope={.major=2,.minor=0,.type=HS2_DOCK_V2_LEASE_CREATE,.header_bytes=40,.payload_bytes=34,.request_id=1,.session_id=response.session_id};hs2_dock_v2_lease_request lease={.lease_id=5,.window_id=6,.operation=HS2_DOCK_V2_CAP_LEASES};memcpy(lease.nonce,request.nonce,16);
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_OK);
    envelope.type=HS2_DOCK_V2_LEASE_RELEASE;envelope.request_id=2;
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_CLEANUP_FAILED); /* first release fails */
    assert(hs2_dock_v2_active_leases(&server)==1&&hs2_dock_v2_pending_cleanup_leases(&server)==1);
    envelope.request_id=3;
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_OK); /* release is retryable and then deactivates the lease */
    assert(hs2_dock_v2_active_leases(&server)==0&&hs2_dock_v2_pending_cleanup_leases(&server)==0);
    assert(hs2_dock_v2_unload(&server)==HS2_DOCK_V2_OK);
}
/* Lease release must name the lease exactly: lease id, owning session, window
 * id, and the full operation set. Any mismatch is refused and the identified
 * lease survives until an exact release retires it. */
static void test_lease_release_requires_exact_match(void) {
    hs2_dock_v2_server server; hs2_dock_v2_server_init(&server,HS2_DOCK_V2_EVIDENCED_CAPABILITIES); hs2_dock_v2_peer peer={.uid=geteuid(),.pid=getpid()};
    hs2_dock_v2_handshake_request request=request_with_nonce();
    request.required_capabilities=HS2_DOCK_V2_CAP_LEASES|HS2_DOCK_V2_CAP_MOVE_REAL|HS2_DOCK_V2_CAP_SET_TRANSFORM;
    hs2_dock_v2_handshake_response response;
    assert(hs2_dock_v2_handshake(&server,&peer,&request,&response)==HS2_DOCK_V2_OK);
    hs2_dock_v2_envelope envelope={.major=2,.minor=0,.type=HS2_DOCK_V2_LEASE_CREATE,.header_bytes=40,.payload_bytes=34,.request_id=1,.session_id=response.session_id};
    const uint16_t exact=HS2_DOCK_V2_CAP_MOVE_REAL|HS2_DOCK_V2_CAP_SET_TRANSFORM;
    hs2_dock_v2_lease_request lease={.lease_id=9,.window_id=77,.operation=exact}; memcpy(lease.nonce,request.nonce,16);
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_OK); assert(hs2_dock_v2_active_leases(&server)==1);

    envelope.type=HS2_DOCK_V2_LEASE_RELEASE;
    envelope.request_id=2; lease.window_id=78; /* wrong window id */
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_LEASE_REJECTED);
    envelope.request_id=3; lease.window_id=77; lease.operation=HS2_DOCK_V2_CAP_MOVE_REAL; /* operation subset */
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_LEASE_REJECTED);
    envelope.request_id=4; lease.operation=exact|HS2_DOCK_V2_CAP_QUERY_FRAME; /* extra operation bit */
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_LEASE_REJECTED);
    envelope.request_id=5; lease.operation=exact; lease.lease_id=10; /* wrong lease id */
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_LEASE_REJECTED);
    envelope.request_id=6; lease.lease_id=9; envelope.session_id=response.session_id+1; /* wrong owning session */
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_SESSION_REJECTED);
    envelope.session_id=response.session_id;
    envelope.request_id=7;
    assert(hs2_dock_v2_handle_lease(&server,&peer,&envelope,&lease)==HS2_DOCK_V2_OK); /* the exact quadruple releases */
    assert(hs2_dock_v2_active_leases(&server)==0&&hs2_dock_v2_pending_cleanup_leases(&server)==0);
    assert(hs2_dock_v2_unload(&server)==HS2_DOCK_V2_OK);
}
static void test_operation_codecs(void) {
    hs2_dock_v2_query_request query = { .window_id = UINT64_C(0x0102030405060708) };
    uint8_t query_bytes[HS2_DOCK_V2_QUERY_REQUEST_BYTES];
    hs2_dock_v2_query_request decoded_query;
    memset(query.nonce, 0xa5, sizeof(query.nonce));
    assert(hs2_dock_v2_encode_query_request(&query, query_bytes));
    const uint8_t query_golden[HS2_DOCK_V2_QUERY_REQUEST_BYTES] = {
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    };
    assert(memcmp(query_bytes, query_golden, sizeof(query_bytes)) == 0);
    assert(hs2_dock_v2_decode_query_request(query_bytes, sizeof(query_bytes), &decoded_query));
    assert(decoded_query.window_id == query.window_id);

    hs2_dock_v2_move_request move = {
        .lease_id = UINT64_C(0x1112131415161718),
        .window_id = UINT64_C(0x0102030405060708),
        .x = 1.5,
        .y = -2.25,
    };
    memcpy(move.nonce, query.nonce, sizeof(move.nonce));
    uint8_t move_bytes[HS2_DOCK_V2_MOVE_REQUEST_BYTES];
    hs2_dock_v2_move_request decoded_move;
    const uint8_t move_golden[HS2_DOCK_V2_MOVE_REQUEST_BYTES] = {
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x3f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xc0,
    };
    assert(hs2_dock_v2_encode_move_request(&move, move_bytes));
    assert(memcmp(move_bytes, move_golden, sizeof(move_bytes)) == 0);
    assert(hs2_dock_v2_decode_move_request(move_bytes, sizeof(move_bytes), &decoded_move));
    assert(decoded_move.lease_id == move.lease_id && decoded_move.x == move.x);

    hs2_dock_v2_frame_response frame = {
        .error = HS2_DOCK_V2_OK, .detail = 7, .x = 1.5, .y = -2.25,
        .width = 3.0, .height = 4.0,
    };
    uint8_t frame_bytes[HS2_DOCK_V2_FRAME_RESPONSE_BYTES];
    hs2_dock_v2_frame_response decoded_frame;
    assert(hs2_dock_v2_encode_frame_response(&frame, frame_bytes));
    assert(hs2_dock_v2_decode_frame_response(frame_bytes, sizeof(frame_bytes), &decoded_frame));
    assert(decoded_frame.detail == 7 && decoded_frame.width == 3.0);

    hs2_dock_v2_warp_request warp = { .lease_id = 1, .window_id = 2, .columns = 9, .rows = 2 };
    uint8_t warp_bytes[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    memset(warp.nonce, 0x5a, sizeof(warp.nonce));
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        warp.points[index] = (hs2_dock_v2_warp_point){ .local_x = (float)index, .local_y = 1,
                                                        .global_x = 2, .global_y = 3 };
    }
    assert(hs2_dock_v2_encode_warp_request(&warp, warp_bytes));
    assert(hs2_dock_v2_decode_warp_request(warp_bytes, sizeof(warp_bytes), &warp));
    warp.rows = 3;
    assert(!hs2_dock_v2_encode_warp_request(&warp, warp_bytes));

    /* Cross-language golden vectors shared with protocol_v2_swift_tests.swift. */
    hs2_dock_v2_transform_request transform = {
        .lease_id = UINT64_C(0x1112131415161718), .window_id = UINT64_C(0x0102030405060708),
        .a = 1.5, .b = -2.25, .c = 3.0, .d = -4.0, .tx = 5.25, .ty = -6.5,
    };
    memcpy(transform.nonce, query.nonce, sizeof(transform.nonce));
    uint8_t transform_bytes[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES];
    const uint8_t transform_golden[HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES] = {
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x3f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xc0,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x40,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0xc0,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x15, 0x40,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1a, 0xc0,
    };
    assert(hs2_dock_v2_encode_transform_request(&transform, transform_bytes));
    assert(memcmp(transform_bytes, transform_golden, sizeof(transform_bytes)) == 0);
    hs2_dock_v2_transform_request decoded_transform;
    assert(hs2_dock_v2_decode_transform_request(transform_bytes, sizeof(transform_bytes),
                                                &decoded_transform));
    assert(decoded_transform.lease_id == transform.lease_id && decoded_transform.tx == 5.25);

    hs2_dock_v2_warp_request golden_warp = {
        .lease_id = UINT64_C(0x1112131415161718), .window_id = UINT64_C(0x0102030405060708),
        .columns = 9, .rows = 2,
    };
    memcpy(golden_warp.nonce, query.nonce, sizeof(golden_warp.nonce));
    golden_warp.points[0] = (hs2_dock_v2_warp_point){ .local_x = 0.5f, .local_y = -1.5f,
                                                       .global_x = 2.5f, .global_y = -3.5f };
    for (size_t index = 1; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        golden_warp.points[index] = (hs2_dock_v2_warp_point){ 0, 0, 0, 0 };
    }
    uint8_t golden_warp_bytes[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    const uint8_t warp_golden_prefix[36] = {
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x09, 0x00, 0x02, 0x00,
    };
    const uint8_t warp_golden_point[16] = {
        0x00, 0x00, 0x00, 0x3f, 0x00, 0x00, 0xc0, 0xbf,
        0x00, 0x00, 0x20, 0x40, 0x00, 0x00, 0x60, 0xc0,
    };
    assert(hs2_dock_v2_encode_warp_request(&golden_warp, golden_warp_bytes));
    assert(memcmp(golden_warp_bytes, warp_golden_prefix, sizeof(warp_golden_prefix)) == 0);
    assert(memcmp(golden_warp_bytes + 36, warp_golden_point, sizeof(warp_golden_point)) == 0);
    for (size_t offset = 52; offset < sizeof(golden_warp_bytes); offset++) {
        assert(golden_warp_bytes[offset] == 0);
    }

    hs2_dock_v2_clear_warp_request clear = {
        .lease_id = UINT64_C(0x1112131415161718), .window_id = UINT64_C(0x0102030405060708),
    };
    memcpy(clear.nonce, query.nonce, sizeof(clear.nonce));
    uint8_t clear_bytes[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES];
    const uint8_t clear_golden[HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES] = {
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    };
    assert(hs2_dock_v2_encode_clear_warp_request(&clear, clear_bytes));
    assert(memcmp(clear_bytes, clear_golden, sizeof(clear_bytes)) == 0);
    hs2_dock_v2_clear_warp_request decoded_clear;
    assert(hs2_dock_v2_decode_clear_warp_request(clear_bytes, sizeof(clear_bytes),
                                                 &decoded_clear));
    assert(decoded_clear.window_id == clear.window_id);
}

/* Fuzz boundary: mutate and truncate every byte of valid transform, warp, and
 * clear-warp payloads. Decoding must never crash, must reject truncation, and
 * every accepted mutation must round-trip. */
static void test_payload_fuzz_boundaries(void) {
    hs2_dock_v2_transform_request transform = {
        .lease_id = 1, .window_id = 2, .a = 1.0, .b = 0.0, .c = 0.0,
        .d = 1.0, .tx = -3.5, .ty = 4.5,
    };
    hs2_dock_v2_warp_request warp = { .lease_id = 1, .window_id = 2, .columns = 9, .rows = 2 };
    hs2_dock_v2_clear_warp_request clear = { .lease_id = 1, .window_id = 2 };
    uint8_t bytes[HS2_DOCK_V2_WARP_REQUEST_BYTES];
    size_t lengths[3] = { HS2_DOCK_V2_TRANSFORM_REQUEST_BYTES, HS2_DOCK_V2_WARP_REQUEST_BYTES,
                          HS2_DOCK_V2_CLEAR_WARP_REQUEST_BYTES };

    memset(transform.nonce, 0x33, sizeof(transform.nonce));
    memset(warp.nonce, 0x33, sizeof(warp.nonce));
    memset(clear.nonce, 0x33, sizeof(clear.nonce));
    for (size_t index = 0; index < HS2_DOCK_V2_WARP_POINTS; index++) {
        warp.points[index] = (hs2_dock_v2_warp_point){ .local_x = (float)index,
                                                        .local_y = 1, .global_x = 2,
                                                        .global_y = 3 };
    }

    for (size_t variant = 0; variant < 3; variant++) {
        if (variant == 0) assert(hs2_dock_v2_encode_transform_request(&transform, bytes));
        if (variant == 1) assert(hs2_dock_v2_encode_warp_request(&warp, bytes));
        if (variant == 2) assert(hs2_dock_v2_encode_clear_warp_request(&clear, bytes));

        for (size_t length = 0; length < lengths[variant]; length++) {
            /* every truncation is rejected */
            if (variant == 0) {
                hs2_dock_v2_transform_request decoded;
                assert(!hs2_dock_v2_decode_transform_request(bytes, length, &decoded));
            } else if (variant == 1) {
                hs2_dock_v2_warp_request decoded;
                assert(!hs2_dock_v2_decode_warp_request(bytes, length, &decoded));
            } else {
                hs2_dock_v2_clear_warp_request decoded;
                assert(!hs2_dock_v2_decode_clear_warp_request(bytes, length, &decoded));
            }
        }
        for (size_t offset = 0; offset < lengths[variant]; offset++) {
            uint8_t original = bytes[offset];
            for (uint8_t tweak = 1; tweak != 0; tweak <<= 1) {
                hs2_dock_v2_transform_request decoded_transform;
                hs2_dock_v2_warp_request decoded_warp;
                hs2_dock_v2_clear_warp_request decoded_clear;
                bool accepted;
                bytes[offset] = original ^ tweak;
                if (variant == 0) {
                    accepted = hs2_dock_v2_decode_transform_request(
                        bytes, lengths[variant], &decoded_transform);
                } else if (variant == 1) {
                    accepted = hs2_dock_v2_decode_warp_request(bytes, lengths[variant],
                                                               &decoded_warp);
                } else {
                    accepted = hs2_dock_v2_decode_clear_warp_request(bytes, lengths[variant],
                                                                     &decoded_clear);
                }
                if (accepted) {
                    /* accepted mutations must re-encode identically */
                    uint8_t reencoded[HS2_DOCK_V2_WARP_REQUEST_BYTES];
                    if (variant == 0) {
                        assert(hs2_dock_v2_encode_transform_request(&decoded_transform,
                                                                    reencoded));
                    } else if (variant == 1) {
                        assert(hs2_dock_v2_encode_warp_request(&decoded_warp, reencoded));
                    } else {
                        assert(hs2_dock_v2_encode_clear_warp_request(&decoded_clear,
                                                                     reencoded));
                    }
                    assert(memcmp(reencoded, bytes, lengths[variant]) == 0);
                }
            }
            bytes[offset] = original;
        }
    }
}
int main(void) { test_golden_vectors();test_transform_codec_rejects_null_pointers();test_envelope_strict_validation();test_request_replay_window();test_handshake_session_and_cleanup();test_rejections_and_cleanup_failure();test_retryable_release_and_unload();test_lease_release_requires_exact_match();test_operation_codecs();test_payload_fuzz_boundaries();return EXIT_SUCCESS; }
