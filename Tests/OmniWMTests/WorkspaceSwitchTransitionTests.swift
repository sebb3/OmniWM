import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite struct WorkspaceSwitchTransitionTests {
  @Test func nextWorkspaceMovesOutgoingUpAndIncomingFromBelow() throws {
    let outgoingFrame = CGRect(x: 100, y: 200, width: 500, height: 400)
    let incomingFrame = CGRect(x: 300, y: 250, width: 600, height: 450)
    let plan = WorkspaceSwitchTransitionPlan(
      displayId: 1,
      monitorFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
      targetWorkspaceId: UUID(),
      outgoingFrames: [11: outgoingFrame],
      incomingFrames: [12: incomingFrame],
      incomingOffsetY: -900,
      duration: .milliseconds(300),
      frameInterval: .milliseconds(16)
    )

    let members = try #require(plan.members())
    let outgoing = try #require(members.first(where: { $0.windowId == 11 }))
    let incoming = try #require(members.first(where: { $0.windowId == 12 }))

    #expect(outgoing.from == transform(for: outgoingFrame))
    #expect(outgoing.to == transform(for: outgoingFrame.offsetBy(dx: 0, dy: 900)))
    #expect(incoming.from == transform(for: incomingFrame.offsetBy(dx: 0, dy: -900)))
    #expect(incoming.to == transform(for: incomingFrame))
  }

  @Test func previousWorkspaceReversesVerticalMotion() throws {
    let frame = CGRect(x: 40, y: 80, width: 500, height: 400)
    let plan = WorkspaceSwitchTransitionPlan(
      displayId: 1,
      monitorFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
      targetWorkspaceId: UUID(),
      outgoingFrames: [1: frame],
      incomingFrames: [2: frame],
      incomingOffsetY: 900,
      duration: .milliseconds(300),
      frameInterval: .milliseconds(16)
    )

    let members = try #require(plan.members())
    let outgoing = try #require(members.first(where: { $0.windowId == 1 }))
    let incoming = try #require(members.first(where: { $0.windowId == 2 }))

    #expect(outgoing.to == transform(for: frame.offsetBy(dx: 0, dy: -900)))
    #expect(incoming.from == transform(for: frame.offsetBy(dx: 0, dy: 900)))
  }

  @Test func transitionIsAllOrNothingAbovePayloadWindowBound() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let outgoing = Dictionary(
      uniqueKeysWithValues: (1...32).map { (UInt32($0), frame) }
    )
    let plan = WorkspaceSwitchTransitionPlan(
      displayId: 1,
      monitorFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
      targetWorkspaceId: UUID(),
      outgoingFrames: outgoing,
      incomingFrames: [33: frame],
      incomingOffsetY: -900,
      duration: .milliseconds(300),
      frameInterval: .milliseconds(16)
    )

    #expect(plan.members() == nil)
  }

  @Test func incomingWorkspaceUsesRestoreFrameWhenPhysicalWindowIsParked() throws {
    let monitor = CGRect(x: 0, y: 0, width: 1600, height: 900)
    let parked = CGRect(x: 1610, y: 200, width: 500, height: 400)
    let restored = CGRect(x: 100, y: 200, width: 500, height: 400)

    let frame = try #require(LayoutRefreshController.transitionFrame(
      physicalFrame: parked,
      restoreFrame: restored,
      monitorFrame: monitor
    ))

    #expect(frame == restored)
  }

  @Test func outgoingWorkspaceStillUsesVisiblePhysicalFrame() throws {
    let monitor = CGRect(x: 0, y: 0, width: 1600, height: 900)
    let visible = CGRect(x: 100, y: 200, width: 500, height: 400)

    let frame = try #require(LayoutRefreshController.transitionFrame(
      physicalFrame: visible,
      restoreFrame: nil,
      monitorFrame: monitor
    ))

    #expect(frame == visible)
  }

  private func transform(for frame: CGRect) -> CGAffineTransform {
    let origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
    return CGAffineTransform(translationX: -origin.x, y: -origin.y)
  }
}
