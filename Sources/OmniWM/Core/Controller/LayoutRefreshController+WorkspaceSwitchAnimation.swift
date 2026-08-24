// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import QuartzCore

/// A vertical slide when switching workspaces, mirroring niri's own
/// `workspace-switch` animation: workspaces are a vertical stack per monitor,
/// and switching between them animates the whole viewport, the same way
/// horizontal column scrolling already does within one workspace.
///
/// Correctness of the *authoritative* end state is entirely inherited rather
/// than reimplemented: the caller runs the existing instant switch (hide the
/// outgoing workspace, reveal the incoming one — `WorkspaceNavigationHandler`,
/// unchanged) to completion *first*, synchronously, exactly as it does today.
/// This type only drives a transient visual overlay on top of that
/// already-correct result — interpolating from where each window was a moment
/// ago to where it now authoritatively is — via `AXManager.applyPositionsViaSkyLight`,
/// the same real cross-process SkyLight-transaction move `LayoutRefreshController
/// +WindowParking.swift` already uses for animated park/reveal ticks during
/// column scrolling. If this animation were disabled entirely, the switch
/// would simply be instant, exactly like today; nothing about tracked state,
/// hidden-state bookkeeping, or focus is at stake here.
struct WorkspaceSwitchTransition {
    let monitorId: Monitor.ID
    /// Drives a 0→1 progress value, not a pixel offset — `value(at:)` returns
    /// exactly `target` once complete, so interpolated frames land exactly on
    /// each window's true frame with no residual gap to correct afterward.
    let spring: SpringAnimation
    /// Each window's frame immediately before the instant switch ran — the
    /// animation's start point (progress 0). The end point (progress 1) is
    /// each window's *current* (already-authoritative) frame, read fresh every
    /// tick — direction falls out of whatever those two frames actually are,
    /// since the real switch already decided which side to park on.
    let outgoingEntries: [(entry: WindowState, priorFrame: CGRect)]
    let incomingEntries: [(entry: WindowState, priorFrame: CGRect)]
}

@MainActor
extension LayoutRefreshController {
    /// Matches niri's own `workspace-switch` config shape (`damping-ratio`,
    /// `stiffness`, `epsilon`) so a future settings.toml entry can map onto it
    /// directly. Not yet configurable — see the yak for follow-up.
    static let workspaceSwitchSpringConfig = SpringConfig(dampingRatio: 1.0, stiffness: 120, epsilon: 0.001)

    /// Starts the visual slide. Must be called *after* the real switch has
    /// already been committed — see the type doc. A no-op if animations are
    /// disabled or there is nothing to animate.
    func startWorkspaceSwitchTransition(
        monitor: Monitor,
        outgoingEntries: [(entry: WindowState, priorFrame: CGRect)],
        incomingEntries: [(entry: WindowState, priorFrame: CGRect)]
    ) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        guard !outgoingEntries.isEmpty || !incomingEntries.isEmpty else { return }
        guard let displayLink = getOrCreateDisplayLink(for: monitor.displayId) else { return }

        let spring = SpringAnimation(
            from: 0,
            to: 1,
            startTime: CACurrentMediaTime(),
            config: Self.workspaceSwitchSpringConfig,
            displayRefreshRate: layoutState.refreshRateByDisplay[monitor.displayId] ?? 60
        )

        layoutState.workspaceSwitchTransitionsByDisplay[monitor.displayId] = WorkspaceSwitchTransition(
            monitorId: monitor.id,
            spring: spring,
            outgoingEntries: outgoingEntries,
            incomingEntries: incomingEntries
        )
        displayLink.add(to: .main, forMode: .common)
    }

    var workspaceSwitchTransitionsByDisplay: [CGDirectDisplayID: WorkspaceSwitchTransition] {
        get { layoutState.workspaceSwitchTransitionsByDisplay }
        set { layoutState.workspaceSwitchTransitionsByDisplay = newValue }
    }

    func tickWorkspaceSwitchTransition(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let transition = layoutState.workspaceSwitchTransitionsByDisplay[displayId] else { return }
        guard let controller else {
            layoutState.workspaceSwitchTransitionsByDisplay.removeValue(forKey: displayId)
            return
        }

        let progress = CGFloat(transition.spring.value(at: targetTime))
        let complete = transition.spring.isComplete(at: targetTime)

        var positions: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        positions.reserveCapacity(transition.outgoingEntries.count + transition.incomingEntries.count)

        for (entry, priorFrame) in transition.outgoingEntries + transition.incomingEntries {
            let currentFrame = fastFrame(for: entry.token, axRef: entry.axRef) ?? priorFrame
            let frame = complete ? currentFrame : interpolatedFrame(from: priorFrame, to: currentFrame, progress: progress)
            positions.append((pid: entry.token.pid, windowId: entry.token.windowId, frame: frame))
        }

        if !positions.isEmpty {
            controller.axManager.applyPositionsViaSkyLight(positions, allowInactive: true)
        }

        if complete {
            layoutState.workspaceSwitchTransitionsByDisplay.removeValue(forKey: displayId)
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    /// Plain LERP from `from` to `to`, both real frames — no assumption about
    /// which axis moves or by how much, since the real switch already decided
    /// the actual start/end positions on both.
    func interpolatedFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: from.origin.x + progress * (to.origin.x - from.origin.x),
            y: from.origin.y + progress * (to.origin.y - from.origin.y),
            width: from.width + progress * (to.width - from.width),
            height: from.height + progress * (to.height - from.height)
        )
    }
}
