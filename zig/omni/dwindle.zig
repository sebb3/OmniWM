const std = @import("std");
const abi = @import("abi_types.zig");

const MIN_RATIO: f64 = 0.1;
const MAX_RATIO: f64 = 1.9;
const MIN_FRACTION: f64 = 0.05;
const MAX_FRACTION: f64 = 0.95;
const STICKS_TOLERANCE: f64 = 2.0;
const NEIGHBOR_EDGE_THRESHOLD_EXTRA: f64 = 5.0;
const NEIGHBOR_MIN_OVERLAP_RATIO: f64 = 0.1;
const DEFAULT_MUTATION_INNER_GAP: f64 = 8.0;
const DEFAULT_SPLIT_RATIO: f64 = 1.0;
const DEFAULT_SPLIT_WIDTH_MULTIPLIER: f64 = 1.0;
const CYCLE_PRESETS = [_]f64{ 0.3, 0.5, 0.7 };

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const RuntimeSettings = struct {
    smart_split: bool,
    default_split_ratio: f64,
    split_width_multiplier: f64,
    inner_gap: f64,
};

const SplitPlan = struct {
    orientation: u8,
    new_first: bool,
};

const Size = struct {
    width: f64,
    height: f64,
};

const LayoutScratch = struct {
    frame_count: usize,
    frames: [abi.MAX_WINDOWS]abi.OmniDwindleWindowFrame,
    has_min_size: [abi.OMNI_DWINDLE_MAX_NODES]u8,
    min_sizes: [abi.OMNI_DWINDLE_MAX_NODES]Size,
};

pub const OmniDwindleLayoutContext = extern struct {
    node_count: usize,
    nodes: [abi.OMNI_DWINDLE_MAX_NODES]abi.OmniDwindleSeedNode,
    seed_state: abi.OmniDwindleSeedState,
    cached_frame_count: usize,
    cached_frames: [abi.MAX_WINDOWS]abi.OmniDwindleWindowFrame,
    cached_node_frame_valid: [abi.OMNI_DWINDLE_MAX_NODES]u8,
    cached_node_frame_x: [abi.OMNI_DWINDLE_MAX_NODES]f64,
    cached_node_frame_y: [abi.OMNI_DWINDLE_MAX_NODES]f64,
    cached_node_frame_width: [abi.OMNI_DWINDLE_MAX_NODES]f64,
    cached_node_frame_height: [abi.OMNI_DWINDLE_MAX_NODES]f64,
    next_node_counter: u64,
};

fn zeroUuid() abi.OmniUuid128 {
    return .{ .bytes = [_]u8{0} ** 16 };
}

fn isZeroUuid(uuid: abi.OmniUuid128) bool {
    return std.mem.eql(u8, uuid.bytes[0..], zeroUuid().bytes[0..]);
}

fn uuidEqual(a: abi.OmniUuid128, b: abi.OmniUuid128) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

fn isFlag(value: u8) bool {
    return value == 0 or value == 1;
}

fn isFiniteNonNegative(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn rectMinX(rect: Rect) f64 {
    return rect.x;
}

fn rectMaxX(rect: Rect) f64 {
    return rect.x + rect.width;
}

fn rectMinY(rect: Rect) f64 {
    return rect.y;
}

fn rectMaxY(rect: Rect) f64 {
    return rect.y + rect.height;
}

fn rectToFrame(window_id: abi.OmniUuid128, rect: Rect) abi.OmniDwindleWindowFrame {
    return .{
        .window_id = window_id,
        .frame_x = rect.x,
        .frame_y = rect.y,
        .frame_width = rect.width,
        .frame_height = rect.height,
    };
}

fn frameToRect(frame: abi.OmniDwindleWindowFrame) Rect {
    return .{
        .x = frame.frame_x,
        .y = frame.frame_y,
        .width = frame.frame_width,
        .height = frame.frame_height,
    };
}

fn abiRectToRect(raw: abi.OmniDwindleRect) Rect {
    return .{
        .x = raw.x,
        .y = raw.y,
        .width = raw.width,
        .height = raw.height,
    };
}

fn decodeRuntimeSettings(raw: abi.OmniDwindleRuntimeSettings) RuntimeSettings {
    return .{
        .smart_split = raw.smart_split != 0,
        .default_split_ratio = if (std.math.isFinite(raw.default_split_ratio))
            raw.default_split_ratio
        else
            DEFAULT_SPLIT_RATIO,
        .split_width_multiplier = if (isFiniteNonNegative(raw.split_width_multiplier))
            raw.split_width_multiplier
        else
            DEFAULT_SPLIT_WIDTH_MULTIPLIER,
        .inner_gap = if (isFiniteNonNegative(raw.inner_gap))
            raw.inner_gap
        else
            DEFAULT_MUTATION_INNER_GAP,
    };
}

fn ratioToFraction(ratio: f64) f64 {
    const clamped_ratio = @min(@max(ratio, MIN_RATIO), MAX_RATIO);
    return @min(@max(clamped_ratio / 2.0, MIN_FRACTION), MAX_FRACTION);
}

fn applyOuterGapsOnly(rect: Rect, req: abi.OmniDwindleLayoutRequest) Rect {
    return .{
        .x = rect.x + req.outer_gap_left,
        .y = rect.y + req.outer_gap_bottom,
        .width = @max(1.0, rect.width - req.outer_gap_left - req.outer_gap_right),
        .height = @max(1.0, rect.height - req.outer_gap_top - req.outer_gap_bottom),
    };
}

fn applyGaps(node_rect: Rect, tiling_area: Rect, req: abi.OmniDwindleLayoutRequest) Rect {
    const at_left = @abs(rectMinX(node_rect) - rectMinX(tiling_area)) < STICKS_TOLERANCE;
    const at_right = @abs(rectMaxX(node_rect) - rectMaxX(tiling_area)) < STICKS_TOLERANCE;
    const at_bottom = @abs(rectMinY(node_rect) - rectMinY(tiling_area)) < STICKS_TOLERANCE;
    const at_top = @abs(rectMaxY(node_rect) - rectMaxY(tiling_area)) < STICKS_TOLERANCE;

    const left_gap = if (at_left) req.outer_gap_left else req.inner_gap / 2.0;
    const right_gap = if (at_right) req.outer_gap_right else req.inner_gap / 2.0;
    const bottom_gap = if (at_bottom) req.outer_gap_bottom else req.inner_gap / 2.0;
    const top_gap = if (at_top) req.outer_gap_top else req.inner_gap / 2.0;

    return .{
        .x = node_rect.x + left_gap,
        .y = node_rect.y + bottom_gap,
        .width = @max(1.0, node_rect.width - left_gap - right_gap),
        .height = @max(1.0, node_rect.height - top_gap - bottom_gap),
    };
}

fn singleWindowRect(screen: Rect, req: abi.OmniDwindleLayoutRequest) Rect {
    const target_ratio = if (@abs(req.single_window_aspect_height) < 0.001)
        std.math.inf(f64)
    else
        req.single_window_aspect_width / req.single_window_aspect_height;

    const current_ratio = if (@abs(screen.height) < 0.001)
        std.math.inf(f64)
    else
        screen.width / screen.height;

    if (@abs(target_ratio - current_ratio) < req.single_window_aspect_tolerance) {
        return screen;
    }

    var width = screen.width;
    var height = screen.height;

    if (current_ratio > target_ratio) {
        width = height * target_ratio;
    } else {
        height = width / target_ratio;
    }

    return .{
        .x = screen.x + (screen.width - width) / 2.0,
        .y = screen.y + (screen.height - height) / 2.0,
        .width = width,
        .height = height,
    };
}

fn splitRect(
    rect: Rect,
    orientation: u8,
    ratio: f64,
    first_min_size: Size,
    second_min_size: Size,
) [2]Rect {
    var fraction = ratioToFraction(ratio);

    switch (orientation) {
        abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL => {
            const total_min = first_min_size.width + second_min_size.width;
            if (total_min > rect.width) {
                const total_min_clamped = @max(total_min, 1.0);
                fraction = first_min_size.width / total_min_clamped;
            } else {
                const min_fraction = first_min_size.width / rect.width;
                const max_fraction = (rect.width - second_min_size.width) / rect.width;
                fraction = @max(min_fraction, @min(max_fraction, fraction));
            }

            const first_w = rect.width * fraction;
            const second_w = rect.width - first_w;
            return .{
                .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = first_w,
                    .height = rect.height,
                },
                .{
                    .x = rect.x + first_w,
                    .y = rect.y,
                    .width = second_w,
                    .height = rect.height,
                },
            };
        },
        abi.OMNI_DWINDLE_ORIENTATION_VERTICAL => {
            const total_min = first_min_size.height + second_min_size.height;
            if (total_min > rect.height) {
                const total_min_clamped = @max(total_min, 1.0);
                fraction = first_min_size.height / total_min_clamped;
            } else {
                const min_fraction = first_min_size.height / rect.height;
                const max_fraction = (rect.height - second_min_size.height) / rect.height;
                fraction = @max(min_fraction, @min(max_fraction, fraction));
            }

            const first_h = rect.height * fraction;
            const second_h = rect.height - first_h;
            return .{
                .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = first_h,
                },
                .{
                    .x = rect.x,
                    .y = rect.y + first_h,
                    .width = rect.width,
                    .height = second_h,
                },
            };
        },
        else => unreachable,
    }
}

fn isValidDirection(direction: u8) bool {
    return switch (direction) {
        abi.OMNI_DWINDLE_DIRECTION_LEFT,
        abi.OMNI_DWINDLE_DIRECTION_RIGHT,
        abi.OMNI_DWINDLE_DIRECTION_UP,
        abi.OMNI_DWINDLE_DIRECTION_DOWN,
        => true,
        else => false,
    };
}

fn isValidOrientation(orientation: u8) bool {
    return switch (orientation) {
        abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL, abi.OMNI_DWINDLE_ORIENTATION_VERTICAL => true,
        else => false,
    };
}

fn isValidNodeKind(kind: u8) bool {
    return switch (kind) {
        abi.OMNI_DWINDLE_NODE_SPLIT, abi.OMNI_DWINDLE_NODE_LEAF => true,
        else => false,
    };
}

fn isValidOp(op: u8) bool {
    return switch (op) {
        abi.OMNI_DWINDLE_OP_ADD_WINDOW,
        abi.OMNI_DWINDLE_OP_REMOVE_WINDOW,
        abi.OMNI_DWINDLE_OP_SYNC_WINDOWS,
        abi.OMNI_DWINDLE_OP_MOVE_FOCUS,
        abi.OMNI_DWINDLE_OP_SWAP_WINDOWS,
        abi.OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN,
        abi.OMNI_DWINDLE_OP_TOGGLE_ORIENTATION,
        abi.OMNI_DWINDLE_OP_RESIZE_SELECTED,
        abi.OMNI_DWINDLE_OP_BALANCE_SIZES,
        abi.OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO,
        abi.OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT,
        abi.OMNI_DWINDLE_OP_SWAP_SPLIT,
        abi.OMNI_DWINDLE_OP_SET_PRESELECTION,
        abi.OMNI_DWINDLE_OP_CLEAR_PRESELECTION,
        abi.OMNI_DWINDLE_OP_VALIDATE_SELECTION,
        => true,
        else => false,
    };
}

fn parseOptionalIndex(raw: i64, count: usize, out_index: *?usize) i32 {
    if (raw == -1) {
        out_index.* = null;
        return abi.OMNI_OK;
    }
    if (raw < -1) return abi.OMNI_ERR_OUT_OF_RANGE;
    const index = std.math.cast(usize, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    if (index >= count) return abi.OMNI_ERR_OUT_OF_RANGE;
    out_index.* = index;
    return abi.OMNI_OK;
}

fn resetContext(ctx: *OmniDwindleLayoutContext) void {
    ctx.node_count = 0;
    ctx.seed_state = .{
        .root_node_index = -1,
        .selected_node_index = -1,
        .has_preselection = 0,
        .preselection_direction = abi.OMNI_DWINDLE_DIRECTION_LEFT,
    };
    ctx.cached_frame_count = 0;
    ctx.cached_node_frame_valid = [_]u8{0} ** abi.OMNI_DWINDLE_MAX_NODES;
    ctx.cached_node_frame_x = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    ctx.cached_node_frame_y = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    ctx.cached_node_frame_width = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    ctx.cached_node_frame_height = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    ctx.next_node_counter = 1;
}

fn asMutableContext(context: [*c]OmniDwindleLayoutContext) ?*OmniDwindleLayoutContext {
    if (context == null) return null;
    const ptr: *OmniDwindleLayoutContext = @ptrCast(&context[0]);
    return ptr;
}

fn asConstContext(context: [*c]const OmniDwindleLayoutContext) ?*const OmniDwindleLayoutContext {
    if (context == null) return null;
    const ptr: *const OmniDwindleLayoutContext = @ptrCast(&context[0]);
    return ptr;
}

fn initOpResult(out_result: [*c]abi.OmniDwindleOpResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_selected_window_id = 0,
        .selected_window_id = zeroUuid(),
        .has_focused_window_id = 0,
        .focused_window_id = zeroUuid(),
        .has_preselection = 0,
        .preselection_direction = abi.OMNI_DWINDLE_DIRECTION_LEFT,
        .removed_window_count = 0,
    };
}

fn validateNodeIdUniqueness(nodes: [*c]const abi.OmniDwindleSeedNode, node_count: usize) i32 {
    for (0..node_count) |idx| {
        const current = nodes[idx].node_id;
        for ((idx + 1)..node_count) |other_idx| {
            if (uuidEqual(current, nodes[other_idx].node_id)) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }
        }
    }
    return abi.OMNI_OK;
}

fn validateWindowIdUniqueness(nodes: [*c]const abi.OmniDwindleSeedNode, node_count: usize) i32 {
    for (0..node_count) |idx| {
        if (nodes[idx].has_window_id == 0) continue;
        const current = nodes[idx].window_id;
        for ((idx + 1)..node_count) |other_idx| {
            if (nodes[other_idx].has_window_id == 0) continue;
            if (uuidEqual(current, nodes[other_idx].window_id)) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }
        }
    }
    return abi.OMNI_OK;
}

fn validateAcyclicParentChain(nodes: [*c]const abi.OmniDwindleSeedNode, node_count: usize) i32 {
    for (0..node_count) |start_idx| {
        var current_idx = start_idx;
        var steps: usize = 0;

        while (true) {
            const parent_raw = nodes[current_idx].parent_index;
            if (parent_raw == -1) break;

            const parent = std.math.cast(usize, parent_raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (parent >= node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

            steps += 1;
            if (steps > node_count) return abi.OMNI_ERR_INVALID_ARGS;
            current_idx = parent;
        }
    }

    return abi.OMNI_OK;
}

fn validateReachabilityFromRoot(
    nodes: [*c]const abi.OmniDwindleSeedNode,
    node_count: usize,
    root_idx: usize,
) i32 {
    var visited = [_]u8{0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var stack = [_]usize{0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var stack_len: usize = 0;
    var visited_count: usize = 0;

    stack[0] = root_idx;
    stack_len = 1;

    while (stack_len > 0) {
        stack_len -= 1;
        const node_index = stack[stack_len];
        if (node_index >= node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

        if (visited[node_index] != 0) return abi.OMNI_ERR_INVALID_ARGS;
        visited[node_index] = 1;
        visited_count += 1;

        const node = nodes[node_index];
        if (node.kind == abi.OMNI_DWINDLE_NODE_SPLIT) {
            const first = std.math.cast(usize, node.first_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const second = std.math.cast(usize, node.second_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (first >= node_count or second >= node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

            if (stack_len + 2 > node_count) return abi.OMNI_ERR_INVALID_ARGS;
            stack[stack_len] = first;
            stack_len += 1;
            stack[stack_len] = second;
            stack_len += 1;
        }
    }

    if (visited_count != node_count) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn validateConstraints(
    constraints: [*c]const abi.OmniDwindleWindowConstraint,
    constraint_count: usize,
) i32 {
    for (0..constraint_count) |idx| {
        const constraint = constraints[idx];
        if (isZeroUuid(constraint.window_id)) return abi.OMNI_ERR_INVALID_ARGS;
        if (!isFlag(constraint.has_max_width) or
            !isFlag(constraint.has_max_height) or
            !isFlag(constraint.is_fixed))
        {
            return abi.OMNI_ERR_INVALID_ARGS;
        }
        if (!isFiniteNonNegative(constraint.min_width) or
            !isFiniteNonNegative(constraint.min_height) or
            !isFiniteNonNegative(constraint.max_width) or
            !isFiniteNonNegative(constraint.max_height))
        {
            return abi.OMNI_ERR_INVALID_ARGS;
        }

        for ((idx + 1)..constraint_count) |other_idx| {
            if (uuidEqual(constraint.window_id, constraints[other_idx].window_id)) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }
        }
    }
    return abi.OMNI_OK;
}

fn constraintMinSize(
    window_id: abi.OmniUuid128,
    constraints: [*c]const abi.OmniDwindleWindowConstraint,
    constraint_count: usize,
) Size {
    for (0..constraint_count) |idx| {
        const constraint = constraints[idx];
        if (!uuidEqual(constraint.window_id, window_id)) continue;
        return .{
            .width = constraint.min_width,
            .height = constraint.min_height,
        };
    }
    return .{
        .width = 1.0,
        .height = 1.0,
    };
}

fn appendFrame(
    scratch: *LayoutScratch,
    window_id: abi.OmniUuid128,
    rect: Rect,
) i32 {
    if (scratch.frame_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    scratch.frames[scratch.frame_count] = rectToFrame(window_id, rect);
    scratch.frame_count += 1;
    return abi.OMNI_OK;
}

fn countWindowLeaves(
    ctx: *const OmniDwindleLayoutContext,
    node_index: usize,
    out_count: *usize,
) i32 {
    if (node_index >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const node = ctx.nodes[node_index];

    if (node.kind == abi.OMNI_DWINDLE_NODE_LEAF) {
        if (node.has_window_id != 0) out_count.* += 1;
        return abi.OMNI_OK;
    }

    if (node.kind != abi.OMNI_DWINDLE_NODE_SPLIT) return abi.OMNI_ERR_INVALID_ARGS;

    const first_idx = std.math.cast(usize, node.first_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const second_idx = std.math.cast(usize, node.second_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    if (first_idx >= ctx.node_count or second_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var rc = countWindowLeaves(ctx, first_idx, out_count);
    if (rc != abi.OMNI_OK) return rc;
    rc = countWindowLeaves(ctx, second_idx, out_count);
    if (rc != abi.OMNI_OK) return rc;
    return abi.OMNI_OK;
}

fn findSingleWindowLeaf(
    ctx: *const OmniDwindleLayoutContext,
    node_index: usize,
) ?usize {
    if (node_index >= ctx.node_count) return null;
    const node = ctx.nodes[node_index];

    if (node.kind == abi.OMNI_DWINDLE_NODE_LEAF) {
        if (node.has_window_id != 0) return node_index;
        return null;
    }

    if (node.kind != abi.OMNI_DWINDLE_NODE_SPLIT) return null;

    const first_idx = std.math.cast(usize, node.first_child_index) orelse return null;
    const second_idx = std.math.cast(usize, node.second_child_index) orelse return null;
    if (first_idx >= ctx.node_count or second_idx >= ctx.node_count) return null;

    if (findSingleWindowLeaf(ctx, first_idx)) |candidate| {
        return candidate;
    }
    return findSingleWindowLeaf(ctx, second_idx);
}

fn computeMinSizeForSubtree(
    ctx: *const OmniDwindleLayoutContext,
    constraints: [*c]const abi.OmniDwindleWindowConstraint,
    constraint_count: usize,
    scratch: *LayoutScratch,
    node_index: usize,
    out_min_size: *Size,
) i32 {
    if (node_index >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    if (scratch.has_min_size[node_index] != 0) {
        out_min_size.* = scratch.min_sizes[node_index];
        return abi.OMNI_OK;
    }

    const node = ctx.nodes[node_index];
    var result = Size{ .width = 1.0, .height = 1.0 };

    switch (node.kind) {
        abi.OMNI_DWINDLE_NODE_LEAF => {
            if (node.has_window_id != 0) {
                result = constraintMinSize(node.window_id, constraints, constraint_count);
            }
        },
        abi.OMNI_DWINDLE_NODE_SPLIT => {
            const first_idx = std.math.cast(usize, node.first_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const second_idx = std.math.cast(usize, node.second_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (first_idx >= ctx.node_count or second_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

            var first_min = Size{ .width = 1.0, .height = 1.0 };
            var second_min = Size{ .width = 1.0, .height = 1.0 };

            var rc = computeMinSizeForSubtree(
                ctx,
                constraints,
                constraint_count,
                scratch,
                first_idx,
                &first_min,
            );
            if (rc != abi.OMNI_OK) return rc;

            rc = computeMinSizeForSubtree(
                ctx,
                constraints,
                constraint_count,
                scratch,
                second_idx,
                &second_min,
            );
            if (rc != abi.OMNI_OK) return rc;

            switch (node.orientation) {
                abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL => {
                    result = .{
                        .width = first_min.width + second_min.width,
                        .height = @max(first_min.height, second_min.height),
                    };
                },
                abi.OMNI_DWINDLE_ORIENTATION_VERTICAL => {
                    result = .{
                        .width = @max(first_min.width, second_min.width),
                        .height = first_min.height + second_min.height,
                    };
                },
                else => return abi.OMNI_ERR_INVALID_ARGS,
            }
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    scratch.min_sizes[node_index] = result;
    scratch.has_min_size[node_index] = 1;
    out_min_size.* = result;
    return abi.OMNI_OK;
}

fn layoutRecursive(
    ctx: *OmniDwindleLayoutContext,
    constraints: [*c]const abi.OmniDwindleWindowConstraint,
    constraint_count: usize,
    req: abi.OmniDwindleLayoutRequest,
    scratch: *LayoutScratch,
    node_index: usize,
    rect: Rect,
    tiling_area: Rect,
) i32 {
    if (node_index >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const node = ctx.nodes[node_index];

    switch (node.kind) {
        abi.OMNI_DWINDLE_NODE_LEAF => {
            if (node.has_window_id == 0) return abi.OMNI_OK;

            const target = if (node.is_fullscreen != 0)
                tiling_area
            else
                applyGaps(rect, tiling_area, req);
            setCachedNodeFrame(ctx, node_index, target);
            return appendFrame(scratch, node.window_id, target);
        },
        abi.OMNI_DWINDLE_NODE_SPLIT => {
            setCachedNodeFrame(ctx, node_index, rect);
            const first_idx = std.math.cast(usize, node.first_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const second_idx = std.math.cast(usize, node.second_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (first_idx >= ctx.node_count or second_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

            var first_min = Size{ .width = 1.0, .height = 1.0 };
            var second_min = Size{ .width = 1.0, .height = 1.0 };

            var rc = computeMinSizeForSubtree(
                ctx,
                constraints,
                constraint_count,
                scratch,
                first_idx,
                &first_min,
            );
            if (rc != abi.OMNI_OK) return rc;

            rc = computeMinSizeForSubtree(
                ctx,
                constraints,
                constraint_count,
                scratch,
                second_idx,
                &second_min,
            );
            if (rc != abi.OMNI_OK) return rc;

            const split_rects = splitRect(
                rect,
                node.orientation,
                node.ratio,
                first_min,
                second_min,
            );

            rc = layoutRecursive(
                ctx,
                constraints,
                constraint_count,
                req,
                scratch,
                first_idx,
                split_rects[0],
                tiling_area,
            );
            if (rc != abi.OMNI_OK) return rc;

            rc = layoutRecursive(
                ctx,
                constraints,
                constraint_count,
                req,
                scratch,
                second_idx,
                split_rects[1],
                tiling_area,
            );
            if (rc != abi.OMNI_OK) return rc;
            return abi.OMNI_OK;
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }
}

fn calculateDirectionalOverlap(
    source: Rect,
    target: Rect,
    direction: u8,
    inner_gap: f64,
) ?f64 {
    const edge_threshold = inner_gap + NEIGHBOR_EDGE_THRESHOLD_EXTRA;
    const min_overlap_ratio = NEIGHBOR_MIN_OVERLAP_RATIO;

    switch (direction) {
        abi.OMNI_DWINDLE_DIRECTION_UP => {
            const edges_touch = @abs(rectMaxY(source) - rectMinY(target)) < edge_threshold;
            if (!edges_touch) return null;

            const overlap_start = @max(rectMinX(source), rectMinX(target));
            const overlap_end = @min(rectMaxX(source), rectMaxX(target));
            const overlap = @max(0.0, overlap_end - overlap_start);
            const min_required = @min(source.width, target.width) * min_overlap_ratio;
            return if (overlap >= min_required) overlap else null;
        },
        abi.OMNI_DWINDLE_DIRECTION_DOWN => {
            const edges_touch = @abs(rectMinY(source) - rectMaxY(target)) < edge_threshold;
            if (!edges_touch) return null;

            const overlap_start = @max(rectMinX(source), rectMinX(target));
            const overlap_end = @min(rectMaxX(source), rectMaxX(target));
            const overlap = @max(0.0, overlap_end - overlap_start);
            const min_required = @min(source.width, target.width) * min_overlap_ratio;
            return if (overlap >= min_required) overlap else null;
        },
        abi.OMNI_DWINDLE_DIRECTION_LEFT => {
            const edges_touch = @abs(rectMinX(source) - rectMaxX(target)) < edge_threshold;
            if (!edges_touch) return null;

            const overlap_start = @max(rectMinY(source), rectMinY(target));
            const overlap_end = @min(rectMaxY(source), rectMaxY(target));
            const overlap = @max(0.0, overlap_end - overlap_start);
            const min_required = @min(source.height, target.height) * min_overlap_ratio;
            return if (overlap >= min_required) overlap else null;
        },
        abi.OMNI_DWINDLE_DIRECTION_RIGHT => {
            const edges_touch = @abs(rectMaxX(source) - rectMinX(target)) < edge_threshold;
            if (!edges_touch) return null;

            const overlap_start = @max(rectMinY(source), rectMinY(target));
            const overlap_end = @min(rectMaxY(source), rectMaxY(target));
            const overlap = @max(0.0, overlap_end - overlap_start);
            const min_required = @min(source.height, target.height) * min_overlap_ratio;
            return if (overlap >= min_required) overlap else null;
        },
        else => return null,
    }
}

fn i64FromUsize(value: usize) i64 {
    return std.math.cast(i64, value) orelse @panic("usize->i64 overflow");
}

fn isLeafNode(node: abi.OmniDwindleSeedNode) bool {
    return node.kind == abi.OMNI_DWINDLE_NODE_LEAF;
}

fn isSplitNode(node: abi.OmniDwindleSeedNode) bool {
    return node.kind == abi.OMNI_DWINDLE_NODE_SPLIT;
}

fn selectedIndex(ctx: *const OmniDwindleLayoutContext) ?usize {
    if (ctx.seed_state.selected_node_index < 0) return null;
    const idx = std.math.cast(usize, ctx.seed_state.selected_node_index) orelse return null;
    if (idx >= ctx.node_count) return null;
    return idx;
}

fn setSelectedIndex(ctx: *OmniDwindleLayoutContext, index: ?usize) void {
    ctx.seed_state.selected_node_index = if (index) |idx|
        i64FromUsize(idx)
    else
        -1;
}

fn rootIndex(ctx: *const OmniDwindleLayoutContext) ?usize {
    if (ctx.node_count == 0) return null;
    if (ctx.seed_state.root_node_index < 0) return null;
    const idx = std.math.cast(usize, ctx.seed_state.root_node_index) orelse return null;
    if (idx >= ctx.node_count) return null;
    return idx;
}

fn childIndex(raw: i64, count: usize) ?usize {
    if (raw < 0) return null;
    const idx = std.math.cast(usize, raw) orelse return null;
    if (idx >= count) return null;
    return idx;
}

fn descendantFirstLeaf(ctx: *const OmniDwindleLayoutContext, start_idx: usize) ?usize {
    if (start_idx >= ctx.node_count) return null;
    var idx = start_idx;
    while (true) {
        const node = ctx.nodes[idx];
        if (isLeafNode(node)) return idx;
        if (!isSplitNode(node)) return null;
        idx = childIndex(node.first_child_index, ctx.node_count) orelse return null;
    }
}

fn findFirstLeafWithWindow(ctx: *const OmniDwindleLayoutContext, start_idx: usize) ?usize {
    if (start_idx >= ctx.node_count) return null;
    var stack = [_]usize{0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var stack_len: usize = 0;

    stack[0] = start_idx;
    stack_len = 1;

    while (stack_len > 0) {
        stack_len -= 1;
        const idx = stack[stack_len];
        if (idx >= ctx.node_count) return null;
        const node = ctx.nodes[idx];
        if (isLeafNode(node)) {
            if (node.has_window_id != 0) return idx;
            continue;
        }
        if (!isSplitNode(node)) return null;
        const first = childIndex(node.first_child_index, ctx.node_count) orelse return null;
        const second = childIndex(node.second_child_index, ctx.node_count) orelse return null;
        if (stack_len + 2 > abi.OMNI_DWINDLE_MAX_NODES) return null;
        stack[stack_len] = second;
        stack_len += 1;
        stack[stack_len] = first;
        stack_len += 1;
    }

    return null;
}

fn findLeafByWindowId(ctx: *const OmniDwindleLayoutContext, window_id: abi.OmniUuid128) ?usize {
    for (0..ctx.node_count) |idx| {
        const node = ctx.nodes[idx];
        if (!isLeafNode(node)) continue;
        if (node.has_window_id == 0) continue;
        if (uuidEqual(node.window_id, window_id)) return idx;
    }
    return null;
}

fn uuidInSlice(values: *const [abi.MAX_WINDOWS]abi.OmniUuid128, value_count: usize, target: abi.OmniUuid128) bool {
    for (0..value_count) |idx| {
        if (uuidEqual(values[idx], target)) return true;
    }
    return false;
}

fn collectWindowIdsRecursive(
    ctx: *const OmniDwindleLayoutContext,
    node_idx: usize,
    out_ids: *[abi.MAX_WINDOWS]abi.OmniUuid128,
    out_count: *usize,
) i32 {
    if (node_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const node = ctx.nodes[node_idx];
    if (isLeafNode(node)) {
        if (node.has_window_id != 0) {
            if (out_count.* >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
            out_ids[out_count.*] = node.window_id;
            out_count.* += 1;
        }
        return abi.OMNI_OK;
    }

    if (!isSplitNode(node)) return abi.OMNI_ERR_INVALID_ARGS;
    const first = childIndex(node.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const second = childIndex(node.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

    var rc = collectWindowIdsRecursive(ctx, first, out_ids, out_count);
    if (rc != abi.OMNI_OK) return rc;
    rc = collectWindowIdsRecursive(ctx, second, out_ids, out_count);
    if (rc != abi.OMNI_OK) return rc;
    return abi.OMNI_OK;
}

fn collectWindowIdsInOrder(
    ctx: *const OmniDwindleLayoutContext,
    out_ids: *[abi.MAX_WINDOWS]abi.OmniUuid128,
    out_count: *usize,
) i32 {
    out_count.* = 0;
    if (ctx.node_count == 0) return abi.OMNI_OK;
    const root_idx = rootIndex(ctx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    return collectWindowIdsRecursive(ctx, root_idx, out_ids, out_count);
}

fn resolveNeighborWindowId(
    ctx: *const OmniDwindleLayoutContext,
    window_id: abi.OmniUuid128,
    direction: u8,
    inner_gap: f64,
) ?abi.OmniUuid128 {
    if (ctx.cached_frame_count == 0) return null;
    if (ctx.cached_frame_count > abi.MAX_WINDOWS) return null;

    var source_rect: ?Rect = null;
    for (0..ctx.cached_frame_count) |idx| {
        const frame = ctx.cached_frames[idx];
        if (uuidEqual(frame.window_id, window_id)) {
            source_rect = frameToRect(frame);
            break;
        }
    }
    if (source_rect == null) return null;

    var best_overlap: f64 = 0.0;
    var best_window: abi.OmniUuid128 = zeroUuid();
    var found = false;

    for (0..ctx.cached_frame_count) |idx| {
        const candidate = ctx.cached_frames[idx];
        if (uuidEqual(candidate.window_id, window_id)) continue;

        if (calculateDirectionalOverlap(source_rect.?, frameToRect(candidate), direction, inner_gap)) |overlap| {
            if (!found or overlap > best_overlap) {
                found = true;
                best_overlap = overlap;
                best_window = candidate.window_id;
            }
        }
    }

    if (!found) return null;
    return best_window;
}

fn removeCachedFrame(ctx: *OmniDwindleLayoutContext, window_id: abi.OmniUuid128) void {
    if (ctx.cached_frame_count == 0) return;
    var idx: usize = 0;
    while (idx < ctx.cached_frame_count) : (idx += 1) {
        if (!uuidEqual(ctx.cached_frames[idx].window_id, window_id)) continue;
        var move_idx = idx;
        while (move_idx + 1 < ctx.cached_frame_count) : (move_idx += 1) {
            ctx.cached_frames[move_idx] = ctx.cached_frames[move_idx + 1];
        }
        ctx.cached_frame_count -= 1;
        return;
    }
}

fn clearCachedNodeFrames(ctx: *OmniDwindleLayoutContext) void {
    ctx.cached_node_frame_valid = [_]u8{0} ** abi.OMNI_DWINDLE_MAX_NODES;
}

fn setCachedNodeFrame(
    ctx: *OmniDwindleLayoutContext,
    node_idx: usize,
    rect: Rect,
) void {
    if (node_idx >= abi.OMNI_DWINDLE_MAX_NODES) return;
    ctx.cached_node_frame_valid[node_idx] = 1;
    ctx.cached_node_frame_x[node_idx] = rect.x;
    ctx.cached_node_frame_y[node_idx] = rect.y;
    ctx.cached_node_frame_width[node_idx] = rect.width;
    ctx.cached_node_frame_height[node_idx] = rect.height;
}

fn cachedNodeFrameRect(
    ctx: *const OmniDwindleLayoutContext,
    node_idx: usize,
) ?Rect {
    if (node_idx >= abi.OMNI_DWINDLE_MAX_NODES) return null;
    if (ctx.cached_node_frame_valid[node_idx] == 0) return null;
    return .{
        .x = ctx.cached_node_frame_x[node_idx],
        .y = ctx.cached_node_frame_y[node_idx],
        .width = ctx.cached_node_frame_width[node_idx],
        .height = ctx.cached_node_frame_height[node_idx],
    };
}

fn swapCachedNodeFrames(
    ctx: *OmniDwindleLayoutContext,
    lhs_idx: usize,
    rhs_idx: usize,
) void {
    if (lhs_idx >= abi.OMNI_DWINDLE_MAX_NODES or rhs_idx >= abi.OMNI_DWINDLE_MAX_NODES) return;
    if (lhs_idx == rhs_idx) return;

    const lhs_valid = ctx.cached_node_frame_valid[lhs_idx];
    const rhs_valid = ctx.cached_node_frame_valid[rhs_idx];
    const lhs_x = ctx.cached_node_frame_x[lhs_idx];
    const lhs_y = ctx.cached_node_frame_y[lhs_idx];
    const lhs_w = ctx.cached_node_frame_width[lhs_idx];
    const lhs_h = ctx.cached_node_frame_height[lhs_idx];

    ctx.cached_node_frame_valid[lhs_idx] = rhs_valid;
    ctx.cached_node_frame_x[lhs_idx] = ctx.cached_node_frame_x[rhs_idx];
    ctx.cached_node_frame_y[lhs_idx] = ctx.cached_node_frame_y[rhs_idx];
    ctx.cached_node_frame_width[lhs_idx] = ctx.cached_node_frame_width[rhs_idx];
    ctx.cached_node_frame_height[lhs_idx] = ctx.cached_node_frame_height[rhs_idx];

    ctx.cached_node_frame_valid[rhs_idx] = lhs_valid;
    ctx.cached_node_frame_x[rhs_idx] = lhs_x;
    ctx.cached_node_frame_y[rhs_idx] = lhs_y;
    ctx.cached_node_frame_width[rhs_idx] = lhs_w;
    ctx.cached_node_frame_height[rhs_idx] = lhs_h;
}

fn createNodeIdFromCounter(counter: u64) abi.OmniUuid128 {
    var result = zeroUuid();
    var temp = counter;
    for (0..8) |idx| {
        result.bytes[idx] = @truncate(temp);
        temp >>= 8;
    }
    result.bytes[8] = 0x4F; // O
    result.bytes[9] = 0x4D; // M
    result.bytes[10] = 0x4E; // N
    result.bytes[11] = 0x49; // I
    result.bytes[12] = 0x44; // D
    result.bytes[13] = 0x57; // W
    result.bytes[14] = 0x4E; // N
    result.bytes[15] = 0x31; // 1
    return result;
}

fn nodeIdExists(ctx: *const OmniDwindleLayoutContext, node_id: abi.OmniUuid128) bool {
    for (0..ctx.node_count) |idx| {
        if (uuidEqual(ctx.nodes[idx].node_id, node_id)) return true;
    }
    return false;
}

fn nextGeneratedNodeId(ctx: *OmniDwindleLayoutContext) abi.OmniUuid128 {
    while (true) {
        const candidate = createNodeIdFromCounter(ctx.next_node_counter);
        ctx.next_node_counter += 1;
        if (!isZeroUuid(candidate) and !nodeIdExists(ctx, candidate)) return candidate;
    }
}

fn makeLeafNode(
    node_id: abi.OmniUuid128,
    parent_index: i64,
    has_window: bool,
    window_id: abi.OmniUuid128,
    is_fullscreen: bool,
) abi.OmniDwindleSeedNode {
    return .{
        .node_id = node_id,
        .parent_index = parent_index,
        .first_child_index = -1,
        .second_child_index = -1,
        .kind = abi.OMNI_DWINDLE_NODE_LEAF,
        .orientation = abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL,
        .ratio = DEFAULT_SPLIT_RATIO,
        .has_window_id = if (has_window) 1 else 0,
        .window_id = if (has_window) window_id else zeroUuid(),
        .is_fullscreen = if (is_fullscreen) 1 else 0,
    };
}

fn appendNode(
    ctx: *OmniDwindleLayoutContext,
    node: abi.OmniDwindleSeedNode,
    out_index: *usize,
) i32 {
    if (ctx.node_count >= abi.OMNI_DWINDLE_MAX_NODES) return abi.OMNI_ERR_OUT_OF_RANGE;
    const idx = ctx.node_count;
    ctx.nodes[idx] = node;
    ctx.cached_node_frame_valid[idx] = 0;
    ctx.cached_node_frame_x[idx] = 0.0;
    ctx.cached_node_frame_y[idx] = 0.0;
    ctx.cached_node_frame_width[idx] = 0.0;
    ctx.cached_node_frame_height[idx] = 0.0;
    out_index.* = idx;
    ctx.node_count += 1;
    return abi.OMNI_OK;
}

fn aspectOrientationForRect(rect: ?Rect, split_width_multiplier: f64) u8 {
    if (rect == null) return abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL;
    if (rect.?.height * split_width_multiplier > rect.?.width) {
        return abi.OMNI_DWINDLE_ORIENTATION_VERTICAL;
    }
    return abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL;
}

fn planSplitForAddWindow(
    target_rect: ?Rect,
    active_window_frame: ?Rect,
    runtime_settings: RuntimeSettings,
) SplitPlan {
    if (!runtime_settings.smart_split or target_rect == null or active_window_frame == null) {
        return .{
            .orientation = aspectOrientationForRect(target_rect, runtime_settings.split_width_multiplier),
            .new_first = false,
        };
    }

    const target = target_rect.?;
    const active = active_window_frame.?;
    const target_center_x = target.x + target.width / 2.0;
    const target_center_y = target.y + target.height / 2.0;
    const active_center_x = active.x + active.width / 2.0;
    const active_center_y = active.y + active.height / 2.0;

    const delta_x = active_center_x - target_center_x;
    const delta_y = active_center_y - target_center_y;

    const slope = if (@abs(delta_x) < 0.001)
        std.math.inf(f64)
    else
        delta_y / delta_x;
    const aspect = if (@abs(target.width) < 0.001)
        std.math.inf(f64)
    else
        target.height / target.width;

    if (@abs(slope) < aspect) {
        return .{
            .orientation = abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL,
            .new_first = delta_x < 0,
        };
    }

    return .{
        .orientation = abi.OMNI_DWINDLE_ORIENTATION_VERTICAL,
        .new_first = delta_y < 0,
    };
}

fn replaceNodeWithNode(
    ctx: *OmniDwindleLayoutContext,
    target_idx: usize,
    source_idx: usize,
) i32 {
    if (target_idx >= ctx.node_count or source_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const source = ctx.nodes[source_idx];
    var target = ctx.nodes[target_idx];
    target.kind = source.kind;
    target.orientation = source.orientation;
    target.ratio = source.ratio;
    target.has_window_id = source.has_window_id;
    target.window_id = source.window_id;
    target.is_fullscreen = source.is_fullscreen;
    target.first_child_index = source.first_child_index;
    target.second_child_index = source.second_child_index;
    ctx.nodes[target_idx] = target;

    if (target.kind == abi.OMNI_DWINDLE_NODE_SPLIT) {
        const first = childIndex(target.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const second = childIndex(target.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        ctx.nodes[first].parent_index = i64FromUsize(target_idx);
        ctx.nodes[second].parent_index = i64FromUsize(target_idx);
    }
    return abi.OMNI_OK;
}

fn compactContext(ctx: *OmniDwindleLayoutContext) i32 {
    if (ctx.node_count == 0) return abi.OMNI_OK;
    const old_root = rootIndex(ctx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const old_selected_raw = ctx.seed_state.selected_node_index;

    var old_to_new = [_]i64{-1} ** abi.OMNI_DWINDLE_MAX_NODES;
    var new_nodes: [abi.OMNI_DWINDLE_MAX_NODES]abi.OmniDwindleSeedNode = undefined;
    var new_cached_valid = [_]u8{0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var new_cached_x = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var new_cached_y = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var new_cached_width = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var new_cached_height = [_]f64{0.0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var stack = [_]usize{0} ** abi.OMNI_DWINDLE_MAX_NODES;
    var stack_len: usize = 0;
    var new_count: usize = 0;

    stack[0] = old_root;
    stack_len = 1;

    while (stack_len > 0) {
        stack_len -= 1;
        const idx = stack[stack_len];
        if (idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
        if (old_to_new[idx] != -1) continue;

        old_to_new[idx] = i64FromUsize(new_count);
        new_nodes[new_count] = ctx.nodes[idx];
        new_count += 1;

        const node = ctx.nodes[idx];
        if (!isSplitNode(node)) continue;
        const first = childIndex(node.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const second = childIndex(node.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (stack_len + 2 > abi.OMNI_DWINDLE_MAX_NODES) return abi.OMNI_ERR_OUT_OF_RANGE;
        stack[stack_len] = second;
        stack_len += 1;
        stack[stack_len] = first;
        stack_len += 1;
    }

    for (0..ctx.node_count) |old_idx| {
        const maybe_new = old_to_new[old_idx];
        if (maybe_new < 0) continue;
        const new_idx = std.math.cast(usize, maybe_new) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        var node = new_nodes[new_idx];

        new_cached_valid[new_idx] = ctx.cached_node_frame_valid[old_idx];
        new_cached_x[new_idx] = ctx.cached_node_frame_x[old_idx];
        new_cached_y[new_idx] = ctx.cached_node_frame_y[old_idx];
        new_cached_width[new_idx] = ctx.cached_node_frame_width[old_idx];
        new_cached_height[new_idx] = ctx.cached_node_frame_height[old_idx];

        if (node.parent_index >= 0) {
            const old_parent = std.math.cast(usize, node.parent_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (old_parent >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_parent = old_to_new[old_parent];
            if (new_parent < 0) return abi.OMNI_ERR_INVALID_ARGS;
            node.parent_index = new_parent;
        }
        if (node.first_child_index >= 0) {
            const old_first = std.math.cast(usize, node.first_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (old_first >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_first = old_to_new[old_first];
            if (new_first < 0) return abi.OMNI_ERR_INVALID_ARGS;
            node.first_child_index = new_first;
        }
        if (node.second_child_index >= 0) {
            const old_second = std.math.cast(usize, node.second_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (old_second >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_second = old_to_new[old_second];
            if (new_second < 0) return abi.OMNI_ERR_INVALID_ARGS;
            node.second_child_index = new_second;
        }
        new_nodes[new_idx] = node;
    }

    for (0..new_count) |idx| {
        ctx.nodes[idx] = new_nodes[idx];
    }
    ctx.cached_node_frame_valid = new_cached_valid;
    ctx.cached_node_frame_x = new_cached_x;
    ctx.cached_node_frame_y = new_cached_y;
    ctx.cached_node_frame_width = new_cached_width;
    ctx.cached_node_frame_height = new_cached_height;
    ctx.node_count = new_count;
    ctx.seed_state.root_node_index = old_to_new[old_root];

    if (old_selected_raw >= 0) {
        const old_selected = std.math.cast(usize, old_selected_raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (old_selected >= abi.OMNI_DWINDLE_MAX_NODES) return abi.OMNI_ERR_OUT_OF_RANGE;
        const new_selected = old_to_new[old_selected];
        if (new_selected >= 0) {
            ctx.seed_state.selected_node_index = new_selected;
        } else {
            ctx.seed_state.selected_node_index = -1;
        }
    } else {
        ctx.seed_state.selected_node_index = -1;
    }

    return abi.OMNI_OK;
}

fn selectedWindowId(ctx: *const OmniDwindleLayoutContext) ?abi.OmniUuid128 {
    const selected_idx = selectedIndex(ctx) orelse return null;
    const node = ctx.nodes[selected_idx];
    if (!isLeafNode(node) or node.has_window_id == 0) return null;
    return node.window_id;
}

fn syncOpResultFromState(
    ctx: *const OmniDwindleLayoutContext,
    out_result: [*c]abi.OmniDwindleOpResult,
    applied: bool,
    removed_count: usize,
) void {
    out_result[0].applied = if (applied) 1 else 0;
    out_result[0].removed_window_count = removed_count;

    if (selectedWindowId(ctx)) |selected_window| {
        out_result[0].has_selected_window_id = 1;
        out_result[0].selected_window_id = selected_window;
        out_result[0].has_focused_window_id = 1;
        out_result[0].focused_window_id = selected_window;
    }

    out_result[0].has_preselection = ctx.seed_state.has_preselection;
    out_result[0].preselection_direction = ctx.seed_state.preselection_direction;
}

fn removeLeafAtIndex(ctx: *OmniDwindleLayoutContext, leaf_idx: usize) i32 {
    if (leaf_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const leaf = ctx.nodes[leaf_idx];
    if (!isLeafNode(leaf)) return abi.OMNI_ERR_INVALID_ARGS;

    const parent_idx = childIndex(leaf.parent_index, ctx.node_count);

    var cleared = leaf;
    cleared.has_window_id = 0;
    cleared.window_id = zeroUuid();
    cleared.is_fullscreen = 0;
    ctx.nodes[leaf_idx] = cleared;

    if (parent_idx == null) return abi.OMNI_OK;

    const parent = ctx.nodes[parent_idx.?];
    if (!isSplitNode(parent)) return abi.OMNI_ERR_INVALID_ARGS;
    const first = childIndex(parent.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const second = childIndex(parent.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const sibling_idx = if (first == leaf_idx) second else if (second == leaf_idx) first else return abi.OMNI_ERR_INVALID_ARGS;

    var rc = replaceNodeWithNode(ctx, parent_idx.?, sibling_idx);
    if (rc != abi.OMNI_OK) return rc;
    rc = compactContext(ctx);
    if (rc != abi.OMNI_OK) return rc;
    return abi.OMNI_OK;
}

fn addWindowInternal(
    ctx: *OmniDwindleLayoutContext,
    window_id: abi.OmniUuid128,
    runtime_settings: RuntimeSettings,
    active_window_frame: ?Rect,
    out_applied: *bool,
) i32 {
    out_applied.* = false;
    if (findLeafByWindowId(ctx, window_id) != null) return abi.OMNI_OK;

    if (ctx.node_count == 0) {
        var root_leaf_index: usize = 0;
        const node = makeLeafNode(
            nextGeneratedNodeId(ctx),
            -1,
            true,
            window_id,
            false,
        );
        const rc = appendNode(ctx, node, &root_leaf_index);
        if (rc != abi.OMNI_OK) return rc;
        ctx.seed_state.root_node_index = i64FromUsize(root_leaf_index);
        setSelectedIndex(ctx, root_leaf_index);
        out_applied.* = true;
        return abi.OMNI_OK;
    }

    const root_idx = rootIndex(ctx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    var target_idx = selectedIndex(ctx);
    if (target_idx == null or !isLeafNode(ctx.nodes[target_idx.?])) {
        target_idx = descendantFirstLeaf(ctx, root_idx);
    }
    if (target_idx == null) return abi.OMNI_ERR_INVALID_ARGS;

    if (ctx.nodes[target_idx.?].has_window_id == 0) {
        ctx.nodes[target_idx.?].window_id = window_id;
        ctx.nodes[target_idx.?].has_window_id = 1;
        ctx.nodes[target_idx.?].is_fullscreen = 0;
        setSelectedIndex(ctx, target_idx.?);
        out_applied.* = true;
        return abi.OMNI_OK;
    }

    var orientation = abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL;
    var new_first = false;
    if (ctx.seed_state.has_preselection != 0) {
        const direction = ctx.seed_state.preselection_direction;
        orientation = switch (direction) {
            abi.OMNI_DWINDLE_DIRECTION_LEFT, abi.OMNI_DWINDLE_DIRECTION_RIGHT => abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL,
            abi.OMNI_DWINDLE_DIRECTION_UP, abi.OMNI_DWINDLE_DIRECTION_DOWN => abi.OMNI_DWINDLE_ORIENTATION_VERTICAL,
            else => abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL,
        };
        new_first = direction == abi.OMNI_DWINDLE_DIRECTION_LEFT or direction == abi.OMNI_DWINDLE_DIRECTION_UP;
    } else {
        const target_rect = cachedNodeFrameRect(ctx, target_idx.?);
        const split_plan = planSplitForAddWindow(target_rect, active_window_frame, runtime_settings);
        orientation = split_plan.orientation;
        new_first = split_plan.new_first;
    }

    const original = ctx.nodes[target_idx.?];
    var existing_leaf_idx: usize = 0;
    var new_leaf_idx: usize = 0;

    var rc = appendNode(
        ctx,
        makeLeafNode(
            nextGeneratedNodeId(ctx),
            i64FromUsize(target_idx.?),
            original.has_window_id != 0,
            original.window_id,
            original.is_fullscreen != 0,
        ),
        &existing_leaf_idx,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = appendNode(
        ctx,
        makeLeafNode(
            nextGeneratedNodeId(ctx),
            i64FromUsize(target_idx.?),
            true,
            window_id,
            false,
        ),
        &new_leaf_idx,
    );
    if (rc != abi.OMNI_OK) return rc;

    var split_node = ctx.nodes[target_idx.?];
    split_node.kind = abi.OMNI_DWINDLE_NODE_SPLIT;
    split_node.orientation = orientation;
    split_node.ratio = runtime_settings.default_split_ratio;
    split_node.has_window_id = 0;
    split_node.window_id = zeroUuid();
    split_node.is_fullscreen = 0;
    split_node.first_child_index = i64FromUsize(if (new_first) new_leaf_idx else existing_leaf_idx);
    split_node.second_child_index = i64FromUsize(if (new_first) existing_leaf_idx else new_leaf_idx);
    ctx.nodes[target_idx.?] = split_node;

    setSelectedIndex(ctx, new_leaf_idx);
    ctx.seed_state.has_preselection = 0;
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn cachedFrameRectForWindowId(
    ctx: *const OmniDwindleLayoutContext,
    window_id: abi.OmniUuid128,
) ?Rect {
    for (0..ctx.cached_frame_count) |idx| {
        const frame = ctx.cached_frames[idx];
        if (uuidEqual(frame.window_id, window_id)) {
            return frameToRect(frame);
        }
    }
    return null;
}

fn removeWindowInternal(ctx: *OmniDwindleLayoutContext, window_id: abi.OmniUuid128, out_applied: *bool) i32 {
    out_applied.* = false;
    const leaf_idx = findLeafByWindowId(ctx, window_id) orelse return abi.OMNI_OK;
    const selected_removed = if (selectedWindowId(ctx)) |selected_window|
        uuidEqual(selected_window, window_id)
    else
        false;
    var replacement_window: ?abi.OmniUuid128 = null;
    if (selected_removed) {
        const leaf = ctx.nodes[leaf_idx];
        if (childIndex(leaf.parent_index, ctx.node_count)) |parent_idx| {
            const parent = ctx.nodes[parent_idx];
            if (isSplitNode(parent)) {
                const first = childIndex(parent.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                const second = childIndex(parent.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                const sibling_idx = if (first == leaf_idx) second else if (second == leaf_idx) first else return abi.OMNI_ERR_INVALID_ARGS;
                if (findFirstLeafWithWindow(ctx, sibling_idx)) |replacement_idx| {
                    replacement_window = ctx.nodes[replacement_idx].window_id;
                }
            }
        }
    }

    const rc = removeLeafAtIndex(ctx, leaf_idx);
    if (rc != abi.OMNI_OK) return rc;
    removeCachedFrame(ctx, window_id);
    if (selected_removed) {
        if (replacement_window) |candidate| {
            if (findLeafByWindowId(ctx, candidate)) |replacement_idx| {
                setSelectedIndex(ctx, replacement_idx);
            } else {
                setSelectedIndex(ctx, null);
            }
        } else {
            setSelectedIndex(ctx, null);
        }
    }
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn computeSyncPlan(
    ctx: *const OmniDwindleLayoutContext,
    payload: abi.OmniDwindleSyncWindowsPayload,
    out_incoming: *[abi.MAX_WINDOWS]abi.OmniUuid128,
    out_incoming_count: *usize,
    out_removed: *[abi.MAX_WINDOWS]abi.OmniUuid128,
    out_removed_count: *usize,
) i32 {
    out_incoming_count.* = 0;
    out_removed_count.* = 0;

    for (0..payload.window_count) |idx| {
        const id = payload.window_ids[idx];
        if (isZeroUuid(id)) return abi.OMNI_ERR_INVALID_ARGS;
        if (uuidInSlice(out_incoming, out_incoming_count.*, id)) continue;
        out_incoming[out_incoming_count.*] = id;
        out_incoming_count.* += 1;
    }

    var current_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var current_count: usize = 0;
    const rc = collectWindowIdsInOrder(ctx, &current_ids, &current_count);
    if (rc != abi.OMNI_OK) return rc;

    for (0..current_count) |idx| {
        const id = current_ids[idx];
        if (!uuidInSlice(out_incoming, out_incoming_count.*, id)) {
            out_removed[out_removed_count.*] = id;
            out_removed_count.* += 1;
        }
    }

    return abi.OMNI_OK;
}

fn balanceSplitRatiosRecursive(
    ctx: *OmniDwindleLayoutContext,
    node_idx: usize,
    out_changed: *bool,
) i32 {
    if (node_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    var node = ctx.nodes[node_idx];
    if (!isSplitNode(node)) return abi.OMNI_OK;

    if (node.ratio != DEFAULT_SPLIT_RATIO) {
        node.ratio = DEFAULT_SPLIT_RATIO;
        ctx.nodes[node_idx] = node;
        out_changed.* = true;
    }

    const first = childIndex(node.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const second = childIndex(node.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

    var rc = balanceSplitRatiosRecursive(ctx, first, out_changed);
    if (rc != abi.OMNI_OK) return rc;
    rc = balanceSplitRatiosRecursive(ctx, second, out_changed);
    if (rc != abi.OMNI_OK) return rc;
    return abi.OMNI_OK;
}

fn nearestPresetIndex(ratio: f64) usize {
    var best_idx: usize = 0;
    var best_distance = @abs(CYCLE_PRESETS[0] - ratio);
    for (1..CYCLE_PRESETS.len) |idx| {
        const distance = @abs(CYCLE_PRESETS[idx] - ratio);
        if (distance < best_distance) {
            best_idx = idx;
            best_distance = distance;
        }
    }
    return best_idx;
}

fn normalizeSelection(ctx: *OmniDwindleLayoutContext) bool {
    const maybe_selected = selectedIndex(ctx);
    if (maybe_selected) |idx| {
        const node = ctx.nodes[idx];
        if (isLeafNode(node) and node.has_window_id != 0) return false;
    }

    const root_idx = rootIndex(ctx) orelse {
        setSelectedIndex(ctx, null);
        return maybe_selected != null;
    };
    if (findFirstLeafWithWindow(ctx, root_idx)) |leaf_idx| {
        const changed = maybe_selected == null or maybe_selected.? != leaf_idx;
        setSelectedIndex(ctx, leaf_idx);
        return changed;
    }

    const fallback_leaf = descendantFirstLeaf(ctx, root_idx) orelse root_idx;
    const changed = maybe_selected == null or maybe_selected.? != fallback_leaf;
    setSelectedIndex(ctx, fallback_leaf);
    return changed;
}

fn moveFocusInternal(ctx: *OmniDwindleLayoutContext, direction: u8, inner_gap: f64) i32 {
    const root_idx = rootIndex(ctx) orelse return abi.OMNI_OK;

    var current_idx = selectedIndex(ctx);
    if (current_idx == null or !isLeafNode(ctx.nodes[current_idx.?]) or ctx.nodes[current_idx.?].has_window_id == 0) {
        const fallback_leaf = descendantFirstLeaf(ctx, root_idx) orelse return abi.OMNI_OK;
        setSelectedIndex(ctx, fallback_leaf);
        current_idx = fallback_leaf;
    }

    const current = ctx.nodes[current_idx.?];
    if (current.has_window_id == 0) return abi.OMNI_OK;

    const neighbor_id = resolveNeighborWindowId(
        ctx,
        current.window_id,
        direction,
        inner_gap,
    ) orelse return abi.OMNI_OK;

    const neighbor_leaf = findLeafByWindowId(ctx, neighbor_id) orelse return abi.OMNI_OK;
    setSelectedIndex(ctx, neighbor_leaf);
    return abi.OMNI_OK;
}

fn swapWindowsInternal(
    ctx: *OmniDwindleLayoutContext,
    direction: u8,
    inner_gap: f64,
    out_applied: *bool,
) i32 {
    out_applied.* = false;
    const selected_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (selected_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const selected = ctx.nodes[selected_idx];
    if (!isLeafNode(selected) or selected.has_window_id == 0) return abi.OMNI_OK;

    const neighbor_id = resolveNeighborWindowId(
        ctx,
        selected.window_id,
        direction,
        inner_gap,
    ) orelse return abi.OMNI_OK;
    const neighbor_idx = findLeafByWindowId(ctx, neighbor_id) orelse return abi.OMNI_OK;
    if (neighbor_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var lhs = ctx.nodes[selected_idx];
    var rhs = ctx.nodes[neighbor_idx];
    if (!isLeafNode(rhs) or rhs.has_window_id == 0) return abi.OMNI_OK;

    const lhs_window = lhs.window_id;
    const lhs_has = lhs.has_window_id;
    const lhs_fullscreen = lhs.is_fullscreen;

    lhs.window_id = rhs.window_id;
    lhs.has_window_id = rhs.has_window_id;
    lhs.is_fullscreen = rhs.is_fullscreen;

    rhs.window_id = lhs_window;
    rhs.has_window_id = lhs_has;
    rhs.is_fullscreen = lhs_fullscreen;

    ctx.nodes[selected_idx] = lhs;
    ctx.nodes[neighbor_idx] = rhs;
    swapCachedNodeFrames(ctx, selected_idx, neighbor_idx);
    setSelectedIndex(ctx, neighbor_idx);
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn toggleFullscreenInternal(ctx: *OmniDwindleLayoutContext, out_applied: *bool) i32 {
    out_applied.* = false;
    const selected_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (selected_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    var selected = ctx.nodes[selected_idx];
    if (!isLeafNode(selected)) return abi.OMNI_OK;
    selected.is_fullscreen = if (selected.is_fullscreen == 0) 1 else 0;
    ctx.nodes[selected_idx] = selected;
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn toggleOrientationInternal(ctx: *OmniDwindleLayoutContext, out_applied: *bool) i32 {
    out_applied.* = false;
    const selected_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (selected_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const parent_idx = childIndex(ctx.nodes[selected_idx].parent_index, ctx.node_count) orelse return abi.OMNI_OK;
    var parent = ctx.nodes[parent_idx];
    if (!isSplitNode(parent)) return abi.OMNI_OK;
    parent.orientation = if (parent.orientation == abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL)
        abi.OMNI_DWINDLE_ORIENTATION_VERTICAL
    else
        abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL;
    ctx.nodes[parent_idx] = parent;
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn resizeSelectedInternal(
    ctx: *OmniDwindleLayoutContext,
    delta: f64,
    direction: u8,
    out_applied: *bool,
) i32 {
    out_applied.* = false;
    var current_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (current_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    const target_orientation = if (direction == abi.OMNI_DWINDLE_DIRECTION_LEFT or direction == abi.OMNI_DWINDLE_DIRECTION_RIGHT)
        abi.OMNI_DWINDLE_ORIENTATION_HORIZONTAL
    else
        abi.OMNI_DWINDLE_ORIENTATION_VERTICAL;
    const increase_first = !(direction == abi.OMNI_DWINDLE_DIRECTION_RIGHT or direction == abi.OMNI_DWINDLE_DIRECTION_UP);

    while (true) {
        const parent_idx = childIndex(ctx.nodes[current_idx].parent_index, ctx.node_count) orelse break;
        var parent = ctx.nodes[parent_idx];
        if (!isSplitNode(parent)) {
            current_idx = parent_idx;
            continue;
        }

        if (parent.orientation == target_orientation) {
            const first = childIndex(parent.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const is_first = first == current_idx;
            var new_ratio = parent.ratio;

            if ((is_first and increase_first) or (!is_first and !increase_first)) {
                new_ratio += delta;
            } else {
                new_ratio -= delta;
            }

            parent.ratio = @min(@max(new_ratio, MIN_RATIO), MAX_RATIO);
            ctx.nodes[parent_idx] = parent;
            out_applied.* = true;
            return abi.OMNI_OK;
        }

        current_idx = parent_idx;
    }

    return abi.OMNI_OK;
}

fn balanceSizesInternal(ctx: *OmniDwindleLayoutContext, out_applied: *bool) i32 {
    out_applied.* = false;
    const root_idx = rootIndex(ctx) orelse return abi.OMNI_OK;
    return balanceSplitRatiosRecursive(ctx, root_idx, out_applied);
}

fn cycleSplitRatioInternal(ctx: *OmniDwindleLayoutContext, forward: bool, out_applied: *bool) i32 {
    out_applied.* = false;
    const selected_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (selected_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const parent_idx = childIndex(ctx.nodes[selected_idx].parent_index, ctx.node_count) orelse return abi.OMNI_OK;
    var parent = ctx.nodes[parent_idx];
    if (!isSplitNode(parent)) return abi.OMNI_OK;

    const current_idx = nearestPresetIndex(parent.ratio);
    const next_idx = if (forward)
        (current_idx + 1) % CYCLE_PRESETS.len
    else
        (current_idx + CYCLE_PRESETS.len - 1) % CYCLE_PRESETS.len;
    parent.ratio = CYCLE_PRESETS[next_idx];
    ctx.nodes[parent_idx] = parent;
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn moveSelectionToRootInternal(ctx: *OmniDwindleLayoutContext, stable: bool, out_applied: *bool) i32 {
    out_applied.* = false;
    var selected_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (selected_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const root_idx = rootIndex(ctx) orelse return abi.OMNI_OK;

    if (!isLeafNode(ctx.nodes[selected_idx])) {
        selected_idx = descendantFirstLeaf(ctx, selected_idx) orelse return abi.OMNI_OK;
    }
    if (selected_idx == root_idx) return abi.OMNI_OK;

    const leaf_parent_idx = childIndex(ctx.nodes[selected_idx].parent_index, ctx.node_count) orelse return abi.OMNI_OK;
    if (leaf_parent_idx == root_idx) return abi.OMNI_OK;

    var ancestor_idx = leaf_parent_idx;
    while (true) {
        const parent_idx = childIndex(ctx.nodes[ancestor_idx].parent_index, ctx.node_count) orelse break;
        if (parent_idx == root_idx) break;
        ancestor_idx = parent_idx;
    }
    const ancestor_parent_idx = childIndex(ctx.nodes[ancestor_idx].parent_index, ctx.node_count) orelse return abi.OMNI_OK;
    if (ancestor_parent_idx != root_idx) return abi.OMNI_OK;

    const root = ctx.nodes[root_idx];
    if (!isSplitNode(root)) return abi.OMNI_OK;
    const root_first = childIndex(root.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const root_second = childIndex(root.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const ancestor_is_first = root_first == ancestor_idx;
    const swap_node_idx = if (ancestor_is_first) root_second else root_first;

    const leaf_parent = ctx.nodes[leaf_parent_idx];
    if (!isSplitNode(leaf_parent)) return abi.OMNI_ERR_INVALID_ARGS;
    const leaf_parent_first = childIndex(leaf_parent.first_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const leaf_parent_second = childIndex(leaf_parent.second_child_index, ctx.node_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const leaf_is_first = leaf_parent_first == selected_idx;
    const leaf_sibling_idx = if (leaf_is_first) leaf_parent_second else leaf_parent_first;

    var updated_leaf_parent = leaf_parent;
    if (leaf_is_first) {
        updated_leaf_parent.first_child_index = i64FromUsize(swap_node_idx);
        updated_leaf_parent.second_child_index = i64FromUsize(leaf_sibling_idx);
    } else {
        updated_leaf_parent.first_child_index = i64FromUsize(leaf_sibling_idx);
        updated_leaf_parent.second_child_index = i64FromUsize(swap_node_idx);
    }
    ctx.nodes[leaf_parent_idx] = updated_leaf_parent;

    ctx.nodes[swap_node_idx].parent_index = i64FromUsize(leaf_parent_idx);
    ctx.nodes[selected_idx].parent_index = i64FromUsize(root_idx);

    var updated_root = root;
    if (ancestor_is_first) {
        updated_root.first_child_index = i64FromUsize(ancestor_idx);
        updated_root.second_child_index = i64FromUsize(selected_idx);
    } else {
        updated_root.first_child_index = i64FromUsize(selected_idx);
        updated_root.second_child_index = i64FromUsize(ancestor_idx);
    }

    if (stable) {
        const old_first = updated_root.first_child_index;
        updated_root.first_child_index = updated_root.second_child_index;
        updated_root.second_child_index = old_first;
    }

    ctx.nodes[root_idx] = updated_root;
    setSelectedIndex(ctx, selected_idx);
    out_applied.* = true;
    return abi.OMNI_OK;
}

fn swapSplitInternal(ctx: *OmniDwindleLayoutContext, out_applied: *bool) i32 {
    out_applied.* = false;
    const selected_idx = selectedIndex(ctx) orelse return abi.OMNI_OK;
    if (selected_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    const parent_idx = childIndex(ctx.nodes[selected_idx].parent_index, ctx.node_count) orelse return abi.OMNI_OK;
    var parent = ctx.nodes[parent_idx];
    if (!isSplitNode(parent)) return abi.OMNI_OK;
    const first = parent.first_child_index;
    parent.first_child_index = parent.second_child_index;
    parent.second_child_index = first;
    ctx.nodes[parent_idx] = parent;
    out_applied.* = true;
    return abi.OMNI_OK;
}


pub fn omni_dwindle_layout_context_create_impl() [*c]OmniDwindleLayoutContext {
    const ctx = std.heap.c_allocator.create(OmniDwindleLayoutContext) catch return null;
    ctx.* = undefined;
    resetContext(ctx);
    return @ptrCast(ctx);
}

pub fn omni_dwindle_layout_context_destroy_impl(context: [*c]OmniDwindleLayoutContext) void {
    const ctx = asMutableContext(context) orelse return;
    std.heap.c_allocator.destroy(ctx);
}

pub fn omni_dwindle_ctx_seed_state_impl(
    context: [*c]OmniDwindleLayoutContext,
    nodes: [*c]const abi.OmniDwindleSeedNode,
    node_count: usize,
    seed_state: [*c]const abi.OmniDwindleSeedState,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (seed_state == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (node_count > abi.OMNI_DWINDLE_MAX_NODES) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (node_count > 0 and nodes == null) return abi.OMNI_ERR_INVALID_ARGS;

    if (!isFlag(seed_state[0].has_preselection)) return abi.OMNI_ERR_INVALID_ARGS;
    if (seed_state[0].has_preselection != 0 and !isValidDirection(seed_state[0].preselection_direction)) {
        return abi.OMNI_ERR_INVALID_ARGS;
    }

    if (node_count == 0) {
        if (seed_state[0].root_node_index != -1 or seed_state[0].selected_node_index != -1) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }
        resetContext(ctx);
        ctx.seed_state = seed_state[0];
        ctx.next_node_counter = 1;
        return abi.OMNI_OK;
    }

    var root_idx: ?usize = null;
    var selected_idx: ?usize = null;
    var rc = parseOptionalIndex(seed_state[0].root_node_index, node_count, &root_idx);
    if (rc != abi.OMNI_OK) return rc;
    rc = parseOptionalIndex(seed_state[0].selected_node_index, node_count, &selected_idx);
    if (rc != abi.OMNI_OK) return rc;
    if (root_idx == null) return abi.OMNI_ERR_OUT_OF_RANGE;

    for (0..node_count) |idx| {
        const node = nodes[idx];
        if (!isValidNodeKind(node.kind)) return abi.OMNI_ERR_INVALID_ARGS;
        if (!isValidOrientation(node.orientation)) return abi.OMNI_ERR_INVALID_ARGS;
        if (!isFlag(node.has_window_id) or !isFlag(node.is_fullscreen)) return abi.OMNI_ERR_INVALID_ARGS;
        if (!std.math.isFinite(node.ratio)) return abi.OMNI_ERR_INVALID_ARGS;
        if (node.ratio < MIN_RATIO or node.ratio > MAX_RATIO) return abi.OMNI_ERR_OUT_OF_RANGE;

        var parent_idx: ?usize = null;
        var first_child_idx: ?usize = null;
        var second_child_idx: ?usize = null;

        rc = parseOptionalIndex(node.parent_index, node_count, &parent_idx);
        if (rc != abi.OMNI_OK) return rc;
        rc = parseOptionalIndex(node.first_child_index, node_count, &first_child_idx);
        if (rc != abi.OMNI_OK) return rc;
        rc = parseOptionalIndex(node.second_child_index, node_count, &second_child_idx);
        if (rc != abi.OMNI_OK) return rc;

        if (parent_idx != null and parent_idx.? == idx) return abi.OMNI_ERR_INVALID_ARGS;
        if (first_child_idx != null and first_child_idx.? == idx) return abi.OMNI_ERR_INVALID_ARGS;
        if (second_child_idx != null and second_child_idx.? == idx) return abi.OMNI_ERR_INVALID_ARGS;

        switch (node.kind) {
            abi.OMNI_DWINDLE_NODE_SPLIT => {
                if (first_child_idx == null or second_child_idx == null) return abi.OMNI_ERR_INVALID_ARGS;
                if (first_child_idx.? == second_child_idx.?) return abi.OMNI_ERR_INVALID_ARGS;
                if (node.has_window_id != 0 or node.is_fullscreen != 0) return abi.OMNI_ERR_INVALID_ARGS;
            },
            abi.OMNI_DWINDLE_NODE_LEAF => {
                if (first_child_idx != null or second_child_idx != null) return abi.OMNI_ERR_INVALID_ARGS;
                if (node.has_window_id == 0 and node.is_fullscreen != 0) return abi.OMNI_ERR_INVALID_ARGS;
            },
            else => return abi.OMNI_ERR_INVALID_ARGS,
        }
    }

    for (0..node_count) |idx| {
        const node = nodes[idx];
        var parent_idx: ?usize = null;
        rc = parseOptionalIndex(node.parent_index, node_count, &parent_idx);
        if (rc != abi.OMNI_OK) return rc;

        if (parent_idx) |parent| {
            const parent_node = nodes[parent];
            if (parent_node.kind != abi.OMNI_DWINDLE_NODE_SPLIT) return abi.OMNI_ERR_INVALID_ARGS;
            const idx_i64 = std.math.cast(i64, idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const matches_first = parent_node.first_child_index == idx_i64;
            const matches_second = parent_node.second_child_index == idx_i64;
            if (!matches_first and !matches_second) return abi.OMNI_ERR_INVALID_ARGS;
        }

        if (node.kind == abi.OMNI_DWINDLE_NODE_SPLIT) {
            const first = std.math.cast(usize, node.first_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const second = std.math.cast(usize, node.second_child_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const idx_i64 = std.math.cast(i64, idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (nodes[first].parent_index != idx_i64) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }
            if (nodes[second].parent_index != idx_i64) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }
        }
    }

    const root = root_idx.?;
    if (nodes[root].parent_index != -1) return abi.OMNI_ERR_INVALID_ARGS;

    rc = validateNodeIdUniqueness(nodes, node_count);
    if (rc != abi.OMNI_OK) return rc;
    rc = validateWindowIdUniqueness(nodes, node_count);
    if (rc != abi.OMNI_OK) return rc;
    rc = validateAcyclicParentChain(nodes, node_count);
    if (rc != abi.OMNI_OK) return rc;
    rc = validateReachabilityFromRoot(nodes, node_count, root);
    if (rc != abi.OMNI_OK) return rc;

    if (selected_idx) |selected| {
        if (selected >= node_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    ctx.node_count = node_count;
    for (0..node_count) |idx| {
        ctx.nodes[idx] = nodes[idx];
    }
    ctx.seed_state = seed_state[0];
    ctx.cached_frame_count = 0;
    clearCachedNodeFrames(ctx);
    ctx.next_node_counter = std.math.cast(u64, node_count + 1) orelse 1;

    return abi.OMNI_OK;
}

pub fn omni_dwindle_ctx_apply_op_impl(
    context: [*c]OmniDwindleLayoutContext,
    request: [*c]const abi.OmniDwindleOpRequest,
    out_result: [*c]abi.OmniDwindleOpResult,
    out_removed_window_ids: [*c]abi.OmniUuid128,
    out_removed_window_capacity: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (request == null or out_result == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (out_removed_window_capacity > 0 and out_removed_window_ids == null) return abi.OMNI_ERR_INVALID_ARGS;

    initOpResult(out_result);

    const op = request[0].op;
    if (!isValidOp(op)) return abi.OMNI_ERR_INVALID_ARGS;
    const runtime_settings_raw = request[0].runtime_settings;
    if (!isFlag(runtime_settings_raw.smart_split) or
        !std.math.isFinite(runtime_settings_raw.default_split_ratio) or
        !isFiniteNonNegative(runtime_settings_raw.split_width_multiplier) or
        !isFiniteNonNegative(runtime_settings_raw.inner_gap))
    {
        return abi.OMNI_ERR_INVALID_ARGS;
    }
    const runtime_settings = decodeRuntimeSettings(runtime_settings_raw);

    switch (op) {
        abi.OMNI_DWINDLE_OP_ADD_WINDOW => {
            const payload = request[0].payload.add_window;
            if (isZeroUuid(payload.window_id)) return abi.OMNI_ERR_INVALID_ARGS;
            if (!isFlag(payload.has_active_window_frame)) return abi.OMNI_ERR_INVALID_ARGS;
            if (payload.has_active_window_frame != 0) {
                const frame = payload.active_window_frame;
                if (!std.math.isFinite(frame.x) or
                    !std.math.isFinite(frame.y) or
                    !isFiniteNonNegative(frame.width) or
                    !isFiniteNonNegative(frame.height))
                {
                    return abi.OMNI_ERR_INVALID_ARGS;
                }
            }
        },
        abi.OMNI_DWINDLE_OP_REMOVE_WINDOW => {
            if (isZeroUuid(request[0].payload.remove_window.window_id)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_SYNC_WINDOWS => {
            const payload = request[0].payload.sync_windows;
            if (payload.window_count > abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
            if (payload.window_count > 0 and payload.window_ids == null) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_MOVE_FOCUS => {
            if (!isValidDirection(request[0].payload.move_focus.direction)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_SWAP_WINDOWS => {
            if (!isValidDirection(request[0].payload.swap_windows.direction)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_RESIZE_SELECTED => {
            const payload = request[0].payload.resize_selected;
            if (!isValidDirection(payload.direction)) return abi.OMNI_ERR_INVALID_ARGS;
            if (!std.math.isFinite(payload.delta)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO => {
            if (!isFlag(request[0].payload.cycle_split_ratio.forward)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT => {
            if (!isFlag(request[0].payload.move_selection_to_root.stable)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_SET_PRESELECTION => {
            if (!isValidDirection(request[0].payload.set_preselection.direction)) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN,
        abi.OMNI_DWINDLE_OP_TOGGLE_ORIENTATION,
        abi.OMNI_DWINDLE_OP_BALANCE_SIZES,
        abi.OMNI_DWINDLE_OP_SWAP_SPLIT,
        abi.OMNI_DWINDLE_OP_CLEAR_PRESELECTION,
        abi.OMNI_DWINDLE_OP_VALIDATE_SELECTION,
        => {},
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    var removed_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var removed_count: usize = 0;
    var applied = false;

    if (op == abi.OMNI_DWINDLE_OP_REMOVE_WINDOW) {
        if (findLeafByWindowId(ctx, request[0].payload.remove_window.window_id) != null) {
            removed_ids[0] = request[0].payload.remove_window.window_id;
            removed_count = 1;
        }
        if (removed_count > out_removed_window_capacity) return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    var sync_incoming = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var sync_incoming_count: usize = 0;
    if (op == abi.OMNI_DWINDLE_OP_SYNC_WINDOWS) {
        const payload = request[0].payload.sync_windows;
        const rc = computeSyncPlan(
            ctx,
            payload,
            &sync_incoming,
            &sync_incoming_count,
            &removed_ids,
            &removed_count,
        );
        if (rc != abi.OMNI_OK) return rc;
        if (removed_count > out_removed_window_capacity) return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    switch (op) {
        abi.OMNI_DWINDLE_OP_ADD_WINDOW => {
            var did_apply = false;
            const payload = request[0].payload.add_window;
            const active_window_frame: ?Rect = if (payload.has_active_window_frame != 0)
                abiRectToRect(payload.active_window_frame)
            else
                null;
            const rc = addWindowInternal(
                ctx,
                payload.window_id,
                runtime_settings,
                active_window_frame,
                &did_apply,
            );
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_REMOVE_WINDOW => {
            var did_apply = false;
            const rc = removeWindowInternal(ctx, request[0].payload.remove_window.window_id, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_SYNC_WINDOWS => {
            for (0..removed_count) |idx| {
                var did_remove = false;
                const rc = removeWindowInternal(ctx, removed_ids[idx], &did_remove);
                if (rc != abi.OMNI_OK) return rc;
                if (did_remove) applied = true;
            }

            for (0..sync_incoming_count) |idx| {
                var did_add = false;
                const rc = addWindowInternal(
                    ctx,
                    sync_incoming[idx],
                    runtime_settings,
                    null,
                    &did_add,
                );
                if (rc != abi.OMNI_OK) return rc;
                if (did_add) applied = true;
            }
        },
        abi.OMNI_DWINDLE_OP_MOVE_FOCUS => {
            const before = selectedIndex(ctx);
            const rc = moveFocusInternal(ctx, request[0].payload.move_focus.direction, runtime_settings.inner_gap);
            if (rc != abi.OMNI_OK) return rc;
            const after = selectedIndex(ctx);
            applied = before == null and after != null or before != null and after == null or (before != null and after != null and before.? != after.?);
        },
        abi.OMNI_DWINDLE_OP_SWAP_WINDOWS => {
            var did_apply = false;
            const rc = swapWindowsInternal(
                ctx,
                request[0].payload.swap_windows.direction,
                runtime_settings.inner_gap,
                &did_apply,
            );
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN => {
            var did_apply = false;
            const rc = toggleFullscreenInternal(ctx, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_TOGGLE_ORIENTATION => {
            var did_apply = false;
            const rc = toggleOrientationInternal(ctx, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_RESIZE_SELECTED => {
            var did_apply = false;
            const payload = request[0].payload.resize_selected;
            const rc = resizeSelectedInternal(ctx, payload.delta, payload.direction, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_BALANCE_SIZES => {
            var did_apply = false;
            const rc = balanceSizesInternal(ctx, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO => {
            var did_apply = false;
            const rc = cycleSplitRatioInternal(ctx, request[0].payload.cycle_split_ratio.forward != 0, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT => {
            var did_apply = false;
            const rc = moveSelectionToRootInternal(ctx, request[0].payload.move_selection_to_root.stable != 0, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_SWAP_SPLIT => {
            var did_apply = false;
            const rc = swapSplitInternal(ctx, &did_apply);
            if (rc != abi.OMNI_OK) return rc;
            applied = did_apply;
        },
        abi.OMNI_DWINDLE_OP_SET_PRESELECTION => {
            ctx.seed_state.has_preselection = 1;
            ctx.seed_state.preselection_direction = request[0].payload.set_preselection.direction;
            applied = true;
        },
        abi.OMNI_DWINDLE_OP_CLEAR_PRESELECTION => {
            const had_preselection = ctx.seed_state.has_preselection != 0;
            ctx.seed_state.has_preselection = 0;
            applied = had_preselection;
        },
        abi.OMNI_DWINDLE_OP_VALIDATE_SELECTION => {
            applied = normalizeSelection(ctx);
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    if (out_removed_window_ids != null and removed_count > 0) {
        for (0..removed_count) |idx| {
            out_removed_window_ids[idx] = removed_ids[idx];
        }
    }

    syncOpResultFromState(ctx, out_result, applied, removed_count);
    return abi.OMNI_OK;
}

pub fn omni_dwindle_ctx_calculate_layout_impl(
    context: [*c]OmniDwindleLayoutContext,
    request: [*c]const abi.OmniDwindleLayoutRequest,
    constraints: [*c]const abi.OmniDwindleWindowConstraint,
    constraint_count: usize,
    out_frames: [*c]abi.OmniDwindleWindowFrame,
    out_frame_capacity: usize,
    out_frame_count: [*c]usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (request == null or out_frame_count == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (constraint_count > abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (constraint_count > 0 and constraints == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (out_frame_capacity > abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (out_frame_capacity > 0 and out_frames == null) return abi.OMNI_ERR_INVALID_ARGS;

    const req = request[0];
    if (!std.math.isFinite(req.screen_x) or
        !std.math.isFinite(req.screen_y) or
        !isFiniteNonNegative(req.screen_width) or
        !isFiniteNonNegative(req.screen_height) or
        !isFiniteNonNegative(req.inner_gap) or
        !isFiniteNonNegative(req.outer_gap_top) or
        !isFiniteNonNegative(req.outer_gap_bottom) or
        !isFiniteNonNegative(req.outer_gap_left) or
        !isFiniteNonNegative(req.outer_gap_right) or
        !isFiniteNonNegative(req.single_window_aspect_width) or
        !isFiniteNonNegative(req.single_window_aspect_height) or
        !isFiniteNonNegative(req.single_window_aspect_tolerance) or
        !isFlag(req.runtime_settings.smart_split) or
        !std.math.isFinite(req.runtime_settings.default_split_ratio) or
        !isFiniteNonNegative(req.runtime_settings.split_width_multiplier) or
        !isFiniteNonNegative(req.runtime_settings.inner_gap))
    {
        return abi.OMNI_ERR_INVALID_ARGS;
    }

    var rc = validateConstraints(constraints, constraint_count);
    if (rc != abi.OMNI_OK) return rc;

    out_frame_count[0] = 0;

    if (ctx.node_count == 0) {
        ctx.cached_frame_count = 0;
        clearCachedNodeFrames(ctx);
        return abi.OMNI_OK;
    }

    if (ctx.seed_state.root_node_index < 0) return abi.OMNI_ERR_OUT_OF_RANGE;
    const root_idx = std.math.cast(usize, ctx.seed_state.root_node_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    if (root_idx >= ctx.node_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var scratch = LayoutScratch{
        .frame_count = 0,
        .frames = undefined,
        .has_min_size = [_]u8{0} ** abi.OMNI_DWINDLE_MAX_NODES,
        .min_sizes = undefined,
    };

    const screen = Rect{
        .x = req.screen_x,
        .y = req.screen_y,
        .width = req.screen_width,
        .height = req.screen_height,
    };
    const tiling_area = applyOuterGapsOnly(screen, req);

    var window_count: usize = 0;
    rc = countWindowLeaves(ctx, root_idx, &window_count);
    if (rc != abi.OMNI_OK) return rc;

    if (window_count == 0) {
        ctx.cached_frame_count = 0;
        return abi.OMNI_OK;
    }

    if (window_count > abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;

    if (window_count == 1) {
        const leaf_idx = findSingleWindowLeaf(ctx, root_idx) orelse return abi.OMNI_ERR_INVALID_ARGS;
        const leaf = ctx.nodes[leaf_idx];
        const target = if (leaf.is_fullscreen != 0)
            screen
        else
            singleWindowRect(tiling_area, req);
        setCachedNodeFrame(ctx, leaf_idx, target);
        rc = appendFrame(&scratch, leaf.window_id, target);
        if (rc != abi.OMNI_OK) return rc;
    } else {
        rc = layoutRecursive(
            ctx,
            constraints,
            constraint_count,
            req,
            &scratch,
            root_idx,
            tiling_area,
            tiling_area,
        );
        if (rc != abi.OMNI_OK) return rc;
    }

    out_frame_count[0] = scratch.frame_count;

    if (out_frame_capacity < scratch.frame_count) {
        ctx.cached_frame_count = 0;
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    if (out_frames != null and scratch.frame_count > 0) {
        for (0..scratch.frame_count) |idx| {
            out_frames[idx] = scratch.frames[idx];
        }
    }

    ctx.cached_frame_count = scratch.frame_count;
    for (0..scratch.frame_count) |idx| {
        ctx.cached_frames[idx] = scratch.frames[idx];
    }
    return abi.OMNI_OK;
}

pub fn omni_dwindle_ctx_find_neighbor_impl(
    context: [*c]const OmniDwindleLayoutContext,
    window_id: abi.OmniUuid128,
    direction: u8,
    inner_gap: f64,
    out_has_neighbor: [*c]u8,
    out_neighbor_window_id: [*c]abi.OmniUuid128,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (out_has_neighbor == null or out_neighbor_window_id == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (!isValidDirection(direction)) return abi.OMNI_ERR_INVALID_ARGS;
    if (!isFiniteNonNegative(inner_gap)) return abi.OMNI_ERR_INVALID_ARGS;
    if (isZeroUuid(window_id)) return abi.OMNI_ERR_INVALID_ARGS;

    out_has_neighbor[0] = 0;
    out_neighbor_window_id[0] = zeroUuid();

    if (ctx.cached_frame_count > abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (resolveNeighborWindowId(ctx, window_id, direction, inner_gap)) |neighbor| {
        out_has_neighbor[0] = 1;
        out_neighbor_window_id[0] = neighbor;
    }
    return abi.OMNI_OK;
}
