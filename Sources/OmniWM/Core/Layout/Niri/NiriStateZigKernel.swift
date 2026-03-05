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

    enum WorkspaceOp: UInt8 {
        case moveWindowToWorkspace = 0
        case moveColumnToWorkspace = 1
    }

    struct MutationNodeTarget {
        let kind: MutationNodeKind
        let index: Int
    }

    struct WorkspaceRequest {
        let op: WorkspaceOp
        let sourceWindowIndex: Int
        let sourceColumnIndex: Int
        let maxVisibleColumns: Int

        init(
            op: WorkspaceOp,
            sourceWindowIndex: Int = -1,
            sourceColumnIndex: Int = -1,
            maxVisibleColumns: Int = -1
        ) {
            self.op = op
            self.sourceWindowIndex = sourceWindowIndex
            self.sourceColumnIndex = sourceColumnIndex
            self.maxVisibleColumns = maxVisibleColumns
        }
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

    struct RuntimeColumnState: Equatable {
        let columnId: NodeId
        let windowStart: Int
        let windowCount: Int
        let activeTileIdx: Int
        let isTabbed: Bool
        let sizeValue: Double
        let widthKind: UInt8
        let isFullWidth: Bool
        let hasSavedWidth: Bool
        let savedWidthKind: UInt8
        let savedWidthValue: Double

        init(
            columnId: NodeId,
            windowStart: Int,
            windowCount: Int,
            activeTileIdx: Int,
            isTabbed: Bool,
            sizeValue: Double,
            widthKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_PROPORTION.rawValue),
            isFullWidth: Bool = false,
            hasSavedWidth: Bool = false,
            savedWidthKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_PROPORTION.rawValue),
            savedWidthValue: Double = 1.0
        ) {
            self.columnId = columnId
            self.windowStart = windowStart
            self.windowCount = windowCount
            self.activeTileIdx = activeTileIdx
            self.isTabbed = isTabbed
            self.sizeValue = sizeValue
            self.widthKind = widthKind
            self.isFullWidth = isFullWidth
            self.hasSavedWidth = hasSavedWidth
            self.savedWidthKind = savedWidthKind
            self.savedWidthValue = savedWidthValue
        }
    }

    struct RuntimeWindowState: Equatable {
        let windowId: NodeId
        let columnId: NodeId
        let columnIndex: Int
        let sizeValue: Double
        let heightKind: UInt8
        let heightValue: Double

        init(
            windowId: NodeId,
            columnId: NodeId,
            columnIndex: Int,
            sizeValue: Double,
            heightKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_HEIGHT_KIND_AUTO.rawValue),
            heightValue: Double = 1.0
        ) {
            self.windowId = windowId
            self.columnId = columnId
            self.columnIndex = columnIndex
            self.sizeValue = sizeValue
            self.heightKind = heightKind
            self.heightValue = heightValue
        }
    }

    struct RuntimeStateExport: Equatable {
        let columns: [RuntimeColumnState]
        let windows: [RuntimeWindowState]
    }

    struct RuntimeNodeTarget: Equatable {
        let kind: MutationNodeKind
        let nodeId: NodeId
    }

    struct RuntimeMutationHints {
        let refreshTabbedVisibilityColumnIds: [NodeId]
        let resetAllColumnCachedWidths: Bool
        let delegatedMoveColumn: (columnId: NodeId, direction: Direction)?

        static let none = RuntimeMutationHints(
            refreshTabbedVisibilityColumnIds: [],
            resetAllColumnCachedWidths: false,
            delegatedMoveColumn: nil
        )
    }

    struct MutationApplyRequest {
        let request: MutationRequest
        let incomingWindowId: UUID?
        let createdColumnId: UUID?
        let placeholderColumnId: UUID?

        init(
            request: MutationRequest,
            incomingWindowId: UUID? = nil,
            createdColumnId: UUID? = nil,
            placeholderColumnId: UUID? = nil
        ) {
            self.request = request
            self.incomingWindowId = incomingWindowId
            self.createdColumnId = createdColumnId
            self.placeholderColumnId = placeholderColumnId
        }
    }

    struct MutationApplyOutcome {
        let rc: Int32
        let applied: Bool
        let targetWindowId: NodeId?
        let targetNode: RuntimeNodeTarget?
        let hints: RuntimeMutationHints
    }

    struct WorkspaceApplyRequest {
        let request: WorkspaceRequest
        let targetCreatedColumnId: UUID?
        let sourcePlaceholderColumnId: UUID?

        init(
            request: WorkspaceRequest,
            targetCreatedColumnId: UUID? = nil,
            sourcePlaceholderColumnId: UUID? = nil
        ) {
            self.request = request
            self.targetCreatedColumnId = targetCreatedColumnId
            self.sourcePlaceholderColumnId = sourcePlaceholderColumnId
        }
    }

    struct WorkspaceApplyOutcome {
        let rc: Int32
        let applied: Bool
        let sourceSelectionWindowId: NodeId?
        let targetSelectionWindowId: NodeId?
        let movedWindowId: NodeId?
    }

    struct RuntimeActiveTileUpdate {
        let columnId: NodeId
        let activeTileIdx: Int
    }

    struct NavigationApplyRequest {
        let request: NavigationRequest
    }

    struct NavigationApplyOutcome {
        let rc: Int32
        let applied: Bool
        let targetWindowId: NodeId?
        let sourceActiveTileUpdate: RuntimeActiveTileUpdate?
        let targetActiveTileUpdate: RuntimeActiveTileUpdate?
        let refreshSourceColumnId: NodeId?
        let refreshTargetColumnId: NodeId?
    }

    static func omniUUID(from nodeId: NodeId) -> OmniUuid128 {
        omniUUID(from: nodeId.uuid)
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

    static func nodeId(from omniUuid: OmniUuid128) -> NodeId {
        NodeId(uuid: uuid(from: omniUuid))
    }

    private static func zeroUUID() -> OmniUuid128 {
        OmniUuid128()
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

    private static func workspaceOpCode(_ op: WorkspaceOp) -> UInt8 {
        op.rawValue
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

    static let sizeKindProportion: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_PROPORTION.rawValue)
    static let sizeKindFixed: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_FIXED.rawValue)
    static let heightKindAuto: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_HEIGHT_KIND_AUTO.rawValue)
    static let heightKindFixed: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_HEIGHT_KIND_FIXED.rawValue)

    static func encodeWidth(_ width: ProportionalSize) -> (kind: UInt8, value: Double) {
        switch width {
        case let .proportion(value):
            return (kind: sizeKindProportion, value: Double(value))
        case let .fixed(value):
            return (kind: sizeKindFixed, value: Double(value))
        }
    }

    static func decodeWidth(kind: UInt8, value: Double) -> ProportionalSize? {
        if kind == sizeKindProportion {
            return .proportion(CGFloat(value))
        }
        if kind == sizeKindFixed {
            return .fixed(CGFloat(value))
        }
        return nil
    }

    static func encodeHeight(_ height: WeightedSize) -> (kind: UInt8, value: Double) {
        switch height {
        case let .auto(weight):
            return (kind: heightKindAuto, value: Double(weight))
        case let .fixed(value):
            return (kind: heightKindFixed, value: Double(value))
        }
    }

    static func decodeHeight(kind: UInt8, value: Double) -> WeightedSize? {
        if kind == heightKindAuto {
            return .auto(weight: CGFloat(value))
        }
        if kind == heightKindFixed {
            return .fixed(CGFloat(value))
        }
        return nil
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
            let encodedWidth = encodeWidth(column.width)
            let encodedSavedWidth = column.savedWidth.map(encodeWidth)

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

                let encodedHeight = encodeHeight(window.height)
                windowInputs.append(
                    OmniNiriStateWindowInput(
                        window_id: omniUUID(from: window.id),
                        column_id: columnId,
                        column_index: columnIndex,
                        size_value: Double(window.size),
                        height_kind: encodedHeight.kind,
                        height_value: encodedHeight.value
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
                    size_value: encodedWidth.value,
                    width_kind: encodedWidth.kind,
                    is_full_width: column.isFullWidth ? 1 : 0,
                    has_saved_width: encodedSavedWidth == nil ? 0 : 1,
                    saved_width_kind: encodedSavedWidth?.kind ?? sizeKindProportion,
                    saved_width_value: encodedSavedWidth?.value ?? 1.0
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

    private static func direction(from rawCode: UInt8) -> Direction? {
        switch rawCode {
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

    private static func rawMutationRequest(from request: MutationRequest) -> OmniNiriMutationRequest {
        OmniNiriMutationRequest(
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
    }

    private static func rawWorkspaceRequest(from request: WorkspaceRequest) -> OmniNiriWorkspaceRequest {
        OmniNiriWorkspaceRequest(
            op: workspaceOpCode(request.op),
            source_window_index: Int64(request.sourceWindowIndex),
            source_column_index: Int64(request.sourceColumnIndex),
            max_visible_columns: Int64(request.maxVisibleColumns)
        )
    }

    private static func rawNavigationRequest(from request: NavigationRequest) -> OmniNiriNavigationRequest {
        OmniNiriNavigationRequest(
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
    }

    static func runtimeStateExport(snapshot: Snapshot) -> RuntimeStateExport {
        let columns = snapshot.columns.map { column in
            RuntimeColumnState(
                columnId: nodeId(from: column.column_id),
                windowStart: column.window_start,
                windowCount: column.window_count,
                activeTileIdx: column.active_tile_idx,
                isTabbed: column.is_tabbed != 0,
                sizeValue: column.size_value,
                widthKind: column.width_kind,
                isFullWidth: column.is_full_width != 0,
                hasSavedWidth: column.has_saved_width != 0,
                savedWidthKind: column.saved_width_kind,
                savedWidthValue: column.saved_width_value
            )
        }
        let windows = snapshot.windows.map { window in
            RuntimeWindowState(
                windowId: nodeId(from: window.window_id),
                columnId: nodeId(from: window.column_id),
                columnIndex: window.column_index,
                sizeValue: window.size_value,
                heightKind: window.height_kind,
                heightValue: window.height_value
            )
        }
        return RuntimeStateExport(columns: columns, windows: windows)
    }

    static func seedRuntimeState(
        context: NiriLayoutZigKernel.LayoutContext,
        snapshot: Snapshot
    ) -> Int32 {
        seedRuntimeState(
            context: context,
            export: runtimeStateExport(snapshot: snapshot)
        )
    }

    static func seedRuntimeState(
        context: NiriLayoutZigKernel.LayoutContext,
        export: RuntimeStateExport
    ) -> Int32 {
        let rawColumns = export.columns.map { column in
            OmniNiriRuntimeColumnState(
                column_id: omniUUID(from: column.columnId),
                window_start: column.windowStart,
                window_count: column.windowCount,
                active_tile_idx: column.activeTileIdx,
                is_tabbed: column.isTabbed ? 1 : 0,
                size_value: column.sizeValue,
                width_kind: column.widthKind,
                is_full_width: column.isFullWidth ? 1 : 0,
                has_saved_width: column.hasSavedWidth ? 1 : 0,
                saved_width_kind: column.savedWidthKind,
                saved_width_value: column.savedWidthValue
            )
        }
        let rawWindows = export.windows.map { window in
            OmniNiriRuntimeWindowState(
                window_id: omniUUID(from: window.windowId),
                column_id: omniUUID(from: window.columnId),
                column_index: window.columnIndex,
                size_value: window.sizeValue,
                height_kind: window.heightKind,
                height_value: window.heightValue
            )
        }

        return rawColumns.withUnsafeBufferPointer { columnBuf in
            rawWindows.withUnsafeBufferPointer { windowBuf in
                context.withRawContext { raw in
                    omni_niri_ctx_seed_runtime_state(
                        raw,
                        columnBuf.baseAddress,
                        columnBuf.count,
                        windowBuf.baseAddress,
                        windowBuf.count
                    )
                }
            }
        }
    }

    static func exportRuntimeState(
        context: NiriLayoutZigKernel.LayoutContext
    ) -> (rc: Int32, export: RuntimeStateExport) {
        var rawExport = OmniNiriRuntimeStateExport(
            columns: nil,
            column_count: 0,
            windows: nil,
            window_count: 0
        )

        let rc = context.withRawContext { raw in
            withUnsafeMutablePointer(to: &rawExport) { exportPtr in
                omni_niri_ctx_export_runtime_state(raw, exportPtr)
            }
        }

        guard rc == OMNI_OK else {
            return (rc: rc, export: RuntimeStateExport(columns: [], windows: []))
        }

        let columns: [RuntimeColumnState]
        if let base = rawExport.columns, rawExport.column_count > 0 {
            let rawColumns = Array(UnsafeBufferPointer(start: base, count: rawExport.column_count))
            columns = rawColumns.map { column in
                RuntimeColumnState(
                    columnId: nodeId(from: column.column_id),
                    windowStart: column.window_start,
                    windowCount: column.window_count,
                    activeTileIdx: column.active_tile_idx,
                    isTabbed: column.is_tabbed != 0,
                    sizeValue: column.size_value,
                    widthKind: column.width_kind,
                    isFullWidth: column.is_full_width != 0,
                    hasSavedWidth: column.has_saved_width != 0,
                    savedWidthKind: column.saved_width_kind,
                    savedWidthValue: column.saved_width_value
                )
            }
        } else {
            columns = []
        }

        let windows: [RuntimeWindowState]
        if let base = rawExport.windows, rawExport.window_count > 0 {
            let rawWindows = Array(UnsafeBufferPointer(start: base, count: rawExport.window_count))
            windows = rawWindows.map { window in
                RuntimeWindowState(
                    windowId: nodeId(from: window.window_id),
                    columnId: nodeId(from: window.column_id),
                    columnIndex: window.column_index,
                    sizeValue: window.size_value,
                    heightKind: window.height_kind,
                    heightValue: window.height_value
                )
            }
        } else {
            windows = []
        }

        return (
            rc: rc,
            export: RuntimeStateExport(columns: columns, windows: windows)
        )
    }

    static func applyMutation(
        context: NiriLayoutZigKernel.LayoutContext,
        request: MutationApplyRequest
    ) -> MutationApplyOutcome {
        var rawRequest = OmniNiriMutationApplyRequest(
            request: rawMutationRequest(from: request.request),
            has_incoming_window_id: request.incomingWindowId == nil ? 0 : 1,
            incoming_window_id: request.incomingWindowId.map(omniUUID(from:)) ?? zeroUUID(),
            has_created_column_id: request.createdColumnId == nil ? 0 : 1,
            created_column_id: request.createdColumnId.map(omniUUID(from:)) ?? zeroUUID(),
            has_placeholder_column_id: request.placeholderColumnId == nil ? 0 : 1,
            placeholder_column_id: request.placeholderColumnId.map(omniUUID(from:)) ?? zeroUUID()
        )

        var rawResult = OmniNiriMutationApplyResult()
        let rc = context.withRawContext { raw in
            withUnsafePointer(to: &rawRequest) { requestPtr in
                withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                    omni_niri_ctx_apply_mutation(raw, requestPtr, resultPtr)
                }
            }
        }

        let targetWindowId: NodeId?
        if rc == OMNI_OK, rawResult.has_target_window_id != 0 {
            targetWindowId = nodeId(from: rawResult.target_window_id)
        } else {
            targetWindowId = nil
        }

        let targetNode: RuntimeNodeTarget?
        if rc == OMNI_OK, rawResult.has_target_node_id != 0 {
            guard let kind = MutationNodeKind(rawValue: rawResult.target_node_kind),
                  kind != .none
            else {
                return MutationApplyOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    hints: .none
                )
            }
            targetNode = RuntimeNodeTarget(
                kind: kind,
                nodeId: nodeId(from: rawResult.target_node_id)
            )
        } else {
            targetNode = nil
        }

        var refreshColumnIds: [NodeId] = []
        if rc == OMNI_OK {
            let maxCount = Int(OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS)
            let refreshCount = max(0, min(maxCount, Int(rawResult.refresh_tabbed_visibility_count)))
            refreshColumnIds.reserveCapacity(refreshCount)

            withUnsafePointer(to: &rawResult.refresh_tabbed_visibility_column_ids) { tuplePtr in
                let base = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: OmniUuid128.self)
                for idx in 0 ..< refreshCount {
                    refreshColumnIds.append(nodeId(from: base[idx]))
                }
            }
        }

        let delegatedMoveColumn: (columnId: NodeId, direction: Direction)?
        if rc == OMNI_OK, rawResult.has_delegate_move_column != 0 {
            guard let direction = direction(from: rawResult.delegate_move_direction) else {
                return MutationApplyOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    hints: .none
                )
            }
            delegatedMoveColumn = (nodeId(from: rawResult.delegate_move_column_id), direction)
        } else {
            delegatedMoveColumn = nil
        }

        let hints = RuntimeMutationHints(
            refreshTabbedVisibilityColumnIds: refreshColumnIds,
            resetAllColumnCachedWidths: rc == OMNI_OK && rawResult.reset_all_column_cached_widths != 0,
            delegatedMoveColumn: delegatedMoveColumn
        )

        return MutationApplyOutcome(
            rc: rc,
            applied: rc == OMNI_OK && rawResult.applied != 0,
            targetWindowId: targetWindowId,
            targetNode: targetNode,
            hints: hints
        )
    }

    static func applyWorkspace(
        sourceContext: NiriLayoutZigKernel.LayoutContext,
        targetContext: NiriLayoutZigKernel.LayoutContext,
        request: WorkspaceApplyRequest
    ) -> WorkspaceApplyOutcome {
        var rawRequest = OmniNiriWorkspaceApplyRequest(
            request: rawWorkspaceRequest(from: request.request),
            has_target_created_column_id: request.targetCreatedColumnId == nil ? 0 : 1,
            target_created_column_id: request.targetCreatedColumnId.map(omniUUID(from:)) ?? zeroUUID(),
            has_source_placeholder_column_id: request.sourcePlaceholderColumnId == nil ? 0 : 1,
            source_placeholder_column_id: request.sourcePlaceholderColumnId.map(omniUUID(from:)) ?? zeroUUID()
        )

        var rawResult = OmniNiriWorkspaceApplyResult()
        let rc = sourceContext.withRawContext { sourceRaw in
            targetContext.withRawContext { targetRaw in
                withUnsafePointer(to: &rawRequest) { requestPtr in
                    withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                        omni_niri_ctx_apply_workspace(sourceRaw, targetRaw, requestPtr, resultPtr)
                    }
                }
            }
        }

        return WorkspaceApplyOutcome(
            rc: rc,
            applied: rc == OMNI_OK && rawResult.applied != 0,
            sourceSelectionWindowId: rc == OMNI_OK && rawResult.has_source_selection_window_id != 0
                ? nodeId(from: rawResult.source_selection_window_id)
                : nil,
            targetSelectionWindowId: rc == OMNI_OK && rawResult.has_target_selection_window_id != 0
                ? nodeId(from: rawResult.target_selection_window_id)
                : nil,
            movedWindowId: rc == OMNI_OK && rawResult.has_moved_window_id != 0
                ? nodeId(from: rawResult.moved_window_id)
                : nil
        )
    }

    static func applyNavigation(
        context: NiriLayoutZigKernel.LayoutContext,
        request: NavigationApplyRequest
    ) -> NavigationApplyOutcome {
        var rawRequest = OmniNiriNavigationApplyRequest(
            request: rawNavigationRequest(from: request.request)
        )

        var rawResult = OmniNiriNavigationApplyResult()
        let rc = context.withRawContext { raw in
            withUnsafePointer(to: &rawRequest) { requestPtr in
                withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                    omni_niri_ctx_apply_navigation(raw, requestPtr, resultPtr)
                }
            }
        }

        let sourceActiveTileUpdate: RuntimeActiveTileUpdate?
        if rc == OMNI_OK, rawResult.update_source_active_tile != 0 {
            guard let idx = Int(exactly: rawResult.source_active_tile_idx) else {
                return NavigationApplyOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    applied: false,
                    targetWindowId: nil,
                    sourceActiveTileUpdate: nil,
                    targetActiveTileUpdate: nil,
                    refreshSourceColumnId: nil,
                    refreshTargetColumnId: nil
                )
            }
            sourceActiveTileUpdate = RuntimeActiveTileUpdate(
                columnId: nodeId(from: rawResult.source_column_id),
                activeTileIdx: idx
            )
        } else {
            sourceActiveTileUpdate = nil
        }

        let targetActiveTileUpdate: RuntimeActiveTileUpdate?
        if rc == OMNI_OK, rawResult.update_target_active_tile != 0 {
            guard let idx = Int(exactly: rawResult.target_active_tile_idx) else {
                return NavigationApplyOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    applied: false,
                    targetWindowId: nil,
                    sourceActiveTileUpdate: nil,
                    targetActiveTileUpdate: nil,
                    refreshSourceColumnId: nil,
                    refreshTargetColumnId: nil
                )
            }
            targetActiveTileUpdate = RuntimeActiveTileUpdate(
                columnId: nodeId(from: rawResult.target_column_id),
                activeTileIdx: idx
            )
        } else {
            targetActiveTileUpdate = nil
        }

        return NavigationApplyOutcome(
            rc: rc,
            applied: rc == OMNI_OK && rawResult.applied != 0,
            targetWindowId: rc == OMNI_OK && rawResult.has_target_window_id != 0
                ? nodeId(from: rawResult.target_window_id)
                : nil,
            sourceActiveTileUpdate: sourceActiveTileUpdate,
            targetActiveTileUpdate: targetActiveTileUpdate,
            refreshSourceColumnId: rc == OMNI_OK && rawResult.refresh_tabbed_visibility_source != 0
                ? nodeId(from: rawResult.refresh_source_column_id)
                : nil,
            refreshTargetColumnId: rc == OMNI_OK && rawResult.refresh_tabbed_visibility_target != 0
                ? nodeId(from: rawResult.refresh_target_column_id)
                : nil
        )
    }
}
