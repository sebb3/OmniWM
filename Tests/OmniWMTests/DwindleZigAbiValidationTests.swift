import CZigLayout
import Foundation
import Testing

@testable import OmniWM

private let abiOK: Int32 = 0
private let abiErrInvalidArgs: Int32 = -1
private let abiErrOutOfRange: Int32 = -2

private func makeUUID(_ marker: UInt8) -> OmniUuid128 {
    var value = OmniUuid128()
    withUnsafeMutableBytes(of: &value) { raw in
        for idx in raw.indices {
            raw[idx] = 0
        }
        raw[0] = marker
    }
    return value
}

private func defaultSeedState(
    rootNodeIndex: Int64 = -1,
    selectedNodeIndex: Int64 = -1,
    hasPreselection: Bool = false,
    preselectionDirection: UInt8 = UInt8(truncatingIfNeeded: OMNI_DWINDLE_DIRECTION_LEFT.rawValue)
) -> OmniDwindleSeedState {
    OmniDwindleSeedState(
        root_node_index: rootNodeIndex,
        selected_node_index: selectedNodeIndex,
        has_preselection: hasPreselection ? 1 : 0,
        preselection_direction: preselectionDirection
    )
}

private func makeLeafNode(
    nodeMarker: UInt8,
    parentIndex: Int64 = -1,
    hasWindow: Bool = true,
    windowMarker: UInt8
) -> OmniDwindleSeedNode {
    OmniDwindleSeedNode(
        node_id: makeUUID(nodeMarker),
        parent_index: parentIndex,
        first_child_index: -1,
        second_child_index: -1,
        kind: UInt8(truncatingIfNeeded: OMNI_DWINDLE_NODE_LEAF.rawValue),
        orientation: UInt8(truncatingIfNeeded: OMNI_DWINDLE_ORIENTATION_HORIZONTAL.rawValue),
        ratio: 1.0,
        has_window_id: hasWindow ? 1 : 0,
        window_id: hasWindow ? makeUUID(windowMarker) : makeUUID(0),
        is_fullscreen: 0
    )
}

private func makeSplitNode(
    nodeMarker: UInt8,
    firstChildIndex: Int64,
    secondChildIndex: Int64,
    orientation: UInt8 = UInt8(truncatingIfNeeded: OMNI_DWINDLE_ORIENTATION_HORIZONTAL.rawValue),
    ratio: Double = 1.0
) -> OmniDwindleSeedNode {
    OmniDwindleSeedNode(
        node_id: makeUUID(nodeMarker),
        parent_index: -1,
        first_child_index: firstChildIndex,
        second_child_index: secondChildIndex,
        kind: UInt8(truncatingIfNeeded: OMNI_DWINDLE_NODE_SPLIT.rawValue),
        orientation: orientation,
        ratio: ratio,
        has_window_id: 0,
        window_id: makeUUID(0),
        is_fullscreen: 0
    )
}

private func approxEqual(_ lhs: Double, _ rhs: Double, epsilon: Double = 0.01) -> Bool {
    abs(lhs - rhs) <= epsilon
}

private func defaultRuntimeSettings(
    smartSplit: Bool = true,
    defaultSplitRatio: Double = 1.0,
    splitWidthMultiplier: Double = 1.0,
    innerGap: Double = 8.0
) -> OmniDwindleRuntimeSettings {
    OmniDwindleRuntimeSettings(
        smart_split: smartSplit ? 1 : 0,
        default_split_ratio: defaultSplitRatio,
        split_width_multiplier: splitWidthMultiplier,
        inner_gap: innerGap
    )
}

private func zeroDwindleRect() -> OmniDwindleRect {
    OmniDwindleRect(x: 0, y: 0, width: 0, height: 0)
}

private func defaultLayoutRequest() -> OmniDwindleLayoutRequest {
    OmniDwindleLayoutRequest(
        screen_x: 0,
        screen_y: 0,
        screen_width: 1920,
        screen_height: 1080,
        inner_gap: 8,
        outer_gap_top: 0,
        outer_gap_bottom: 0,
        outer_gap_left: 0,
        outer_gap_right: 0,
        single_window_aspect_width: 4,
        single_window_aspect_height: 3,
        single_window_aspect_tolerance: 0.1,
        runtime_settings: defaultRuntimeSettings()
    )
}

private func defaultOpResult() -> OmniDwindleOpResult {
    OmniDwindleOpResult(
        applied: 0,
        has_selected_window_id: 0,
        selected_window_id: makeUUID(0),
        has_focused_window_id: 0,
        focused_window_id: makeUUID(0),
        has_preselection: 0,
        preselection_direction: UInt8(truncatingIfNeeded: OMNI_DWINDLE_DIRECTION_LEFT.rawValue),
        removed_window_count: 0
    )
}

private func makeOpRequest(
    op: UInt8,
    runtimeSettings: OmniDwindleRuntimeSettings = defaultRuntimeSettings(),
    configurePayload: (inout OmniDwindleOpPayload) -> Void = { _ in }
) -> OmniDwindleOpRequest {
    var payload = OmniDwindleOpPayload()
    configurePayload(&payload)
    return OmniDwindleOpRequest(
        op: op,
        payload: payload,
        runtime_settings: runtimeSettings
    )
}

private func withDwindleContext<T>(_ body: (OpaquePointer) -> T) -> T {
    guard let context = omni_dwindle_layout_context_create() else {
        fatalError("Failed to allocate OmniDwindleLayoutContext")
    }
    defer {
        omni_dwindle_layout_context_destroy(context)
    }
    return body(context)
}

private func seedState(
    context: OpaquePointer,
    nodes: [OmniDwindleSeedNode],
    seedState: OmniDwindleSeedState
) -> Int32 {
    nodes.withUnsafeBufferPointer { nodeBuf in
        var mutableSeed = seedState
        return withUnsafePointer(to: &mutableSeed) { seedPtr in
            omni_dwindle_ctx_seed_state(context, nodeBuf.baseAddress, nodeBuf.count, seedPtr)
        }
    }
}

private func applyOp(
    context: OpaquePointer,
    request: OmniDwindleOpRequest,
    removedCapacity: Int = 8
) -> (rc: Int32, result: OmniDwindleOpResult, removed: [OmniUuid128]) {
    var mutableRequest = request
    var result = defaultOpResult()
    var removed = [OmniUuid128](repeating: makeUUID(0), count: max(0, removedCapacity))
    let rc = withUnsafePointer(to: &mutableRequest) { requestPtr in
        withUnsafeMutablePointer(to: &result) { resultPtr in
            removed.withUnsafeMutableBufferPointer { removedBuf in
                omni_dwindle_ctx_apply_op(
                    context,
                    requestPtr,
                    resultPtr,
                    removedCapacity > 0 ? removedBuf.baseAddress : nil,
                    removedCapacity > 0 ? removedBuf.count : 0
                )
            }
        }
    }
    return (rc, result, removed)
}

private func layoutFrameCount(context: OpaquePointer) -> Int {
    var request = defaultLayoutRequest()
    var outCount = -1
    var frames = [OmniDwindleWindowFrame](
        repeating: OmniDwindleWindowFrame(
            window_id: makeUUID(0),
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0
        ),
        count: 16
    )
    let rc = withUnsafePointer(to: &request) { requestPtr in
        frames.withUnsafeMutableBufferPointer { frameBuf in
            withUnsafeMutablePointer(to: &outCount) { countPtr in
                omni_dwindle_ctx_calculate_layout(
                    context,
                    requestPtr,
                    nil,
                    0,
                    frameBuf.baseAddress,
                    frameBuf.count,
                    countPtr
                )
            }
        }
    }
    #expect(rc == abiOK)
    return max(0, outCount)
}

@Suite struct DwindleZigAbiValidationTests {
    @Test func constantsStayAligned() {
        #expect(Int(OMNI_DWINDLE_MAX_NODES) == 1023)

        #expect(OMNI_DWINDLE_NODE_SPLIT.rawValue == 0)
        #expect(OMNI_DWINDLE_NODE_LEAF.rawValue == 1)
        #expect(OMNI_DWINDLE_ORIENTATION_HORIZONTAL.rawValue == 0)
        #expect(OMNI_DWINDLE_ORIENTATION_VERTICAL.rawValue == 1)
        #expect(OMNI_DWINDLE_DIRECTION_LEFT.rawValue == 0)
        #expect(OMNI_DWINDLE_DIRECTION_RIGHT.rawValue == 1)
        #expect(OMNI_DWINDLE_DIRECTION_UP.rawValue == 2)
        #expect(OMNI_DWINDLE_DIRECTION_DOWN.rawValue == 3)

        #expect(OMNI_DWINDLE_OP_ADD_WINDOW.rawValue == 0)
        #expect(OMNI_DWINDLE_OP_REMOVE_WINDOW.rawValue == 1)
        #expect(OMNI_DWINDLE_OP_SYNC_WINDOWS.rawValue == 2)
        #expect(OMNI_DWINDLE_OP_MOVE_FOCUS.rawValue == 3)
        #expect(OMNI_DWINDLE_OP_SWAP_WINDOWS.rawValue == 4)
        #expect(OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN.rawValue == 5)
        #expect(OMNI_DWINDLE_OP_TOGGLE_ORIENTATION.rawValue == 6)
        #expect(OMNI_DWINDLE_OP_RESIZE_SELECTED.rawValue == 7)
        #expect(OMNI_DWINDLE_OP_BALANCE_SIZES.rawValue == 8)
        #expect(OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO.rawValue == 9)
        #expect(OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT.rawValue == 10)
        #expect(OMNI_DWINDLE_OP_SWAP_SPLIT.rawValue == 11)
        #expect(OMNI_DWINDLE_OP_SET_PRESELECTION.rawValue == 12)
        #expect(OMNI_DWINDLE_OP_CLEAR_PRESELECTION.rawValue == 13)
        #expect(OMNI_DWINDLE_OP_VALIDATE_SELECTION.rawValue == 14)
    }

    @Test func abiTypesAreConstructible() {
        #expect(MemoryLayout<OmniDwindleSeedNode>.size > 0)
        #expect(MemoryLayout<OmniDwindleSeedState>.size > 0)
        #expect(MemoryLayout<OmniDwindleLayoutRequest>.size > 0)
        #expect(MemoryLayout<OmniDwindleWindowConstraint>.size > 0)
        #expect(MemoryLayout<OmniDwindleWindowFrame>.size > 0)
        #expect(MemoryLayout<OmniDwindleOpPayload>.size > 0)
        #expect(MemoryLayout<OmniDwindleOpRequest>.size > 0)
        #expect(MemoryLayout<OmniDwindleOpResult>.size > 0)
    }

    @Test func contextLifecycleIsAllocationSafe() {
        let context = omni_dwindle_layout_context_create()
        #expect(context != nil)
        omni_dwindle_layout_context_destroy(context)
        omni_dwindle_layout_context_destroy(nil)
    }

    @Test func seedStateRejectsInvalidArgsAndTopology() {
        var seed = defaultSeedState()
        let nilContextRC = withUnsafePointer(to: &seed) { seedPtr in
            omni_dwindle_ctx_seed_state(nil, nil, 0, seedPtr)
        }
        #expect(nilContextRC == abiErrInvalidArgs)

        withDwindleContext { context in
            let nilSeedRC = omni_dwindle_ctx_seed_state(context, nil, 0, nil)
            #expect(nilSeedRC == abiErrInvalidArgs)

            var seededRootState = defaultSeedState(rootNodeIndex: 0)
            let missingNodesRC = withUnsafePointer(to: &seededRootState) { seedPtr in
                omni_dwindle_ctx_seed_state(context, nil, 1, seedPtr)
            }
            #expect(missingNodesRC == abiErrInvalidArgs)

            var badIndexNode = makeLeafNode(nodeMarker: 1, windowMarker: 11)
            badIndexNode.parent_index = Int64(OMNI_DWINDLE_MAX_NODES) + 1
            let badIndexRC = seedState(
                context: context,
                nodes: [badIndexNode],
                seedState: defaultSeedState(rootNodeIndex: 0)
            )
            #expect(badIndexRC == abiErrOutOfRange)

            var badKindNode = makeLeafNode(nodeMarker: 1, windowMarker: 11)
            badKindNode.kind = 0xFF
            let badKindRC = seedState(
                context: context,
                nodes: [badKindNode],
                seedState: defaultSeedState(rootNodeIndex: 0)
            )
            #expect(badKindRC == abiErrInvalidArgs)

            var splitNode = makeLeafNode(nodeMarker: 1, windowMarker: 11)
            splitNode.kind = UInt8(truncatingIfNeeded: OMNI_DWINDLE_NODE_SPLIT.rawValue)
            splitNode.has_window_id = 0
            splitNode.window_id = makeUUID(0)
            splitNode.first_child_index = 1
            splitNode.second_child_index = 1

            var childNode = makeLeafNode(nodeMarker: 2, parentIndex: 0, windowMarker: 22)
            childNode.parent_index = 0

            let inconsistentSplitRC = seedState(
                context: context,
                nodes: [splitNode, childNode],
                seedState: defaultSeedState(rootNodeIndex: 0)
            )
            #expect(inconsistentSplitRC == abiErrInvalidArgs)

            let duplicateNodeIdRC = seedState(
                context: context,
                nodes: [
                    makeLeafNode(nodeMarker: 7, windowMarker: 31),
                    makeLeafNode(nodeMarker: 7, windowMarker: 32),
                ],
                seedState: defaultSeedState(rootNodeIndex: 0)
            )
            #expect(duplicateNodeIdRC == abiErrInvalidArgs)

            let duplicateWindowIdRC = seedState(
                context: context,
                nodes: [
                    makeLeafNode(nodeMarker: 7, windowMarker: 42),
                    makeLeafNode(nodeMarker: 8, windowMarker: 42),
                ],
                seedState: defaultSeedState(rootNodeIndex: 0)
            )
            #expect(duplicateWindowIdRC == abiErrInvalidArgs)
        }
    }

    @Test func seedStateAcceptsMinimalLeafTree() {
        withDwindleContext { context in
            let node = makeLeafNode(nodeMarker: 1, windowMarker: 99)
            let rc = seedState(
                context: context,
                nodes: [node],
                seedState: defaultSeedState(rootNodeIndex: 0, selectedNodeIndex: 0)
            )
            #expect(rc == abiOK)
        }
    }

    @Test func applyOpRejectsInvalidInputs() {
        withDwindleContext { context in
            var result = defaultOpResult()

            let nilContextRC = withUnsafeMutablePointer(to: &result) { resultPtr in
                omni_dwindle_ctx_apply_op(nil, nil, resultPtr, nil, 0)
            }
            #expect(nilContextRC == abiErrInvalidArgs)

            var invalidRequest = makeOpRequest(op: 0xFF)
            let invalidOpRC = withUnsafePointer(to: &invalidRequest) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(invalidOpRC == abiErrInvalidArgs)

            var badDirectionRequest = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_MOVE_FOCUS.rawValue)
            ) { payload in
                payload.move_focus = OmniDwindleMoveFocusPayload(direction: 0xFF)
            }
            let badDirectionRC = withUnsafePointer(to: &badDirectionRequest) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(badDirectionRC == abiErrInvalidArgs)

            var removePtrContract = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_VALIDATE_SELECTION.rawValue)
            )
            let badRemovedBufferRC = withUnsafePointer(to: &removePtrContract) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 1)
                }
            }
            #expect(badRemovedBufferRC == abiErrInvalidArgs)

            var badRuntime = defaultRuntimeSettings()
            badRuntime.smart_split = 2
            var invalidRuntimeRequest = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_VALIDATE_SELECTION.rawValue),
                runtimeSettings: badRuntime
            )
            let invalidRuntimeRC = withUnsafePointer(to: &invalidRuntimeRequest) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(invalidRuntimeRC == abiErrInvalidArgs)

            var invalidActiveFrameFlag = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_ADD_WINDOW.rawValue)
            ) { payload in
                payload.add_window = OmniDwindleAddWindowPayload(
                    window_id: makeUUID(99),
                    has_active_window_frame: 2,
                    active_window_frame: zeroDwindleRect()
                )
            }
            let invalidFrameFlagRC = withUnsafePointer(to: &invalidActiveFrameFlag) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(invalidFrameFlagRC == abiErrInvalidArgs)

            var invalidActiveFrame = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_ADD_WINDOW.rawValue)
            ) { payload in
                payload.add_window = OmniDwindleAddWindowPayload(
                    window_id: makeUUID(98),
                    has_active_window_frame: 1,
                    active_window_frame: OmniDwindleRect(x: 0, y: 0, width: .nan, height: 10)
                )
            }
            let invalidFrameRC = withUnsafePointer(to: &invalidActiveFrame) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(invalidFrameRC == abiErrInvalidArgs)
        }
    }

    @Test func applyOpReturnsDeterministicNoOpResultForValidInput() {
        withDwindleContext { context in
            var request = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN.rawValue)
            ) { payload in
                payload.toggle_fullscreen = OmniDwindleToggleFullscreenPayload(unused: 0)
            }
            var result = defaultOpResult()
            let rc = withUnsafePointer(to: &request) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(rc == abiOK)
            #expect(result.applied == 0)
            #expect(result.removed_window_count == 0)
        }
    }

    @Test func applyOpAddAndRemoveUpdateSelectionAndRemovedIds() {
        withDwindleContext { context in
            let addRequest = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_ADD_WINDOW.rawValue)
            ) { payload in
                payload.add_window = OmniDwindleAddWindowPayload(
                    window_id: makeUUID(11),
                    has_active_window_frame: 0,
                    active_window_frame: zeroDwindleRect()
                )
            }
            let addResult = applyOp(context: context, request: addRequest, removedCapacity: 4)
            #expect(addResult.rc == abiOK)
            #expect(addResult.result.applied == 1)
            #expect(addResult.result.has_selected_window_id == 1)
            #expect(addResult.result.selected_window_id.bytes.0 == 11)
            #expect(addResult.result.has_focused_window_id == 1)
            #expect(addResult.result.focused_window_id.bytes.0 == 11)
            #expect(addResult.result.removed_window_count == 0)

            let removeRequest = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_REMOVE_WINDOW.rawValue)
            ) { payload in
                payload.remove_window = OmniDwindleRemoveWindowPayload(window_id: makeUUID(11))
            }
            let removeResult = applyOp(context: context, request: removeRequest, removedCapacity: 4)
            #expect(removeResult.rc == abiOK)
            #expect(removeResult.result.applied == 1)
            #expect(removeResult.result.removed_window_count == 1)
            #expect(removeResult.removed[0].bytes.0 == 11)
            #expect(removeResult.result.has_selected_window_id == 0)
            #expect(removeResult.result.has_focused_window_id == 0)
            #expect(layoutFrameCount(context: context) == 0)
        }
    }

    @Test func applyOpRemoveHonorsCapacityWithoutMutation() {
        withDwindleContext { context in
            for marker in [UInt8(11), UInt8(22)] {
                let addRequest = makeOpRequest(
                    op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_ADD_WINDOW.rawValue)
                ) { payload in
                    payload.add_window = OmniDwindleAddWindowPayload(
                        window_id: makeUUID(marker),
                        has_active_window_frame: 0,
                        active_window_frame: zeroDwindleRect()
                    )
                }
                let addResult = applyOp(context: context, request: addRequest, removedCapacity: 0)
                #expect(addResult.rc == abiOK)
            }
            #expect(layoutFrameCount(context: context) == 2)

            var removeRequest = makeOpRequest(
                op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_REMOVE_WINDOW.rawValue)
            ) { payload in
                payload.remove_window = OmniDwindleRemoveWindowPayload(window_id: makeUUID(11))
            }
            var result = defaultOpResult()
            let noCapacityRC = withUnsafePointer(to: &removeRequest) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_dwindle_ctx_apply_op(context, requestPtr, resultPtr, nil, 0)
                }
            }
            #expect(noCapacityRC == abiErrOutOfRange)
            #expect(layoutFrameCount(context: context) == 2)
        }
    }

    @Test func applyOpSyncRemovesInCurrentStateOrder() {
        withDwindleContext { context in
            for marker in [UInt8(11), UInt8(22), UInt8(33)] {
                let addRequest = makeOpRequest(
                    op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_ADD_WINDOW.rawValue)
                ) { payload in
                    payload.add_window = OmniDwindleAddWindowPayload(
                        window_id: makeUUID(marker),
                        has_active_window_frame: 0,
                        active_window_frame: zeroDwindleRect()
                    )
                }
                let addResult = applyOp(context: context, request: addRequest, removedCapacity: 4)
                #expect(addResult.rc == abiOK)
            }
            #expect(layoutFrameCount(context: context) == 3)

            var rawResult = defaultOpResult()
            var removed = [OmniUuid128](repeating: makeUUID(0), count: 4)
            let syncWindowIds: [OmniUuid128] = [makeUUID(33), makeUUID(44)]
            let rc = syncWindowIds.withUnsafeBufferPointer { idBuf in
                var request = makeOpRequest(
                    op: UInt8(truncatingIfNeeded: OMNI_DWINDLE_OP_SYNC_WINDOWS.rawValue)
                ) { payload in
                    payload.sync_windows = OmniDwindleSyncWindowsPayload(
                        window_ids: idBuf.baseAddress,
                        window_count: idBuf.count
                    )
                }
                return withUnsafePointer(to: &request) { requestPtr in
                    withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                        removed.withUnsafeMutableBufferPointer { removedBuf in
                            omni_dwindle_ctx_apply_op(
                                context,
                                requestPtr,
                                resultPtr,
                                removedBuf.baseAddress,
                                removedBuf.count
                            )
                        }
                    }
                }
            }

            #expect(rc == abiOK)
            #expect(rawResult.removed_window_count == 2)
            #expect(removed[0].bytes.0 == 11)
            #expect(removed[1].bytes.0 == 22)
            #expect(rawResult.has_selected_window_id == 1)
            #expect(rawResult.selected_window_id.bytes.0 == 44)
            #expect(layoutFrameCount(context: context) == 2)
        }
    }

    @Test func calculateLayoutRejectsInvalidArgs() {
        withDwindleContext { context in
            var request = defaultLayoutRequest()

            let nullOutCountRC = withUnsafePointer(to: &request) { requestPtr in
                omni_dwindle_ctx_calculate_layout(context, requestPtr, nil, 0, nil, 0, nil)
            }
            #expect(nullOutCountRC == abiErrInvalidArgs)

            var frameCount: Int = 0
            let missingFrameBufferRC = withUnsafePointer(to: &request) { requestPtr in
                withUnsafeMutablePointer(to: &frameCount) { frameCountPtr in
                    omni_dwindle_ctx_calculate_layout(
                        context,
                        requestPtr,
                        nil,
                        0,
                        nil,
                        1,
                        frameCountPtr
                    )
                }
            }
            #expect(missingFrameBufferRC == abiErrInvalidArgs)

            let missingConstraintsRC = withUnsafePointer(to: &request) { requestPtr in
                withUnsafeMutablePointer(to: &frameCount) { frameCountPtr in
                    omni_dwindle_ctx_calculate_layout(
                        context,
                        requestPtr,
                        nil,
                        1,
                        nil,
                        0,
                        frameCountPtr
                    )
                }
            }
            #expect(missingConstraintsRC == abiErrInvalidArgs)
        }
    }

    @Test func calculateLayoutReturnsNoFramesForValidInput() {
        withDwindleContext { context in
            var request = defaultLayoutRequest()
            var outCount: Int = -1
            let rc = withUnsafePointer(to: &request) { requestPtr in
                withUnsafeMutablePointer(to: &outCount) { outCountPtr in
                    omni_dwindle_ctx_calculate_layout(
                        context,
                        requestPtr,
                        nil,
                        0,
                        nil,
                        0,
                        outCountPtr
                    )
                }
            }
            #expect(rc == abiOK)
            #expect(outCount == 0)
        }
    }

    @Test func calculateLayoutReturnsFrameForSeededSingleWindow() {
        withDwindleContext { context in
            let node = makeLeafNode(nodeMarker: 1, windowMarker: 77)
            let seedRC = seedState(
                context: context,
                nodes: [node],
                seedState: defaultSeedState(rootNodeIndex: 0, selectedNodeIndex: 0)
            )
            #expect(seedRC == abiOK)
            guard seedRC == abiOK else { return }

            var request = defaultLayoutRequest()
            var frames = [OmniDwindleWindowFrame](
                repeating: OmniDwindleWindowFrame(
                    window_id: makeUUID(0),
                    frame_x: 0,
                    frame_y: 0,
                    frame_width: 0,
                    frame_height: 0
                ),
                count: 4
            )
            var outCount: Int = 0

            let rc = withUnsafePointer(to: &request) { requestPtr in
                frames.withUnsafeMutableBufferPointer { frameBuf in
                    withUnsafeMutablePointer(to: &outCount) { countPtr in
                        omni_dwindle_ctx_calculate_layout(
                            context,
                            requestPtr,
                            nil,
                            0,
                            frameBuf.baseAddress,
                            frameBuf.count,
                            countPtr
                        )
                    }
                }
            }

            #expect(rc == abiOK)
            #expect(outCount == 1)
            guard outCount == 1 else { return }

            let frame = frames[0]
            #expect(frame.window_id.bytes.0 == 77)
            #expect(approxEqual(frame.frame_x, 240))
            #expect(approxEqual(frame.frame_y, 0))
            #expect(approxEqual(frame.frame_width, 1440))
            #expect(approxEqual(frame.frame_height, 1080))
        }
    }

    @Test func calculateLayoutReturnsOutOfRangeWhenFrameCapacityIsInsufficient() {
        withDwindleContext { context in
            let root = makeSplitNode(nodeMarker: 1, firstChildIndex: 1, secondChildIndex: 2)
            let left = makeLeafNode(nodeMarker: 2, parentIndex: 0, windowMarker: 11)
            let right = makeLeafNode(nodeMarker: 3, parentIndex: 0, windowMarker: 22)

            let seedRC = seedState(
                context: context,
                nodes: [root, left, right],
                seedState: defaultSeedState(rootNodeIndex: 0, selectedNodeIndex: 1)
            )
            #expect(seedRC == abiOK)
            guard seedRC == abiOK else { return }

            var request = defaultLayoutRequest()
            var frames = [OmniDwindleWindowFrame](
                repeating: OmniDwindleWindowFrame(
                    window_id: makeUUID(0),
                    frame_x: 0,
                    frame_y: 0,
                    frame_width: 0,
                    frame_height: 0
                ),
                count: 1
            )
            var outCount: Int = 0

            let rc = withUnsafePointer(to: &request) { requestPtr in
                frames.withUnsafeMutableBufferPointer { frameBuf in
                    withUnsafeMutablePointer(to: &outCount) { countPtr in
                        omni_dwindle_ctx_calculate_layout(
                            context,
                            requestPtr,
                            nil,
                            0,
                            frameBuf.baseAddress,
                            frameBuf.count,
                            countPtr
                        )
                    }
                }
            }

            #expect(rc == abiErrOutOfRange)
            #expect(outCount == 2)
        }
    }

    @Test func findNeighborRejectsInvalidArgs() {
        withDwindleContext { context in
            var hasNeighbor: UInt8 = 0
            var neighbor = makeUUID(0)

            let invalidDirectionRC = withUnsafeMutablePointer(to: &hasNeighbor) { hasNeighborPtr in
                withUnsafeMutablePointer(to: &neighbor) { neighborPtr in
                    omni_dwindle_ctx_find_neighbor(
                        context,
                        makeUUID(9),
                        0xFF,
                        8.0,
                        hasNeighborPtr,
                        neighborPtr
                    )
                }
            }
            #expect(invalidDirectionRC == abiErrInvalidArgs)

            let nilOutRC = withUnsafeMutablePointer(to: &neighbor) { neighborPtr in
                omni_dwindle_ctx_find_neighbor(
                    context,
                    makeUUID(9),
                    UInt8(truncatingIfNeeded: OMNI_DWINDLE_DIRECTION_LEFT.rawValue),
                    8.0,
                    nil,
                    neighborPtr
                )
            }
            #expect(nilOutRC == abiErrInvalidArgs)
        }
    }

    @Test func findNeighborReturnsResolvedNeighborAfterLayout() {
        withDwindleContext { context in
            let root = makeSplitNode(nodeMarker: 1, firstChildIndex: 1, secondChildIndex: 2)
            let left = makeLeafNode(nodeMarker: 2, parentIndex: 0, windowMarker: 51)
            let right = makeLeafNode(nodeMarker: 3, parentIndex: 0, windowMarker: 52)

            let seedRC = seedState(
                context: context,
                nodes: [root, left, right],
                seedState: defaultSeedState(rootNodeIndex: 0, selectedNodeIndex: 1)
            )
            #expect(seedRC == abiOK)
            guard seedRC == abiOK else { return }

            var request = defaultLayoutRequest()
            var frames = [OmniDwindleWindowFrame](
                repeating: OmniDwindleWindowFrame(
                    window_id: makeUUID(0),
                    frame_x: 0,
                    frame_y: 0,
                    frame_width: 0,
                    frame_height: 0
                ),
                count: 4
            )
            var outCount: Int = 0
            let layoutRC = withUnsafePointer(to: &request) { requestPtr in
                frames.withUnsafeMutableBufferPointer { frameBuf in
                    withUnsafeMutablePointer(to: &outCount) { countPtr in
                        omni_dwindle_ctx_calculate_layout(
                            context,
                            requestPtr,
                            nil,
                            0,
                            frameBuf.baseAddress,
                            frameBuf.count,
                            countPtr
                        )
                    }
                }
            }

            #expect(layoutRC == abiOK)
            #expect(outCount == 2)
            guard layoutRC == abiOK else { return }

            var hasNeighbor: UInt8 = 0
            var neighbor = makeUUID(0)
            let rc = withUnsafeMutablePointer(to: &hasNeighbor) { hasNeighborPtr in
                withUnsafeMutablePointer(to: &neighbor) { neighborPtr in
                    omni_dwindle_ctx_find_neighbor(
                        context,
                        left.window_id,
                        UInt8(truncatingIfNeeded: OMNI_DWINDLE_DIRECTION_RIGHT.rawValue),
                        8.0,
                        hasNeighborPtr,
                        neighborPtr
                    )
                }
            }

            #expect(rc == abiOK)
            #expect(hasNeighbor == 1)
            #expect(neighbor.bytes.0 == right.window_id.bytes.0)
        }
    }

    @Test func findNeighborReturnsNoNeighborForValidInput() {
        withDwindleContext { context in
            var hasNeighbor: UInt8 = 99
            var neighbor = makeUUID(123)
            let rc = withUnsafeMutablePointer(to: &hasNeighbor) { hasNeighborPtr in
                withUnsafeMutablePointer(to: &neighbor) { neighborPtr in
                    omni_dwindle_ctx_find_neighbor(
                        context,
                        makeUUID(9),
                        UInt8(truncatingIfNeeded: OMNI_DWINDLE_DIRECTION_LEFT.rawValue),
                        8.0,
                        hasNeighborPtr,
                        neighborPtr
                    )
                }
            }
            #expect(rc == abiOK)
            #expect(hasNeighbor == 0)
            #expect(neighbor.bytes.0 == 0)
        }
    }
}
