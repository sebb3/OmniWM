// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct WorkspaceSwitchTransitionPlan {
  let displayId: CGDirectDisplayID
  let monitorFrame: CGRect
  let targetWorkspaceId: WorkspaceDescriptor.ID
  let outgoingFrames: [UInt32: CGRect]
  let incomingFrames: [UInt32: CGRect]
  let incomingOffsetY: CGFloat
  let duration: Duration
  let frameInterval: Duration

  func members() -> [DockWorkspaceTransitionMember]? {
    guard outgoingFrames.count + incomingFrames.count <= 32 else { return nil }

    let outgoing = outgoingFrames.map { windowId, frame in
      DockWorkspaceTransitionMember(
        windowId: windowId,
        from: Self.presentationTransform(for: frame),
        to: Self.presentationTransform(
          for: frame.offsetBy(dx: 0, dy: -incomingOffsetY)
        )
      )
    }
    let incoming = incomingFrames.map { windowId, frame in
      DockWorkspaceTransitionMember(
        windowId: windowId,
        from: Self.presentationTransform(
          for: frame.offsetBy(dx: 0, dy: incomingOffsetY)
        ),
        to: Self.presentationTransform(for: frame)
      )
    }
    return (outgoing + incoming).sorted { $0.windowId < $1.windowId }
  }

  static func presentationTransform(for frame: CGRect) -> CGAffineTransform {
    let origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
    return CGAffineTransform(translationX: -origin.x, y: -origin.y)
  }
}

@MainActor
final class WorkspaceSwitchTransitionCoordinator {
  private var tasksByDisplay: [CGDirectDisplayID: Task<Void, Never>] = [:]
  private var generationsByDisplay: [CGDirectDisplayID: UUID] = [:]

  func start(
    _ plan: WorkspaceSwitchTransitionPlan,
    members: [DockWorkspaceTransitionMember],
    completion: @escaping @MainActor () -> Void
  ) {
    tasksByDisplay.removeValue(forKey: plan.displayId)?.cancel()
    let generation = UUID()
    generationsByDisplay[plan.displayId] = generation
    tasksByDisplay[plan.displayId] = Task { [weak self] in
      defer {
        if self?.generationsByDisplay[plan.displayId] == generation {
          self?.tasksByDisplay.removeValue(forKey: plan.displayId)
          self?.generationsByDisplay.removeValue(forKey: plan.displayId)
        }
      }
      _ = await DockPayloadClient.runWorkspaceTransition(
        members: members,
        duration: plan.duration,
        frameInterval: plan.frameInterval
      )
      guard !Task.isCancelled,
        self?.generationsByDisplay[plan.displayId] == generation
      else { return }
      completion()
    }
  }

  func cancel(displayId: CGDirectDisplayID) {
    tasksByDisplay.removeValue(forKey: displayId)?.cancel()
    generationsByDisplay.removeValue(forKey: displayId)
  }

  func cancelAll() {
    for task in tasksByDisplay.values {
      task.cancel()
    }
    tasksByDisplay.removeAll()
    generationsByDisplay.removeAll()
  }
}

@MainActor
extension LayoutRefreshController {
  func prepareWorkspaceSwitchTransition(
    sourceWorkspaceId: WorkspaceDescriptor.ID,
    targetWorkspaceId: WorkspaceDescriptor.ID,
    monitor: Monitor
  ) -> WorkspaceSwitchTransitionPlan? {
    guard sourceWorkspaceId != targetWorkspaceId,
      controller?.motionPolicy.animationsEnabled != false,
      let controller
    else { return nil }

    let ordered = controller.workspaceManager.workspaces(on: monitor.id)
    guard let sourceIndex = ordered.firstIndex(where: { $0.id == sourceWorkspaceId }),
      let targetIndex = ordered.firstIndex(where: { $0.id == targetWorkspaceId }),
      sourceIndex != targetIndex
    else { return nil }

    let outgoingFrames = transitionFrames(in: sourceWorkspaceId, monitorFrame: monitor.frame)
    let travel = max(monitor.frame.height, 1)
    let incomingOffsetY = targetIndex > sourceIndex ? -travel : travel
    let refreshRate = max(Monitor.refreshRate(for: monitor.displayId), 1)

    return WorkspaceSwitchTransitionPlan(
      displayId: monitor.displayId,
      monitorFrame: monitor.frame,
      targetWorkspaceId: targetWorkspaceId,
      outgoingFrames: outgoingFrames,
      incomingFrames: transitionFrames(
        in: targetWorkspaceId,
        monitorFrame: monitor.frame
      ),
      incomingOffsetY: incomingOffsetY,
      duration: .milliseconds(300),
      frameInterval: .nanoseconds(Int64(1_000_000_000 / refreshRate))
    )
  }

  func startWorkspaceSwitchTransition(
    _ plan: WorkspaceSwitchTransitionPlan?,
    completion: @escaping @MainActor () -> Void
  ) -> Bool {
    guard let plan,
      controller?.workspaceManager.activeWorkspace(
        on: Monitor.ID(displayId: plan.displayId)
      )?.id == plan.targetWorkspaceId
    else { return false }

    guard let members = plan.members(),
      !members.isEmpty
    else { return false }
    workspaceSwitchTransitionCoordinator.start(plan, members: members, completion: completion)
    return true
  }

  private func transitionFrames(
    in workspaceId: WorkspaceDescriptor.ID,
    monitorFrame: CGRect
  ) -> [UInt32: CGRect] {
    guard let controller else { return [:] }
    let monitor = controller.workspaceManager.monitor(for: workspaceId)
    return controller.workspaceManager.entries(in: workspaceId).reduce(into: [:]) { frames, entry in
      guard !controller.isManagedWindowSuppressedByMacOSHide(entry.token),
        let windowId = UInt32(exactly: entry.windowId),
        let frame = Self.transitionFrame(
          physicalFrame: fastFrame(for: entry.token, axRef: entry.axRef),
          restoreFrame: workspaceInactiveRestoreFrame(for: entry, monitor: monitor),
          monitorFrame: monitorFrame
        ),
        monitorFrame.intersects(frame)
      else { return }
      frames[windowId] = frame
    }
  }

  private func workspaceInactiveRestoreFrame(
    for entry: WindowState,
    monitor: Monitor?
  ) -> CGRect? {
    guard let monitor,
      let hiddenState = entry.hiddenState,
      hiddenState.workspaceInactive
    else { return nil }
    return makeRestorePositionPlan(
      for: entry,
      monitor: monitor,
      hiddenState: hiddenState
    )?.frame
  }

  nonisolated static func transitionFrame(
    physicalFrame: CGRect?,
    restoreFrame: CGRect?,
    monitorFrame: CGRect
  ) -> CGRect? {
    if let restoreFrame, monitorFrame.intersects(restoreFrame) {
      return restoreFrame
    }
    guard let physicalFrame, monitorFrame.intersects(physicalFrame) else { return nil }
    return physicalFrame
  }
}
