#include "protocol_v2_server.h"

#include <string.h>
#include <unistd.h>

static bool peers_match(const hs2_dock_v2_peer *left, const hs2_dock_v2_peer *right)
{
    return left->uid == right->uid && left->pid == right->pid;
}

static hs2_dock_v2_session *session_for(hs2_dock_v2_server *server,
                                        const hs2_dock_v2_peer *peer,
                                        uint64_t session_id,
                                        const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES])
{
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_SESSIONS; index++) {
        hs2_dock_v2_session *session = &server->sessions[index];
        if (session->active && session->session_id == session_id &&
            peers_match(&session->peer, peer) &&
            memcmp(session->nonce, nonce, HS2_DOCK_V2_NONCE_BYTES) == 0) {
            return session;
        }
    }
    return NULL;
}

/* Replay detection over a bounded window. A request id already inside the
 * window is a replay and is refused; otherwise the id is remembered in the
 * next ring slot, evicting the oldest retained id once the window is full.
 * The window therefore never refuses new work merely because it is full. */
static bool remember_request(hs2_dock_v2_session *session, uint64_t request_id)
{
    for (size_t index = 0; index < session->request_count; index++) {
        if (session->request_ids[index] == request_id) {
            return false;
        }
    }
    session->request_ids[session->request_next] = request_id;
    session->request_next = (session->request_next + 1) % HS2_DOCK_V2_REQUEST_WINDOW;
    if (session->request_count < HS2_DOCK_V2_REQUEST_WINDOW) {
        session->request_count++;
    }
    return true;
}

/* Runs the registered cleanup for one lease. On failure the lease stays active
 * with its retained cleanup data so a later release, clear, disconnect, or
 * unload can retry; residue is never silently discarded. */
static bool run_cleanup(hs2_dock_v2_server *server, hs2_dock_v2_lease *lease)
{
    if (server->cleanup != NULL &&
        !server->cleanup(lease->window_id, lease->operation, &lease->note,
                         server->cleanup_context)) {
        server->cleanup_failed = true;
        lease->note.cleanup_failed = true;
        return false;
    }
    lease->note.cleanup_failed = false;
    return true;
}

static uint16_t clear_session_leases(hs2_dock_v2_server *server, uint64_t session_id)
{
    uint16_t result = HS2_DOCK_V2_OK;
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        hs2_dock_v2_lease *lease = &server->leases[index];
        if (!lease->active || lease->session_id != session_id) {
            continue;
        }
        if (!run_cleanup(server, lease)) {
            result = HS2_DOCK_V2_CLEANUP_FAILED;
            continue;
        }
        lease->active = false;
    }
    return result;
}

void hs2_dock_v2_server_init(hs2_dock_v2_server *server, uint64_t capabilities)
{
    memset(server, 0, sizeof(*server));
    server->available_capabilities = capabilities & HS2_DOCK_V2_EVIDENCED_CAPABILITIES;
    server->next_session_id = 1;
    server->loaded = true;
}

void hs2_dock_v2_server_set_cleanup(hs2_dock_v2_server *server,
                                    hs2_dock_v2_cleanup_fn cleanup,
                                    void *context)
{
    server->cleanup = cleanup;
    server->cleanup_context = context;
}

uint16_t hs2_dock_v2_handshake(hs2_dock_v2_server *server,
                               const hs2_dock_v2_peer *peer,
                               const hs2_dock_v2_handshake_request *request,
                               hs2_dock_v2_handshake_response *response)
{
    hs2_dock_v2_session *slot = NULL;

    memset(response, 0, sizeof(*response));
    response->major = HS2_DOCK_V2_MAJOR;
    response->minor = HS2_DOCK_V2_MINOR;
    response->build = HS2_DOCK_V2_BUILD;
    response->available_capabilities = server->available_capabilities;
    response->peer_uid = (uint32_t)peer->uid;
    response->peer_pid = (int32_t)peer->pid;

    if (!server->loaded || peer->uid != geteuid() || peer->pid <= 0) {
        response->error = HS2_DOCK_V2_CREDENTIAL_REJECTED;
        return response->error;
    }
    if (request->protocol_min_major > HS2_DOCK_V2_MAJOR ||
        request->protocol_max_major < HS2_DOCK_V2_MAJOR) {
        response->error = HS2_DOCK_V2_UNSUPPORTED_VERSION;
        return response->error;
    }
    if (request->build_min > HS2_DOCK_V2_BUILD || request->build_max < HS2_DOCK_V2_BUILD) {
        response->error = HS2_DOCK_V2_BUILD_REJECTED;
        return response->error;
    }
    if ((request->required_capabilities & server->available_capabilities) !=
        request->required_capabilities) {
        response->error = HS2_DOCK_V2_CAPABILITY_REJECTED;
        return response->error;
    }

    for (size_t index = 0; index < HS2_DOCK_V2_MAX_SESSIONS; index++) {
        if (!server->sessions[index].active) {
            slot = &server->sessions[index];
            break;
        }
    }
    if (slot == NULL) {
        response->error = HS2_DOCK_V2_SESSION_REJECTED;
        return response->error;
    }

    slot->active = true;
    slot->peer = *peer;
    slot->session_id = server->next_session_id++;
    if (slot->session_id == 0) {
        slot->session_id = server->next_session_id++;
    }
    slot->capabilities = request->required_capabilities |
                         (request->optional_capabilities & server->available_capabilities);
    memcpy(slot->nonce, request->nonce, HS2_DOCK_V2_NONCE_BYTES);
    response->session_id = slot->session_id;
    response->granted_capabilities = slot->capabilities;
    memcpy(response->nonce, slot->nonce, HS2_DOCK_V2_NONCE_BYTES);
    return HS2_DOCK_V2_OK;
}

uint16_t hs2_dock_v2_authorize_operation(hs2_dock_v2_server *server,
                                         const hs2_dock_v2_peer *peer,
                                         const hs2_dock_v2_envelope *envelope,
                                         const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES],
                                         uint64_t capability)
{
    if (!server->loaded || envelope->major != HS2_DOCK_V2_MAJOR ||
        envelope->minor != HS2_DOCK_V2_MINOR) {
        return HS2_DOCK_V2_UNSUPPORTED_VERSION;
    }

    hs2_dock_v2_session *session = session_for(server, peer, envelope->session_id, nonce);
    if (session == NULL) {
        return HS2_DOCK_V2_SESSION_REJECTED;
    }
    if (!remember_request(session, envelope->request_id)) {
        return HS2_DOCK_V2_DUPLICATE_REQUEST;
    }
    if ((session->capabilities & capability) == 0) {
        return HS2_DOCK_V2_CAPABILITY_REJECTED;
    }
    return HS2_DOCK_V2_OK;
}

uint16_t hs2_dock_v2_authorize_leased_operation(hs2_dock_v2_server *server,
                                                const hs2_dock_v2_peer *peer,
                                                const hs2_dock_v2_envelope *envelope,
                                                const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES],
                                                uint64_t capability,
                                                uint64_t lease_id,
                                                uint64_t window_id,
                                                hs2_dock_v2_lease **lease)
{
    uint16_t result = hs2_dock_v2_authorize_operation(server, peer, envelope, nonce, capability);
    if (result != HS2_DOCK_V2_OK) {
        return result;
    }

    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        hs2_dock_v2_lease *candidate = &server->leases[index];
        if (candidate->active && candidate->lease_id == lease_id &&
            candidate->window_id == window_id &&
            candidate->session_id == envelope->session_id &&
            (candidate->operation & capability) != 0) {
            if (lease != NULL) {
                *lease = candidate;
            }
            return HS2_DOCK_V2_OK;
        }
    }
    return HS2_DOCK_V2_LEASE_REJECTED;
}

uint16_t hs2_dock_v2_authorize_move(hs2_dock_v2_server *server,
                                    const hs2_dock_v2_peer *peer,
                                    const hs2_dock_v2_envelope *envelope,
                                    const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES],
                                    uint64_t lease_id,
                                    uint64_t window_id)
{
    return hs2_dock_v2_authorize_leased_operation(server, peer, envelope, nonce,
                                                  HS2_DOCK_V2_CAP_MOVE_REAL, lease_id,
                                                  window_id, NULL);
}

uint16_t hs2_dock_v2_handle_lease(hs2_dock_v2_server *server,
                                  const hs2_dock_v2_peer *peer,
                                  const hs2_dock_v2_envelope *envelope,
                                  const hs2_dock_v2_lease_request *request)
{
    if (!server->loaded || envelope->major != HS2_DOCK_V2_MAJOR ||
        envelope->minor != HS2_DOCK_V2_MINOR) {
        return HS2_DOCK_V2_UNSUPPORTED_VERSION;
    }

    hs2_dock_v2_session *session = session_for(server, peer, envelope->session_id, request->nonce);
    if (session == NULL) {
        return HS2_DOCK_V2_SESSION_REJECTED;
    }
    if (!remember_request(session, envelope->request_id)) {
        return HS2_DOCK_V2_DUPLICATE_REQUEST;
    }
    if ((session->capabilities & HS2_DOCK_V2_CAP_LEASES) == 0 ||
        (request->operation & ~HS2_DOCK_V2_EVIDENCED_CAPABILITIES) != 0 ||
        (request->operation & session->capabilities) != request->operation) {
        return HS2_DOCK_V2_LEASE_REJECTED;
    }
    if (envelope->type == HS2_DOCK_V2_LEASE_CLEAR) {
        return clear_session_leases(server, session->session_id);
    }

    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        hs2_dock_v2_lease *lease = &server->leases[index];
        if (!lease->active || lease->lease_id != request->lease_id) {
            continue;
        }
        /* An existing lease with this id must be named exactly: the owning
         * session, the window, and the full operation set. A release (or
         * create) that misnames any field is refused; it never matches a
         * different window or a partial/extended operation set. */
        if (lease->session_id != session->session_id ||
            lease->window_id != request->window_id ||
            lease->operation != request->operation) {
            return HS2_DOCK_V2_LEASE_REJECTED;
        }
        if (envelope->type == HS2_DOCK_V2_LEASE_RELEASE) {
            if (!run_cleanup(server, lease)) {
                return HS2_DOCK_V2_CLEANUP_FAILED;
            }
            lease->active = false;
            return HS2_DOCK_V2_OK;
        }
        return HS2_DOCK_V2_LEASE_REJECTED;
    }

    if (envelope->type != HS2_DOCK_V2_LEASE_CREATE) {
        return HS2_DOCK_V2_LEASE_REJECTED;
    }
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        if (!server->leases[index].active) {
            server->leases[index] = (hs2_dock_v2_lease){
                .active = true,
                .lease_id = request->lease_id,
                .window_id = request->window_id,
                .operation = request->operation,
                .session_id = session->session_id,
            };
            return HS2_DOCK_V2_OK;
        }
    }
    return HS2_DOCK_V2_LEASE_REJECTED;
}

uint16_t hs2_dock_v2_disconnect(hs2_dock_v2_server *server,
                                const hs2_dock_v2_peer *peer,
                                uint64_t session_id,
                                const uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES])
{
    hs2_dock_v2_session *session = session_for(server, peer, session_id, nonce);
    if (session == NULL) {
        return HS2_DOCK_V2_SESSION_REJECTED;
    }
    uint16_t result = clear_session_leases(server, session_id);
    memset(session, 0, sizeof(*session));
    return result;
}

uint16_t hs2_dock_v2_unload(hs2_dock_v2_server *server)
{
    uint16_t result = HS2_DOCK_V2_OK;
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_SESSIONS; index++) {
        hs2_dock_v2_session *session = &server->sessions[index];
        if (!session->active) {
            continue;
        }
        uint16_t cleanup_result = clear_session_leases(server, session->session_id);
        if (cleanup_result != HS2_DOCK_V2_OK) {
            result = cleanup_result;
        }
        memset(session, 0, sizeof(*session));
    }
    /* Retry orphans: leases whose session already went away with a failed
     * cleanup keep their retained residue and are retried on unload. */
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        hs2_dock_v2_lease *lease = &server->leases[index];
        if (!lease->active) {
            continue;
        }
        if (run_cleanup(server, lease)) {
            lease->active = false;
        } else {
            result = HS2_DOCK_V2_CLEANUP_FAILED;
        }
    }
    server->loaded = false;
    return result;
}

size_t hs2_dock_v2_active_leases(const hs2_dock_v2_server *server)
{
    size_t count = 0;
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        if (server->leases[index].active) {
            count++;
        }
    }
    return count;
}

size_t hs2_dock_v2_pending_cleanup_leases(const hs2_dock_v2_server *server)
{
    size_t count = 0;
    for (size_t index = 0; index < HS2_DOCK_V2_MAX_LEASES; index++) {
        const hs2_dock_v2_lease *lease = &server->leases[index];
        if (lease->active && lease->note.cleanup_failed) {
            count++;
        }
    }
    return count;
}
