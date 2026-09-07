#ifndef HS2_DOCK_PAYLOAD_SERVER_H
#define HS2_DOCK_PAYLOAD_SERVER_H

#include <stdbool.h>

#include "operation_dispatch.h"

/* Captures the kernel-verified peer credentials for a connected AF_UNIX
 * socket: the effective uid via getpeereid(2) and the pid via LOCAL_PEERPID,
 * falling back to LOCAL_PEEREPID. Returns false when the kernel cannot
 * identify the peer, in which case the connection must not be served. */
bool hs2_dock_v2_capture_peer(int fd, hs2_dock_v2_peer *peer);

/* Default handshake deadline (milliseconds), measured on the monotonic clock
 * from the instant a connection is accepted. A same-UID client that connects
 * and never completes a handshake -- one that goes silent, stalls half an
 * envelope in, or trickles bytes to keep individual reads alive -- is dropped
 * once the deadline passes, so it cannot monopolize the serialized server. */
#define HS2_DOCK_V2_HANDSHAKE_TIMEOUT_MS 2000L

/* Serves one accepted connection. Until a session is established every
 * blocked receive is armed with only the time remaining until an absolute
 * monotonic deadline fixed at accept (handshake_timeout_ms 0 disables it), so
 * no sequence of partial deliveries can extend it. Immediately after a
 * successful negotiation the deadline is retired and all receive bounds are
 * removed, so an established Core session may idle indefinitely between
 * commands -- only peer disconnect, error, or the stopping/unload shutdown()
 * interrupts it. */
bool hs2_dock_v2_serve_connection(int fd,
                                  hs2_dock_v2_server *server,
                                  const hs2_dock_skylight_api *api,
                                  const hs2_dock_v2_peer *peer,
                                  const volatile bool *stopping,
                                  long handshake_timeout_ms);

#endif
