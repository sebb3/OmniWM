import Foundation

@MainActor
final class FocusOperationCoordinator {
    // Transient sequencing only. Durable focus/session ownership lives in WorkspaceManager.
    private var pendingFocusToken: WindowToken?
    private var deferredFocusToken: WindowToken?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    func discardPendingFocus(_ token: WindowToken) {
        if pendingFocusToken == token {
            pendingFocusToken = nil
        }
        if deferredFocusToken == token {
            deferredFocusToken = nil
        }
    }

    func rekeyPendingFocus(from oldToken: WindowToken, to newToken: WindowToken) {
        if pendingFocusToken == oldToken {
            pendingFocusToken = newToken
        }
        if deferredFocusToken == oldToken {
            deferredFocusToken = newToken
        }
    }

    func focusWindow(
        _ token: WindowToken,
        performFocus: () -> Void,
        onDeferredFocus: @escaping (WindowToken) -> Void
    ) {
        let now = Date()

        if pendingFocusToken == token {
            if now.timeIntervalSince(lastFocusTime) < 0.016 {
                return
            }
        }

        if isFocusOperationPending {
            deferredFocusToken = token
            return
        }

        isFocusOperationPending = true
        pendingFocusToken = token
        lastFocusTime = now

        performFocus()

        isFocusOperationPending = false
        if let deferred = deferredFocusToken, deferred != token {
            deferredFocusToken = nil
            onDeferredFocus(deferred)
        }
    }
}
