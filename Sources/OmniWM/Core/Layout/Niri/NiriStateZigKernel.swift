import CZigLayout
import Foundation

enum NiriStateZigKernel {
    struct Snapshot {
        struct ColumnEntry {
            let column: NiriContainer
            let columnIndex: Int
            let windowStart: Int
            let windowCount: Int
        }

        struct WindowEntry {
            let window: NiriWindow
            let column: NiriContainer
            let columnIndex: Int
            let rowIndex: Int
        }

        var columns: [OmniNiriStateColumnInput]
        var windows: [OmniNiriStateWindowInput]
        var columnEntries: [ColumnEntry]
        var windowEntries: [WindowEntry]
        var windowIndexByNodeId: [NodeId: Int]
        var columnIndexByNodeId: [NodeId: Int]
    }

    struct ValidationOutcome {
        let rc: Int32
        let result: OmniNiriStateValidationResult

        var isValid: Bool {
            rc == OMNI_OK && result.first_error_code == OMNI_OK
        }
    }

    struct SelectionContext {
        let selectedWindowIndex: Int
        let selectedColumnIndex: Int
        let selectedRowIndex: Int
    }

    enum NavigationOp {
        case moveByColumns
        case moveVertical
        case focusTarget
        case focusDownOrLeft
        case focusUpOrRight
        case focusColumnFirst
        case focusColumnLast
        case focusColumnIndex
        case focusWindowIndex
        case focusWindowTop
        case focusWindowBottom
    }

    enum MutationOp: UInt8 {
        case moveWindowVertical = 0
        case swapWindowVertical = 1
        case moveWindowHorizontal = 2
        case swapWindowHorizontal = 3
        case swapWindowsByMove = 4
        case insertWindowByMove = 5
        case moveWindowToColumn = 6
        case createColumnAndMove = 7
        case insertWindowInNewColumn = 8
        case moveColumn = 9
        case consumeWindow = 10
        case expelWindow = 11
        case cleanupEmptyColumn = 12
        case normalizeColumnSizes = 13
        case normalizeWindowSizes = 14
        case balanceSizes = 15
        case addWindow = 16
        case removeWindow = 17
        case validateSelection = 18
        case fallbackSelectionOnRemoval = 19
    }

    enum MutationNodeKind: UInt8 {
        case none = 0
        case window = 1
        case column = 2
    }

    enum MutationEditKind: UInt8 {
        case setActiveTile = 0
        case swapWindows = 1
        case moveWindowToColumnIndex = 2
        case swapColumnWidthState = 3
        case swapWindowSizeHeight = 4
        case resetWindowSizeHeight = 5
        case removeColumnIfEmpty = 6
        case refreshTabbedVisibility = 7
        case delegateMoveColumn = 8
        case createColumnAdjacentAndMoveWindow = 9
        case insertNewColumnAtIndexAndMoveWindow = 10
        case swapColumns = 11
        case normalizeColumnsByFactor = 12
        case normalizeColumnWindowsByFactor = 13
        case balanceColumns = 14
        case insertIncomingWindowIntoColumn = 15
        case insertIncomingWindowInNewColumn = 16
        case removeWindowByIndex = 17
        case resetAllColumnCachedWidths = 18
    }

    struct MutationNodeTarget {
        let kind: MutationNodeKind
        let index: Int
    }

    struct NavigationRequest {
        let op: NavigationOp
        let direction: Direction?
        let orientation: Monitor.Orientation
        let infiniteLoop: Bool
        let selectedWindowIndex: Int
        let selectedColumnIndex: Int
        let selectedRowIndex: Int
        let step: Int
        let targetRowIndex: Int
        let targetColumnIndex: Int
        let targetWindowIndex: Int

        init(
            op: NavigationOp,
            selection: SelectionContext?,
            direction: Direction? = nil,
            orientation: Monitor.Orientation = .horizontal,
            infiniteLoop: Bool = false,
            step: Int = 0,
            targetRowIndex: Int = -1,
            targetColumnIndex: Int = -1,
            targetWindowIndex: Int = -1
        ) {
            self.op = op
            self.direction = direction
            self.orientation = orientation
            self.infiniteLoop = infiniteLoop
            selectedWindowIndex = selection?.selectedWindowIndex ?? -1
            selectedColumnIndex = selection?.selectedColumnIndex ?? -1
            selectedRowIndex = selection?.selectedRowIndex ?? -1
            self.step = step
            self.targetRowIndex = targetRowIndex
            self.targetColumnIndex = targetColumnIndex
            self.targetWindowIndex = targetWindowIndex
        }
    }

    struct MutationRequest {
        let op: MutationOp
        let sourceWindowIndex: Int
        let targetWindowIndex: Int
        let direction: Direction?
        let infiniteLoop: Bool
        let insertPosition: InsertPosition?
        let maxWindowsPerColumn: Int
        let sourceColumnIndex: Int
        let targetColumnIndex: Int
        let insertColumnIndex: Int
        let maxVisibleColumns: Int
        let selectedNodeKind: MutationNodeKind
        let selectedNodeIndex: Int
        let focusedWindowIndex: Int

        init(
            op: MutationOp,
            sourceWindowIndex: Int = -1,
            targetWindowIndex: Int = -1,
            direction: Direction? = nil,
            infiniteLoop: Bool = false,
            insertPosition: InsertPosition? = nil,
            maxWindowsPerColumn: Int = 1,
            sourceColumnIndex: Int = -1,
            targetColumnIndex: Int = -1,
            insertColumnIndex: Int = -1,
            maxVisibleColumns: Int = -1,
            selectedNodeKind: MutationNodeKind = .none,
            selectedNodeIndex: Int = -1,
            focusedWindowIndex: Int = -1
        ) {
            self.op = op
            self.sourceWindowIndex = sourceWindowIndex
            self.targetWindowIndex = targetWindowIndex
            self.direction = direction
            self.infiniteLoop = infiniteLoop
            self.insertPosition = insertPosition
            self.maxWindowsPerColumn = maxWindowsPerColumn
            self.sourceColumnIndex = sourceColumnIndex
            self.targetColumnIndex = targetColumnIndex
            self.insertColumnIndex = insertColumnIndex
            self.maxVisibleColumns = maxVisibleColumns
            self.selectedNodeKind = selectedNodeKind
            self.selectedNodeIndex = selectedNodeIndex
            self.focusedWindowIndex = focusedWindowIndex
        }
    }

    struct NavigationOutcome {
        let rc: Int32
        let result: OmniNiriNavigationResult
        let targetWindowIndex: Int?

        var hasTarget: Bool {
            rc == OMNI_OK && targetWindowIndex != nil
        }
    }

    struct MutationEdit {
        let kind: MutationEditKind
        let subjectIndex: Int
        let relatedIndex: Int
        let valueA: Int
        let valueB: Int
        let scalarA: Double
        let scalarB: Double

        init(
            kind: MutationEditKind,
            subjectIndex: Int,
            relatedIndex: Int,
            valueA: Int,
            valueB: Int,
            scalarA: Double = 0,
            scalarB: Double = 0
        ) {
            self.kind = kind
            self.subjectIndex = subjectIndex
            self.relatedIndex = relatedIndex
            self.valueA = valueA
            self.valueB = valueB
            self.scalarA = scalarA
            self.scalarB = scalarB
        }
    }

    struct MutationOutcome {
        let rc: Int32
        let applied: Bool
        let targetWindowIndex: Int?
        let targetNode: MutationNodeTarget?
        let edits: [MutationEdit]

        init(
            rc: Int32,
            applied: Bool,
            targetWindowIndex: Int?,
            targetNode: MutationNodeTarget? = nil,
            edits: [MutationEdit]
        ) {
            self.rc = rc
            self.applied = applied
            self.targetWindowIndex = targetWindowIndex
            self.targetNode = targetNode
            self.edits = edits
        }

        var hasTarget: Bool {
            rc == OMNI_OK && targetWindowIndex != nil
        }

        var hasTargetNode: Bool {
            rc == OMNI_OK && targetNode != nil
        }
    }

    private static func omniUUID(from nodeId: NodeId) -> OmniUuid128 {
        omniUUID(from: nodeId.uuid)
    }

    private static func omniUUID(from uuid: UUID) -> OmniUuid128 {
        var rawUUID = uuid.uuid
        var encoded = OmniUuid128()
        withUnsafeBytes(of: &rawUUID) { src in
            withUnsafeMutableBytes(of: &encoded) { dst in
                dst.copyBytes(from: src)
            }
        }
        return encoded
    }

    private static func navigationOpCode(_ op: NavigationOp) -> UInt8 {
        switch op {
        case .moveByColumns:
            return 0
        case .moveVertical:
            return 1
        case .focusTarget:
            return 2
        case .focusDownOrLeft:
            return 3
        case .focusUpOrRight:
            return 4
        case .focusColumnFirst:
            return 5
        case .focusColumnLast:
            return 6
        case .focusColumnIndex:
            return 7
        case .focusWindowIndex:
            return 8
        case .focusWindowTop:
            return 9
        case .focusWindowBottom:
            return 10
        }
    }

    private static func mutationNodeKindCode(_ kind: MutationNodeKind) -> UInt8 {
        switch kind {
        case .none:
            return 0
        case .window:
            return 1
        case .column:
            return 2
        }
    }

    private static func navigationDirectionCode(_ direction: Direction?) -> UInt8 {
        switch direction {
        case .left:
            return 0
        case .right:
            return 1
        case .up:
            return 2
        case .down:
            return 3
        case nil:
            return 0
        }
    }

    private static func mutationDirectionCode(_ direction: Direction?) -> UInt8 {
        switch direction {
        case .left:
            return 0
        case .right:
            return 1
        case .up:
            return 2
        case .down:
            return 3
        case nil:
            // Direction-required mutation ops must reject unspecified direction.
            return 0xFF
        }
    }

    private static func insertPositionCode(_ position: InsertPosition?) -> UInt8 {
        switch position {
        case .before:
            return 0
        case .after:
            return 1
        case .swap:
            return 2
        case nil:
            return 0
        }
    }

    private static func orientationCode(_ orientation: Monitor.Orientation) -> UInt8 {
        switch orientation {
        case .horizontal:
            return 0
        case .vertical:
            return 1
        }
    }

    static func makeSnapshot(columns: [NiriContainer]) -> Snapshot {
        let estimatedWindowCount = columns.reduce(0) { partial, column in
            partial + column.windowNodes.count
        }

        var columnInputs: [OmniNiriStateColumnInput] = []
        columnInputs.reserveCapacity(columns.count)

        var windowInputs: [OmniNiriStateWindowInput] = []
        windowInputs.reserveCapacity(estimatedWindowCount)

        var columnEntries: [Snapshot.ColumnEntry] = []
        columnEntries.reserveCapacity(columns.count)

        var windowEntries: [Snapshot.WindowEntry] = []
        windowEntries.reserveCapacity(estimatedWindowCount)

        var windowIndexByNodeId: [NodeId: Int] = [:]
        windowIndexByNodeId.reserveCapacity(estimatedWindowCount)

        var columnIndexByNodeId: [NodeId: Int] = [:]
        columnIndexByNodeId.reserveCapacity(columns.count + estimatedWindowCount)

        for (columnIndex, column) in columns.enumerated() {
            let start = windowInputs.count
            let windows = column.windowNodes
            let columnId = omniUUID(from: column.id)

            columnEntries.append(
                Snapshot.ColumnEntry(
                    column: column,
                    columnIndex: columnIndex,
                    windowStart: start,
                    windowCount: windows.count
                )
            )
            columnIndexByNodeId[column.id] = columnIndex

            for (rowIndex, window) in windows.enumerated() {
                let windowIndex = windowInputs.count
                windowEntries.append(
                    Snapshot.WindowEntry(
                        window: window,
                        column: column,
                        columnIndex: columnIndex,
                        rowIndex: rowIndex
                    )
                )
                windowIndexByNodeId[window.id] = windowIndex
                columnIndexByNodeId[window.id] = columnIndex

                windowInputs.append(
                    OmniNiriStateWindowInput(
                        window_id: omniUUID(from: window.id),
                        column_id: columnId,
                        column_index: columnIndex,
                        size_value: Double(window.size)
                    )
                )
            }

            columnInputs.append(
                OmniNiriStateColumnInput(
                    column_id: columnId,
                    window_start: start,
                    window_count: windows.count,
                    active_tile_idx: max(0, column.activeTileIdx),
                    is_tabbed: column.isTabbed ? 1 : 0,
                    size_value: Double(column.size)
                )
            )
        }

        return Snapshot(
            columns: columnInputs,
            windows: windowInputs,
            columnEntries: columnEntries,
            windowEntries: windowEntries,
            windowIndexByNodeId: windowIndexByNodeId,
            columnIndexByNodeId: columnIndexByNodeId
        )
    }

    static func makeSelectionContext(node: NiriNode, snapshot: Snapshot) -> SelectionContext? {
        if let windowIndex = snapshot.windowIndexByNodeId[node.id],
           snapshot.windowEntries.indices.contains(windowIndex)
        {
            let entry = snapshot.windowEntries[windowIndex]
            return SelectionContext(
                selectedWindowIndex: windowIndex,
                selectedColumnIndex: entry.columnIndex,
                selectedRowIndex: entry.rowIndex
            )
        }

        guard let columnIndex = snapshot.columnIndexByNodeId[node.id],
              snapshot.columnEntries.indices.contains(columnIndex)
        else {
            return nil
        }

        let columnEntry = snapshot.columnEntries[columnIndex]
        guard columnEntry.windowCount > 0 else { return nil }

        // Match Swift fallback in updateActiveTileIdx(for:in:) when node is not a window.
        return SelectionContext(
            selectedWindowIndex: columnEntry.windowStart,
            selectedColumnIndex: columnIndex,
            selectedRowIndex: 0
        )
    }

    static func mutationNodeTarget(
        for nodeId: NodeId?,
        snapshot: Snapshot
    ) -> MutationNodeTarget {
        guard let nodeId else {
            return MutationNodeTarget(kind: .none, index: -1)
        }

        if let windowIndex = snapshot.windowIndexByNodeId[nodeId],
           snapshot.windowEntries.indices.contains(windowIndex)
        {
            return MutationNodeTarget(kind: .window, index: windowIndex)
        }

        if let columnIndex = snapshot.columnIndexByNodeId[nodeId],
           snapshot.columnEntries.indices.contains(columnIndex)
        {
            return MutationNodeTarget(kind: .column, index: columnIndex)
        }

        return MutationNodeTarget(kind: .none, index: -1)
    }

    static func nodeId(
        from target: MutationNodeTarget?,
        snapshot: Snapshot
    ) -> NodeId? {
        guard let target else { return nil }
        switch target.kind {
        case .window:
            guard snapshot.windowEntries.indices.contains(target.index) else { return nil }
            return snapshot.windowEntries[target.index].window.id
        case .column:
            guard snapshot.columnEntries.indices.contains(target.index) else { return nil }
            return snapshot.columnEntries[target.index].column.id
        case .none:
            return nil
        }
    }

    static func validate(snapshot: Snapshot) -> ValidationOutcome {
        var rawResult = OmniNiriStateValidationResult(
            column_count: 0,
            window_count: 0,
            first_invalid_column_index: -1,
            first_invalid_window_index: -1,
            first_error_code: Int32(OMNI_OK)
        )

        let rc: Int32 = snapshot.columns.withUnsafeBufferPointer { columnBuf in
            snapshot.windows.withUnsafeBufferPointer { windowBuf in
                withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                    omni_niri_validate_state_snapshot(
                        columnBuf.baseAddress,
                        columnBuf.count,
                        windowBuf.baseAddress,
                        windowBuf.count,
                        resultPtr
                    )
                }
            }
        }

        return ValidationOutcome(rc: rc, result: rawResult)
    }

    static func resolveNavigation(
        snapshot: Snapshot,
        request: NavigationRequest
    ) -> NavigationOutcome {
        var rawResult = OmniNiriNavigationResult(
            has_target: 0,
            target_window_index: -1,
            update_source_active_tile: 0,
            source_column_index: -1,
            source_active_tile_idx: -1,
            update_target_active_tile: 0,
            target_column_index: -1,
            target_active_tile_idx: -1,
            refresh_tabbed_visibility_source: 0,
            refresh_tabbed_visibility_target: 0
        )

        let rawRequest = OmniNiriNavigationRequest(
            op: navigationOpCode(request.op),
            direction: navigationDirectionCode(request.direction),
            orientation: orientationCode(request.orientation),
            infinite_loop: request.infiniteLoop ? 1 : 0,
            selected_window_index: Int64(request.selectedWindowIndex),
            selected_column_index: Int64(request.selectedColumnIndex),
            selected_row_index: Int64(request.selectedRowIndex),
            step: Int64(request.step),
            target_row_index: Int64(request.targetRowIndex),
            target_column_index: Int64(request.targetColumnIndex),
            target_window_index: Int64(request.targetWindowIndex)
        )

        let rc: Int32 = snapshot.columns.withUnsafeBufferPointer { columnBuf in
            snapshot.windows.withUnsafeBufferPointer { windowBuf in
                var mutableRequest = rawRequest
                return withUnsafePointer(to: &mutableRequest) { requestPtr in
                    withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                        omni_niri_navigation_resolve(
                            columnBuf.baseAddress,
                            columnBuf.count,
                            windowBuf.baseAddress,
                            windowBuf.count,
                            requestPtr,
                            resultPtr
                        )
                    }
                }
            }
        }

        let targetWindowIndex: Int?
        if rc == OMNI_OK,
           rawResult.has_target != 0,
           let idx = Int(exactly: rawResult.target_window_index),
           snapshot.windowEntries.indices.contains(idx)
        {
            targetWindowIndex = idx
        } else {
            targetWindowIndex = nil
        }

        return NavigationOutcome(
            rc: rc,
            result: rawResult,
            targetWindowIndex: targetWindowIndex
        )
    }

    static func resolveMutation(
        snapshot: Snapshot,
        request: MutationRequest
    ) -> MutationOutcome {
        var rawResult = OmniNiriMutationResult()
        rawResult.applied = 0
        rawResult.has_target_window = 0
        rawResult.target_window_index = -1
        rawResult.has_target_node = 0
        rawResult.target_node_kind = mutationNodeKindCode(.none)
        rawResult.target_node_index = -1
        rawResult.edit_count = 0

        let rawRequest = OmniNiriMutationRequest(
            op: request.op.rawValue,
            direction: mutationDirectionCode(request.direction),
            infinite_loop: request.infiniteLoop ? 1 : 0,
            insert_position: insertPositionCode(request.insertPosition),
            source_window_index: Int64(request.sourceWindowIndex),
            target_window_index: Int64(request.targetWindowIndex),
            max_windows_per_column: Int64(request.maxWindowsPerColumn),
            source_column_index: Int64(request.sourceColumnIndex),
            target_column_index: Int64(request.targetColumnIndex),
            insert_column_index: Int64(request.insertColumnIndex),
            max_visible_columns: Int64(request.maxVisibleColumns),
            selected_node_kind: mutationNodeKindCode(request.selectedNodeKind),
            selected_node_index: Int64(request.selectedNodeIndex),
            focused_window_index: Int64(request.focusedWindowIndex)
        )

        let rc: Int32 = snapshot.columns.withUnsafeBufferPointer { columnBuf in
            snapshot.windows.withUnsafeBufferPointer { windowBuf in
                var mutableRequest = rawRequest
                return withUnsafePointer(to: &mutableRequest) { requestPtr in
                    withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                        omni_niri_mutation_plan(
                            columnBuf.baseAddress,
                            columnBuf.count,
                            windowBuf.baseAddress,
                            windowBuf.count,
                            requestPtr,
                            resultPtr
                        )
                    }
                }
            }
        }

        let targetWindowIndex: Int?
        if rc == OMNI_OK,
           rawResult.has_target_window != 0,
           let idx = Int(exactly: rawResult.target_window_index),
           snapshot.windowEntries.indices.contains(idx)
        {
            targetWindowIndex = idx
        } else {
            targetWindowIndex = nil
        }

        let targetNode: MutationNodeTarget?
        if rc == OMNI_OK, rawResult.has_target_node != 0 {
            guard let nodeKind = MutationNodeKind(rawValue: rawResult.target_node_kind),
                  let nodeIndex = Int(exactly: rawResult.target_node_index)
            else {
                return MutationOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    applied: false,
                    targetWindowIndex: nil,
                    targetNode: nil,
                    edits: []
                )
            }

            let isValidTarget = switch nodeKind {
            case .window:
                snapshot.windowEntries.indices.contains(nodeIndex)
            case .column:
                snapshot.columnEntries.indices.contains(nodeIndex)
            case .none:
                false
            }

            if !isValidTarget {
                return MutationOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    applied: false,
                    targetWindowIndex: nil,
                    targetNode: nil,
                    edits: []
                )
            }

            targetNode = MutationNodeTarget(kind: nodeKind, index: nodeIndex)
        } else {
            targetNode = nil
        }

        let maxEdits = Int(OMNI_NIRI_MUTATION_MAX_EDITS)
        let requestedCount = Int(rawResult.edit_count)
        let editCount = max(0, min(maxEdits, requestedCount))
        var edits: [MutationEdit] = []
        edits.reserveCapacity(editCount)

        var decodeError = false
        withUnsafePointer(to: &rawResult.edits) { tuplePtr in
            let base = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: OmniNiriMutationEdit.self)
            for idx in 0 ..< editCount {
                let rawEdit = base[idx]
                guard let kind = MutationEditKind(rawValue: rawEdit.kind),
                      let subjectIndex = Int(exactly: rawEdit.subject_index),
                      let relatedIndex = Int(exactly: rawEdit.related_index),
                      let valueA = Int(exactly: rawEdit.value_a),
                      let valueB = Int(exactly: rawEdit.value_b)
                else {
                    decodeError = true
                    break
                }

                edits.append(
                    MutationEdit(
                        kind: kind,
                        subjectIndex: subjectIndex,
                        relatedIndex: relatedIndex,
                        valueA: valueA,
                        valueB: valueB,
                        scalarA: rawEdit.scalar_a,
                        scalarB: rawEdit.scalar_b
                    )
                )
            }
        }

        if decodeError {
            return MutationOutcome(
                rc: Int32(OMNI_ERR_INVALID_ARGS),
                applied: false,
                targetWindowIndex: nil,
                targetNode: nil,
                edits: []
            )
        }

        return MutationOutcome(
            rc: rc,
            applied: rc == OMNI_OK && rawResult.applied != 0,
            targetWindowIndex: targetWindowIndex,
            targetNode: targetNode,
            edits: edits
        )
    }
}
