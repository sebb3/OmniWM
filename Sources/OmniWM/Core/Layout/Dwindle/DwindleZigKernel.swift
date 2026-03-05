import CZigLayout
import CoreGraphics
import Foundation

enum DwindleZigKernel {
    enum NodeKind: UInt8 {
        case split = 0
        case leaf = 1
    }

    enum Orientation: UInt8 {
        case horizontal = 0
        case vertical = 1
    }

    struct SeedNode {
        let nodeId: UUID
        let parentIndex: Int
        let firstChildIndex: Int
        let secondChildIndex: Int
        let kind: NodeKind
        let orientation: Orientation
        let ratio: CGFloat
        let windowId: UUID?
        let isFullscreen: Bool
    }

    struct SeedState {
        let rootNodeIndex: Int
        let selectedNodeIndex: Int
        let preselection: Direction?

        init(
            rootNodeIndex: Int,
            selectedNodeIndex: Int = -1,
            preselection: Direction? = nil
        ) {
            self.rootNodeIndex = rootNodeIndex
            self.selectedNodeIndex = selectedNodeIndex
            self.preselection = preselection
        }
    }

    struct LayoutRequest {
        let screen: CGRect
        let innerGap: CGFloat
        let outerGapTop: CGFloat
        let outerGapBottom: CGFloat
        let outerGapLeft: CGFloat
        let outerGapRight: CGFloat
        let singleWindowAspectRatio: CGSize
        let singleWindowAspectTolerance: CGFloat
        let runtimeSettings: OmniDwindleRuntimeSettings

        init(screen: CGRect, settings: DwindleSettings) {
            self.screen = screen
            innerGap = settings.innerGap
            outerGapTop = settings.outerGapTop
            outerGapBottom = settings.outerGapBottom
            outerGapLeft = settings.outerGapLeft
            outerGapRight = settings.outerGapRight
            singleWindowAspectRatio = settings.singleWindowAspectRatio
            singleWindowAspectTolerance = settings.singleWindowAspectRatioTolerance
            runtimeSettings = DwindleZigKernel.runtimeSettingsRaw(from: settings)
        }
    }

    struct WindowConstraint {
        let windowId: UUID
        let minSize: CGSize
        let maxSize: CGSize
        let hasMaxWidth: Bool
        let hasMaxHeight: Bool
        let isFixed: Bool

        init(windowId: UUID, constraints: WindowSizeConstraints) {
            self.windowId = windowId
            minSize = constraints.minSize
            maxSize = constraints.maxSize
            hasMaxWidth = constraints.hasMaxWidth
            hasMaxHeight = constraints.hasMaxHeight
            isFixed = constraints.isFixed
        }
    }

    struct LayoutResult {
        let rc: Int32
        let frameCount: Int
        let framesByWindowId: [UUID: CGRect]
    }

    struct NeighborResult {
        let rc: Int32
        let neighborWindowId: UUID?
    }

    enum Op {
        case addWindow(windowId: UUID)
        case removeWindow(windowId: UUID)
        case syncWindows(windowIds: [UUID])
        case moveFocus(direction: Direction)
        case swapWindows(direction: Direction)
        case toggleFullscreen
        case toggleOrientation
        case resizeSelected(delta: CGFloat, direction: Direction)
        case balanceSizes
        case cycleSplitRatio(forward: Bool)
        case moveSelectionToRoot(stable: Bool)
        case swapSplit
        case setPreselection(direction: Direction)
        case clearPreselection
        case validateSelection
    }

    struct OpResult {
        let rc: Int32
        let applied: Bool
        let selectedWindowId: UUID?
        let focusedWindowId: UUID?
        let preselection: Direction?
        let removedWindowIds: [UUID]
    }

    final class LayoutContext {
        fileprivate let raw: OpaquePointer

        init?() {
            guard let raw = omni_dwindle_layout_context_create() else { return nil }
            self.raw = raw
        }

        deinit {
            omni_dwindle_layout_context_destroy(raw)
        }
    }

    static func seedState(
        context: LayoutContext,
        nodes: [SeedNode],
        state: SeedState
    ) -> Int32 {
        let rawNodes = nodes.map { node in
            OmniDwindleSeedNode(
                node_id: omniUUID(from: node.nodeId),
                parent_index: Int64(node.parentIndex),
                first_child_index: Int64(node.firstChildIndex),
                second_child_index: Int64(node.secondChildIndex),
                kind: node.kind.rawValue,
                orientation: node.orientation.rawValue,
                ratio: Double(node.ratio),
                has_window_id: node.windowId == nil ? 0 : 1,
                window_id: node.windowId.map(omniUUID(from:)) ?? zeroUUID(),
                is_fullscreen: node.isFullscreen ? 1 : 0
            )
        }

        var rawState = OmniDwindleSeedState(
            root_node_index: Int64(state.rootNodeIndex),
            selected_node_index: Int64(state.selectedNodeIndex),
            has_preselection: state.preselection == nil ? 0 : 1,
            preselection_direction: directionCode(state.preselection ?? .left)
        )

        return rawNodes.withUnsafeBufferPointer { nodeBuf in
            withUnsafePointer(to: &rawState) { statePtr in
                omni_dwindle_ctx_seed_state(
                    context.raw,
                    nodeBuf.baseAddress,
                    nodeBuf.count,
                    statePtr
                )
            }
        }
    }

    static func calculateLayout(
        context: LayoutContext,
        request: LayoutRequest,
        constraints: [WindowConstraint]
    ) -> LayoutResult {
        let rawRequest = OmniDwindleLayoutRequest(
            screen_x: Double(request.screen.minX),
            screen_y: Double(request.screen.minY),
            screen_width: Double(request.screen.width),
            screen_height: Double(request.screen.height),
            inner_gap: Double(request.innerGap),
            outer_gap_top: Double(request.outerGapTop),
            outer_gap_bottom: Double(request.outerGapBottom),
            outer_gap_left: Double(request.outerGapLeft),
            outer_gap_right: Double(request.outerGapRight),
            single_window_aspect_width: Double(request.singleWindowAspectRatio.width),
            single_window_aspect_height: Double(request.singleWindowAspectRatio.height),
            single_window_aspect_tolerance: Double(request.singleWindowAspectTolerance),
            runtime_settings: request.runtimeSettings
        )

        let rawConstraints = constraints.map { constraint in
            OmniDwindleWindowConstraint(
                window_id: omniUUID(from: constraint.windowId),
                min_width: Double(constraint.minSize.width),
                min_height: Double(constraint.minSize.height),
                max_width: Double(constraint.maxSize.width),
                max_height: Double(constraint.maxSize.height),
                has_max_width: constraint.hasMaxWidth ? 1 : 0,
                has_max_height: constraint.hasMaxHeight ? 1 : 0,
                is_fixed: constraint.isFixed ? 1 : 0
            )
        }

        var rawFrames = [OmniDwindleWindowFrame](
            repeating: OmniDwindleWindowFrame(
                window_id: zeroUUID(),
                frame_x: 0,
                frame_y: 0,
                frame_width: 0,
                frame_height: 0
            ),
            count: 512
        )

        var outFrameCount: Int = 0
        let rc: Int32 = rawConstraints.withUnsafeBufferPointer { constraintBuf in
            rawFrames.withUnsafeMutableBufferPointer { frameBuf in
                var mutableRequest = rawRequest
                return withUnsafePointer(to: &mutableRequest) { requestPtr in
                    withUnsafeMutablePointer(to: &outFrameCount) { outCountPtr in
                        omni_dwindle_ctx_calculate_layout(
                            context.raw,
                            requestPtr,
                            constraintBuf.baseAddress,
                            constraintBuf.count,
                            frameBuf.baseAddress,
                            frameBuf.count,
                            outCountPtr
                        )
                    }
                }
            }
        }

        guard rc == OMNI_OK else {
            return LayoutResult(rc: rc, frameCount: max(0, outFrameCount), framesByWindowId: [:])
        }

        let resolvedCount = min(max(outFrameCount, 0), rawFrames.count)
        var framesByWindowId: [UUID: CGRect] = [:]
        framesByWindowId.reserveCapacity(resolvedCount)

        for idx in 0 ..< resolvedCount {
            let frame = rawFrames[idx]
            framesByWindowId[uuid(from: frame.window_id)] = CGRect(
                x: frame.frame_x,
                y: frame.frame_y,
                width: frame.frame_width,
                height: frame.frame_height
            )
        }

        return LayoutResult(rc: rc, frameCount: outFrameCount, framesByWindowId: framesByWindowId)
    }

    static func findNeighbor(
        context: LayoutContext,
        windowId: UUID,
        direction: Direction,
        innerGap: CGFloat
    ) -> NeighborResult {
        var hasNeighbor: UInt8 = 0
        var neighborId = zeroUUID()

        let rc = withUnsafeMutablePointer(to: &hasNeighbor) { hasNeighborPtr in
            withUnsafeMutablePointer(to: &neighborId) { neighborPtr in
                omni_dwindle_ctx_find_neighbor(
                    context.raw,
                    omniUUID(from: windowId),
                    directionCode(direction),
                    Double(innerGap),
                    hasNeighborPtr,
                    neighborPtr
                )
            }
        }

        guard rc == OMNI_OK else {
            return NeighborResult(rc: rc, neighborWindowId: nil)
        }

        guard hasNeighbor != 0, !isZeroUUID(neighborId) else {
            return NeighborResult(rc: rc, neighborWindowId: nil)
        }

        return NeighborResult(rc: rc, neighborWindowId: uuid(from: neighborId))
    }

    static func applyOp(
        context: LayoutContext,
        op: Op,
        runtimeSettings: DwindleSettings,
        activeWindowFrame: CGRect? = nil
    ) -> OpResult {
        var removedRaw = [OmniUuid128](repeating: zeroUUID(), count: 512)
        var rawResult = OmniDwindleOpResult(
            applied: 0,
            has_selected_window_id: 0,
            selected_window_id: zeroUUID(),
            has_focused_window_id: 0,
            focused_window_id: zeroUUID(),
            has_preselection: 0,
            preselection_direction: directionCode(.left),
            removed_window_count: 0
        )
        let rawRuntimeSettings = runtimeSettingsRaw(from: runtimeSettings)

        func invoke(opCode: UInt8, configure: (inout OmniDwindleOpPayload) -> Void) -> Int32 {
            var payload = OmniDwindleOpPayload()
            configure(&payload)
            var request = OmniDwindleOpRequest(
                op: opCode,
                payload: payload,
                runtime_settings: rawRuntimeSettings
            )
            return removedRaw.withUnsafeMutableBufferPointer { removedBuf in
                withUnsafePointer(to: &request) { requestPtr in
                    withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                        omni_dwindle_ctx_apply_op(
                            context.raw,
                            requestPtr,
                            resultPtr,
                            removedBuf.baseAddress,
                            removedBuf.count
                        )
                    }
                }
            }
        }

        let rc: Int32
        switch op {
        case let .addWindow(windowId):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_ADD_WINDOW.rawValue)) { payload in
                payload.add_window = OmniDwindleAddWindowPayload(
                    window_id: omniUUID(from: windowId),
                    has_active_window_frame: activeWindowFrame == nil ? 0 : 1,
                    active_window_frame: activeWindowFrame.map(rawRect(from:)) ?? zeroRect()
                )
            }
        case let .removeWindow(windowId):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_REMOVE_WINDOW.rawValue)) { payload in
                payload.remove_window = OmniDwindleRemoveWindowPayload(window_id: omniUUID(from: windowId))
            }
        case let .syncWindows(windowIds):
            let rawWindowIds = windowIds.map(omniUUID(from:))
            rc = rawWindowIds.withUnsafeBufferPointer { idBuf in
                invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_SYNC_WINDOWS.rawValue)) { payload in
                    payload.sync_windows = OmniDwindleSyncWindowsPayload(
                        window_ids: idBuf.baseAddress,
                        window_count: idBuf.count
                    )
                }
            }
        case let .moveFocus(direction):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_MOVE_FOCUS.rawValue)) { payload in
                payload.move_focus = OmniDwindleMoveFocusPayload(direction: directionCode(direction))
            }
        case let .swapWindows(direction):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_SWAP_WINDOWS.rawValue)) { payload in
                payload.swap_windows = OmniDwindleSwapWindowsPayload(direction: directionCode(direction))
            }
        case .toggleFullscreen:
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN.rawValue)) { payload in
                payload.toggle_fullscreen = OmniDwindleToggleFullscreenPayload(unused: 0)
            }
        case .toggleOrientation:
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_TOGGLE_ORIENTATION.rawValue)) { payload in
                payload.toggle_orientation = OmniDwindleToggleOrientationPayload(unused: 0)
            }
        case let .resizeSelected(delta, direction):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_RESIZE_SELECTED.rawValue)) { payload in
                payload.resize_selected = OmniDwindleResizeSelectedPayload(
                    delta: Double(delta),
                    direction: directionCode(direction)
                )
            }
        case .balanceSizes:
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_BALANCE_SIZES.rawValue)) { payload in
                payload.balance_sizes = OmniDwindleBalanceSizesPayload(unused: 0)
            }
        case let .cycleSplitRatio(forward):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO.rawValue)) { payload in
                payload.cycle_split_ratio = OmniDwindleCycleSplitRatioPayload(forward: forward ? 1 : 0)
            }
        case let .moveSelectionToRoot(stable):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT.rawValue)) { payload in
                payload.move_selection_to_root = OmniDwindleMoveSelectionToRootPayload(stable: stable ? 1 : 0)
            }
        case .swapSplit:
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_SWAP_SPLIT.rawValue)) { payload in
                payload.swap_split = OmniDwindleSwapSplitPayload(unused: 0)
            }
        case let .setPreselection(direction):
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_SET_PRESELECTION.rawValue)) { payload in
                payload.set_preselection = OmniDwindleSetPreselectionPayload(direction: directionCode(direction))
            }
        case .clearPreselection:
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_CLEAR_PRESELECTION.rawValue)) { payload in
                payload.clear_preselection = OmniDwindleClearPreselectionPayload(unused: 0)
            }
        case .validateSelection:
            rc = invoke(opCode: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_VALIDATE_SELECTION.rawValue)) { payload in
                payload.validate_selection = OmniDwindleValidateSelectionPayload(unused: 0)
            }
        }

        let selected: UUID?
        if rawResult.has_selected_window_id != 0, !isZeroUUID(rawResult.selected_window_id) {
            selected = uuid(from: rawResult.selected_window_id)
        } else {
            selected = nil
        }

        let focused: UUID?
        if rawResult.has_focused_window_id != 0, !isZeroUUID(rawResult.focused_window_id) {
            focused = uuid(from: rawResult.focused_window_id)
        } else {
            focused = nil
        }

        let preselection: Direction?
        if rawResult.has_preselection != 0 {
            preselection = direction(from: rawResult.preselection_direction)
        } else {
            preselection = nil
        }

        let resolvedRemovedCount = min(max(0, rawResult.removed_window_count), removedRaw.count)
        var removedIds: [UUID] = []
        removedIds.reserveCapacity(resolvedRemovedCount)
        if rc == OMNI_OK, resolvedRemovedCount > 0 {
            for idx in 0 ..< resolvedRemovedCount {
                if isZeroUUID(removedRaw[idx]) { continue }
                removedIds.append(uuid(from: removedRaw[idx]))
            }
        }

        return OpResult(
            rc: rc,
            applied: rawResult.applied != 0,
            selectedWindowId: selected,
            focusedWindowId: focused,
            preselection: preselection,
            removedWindowIds: removedIds
        )
    }

    static func omniUUID(from uuid: UUID) -> OmniUuid128 {
        var rawUUID = uuid.uuid
        var encoded = OmniUuid128()
        withUnsafeBytes(of: &rawUUID) { src in
            withUnsafeMutableBytes(of: &encoded) { dst in
                dst.copyBytes(from: src)
            }
        }
        return encoded
    }

    static func uuid(from omniUuid: OmniUuid128) -> UUID {
        var decoded = UUID().uuid
        var value = omniUuid
        withUnsafeBytes(of: &value) { src in
            withUnsafeMutableBytes(of: &decoded) { dst in
                dst.copyBytes(from: src)
            }
        }
        return UUID(uuid: decoded)
    }

    private static func zeroUUID() -> OmniUuid128 {
        OmniUuid128()
    }

    private static func isZeroUUID(_ value: OmniUuid128) -> Bool {
        withUnsafeBytes(of: value) { raw in
            raw.allSatisfy { $0 == 0 }
        }
    }

    private static func runtimeSettingsRaw(from settings: DwindleSettings) -> OmniDwindleRuntimeSettings {
        OmniDwindleRuntimeSettings(
            smart_split: settings.smartSplit ? 1 : 0,
            default_split_ratio: Double(settings.defaultSplitRatio),
            split_width_multiplier: Double(settings.splitWidthMultiplier),
            inner_gap: Double(settings.innerGap)
        )
    }

    private static func rawRect(from frame: CGRect) -> OmniDwindleRect {
        OmniDwindleRect(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.size.width),
            height: Double(frame.size.height)
        )
    }

    private static func zeroRect() -> OmniDwindleRect {
        OmniDwindleRect(x: 0, y: 0, width: 0, height: 0)
    }

    private static func directionCode(_ direction: Direction) -> UInt8 {
        switch direction {
        case .left:
            return 0
        case .right:
            return 1
        case .up:
            return 2
        case .down:
            return 3
        }
    }

    private static func direction(from raw: UInt8) -> Direction? {
        switch raw {
        case 0:
            return .left
        case 1:
            return .right
        case 2:
            return .up
        case 3:
            return .down
        default:
            return nil
        }
    }
}
