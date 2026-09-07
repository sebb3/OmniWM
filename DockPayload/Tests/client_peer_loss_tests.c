/* Process tests for the C status/query client's peer-loss behavior.
 *
 * The client under test is the real built binary, exec'd against a fake
 * listener that owns a throwaway socket path in a directory this test owns;
 * the client is pointed there by the same test-only socket-path override the
 * payload honors, so the production per-user socket is never unlinked, bound,
 * or connected to. The listener loses the peer at three defined points --
 * before anything is answered, after the handshake request has been drained,
 * and after a forged-but-valid handshake reply -- and the client must react
 * with a normal nonzero exit every time. SO_NOSIGPIPE is what keeps a write
 * that lands on the dead socket from terminating the client with SIGPIPE;
 * the parent never installs a SIGPIPE disposition, so a regression dies by
 * signal and fails the test. Nothing here loads the payload or contacts the
 * Dock. The production socket path is checked before and after the whole
 * run: whatever its prior state, this test leaves it untouched. */

#include "protocol_v2.h"

#include <assert.h>
#include <errno.h>
#include <pwd.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define CLIENT_PATH "build/hs2-dock-window-spike"
#define SOCKET_FORMAT "/tmp/hs2-dock-window-v2-%s.socket"
#define SOCKET_OVERRIDE_ENV "HS2_DOCK_V2_SOCKET_PATH"

static void deadline_expired(int signal_number)
{
    (void)signal_number;
    _exit(124);
}

static pid_t spawn_client(char *const argv[])
{
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        execv(CLIENT_PATH, argv);
        _exit(127); /* unreachable binary: fail the test, never hang */
    }
    return pid;
}

/* The client exited on its own -- never by signal -- with the rejection
 * status peer loss is defined to produce. */
static void expect_graceful_rejection(pid_t pid)
{
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status) && !WIFSIGNALED(status));
    assert(WEXITSTATUS(status) == 4);
}

static void transfer_read(int fd, void *bytes, size_t count)
{
    uint8_t *cursor = bytes;
    while (count > 0) {
        ssize_t result = recv(fd, cursor, count, 0);
        assert(result > 0);
        cursor += result;
        count -= (size_t)result;
    }
}

static void transfer_write(int fd, const void *bytes, size_t count)
{
    const uint8_t *cursor = bytes;
    while (count > 0) {
        ssize_t result = send(fd, cursor, count, 0);
        assert(result > 0);
        cursor += result;
        count -= (size_t)result;
    }
}

/* Reads exactly one framed handshake request, returning its request id and
 * nonce so a forged reply can be indistinguishable from the real payload. */
static void drain_handshake_request(int fd, uint64_t *request_id,
                                    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES])
{
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    uint8_t payload[HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES];
    transfer_read(fd, header, sizeof(header));
    transfer_read(fd, payload, sizeof(payload));
    hs2_dock_v2_envelope envelope;
    assert(hs2_dock_v2_decode_envelope(header, sizeof(header), &envelope));
    assert(envelope.type == HS2_DOCK_V2_HANDSHAKE_REQUEST &&
           envelope.payload_bytes == HS2_DOCK_V2_HANDSHAKE_REQUEST_BYTES);
    hs2_dock_v2_handshake_request request;
    assert(hs2_dock_v2_decode_handshake_request(payload, sizeof(payload), &request));
    *request_id = envelope.request_id;
    memcpy(nonce, request.nonce, HS2_DOCK_V2_NONCE_BYTES);
}

int main(void)
{
    struct passwd *account = getpwuid(geteuid());
    assert(account != NULL);
    char production[sizeof(((struct sockaddr_un *)0)->sun_path)];
    assert(snprintf(production, sizeof(production), SOCKET_FORMAT, account->pw_name) <
           (int)sizeof(production));

    /* An isolated socket path behind the test-only override: the fake
     * listener binds this throwaway path, the exec'd client inherits the
     * override and connects here, and the production path stays untouched. */
    char directory[] = "/tmp/hs2-dock-v2-client.XXXXXX";
    assert(mkdtemp(directory) != NULL);
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    assert(snprintf(path, sizeof(path), "%s/socket", directory) < (int)sizeof(path));
    assert(setenv(SOCKET_OVERRIDE_ENV, path, 1) == 0);

    /* Production-path isolation proof: whatever state the production socket
     * is in before the run, it must be in exactly that state after it. */
    bool production_existed = access(production, F_OK) == 0;

    signal(SIGALRM, deadline_expired);
    alarm(30);

    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(listener >= 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    assert(bind(listener, (const struct sockaddr *)&address, sizeof(address)) == 0);
    assert(chmod(path, 0600) == 0);
    assert(listen(listener, 4) == 0);

    /* The peer vanishes before anything is answered: the client's own writes
     * can now land on a dead socket, which without SO_NOSIGPIPE is SIGPIPE. */
    char *status_argv[] = {"hs2-dock-window-spike", "status", NULL};
    pid_t pid = spawn_client(status_argv);
    int fd = accept(listener, NULL, NULL);
    assert(fd >= 0);
    close(fd);
    usleep(300 * 1000); /* any in-flight client write lands after the loss */
    expect_graceful_rejection(pid);

    /* The handshake request is fully drained, then the peer is lost before
     * the reply: the client observes the disconnect in its read instead. */
    char *query_argv[] = {"hs2-dock-window-spike", "query", "77", NULL};
    pid = spawn_client(query_argv);
    fd = accept(listener, NULL, NULL);
    assert(fd >= 0);
    uint64_t request_id = 0;
    uint8_t nonce[HS2_DOCK_V2_NONCE_BYTES];
    drain_handshake_request(fd, &request_id, nonce);
    close(fd);
    expect_graceful_rejection(pid);

    /* The peer answers the handshake and is then lost before the query: the
     * client's post-negotiation write now targets a dead socket, the exact
     * write-side loss SO_NOSIGPIPE converts from SIGPIPE into an error. */
    pid = spawn_client(query_argv);
    fd = accept(listener, NULL, NULL);
    assert(fd >= 0);
    drain_handshake_request(fd, &request_id, nonce);
    hs2_dock_v2_handshake_response accepted = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .build = HS2_DOCK_V2_BUILD,
        .available_capabilities = HS2_DOCK_V2_EVIDENCED_CAPABILITIES,
        .granted_capabilities = HS2_DOCK_V2_EVIDENCED_CAPABILITIES,
        .session_id = 7,
        .peer_uid = (uint32_t)geteuid(),
        .peer_pid = pid,
        .error = HS2_DOCK_V2_OK,
    };
    memcpy(accepted.nonce, nonce, HS2_DOCK_V2_NONCE_BYTES);
    uint8_t payload[HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES];
    assert(hs2_dock_v2_encode_handshake_response(&accepted, payload));
    hs2_dock_v2_envelope reply = {
        .major = HS2_DOCK_V2_MAJOR,
        .minor = HS2_DOCK_V2_MINOR,
        .type = HS2_DOCK_V2_HANDSHAKE_RESPONSE,
        .header_bytes = HS2_DOCK_V2_ENVELOPE_BYTES,
        .payload_bytes = HS2_DOCK_V2_HANDSHAKE_RESPONSE_BYTES,
        .request_id = request_id,
        .session_id = accepted.session_id,
    };
    uint8_t header[HS2_DOCK_V2_ENVELOPE_BYTES];
    assert(hs2_dock_v2_encode_envelope(&reply, header));
    transfer_write(fd, header, sizeof(header));
    transfer_write(fd, payload, sizeof(payload));
    close(fd);
    usleep(300 * 1000); /* let the client's query send land after the loss */
    expect_graceful_rejection(pid);

    close(listener);
    assert(unlink(path) == 0);
    assert(rmdir(directory) == 0);
    if (production_existed) {
        /* a live production socket is left exactly as found */
        assert(access(production, F_OK) == 0);
    } else {
        errno = 0;
        assert(access(production, F_OK) == -1 && errno == ENOENT);
    }
    return 0;
}
