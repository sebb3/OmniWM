import AppKit
import CZigLayout
import Foundation

enum NiriLayoutZigKernel {
    struct InteractionIndex {
        let windowEntries: [InteractionSnapshot.WindowEntry]
        let windowIndexByNodeId: [NodeId: Int]
    }

    struct LayoutPassResult {
        let windows: [WindowResult]
        let columns: [ColumnResult]
    }

    final class LayoutContext {
        fileprivate let raw: OpaquePointer

        init?() {
            guard let raw = omni_niri_layout_context_create() else { return nil }
            self.raw = raw
        }

        deinit {
            omni_niri_layout_context_destroy(raw)
        }
    }

    struct WindowResult {
        let window: NiriWindow
        let baseFrame: CGRect
        let animatedFrame: CGRect
        let resolvedSpan: CGFloat
        let wasConstrained: Bool
        let hideSide: HideSide?
    }

    struct ColumnResult {
        let column: NiriContainer
        let frame: CGRect
        let hideSide: HideSide?
        let isVisible: Bool
    }

    struct ResizeHitResult {
        let window: NiriWindow
        let columnIndex: Int
        let edges: ResizeEdge
        let frame: CGRect
    }

    struct ResizeComputationInput {
        let edges: ResizeEdge
        let startLocation: CGPoint
        let currentLocation: CGPoint
        let originalColumnWidth: CGFloat
        let minColumnWidth: CGFloat
        let maxColumnWidth: CGFloat
        let originalWindowWeight: CGFloat
        let minWindowWeight: CGFloat
        let maxWindowWeight: CGFloat
        let pixelsPerWeight: CGFloat
        let originalViewOffset: CGFloat?
    }

    struct ResizeComputationResult {
        let changedWidth: Bool
        let newColumnWidth: CGFloat
        let changedWeight: Bool
        let newWindowWeight: CGFloat
        let adjustViewOffset: Bool
        let newViewOffset: CGFloat
    }

    struct InteractionSnapshot {
        struct WindowEntry {
            let window: NiriWindow
            let columnIndex: Int
            let frame: CGRect
        }

        struct ColumnDropzoneMeta {
            let minY: CGFloat
            let maxY: CGFloat
            let postInsertionCount: Int
        }

        let windowEntries: [WindowEntry]
        let inputs: [OmniNiriHitTestWindow]
        let windowIndexByNodeId: [NodeId: Int]
        let columnDropzoneMeta: [ColumnDropzoneMeta?]
    }

    struct MoveTargetResult {
        let window: NiriWindow
        let insertPosition: InsertPosition
    }

    struct DropzoneComputationInput {
        let targetFrame: CGRect
        let columnIndex: Int
        let columnMinY: CGFloat
        let columnMaxY: CGFloat
        let postInsertionCount: Int
        let gap: CGFloat
        let position: InsertPosition
    }

    private static func orientationCode(_ orientation: Monitor.Orientation) -> UInt8 {
        switch orientation {
        case .horizontal:
            0
        case .vertical:
            1
        }
    }

    private static func sizingModeCode(_ mode: SizingMode) -> UInt8 {
        switch mode {
        case .normal:
            0
        case .fullscreen:
            1
        }
    }

    private static func hideSideFromCode(_ code: UInt8) -> HideSide? {
        if code == 1 {
            return .left
        }
        if code == 2 {
            return .right
        }
        return nil
    }

    private static func resizeEdgeCode(_ edges: ResizeEdge) -> UInt8 {
        UInt8(edges.rawValue & 0xFF)
    }

    private static func resizeEdgeFromCode(_ code: UInt8) -> ResizeEdge {
        ResizeEdge(rawValue: UInt32(code))
    }

    private static func insertPositionCode(_ position: InsertPosition) -> UInt8 {
        let beforeCode: UInt8 = 0
        let afterCode: UInt8 = 1
        let swapCode: UInt8 = 2
        switch position {
        case .before:
            return beforeCode
        case .after:
            return afterCode
        case .swap:
            return swapCode
        }
    }

    private static func insertPositionFromCode(_ code: UInt8) -> InsertPosition? {
        let beforeCode: UInt8 = 0
        let afterCode: UInt8 = 1
        let swapCode: UInt8 = 2
        switch code {
        case beforeCode:
            return .before
        case afterCode:
            return .after
        case swapCode:
            return .swap
        default:
            return nil
        }
    }

    static func run(
        context: LayoutContext,
        columns: [NiriContainer],
        orientation: Monitor.Orientation,
        primaryGap: CGFloat,
        secondaryGap: CGFloat,
        workingFrame: CGRect,
        viewFrame: CGRect,
        fullscreenFrame: CGRect,
        viewStart: CGFloat,
        viewportSpan: CGFloat,
        workspaceOffset: CGFloat,
        scale: CGFloat,
        tabIndicatorWidth: CGFloat,
        time: TimeInterval
    ) -> LayoutPassResult {
        guard !columns.isEmpty else {
            return LayoutPassResult(windows: [], columns: [])
        }

        var columnInputs: [OmniNiriColumnInput] = []
        columnInputs.reserveCapacity(columns.count)

        var windowInputs: [OmniNiriWindowInput] = []
        var flatWindows: [NiriWindow] = []

        for column in columns {
            let start = windowInputs.count
            let windows = column.windowNodes
            flatWindows.append(contentsOf: windows)

            for window in windows {
                let weight: CGFloat
                let minConstraint: CGFloat
                let maxConstraint: CGFloat
                let hasMaxConstraint: Bool
                let hasFixedValue: Bool
                let fixedValue: CGFloat

                switch orientation {
                case .horizontal:
                    weight = max(0.1, window.heightWeight)
                    minConstraint = window.constraints.minSize.height
                    maxConstraint = window.constraints.maxSize.height
                    hasMaxConstraint = window.constraints.hasMaxHeight
                    switch window.height {
                    case let .fixed(h):
                        hasFixedValue = true
                        fixedValue = h
                    case .auto:
                        hasFixedValue = false
                        fixedValue = 0
                    }
                case .vertical:
                    weight = max(0.1, window.widthWeight)
                    minConstraint = window.constraints.minSize.width
                    maxConstraint = window.constraints.maxSize.width
                    hasMaxConstraint = window.constraints.hasMaxWidth
                    switch window.windowWidth {
                    case let .fixed(w):
                        hasFixedValue = true
                        fixedValue = w
                    case .auto:
                        hasFixedValue = false
                        fixedValue = 0
                    }
                }

                let renderOffset = window.renderOffset(at: time)
                windowInputs.append(
                    OmniNiriWindowInput(
                        weight: Double(weight),
                        min_constraint: Double(minConstraint),
                        max_constraint: Double(maxConstraint),
                        has_max_constraint: hasMaxConstraint ? 1 : 0,
                        is_constraint_fixed: window.constraints.isFixed ? 1 : 0,
                        has_fixed_value: hasFixedValue ? 1 : 0,
                        fixed_value: Double(fixedValue),
                        sizing_mode: sizingModeCode(window.sizingMode),
                        render_offset_x: Double(renderOffset.x),
                        render_offset_y: Double(renderOffset.y)
                    )
                )
            }

            let span: CGFloat = switch orientation {
            case .horizontal:
                column.cachedWidth
            case .vertical:
                column.cachedHeight
            }

            let columnRenderOffset = column.renderOffset(at: time)
            columnInputs.append(
                OmniNiriColumnInput(
                    span: Double(span),
                    render_offset_x: Double(columnRenderOffset.x),
                    render_offset_y: Double(columnRenderOffset.y),
                    is_tabbed: column.isTabbed ? 1 : 0,
                    tab_indicator_width: Double(column.isTabbed ? tabIndicatorWidth : 0),
                    window_start: start,
                    window_count: windows.count
                )
            )
        }

        var rawColumnOutputs = [OmniNiriColumnOutput](
            repeating: OmniNiriColumnOutput(
                frame_x: 0,
                frame_y: 0,
                frame_width: 0,
                frame_height: 0,
                hide_side: 0,
                is_visible: 0
            ),
            count: columnInputs.count
        )

        var rawOutputs = [OmniNiriWindowOutput](
            repeating: OmniNiriWindowOutput(
                frame_x: 0,
                frame_y: 0,
                frame_width: 0,
                frame_height: 0,
                animated_x: 0,
                animated_y: 0,
                animated_width: 0,
                animated_height: 0,
                resolved_span: 0,
                was_constrained: 0,
                hide_side: 0,
                column_index: 0
            ),
            count: windowInputs.count
        )

        let rc: Int32 = columnInputs.withUnsafeBufferPointer { colBuf in
            windowInputs.withUnsafeBufferPointer { winBuf in
                rawOutputs.withUnsafeMutableBufferPointer { winOutBuf in
                    rawColumnOutputs.withUnsafeMutableBufferPointer { colOutBuf in
                            omni_niri_layout_pass_v3(
                                context.raw,
                                colBuf.baseAddress,
                                colBuf.count,
                                winBuf.baseAddress,
                            winBuf.count,
                            Double(workingFrame.origin.x),
                            Double(workingFrame.origin.y),
                            Double(workingFrame.width),
                            Double(workingFrame.height),
                            Double(viewFrame.origin.x),
                            Double(viewFrame.origin.y),
                            Double(viewFrame.width),
                            Double(viewFrame.height),
                            Double(fullscreenFrame.origin.x),
                            Double(fullscreenFrame.origin.y),
                            Double(fullscreenFrame.width),
                            Double(fullscreenFrame.height),
                            Double(primaryGap),
                            Double(secondaryGap),
                            Double(viewStart),
                            Double(viewportSpan),
                            Double(workspaceOffset),
                            Double(scale),
                            orientationCode(orientation),
                            winOutBuf.baseAddress,
                            winOutBuf.count,
                            colOutBuf.baseAddress,
                            colOutBuf.count
                        )
                    }
                }
            }
        }

        precondition(
            rc == OMNI_OK,
            "omni_niri_layout_pass_v3 failed rc=\(rc) columns=\(columnInputs.count) windows=\(windowInputs.count)"
        )

        let windows = zip(flatWindows, rawOutputs).map { window, output in
            WindowResult(
                window: window,
                baseFrame: CGRect(
                    x: output.frame_x,
                    y: output.frame_y,
                    width: output.frame_width,
                    height: output.frame_height
                ),
                animatedFrame: CGRect(
                    x: output.animated_x,
                    y: output.animated_y,
                    width: output.animated_width,
                    height: output.animated_height
                ),
                resolvedSpan: CGFloat(output.resolved_span),
                wasConstrained: output.was_constrained != 0,
                hideSide: hideSideFromCode(output.hide_side)
            )
        }

        let columnsOut = zip(columns, rawColumnOutputs).map { column, output in
            ColumnResult(
                column: column,
                frame: CGRect(
                    x: output.frame_x,
                    y: output.frame_y,
                    width: output.frame_width,
                    height: output.frame_height
                ),
                hideSide: hideSideFromCode(output.hide_side),
                isVisible: output.is_visible != 0
            )
        }

        return LayoutPassResult(windows: windows, columns: columnsOut)
    }

    static func makeInteractionSnapshot(columns: [NiriContainer]) -> InteractionSnapshot {
        let estimatedWindowCount = columns.reduce(0) { partial, column in
            partial + column.windowNodes.count
        }

        var entries: [InteractionSnapshot.WindowEntry] = []
        entries.reserveCapacity(estimatedWindowCount)

        var inputs: [OmniNiriHitTestWindow] = []
        inputs.reserveCapacity(estimatedWindowCount)

        var indexByNodeId: [NodeId: Int] = [:]
        indexByNodeId.reserveCapacity(estimatedWindowCount)

        var columnMeta = Array<InteractionSnapshot.ColumnDropzoneMeta?>(
            repeating: nil,
            count: columns.count
        )

        for (columnIndex, column) in columns.enumerated() {
            let windows = column.windowNodes
            if let firstFrame = windows.first?.frame,
               let lastFrame = windows.last?.frame
            {
                columnMeta[columnIndex] = InteractionSnapshot.ColumnDropzoneMeta(
                    minY: firstFrame.minY,
                    maxY: lastFrame.maxY,
                    postInsertionCount: windows.count + 1
                )
            }

            for window in windows {
                guard let frame = window.frame else { continue }
                let index = entries.count
                entries.append(
                    InteractionSnapshot.WindowEntry(
                        window: window,
                        columnIndex: columnIndex,
                        frame: frame
                    )
                )
                indexByNodeId[window.id] = index
                inputs.append(
                    OmniNiriHitTestWindow(
                        window_index: index,
                        column_index: columnIndex,
                        frame_x: Double(frame.origin.x),
                        frame_y: Double(frame.origin.y),
                        frame_width: Double(frame.width),
                        frame_height: Double(frame.height),
                        is_fullscreen: window.isFullscreen ? 1 : 0
                    )
                )
            }
        }

        return InteractionSnapshot(
            windowEntries: entries,
            inputs: inputs,
            windowIndexByNodeId: indexByNodeId,
            columnDropzoneMeta: columnMeta
        )
    }

    static func makeInteractionIndex(columns: [NiriContainer]) -> InteractionIndex {
        let estimatedWindowCount = columns.reduce(0) { partial, column in
            partial + column.windowNodes.count
        }

        var entries: [InteractionSnapshot.WindowEntry] = []
        entries.reserveCapacity(estimatedWindowCount)

        var indexByNodeId: [NodeId: Int] = [:]
        indexByNodeId.reserveCapacity(estimatedWindowCount)

        for (columnIndex, column) in columns.enumerated() {
            for window in column.windowNodes {
                guard let frame = window.frame else { continue }
                let index = entries.count
                entries.append(
                    InteractionSnapshot.WindowEntry(
                        window: window,
                        columnIndex: columnIndex,
                        frame: frame
                    )
                )
                indexByNodeId[window.id] = index
            }
        }

        return InteractionIndex(
            windowEntries: entries,
            windowIndexByNodeId: indexByNodeId
        )
    }

    @discardableResult
    static func seedInteractionContext(
        context: LayoutContext,
        snapshot: InteractionSnapshot
    ) -> Bool {
        var rawColumnMeta = [OmniNiriColumnDropzoneMeta](
            repeating: OmniNiriColumnDropzoneMeta(
                is_valid: 0,
                min_y: 0,
                max_y: 0,
                post_insertion_count: 0
            ),
            count: snapshot.columnDropzoneMeta.count
        )

        for (index, meta) in snapshot.columnDropzoneMeta.enumerated() {
            guard let meta else { continue }
            rawColumnMeta[index] = OmniNiriColumnDropzoneMeta(
                is_valid: 1,
                min_y: Double(meta.minY),
                max_y: Double(meta.maxY),
                post_insertion_count: meta.postInsertionCount
            )
        }

        let rc = snapshot.inputs.withUnsafeBufferPointer { windowBuf in
            rawColumnMeta.withUnsafeBufferPointer { columnBuf in
                omni_niri_layout_context_set_interaction(
                    context.raw,
                    windowBuf.baseAddress,
                    windowBuf.count,
                    columnBuf.baseAddress,
                    columnBuf.count
                )
            }
        }

        return rc == OMNI_OK
    }

    static func hitTestTiled(
        context: LayoutContext,
        interaction: InteractionIndex,
        point: CGPoint
    ) -> NiriWindow? {
        guard !interaction.windowEntries.isEmpty else { return nil }

        var outIndex: Int64 = -1
        let rc = withUnsafeMutablePointer(to: &outIndex) { outPtr in
            omni_niri_ctx_hit_test_tiled(
                context.raw,
                Double(point.x),
                Double(point.y),
                outPtr
            )
        }

        precondition(rc == OMNI_OK, "omni_niri_ctx_hit_test_tiled failed rc=\(rc)")
        guard outIndex >= 0, outIndex < Int64(interaction.windowEntries.count) else { return nil }
        return interaction.windowEntries[Int(outIndex)].window
    }

    static func hitTestResize(
        context: LayoutContext,
        interaction: InteractionIndex,
        point: CGPoint,
        threshold: CGFloat
    ) -> ResizeHitResult? {
        guard !interaction.windowEntries.isEmpty else { return nil }

        var out = OmniNiriResizeHitResult(window_index: -1, edges: 0)
        let rc = withUnsafeMutablePointer(to: &out) { outPtr in
            omni_niri_ctx_hit_test_resize(
                context.raw,
                Double(point.x),
                Double(point.y),
                Double(threshold),
                outPtr
            )
        }

        precondition(rc == OMNI_OK, "omni_niri_ctx_hit_test_resize failed rc=\(rc)")
        guard out.window_index >= 0, out.window_index < Int64(interaction.windowEntries.count) else { return nil }

        let index = Int(out.window_index)
        let entry = interaction.windowEntries[index]
        let edges = resizeEdgeFromCode(out.edges)
        guard !edges.isEmpty else { return nil }

        return ResizeHitResult(
            window: entry.window,
            columnIndex: entry.columnIndex,
            edges: edges,
            frame: entry.frame
        )
    }

    static func hitTestMoveTarget(
        context: LayoutContext,
        interaction: InteractionIndex,
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool
    ) -> MoveTargetResult? {
        guard !interaction.windowEntries.isEmpty else { return nil }

        let excludingIndex = interaction.windowIndexByNodeId[excludingWindowId].map(Int64.init) ?? -1
        var out = OmniNiriMoveTargetResult(
            window_index: -1,
            insert_position: insertPositionCode(.swap)
        )

        let rc = withUnsafeMutablePointer(to: &out) { outPtr in
            omni_niri_ctx_hit_test_move_target(
                context.raw,
                Double(point.x),
                Double(point.y),
                excludingIndex,
                isInsertMode ? 1 : 0,
                outPtr
            )
        }

        precondition(rc == OMNI_OK, "omni_niri_ctx_hit_test_move_target failed rc=\(rc)")
        guard out.window_index >= 0, out.window_index < Int64(interaction.windowEntries.count) else { return nil }
        guard let position = insertPositionFromCode(out.insert_position) else { return nil }

        return MoveTargetResult(
            window: interaction.windowEntries[Int(out.window_index)].window,
            insertPosition: position
        )
    }

    static func insertionDropzoneFrame(
        context: LayoutContext,
        interaction: InteractionIndex,
        targetWindowId: NodeId,
        position: InsertPosition,
        gap: CGFloat
    ) -> CGRect? {
        guard let windowIndex = interaction.windowIndexByNodeId[targetWindowId] else { return nil }

        var rawOutput = OmniNiriDropzoneResult(
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0,
            is_valid: 0
        )
        let rc = withUnsafeMutablePointer(to: &rawOutput) { outputPtr in
            omni_niri_ctx_insertion_dropzone(
                context.raw,
                Int64(windowIndex),
                Double(gap),
                insertPositionCode(position),
                outputPtr
            )
        }
        precondition(rc == OMNI_OK, "omni_niri_ctx_insertion_dropzone failed rc=\(rc)")
        guard rawOutput.is_valid != 0 else { return nil }
        return CGRect(
            x: rawOutput.frame_x,
            y: rawOutput.frame_y,
            width: rawOutput.frame_width,
            height: rawOutput.frame_height
        )
    }

    static func hitTestTiled(
        snapshot: InteractionSnapshot,
        point: CGPoint
    ) -> NiriWindow? {
        guard !snapshot.inputs.isEmpty else { return nil }

        var outIndex: Int64 = -1
        let rc = snapshot.inputs.withUnsafeBufferPointer { buf in
            withUnsafeMutablePointer(to: &outIndex) { outPtr in
                omni_niri_hit_test_tiled(
                    buf.baseAddress,
                    buf.count,
                    Double(point.x),
                    Double(point.y),
                    outPtr
                )
            }
        }

        precondition(rc == OMNI_OK, "omni_niri_hit_test_tiled failed rc=\(rc)")
        guard outIndex >= 0, outIndex < Int64(snapshot.windowEntries.count) else { return nil }
        return snapshot.windowEntries[Int(outIndex)].window
    }

    static func hitTestResize(
        snapshot: InteractionSnapshot,
        point: CGPoint,
        threshold: CGFloat
    ) -> ResizeHitResult? {
        guard !snapshot.inputs.isEmpty else { return nil }

        var out = OmniNiriResizeHitResult(window_index: -1, edges: 0)
        let rc = snapshot.inputs.withUnsafeBufferPointer { buf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_niri_hit_test_resize(
                    buf.baseAddress,
                    buf.count,
                    Double(point.x),
                    Double(point.y),
                    Double(threshold),
                    outPtr
                )
            }
        }

        precondition(rc == OMNI_OK, "omni_niri_hit_test_resize failed rc=\(rc)")
        guard out.window_index >= 0, out.window_index < Int64(snapshot.windowEntries.count) else { return nil }

        let index = Int(out.window_index)
        let entry = snapshot.windowEntries[index]
        let edges = resizeEdgeFromCode(out.edges)
        guard !edges.isEmpty else { return nil }

        return ResizeHitResult(
            window: entry.window,
            columnIndex: entry.columnIndex,
            edges: edges,
            frame: entry.frame
        )
    }

    static func hitTestMoveTarget(
        snapshot: InteractionSnapshot,
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool
    ) -> MoveTargetResult? {
        guard !snapshot.inputs.isEmpty else { return nil }

        let excludingIndex = snapshot.windowIndexByNodeId[excludingWindowId].map(Int64.init) ?? -1
        var out = OmniNiriMoveTargetResult(
            window_index: -1,
            insert_position: insertPositionCode(.swap)
        )

        let rc = snapshot.inputs.withUnsafeBufferPointer { buf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_niri_hit_test_move_target(
                    buf.baseAddress,
                    buf.count,
                    Double(point.x),
                    Double(point.y),
                    excludingIndex,
                    isInsertMode ? 1 : 0,
                    outPtr
                )
            }
        }

        precondition(rc == OMNI_OK, "omni_niri_hit_test_move_target failed rc=\(rc)")
        guard out.window_index >= 0, out.window_index < Int64(snapshot.windowEntries.count) else { return nil }
        guard let position = insertPositionFromCode(out.insert_position) else { return nil }

        return MoveTargetResult(
            window: snapshot.windowEntries[Int(out.window_index)].window,
            insertPosition: position
        )
    }

    static func computeInsertionDropzone(_ input: DropzoneComputationInput) -> CGRect? {
        var rawInput = OmniNiriDropzoneInput(
            target_frame_x: Double(input.targetFrame.origin.x),
            target_frame_y: Double(input.targetFrame.origin.y),
            target_frame_width: Double(input.targetFrame.width),
            target_frame_height: Double(input.targetFrame.height),
            column_min_y: Double(input.columnMinY),
            column_max_y: Double(input.columnMaxY),
            gap: Double(input.gap),
            insert_position: insertPositionCode(input.position),
            post_insertion_count: input.postInsertionCount
        )
        var rawOutput = OmniNiriDropzoneResult(
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0,
            is_valid: 0
        )

        let rc = withUnsafePointer(to: &rawInput) { inputPtr in
            withUnsafeMutablePointer(to: &rawOutput) { outputPtr in
                omni_niri_insertion_dropzone(inputPtr, outputPtr)
            }
        }

        precondition(rc == OMNI_OK, "omni_niri_insertion_dropzone failed rc=\(rc)")
        guard rawOutput.is_valid != 0 else { return nil }
        return CGRect(
            x: rawOutput.frame_x,
            y: rawOutput.frame_y,
            width: rawOutput.frame_width,
            height: rawOutput.frame_height
        )
    }

    static func computeResize(_ input: ResizeComputationInput) -> ResizeComputationResult {
        var rawInput = OmniNiriResizeInput(
            edges: resizeEdgeCode(input.edges),
            start_x: Double(input.startLocation.x),
            start_y: Double(input.startLocation.y),
            current_x: Double(input.currentLocation.x),
            current_y: Double(input.currentLocation.y),
            original_column_width: Double(input.originalColumnWidth),
            min_column_width: Double(input.minColumnWidth),
            max_column_width: Double(input.maxColumnWidth),
            original_window_weight: Double(input.originalWindowWeight),
            min_window_weight: Double(input.minWindowWeight),
            max_window_weight: Double(input.maxWindowWeight),
            pixels_per_weight: Double(input.pixelsPerWeight),
            has_original_view_offset: input.originalViewOffset == nil ? 0 : 1,
            original_view_offset: Double(input.originalViewOffset ?? 0)
        )
        var rawOutput = OmniNiriResizeResult(
            changed_width: 0,
            new_column_width: 0,
            changed_weight: 0,
            new_window_weight: 0,
            adjust_view_offset: 0,
            new_view_offset: 0
        )

        let rc = withUnsafePointer(to: &rawInput) { inputPtr in
            withUnsafeMutablePointer(to: &rawOutput) { outputPtr in
                omni_niri_resize_compute(inputPtr, outputPtr)
            }
        }
        precondition(rc == OMNI_OK, "omni_niri_resize_compute failed rc=\(rc)")

        return ResizeComputationResult(
            changedWidth: rawOutput.changed_width != 0,
            newColumnWidth: CGFloat(rawOutput.new_column_width),
            changedWeight: rawOutput.changed_weight != 0,
            newWindowWeight: CGFloat(rawOutput.new_window_weight),
            adjustViewOffset: rawOutput.adjust_view_offset != 0,
            newViewOffset: CGFloat(rawOutput.new_view_offset)
        )
    }

}
