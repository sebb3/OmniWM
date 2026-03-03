#pragma once
#include <stddef.h>
#include <stdint.h>

/// Input descriptor for one window on a single axis.
/// Zig struct OmniAxisInput must match this layout exactly.
typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    double fixed_value; // ignored when has_fixed_value == 0
} OmniAxisInput;

/// Result for one window on a single axis.
typedef struct {
    double value;
    uint8_t was_constrained;
} OmniAxisOutput;

typedef enum {
    OMNI_CENTER_NEVER = 0,
    OMNI_CENTER_ALWAYS = 1,
    OMNI_CENTER_ON_OVERFLOW = 2
} OmniCenterMode;

typedef struct {
    double view_pos;
    size_t column_index;
} OmniSnapResult;

typedef enum {
    OMNI_NIRI_ORIENTATION_HORIZONTAL = 0,
    OMNI_NIRI_ORIENTATION_VERTICAL = 1
} OmniNiriOrientation;

typedef enum {
    OMNI_NIRI_SIZING_NORMAL = 0,
    OMNI_NIRI_SIZING_FULLSCREEN = 1
} OmniNiriSizingMode;

typedef enum {
    OMNI_NIRI_HIDE_NONE = 0,
    OMNI_NIRI_HIDE_LEFT = 1,
    OMNI_NIRI_HIDE_RIGHT = 2
} OmniNiriHideSide;

typedef struct {
    double span;
    double render_offset_x;
    double render_offset_y;
    uint8_t is_tabbed;
    double tab_indicator_width;
    size_t window_start;
    size_t window_count;
} OmniNiriColumnInput;

typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    double fixed_value;
    uint8_t sizing_mode;
    double render_offset_x;
    double render_offset_y;
} OmniNiriWindowInput;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    double animated_x;
    double animated_y;
    double animated_width;
    double animated_height;
    double resolved_span;
    uint8_t was_constrained;
    uint8_t hide_side;
    size_t column_index;
} OmniNiriWindowOutput;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t hide_side;
    uint8_t is_visible;
} OmniNiriColumnOutput;

typedef enum {
    OMNI_NIRI_RESIZE_EDGE_TOP = 0b0001,
    OMNI_NIRI_RESIZE_EDGE_BOTTOM = 0b0010,
    OMNI_NIRI_RESIZE_EDGE_LEFT = 0b0100,
    OMNI_NIRI_RESIZE_EDGE_RIGHT = 0b1000
} OmniNiriResizeEdge;

typedef struct {
    size_t window_index;
    size_t column_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t is_fullscreen;
} OmniNiriHitTestWindow;

typedef struct {
    int64_t window_index;
    uint8_t edges;
} OmniNiriResizeHitResult;

typedef enum {
    OMNI_NIRI_INSERT_BEFORE = 0,
    OMNI_NIRI_INSERT_AFTER = 1,
    OMNI_NIRI_INSERT_SWAP = 2
} OmniNiriInsertPosition;

typedef struct {
    int64_t window_index;
    uint8_t insert_position;
} OmniNiriMoveTargetResult;

typedef struct {
    double target_frame_x;
    double target_frame_y;
    double target_frame_width;
    double target_frame_height;
    double column_min_y;
    double column_max_y;
    double gap;
    uint8_t insert_position;
    size_t post_insertion_count;
} OmniNiriDropzoneInput;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t is_valid;
} OmniNiriDropzoneResult;

typedef struct {
    uint8_t edges;
    double start_x;
    double start_y;
    double current_x;
    double current_y;
    double original_column_width;
    double min_column_width;
    double max_column_width;
    double original_window_weight;
    double min_window_weight;
    double max_window_weight;
    double pixels_per_weight;
    uint8_t has_original_view_offset;
    double original_view_offset;
} OmniNiriResizeInput;

typedef struct {
    uint8_t changed_width;
    double new_column_width;
    uint8_t changed_weight;
    double new_window_weight;
    uint8_t adjust_view_offset;
    double new_view_offset;
} OmniNiriResizeResult;

enum {
    OMNI_OK = 0,
    OMNI_ERR_INVALID_ARGS = -1,
    OMNI_ERR_OUT_OF_RANGE = -2
};

/// Solve axis layout for window_count windows.
///
/// is_tabbed: 0 = normal (weighted) layout, 1 = tabbed (all windows share one span).
///
/// Returns 0 on success.
/// Returns -1 if out_count < window_count or window_count exceeds the internal limit.
int32_t omni_axis_solve(
    const OmniAxisInput *windows,
    size_t window_count,
    double available_space,
    double gap_size,
    uint8_t is_tabbed,
    OmniAxisOutput *out,
    size_t out_count);

/// Tabbed variant (all windows get the same span, gaps are ignored).
/// Equivalent to calling omni_axis_solve with is_tabbed = 1.
int32_t omni_axis_solve_tabbed(
    const OmniAxisInput *windows,
    size_t window_count,
    double available_space,
    double gap_size,
    OmniAxisOutput *out,
    size_t out_count);

/// Compute viewport offset needed to reveal a target container index.
/// Returns 0 on success, -1 for invalid args, -2 when index/range is invalid.
int32_t omni_viewport_compute_visible_offset(
    const double *spans,
    size_t span_count,
    size_t container_index,
    double gap,
    double viewport_span,
    double current_view_start,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    int64_t from_container_index,
    double *out_target_offset);

/// Find the nearest snap target for projected viewport position.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_viewport_find_snap_target(
    const double *spans,
    size_t span_count,
    double gap,
    double viewport_span,
    double projected_view_pos,
    double current_view_pos,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    OmniSnapResult *out_result);

/// Run tiled layout pass and emit window frames.
/// Returns 0 on success, -1 for invalid args, -2 for range/assignment errors.
int32_t omni_niri_layout_pass(
    const OmniNiriColumnInput *columns,
    size_t column_count,
    const OmniNiriWindowInput *windows,
    size_t window_count,
    double working_x,
    double working_y,
    double working_width,
    double working_height,
    double view_x,
    double view_y,
    double view_width,
    double view_height,
    double fullscreen_x,
    double fullscreen_y,
    double fullscreen_width,
    double fullscreen_height,
    double primary_gap,
    double secondary_gap,
    double view_start,
    double viewport_span,
    double workspace_offset,
    double scale,
    uint8_t orientation,
    OmniNiriWindowOutput *out_windows,
    size_t out_window_count);

/// Layout-pass v2 also emits optional column frames.
/// Returns 0 on success, -1 for invalid args, -2 for range/assignment errors.
int32_t omni_niri_layout_pass_v2(
    const OmniNiriColumnInput *columns,
    size_t column_count,
    const OmniNiriWindowInput *windows,
    size_t window_count,
    double working_x,
    double working_y,
    double working_width,
    double working_height,
    double view_x,
    double view_y,
    double view_width,
    double view_height,
    double fullscreen_x,
    double fullscreen_y,
    double fullscreen_width,
    double fullscreen_height,
    double primary_gap,
    double secondary_gap,
    double view_start,
    double viewport_span,
    double workspace_offset,
    double scale,
    uint8_t orientation,
    OmniNiriWindowOutput *out_windows,
    size_t out_window_count,
    OmniNiriColumnOutput *out_columns,
    size_t out_column_count);

/// Hit-test tiled windows and return first containing window index.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_hit_test_tiled(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    int64_t *out_window_index);

/// Hit-test resize edges around tiled windows.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_hit_test_resize(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    double threshold,
    OmniNiriResizeHitResult *out_result);

/// Resolve move target under cursor, with swap or insert semantics.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_hit_test_move_target(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    int64_t excluding_window_index,
    uint8_t is_insert_mode,
    OmniNiriMoveTargetResult *out_result);

/// Compute insertion dropzone frame for before/after/swap placement.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_insertion_dropzone(
    const OmniNiriDropzoneInput *input,
    OmniNiriDropzoneResult *out_result);

/// Compute interactive resize updates for column width/window weight.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_resize_compute(
    const OmniNiriResizeInput *input,
    OmniNiriResizeResult *out_result);

typedef struct {
    uint8_t bytes[16];
} OmniUuid128;

typedef struct {
    OmniUuid128 column_id;
    size_t window_start;
    size_t window_count;
    size_t active_tile_idx;
    uint8_t is_tabbed;
    double size_value;
} OmniNiriStateColumnInput;

typedef struct {
    OmniUuid128 window_id;
    OmniUuid128 column_id;
    size_t column_index;
    double size_value;
} OmniNiriStateWindowInput;

typedef struct {
    size_t column_count;
    size_t window_count;
    int64_t first_invalid_column_index;
    int64_t first_invalid_window_index;
    int32_t first_error_code;
} OmniNiriStateValidationResult;

/// Validate snapshot bounds, ownership, and assignment consistency.
/// Returns 0 when valid, otherwise -1/-2 and fills first_invalid_* fields.
int32_t omni_niri_validate_state_snapshot(
    const OmniNiriStateColumnInput *columns,
    size_t column_count,
    const OmniNiriStateWindowInput *windows,
    size_t window_count,
    OmniNiriStateValidationResult *out_result);

typedef enum {
    OMNI_NIRI_DIRECTION_LEFT = 0,
    OMNI_NIRI_DIRECTION_RIGHT = 1,
    OMNI_NIRI_DIRECTION_UP = 2,
    OMNI_NIRI_DIRECTION_DOWN = 3
} OmniNiriDirection;

typedef enum {
    OMNI_NIRI_NAV_OP_MOVE_BY_COLUMNS = 0,
    OMNI_NIRI_NAV_OP_MOVE_VERTICAL = 1,
    OMNI_NIRI_NAV_OP_FOCUS_TARGET = 2,
    OMNI_NIRI_NAV_OP_FOCUS_DOWN_OR_LEFT = 3,
    OMNI_NIRI_NAV_OP_FOCUS_UP_OR_RIGHT = 4,
    OMNI_NIRI_NAV_OP_FOCUS_COLUMN_FIRST = 5,
    OMNI_NIRI_NAV_OP_FOCUS_COLUMN_LAST = 6,
    OMNI_NIRI_NAV_OP_FOCUS_COLUMN_INDEX = 7,
    OMNI_NIRI_NAV_OP_FOCUS_WINDOW_INDEX = 8,
    OMNI_NIRI_NAV_OP_FOCUS_WINDOW_TOP = 9,
    OMNI_NIRI_NAV_OP_FOCUS_WINDOW_BOTTOM = 10
} OmniNiriNavigationOp;

typedef struct {
    uint8_t op;
    uint8_t direction;
    uint8_t orientation;
    uint8_t infinite_loop;
    int64_t selected_window_index;
    int64_t selected_column_index;
    int64_t selected_row_index;
    int64_t step;
    int64_t target_row_index;
    int64_t target_column_index;
    int64_t target_window_index;
} OmniNiriNavigationRequest;

typedef struct {
    uint8_t has_target;
    int64_t target_window_index;
    uint8_t update_source_active_tile;
    int64_t source_column_index;
    int64_t source_active_tile_idx;
    uint8_t update_target_active_tile;
    int64_t target_column_index;
    int64_t target_active_tile_idx;
    uint8_t refresh_tabbed_visibility_source;
    uint8_t refresh_tabbed_visibility_target;
} OmniNiriNavigationResult;

/// Resolve navigation request against a validated snapshot.
/// Returns 0 on success, -1 for invalid args, -2 for range errors.
int32_t omni_niri_navigation_resolve(
    const OmniNiriStateColumnInput *columns,
    size_t column_count,
    const OmniNiriStateWindowInput *windows,
    size_t window_count,
    const OmniNiriNavigationRequest *request,
    OmniNiriNavigationResult *out_result);

typedef enum {
    OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL = 0,
    OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL = 1,
    OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL = 2,
    OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL = 3,
    OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE = 4,
    OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE = 5,
    OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN = 6,
    OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE = 7,
    OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN = 8,
    OMNI_NIRI_MUTATION_OP_MOVE_COLUMN = 9,
    OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW = 10,
    OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW = 11,
    OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN = 12,
    OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES = 13,
    OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES = 14,
    OMNI_NIRI_MUTATION_OP_BALANCE_SIZES = 15,
    OMNI_NIRI_MUTATION_OP_ADD_WINDOW = 16,
    OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW = 17,
    OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION = 18,
    OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL = 19
} OmniNiriMutationOp;

typedef enum {
    OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE = 0,
    OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS = 1,
    OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX = 2,
    OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE = 3,
    OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT = 4,
    OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT = 5,
    OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY = 6,
    OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY = 7,
    OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN = 8,
    OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW = 9,
    OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW = 10,
    OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS = 11,
    OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR = 12,
    OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR = 13,
    OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS = 14,
    OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN = 15,
    OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN = 16,
    OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX = 17,
    OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS = 18
} OmniNiriMutationEditKind;

typedef enum {
    OMNI_NIRI_MUTATION_NODE_NONE = 0,
    OMNI_NIRI_MUTATION_NODE_WINDOW = 1,
    OMNI_NIRI_MUTATION_NODE_COLUMN = 2
} OmniNiriMutationNodeKind;

typedef struct {
    uint8_t op;
    uint8_t direction;
    uint8_t infinite_loop;
    uint8_t insert_position;
    int64_t source_window_index;
    int64_t target_window_index;
    int64_t max_windows_per_column;
    int64_t source_column_index;
    int64_t target_column_index;
    int64_t insert_column_index;
    int64_t max_visible_columns;
    uint8_t selected_node_kind;
    int64_t selected_node_index;
    int64_t focused_window_index;
} OmniNiriMutationRequest;

typedef struct {
    uint8_t kind;
    int64_t subject_index;
    int64_t related_index;
    int64_t value_a;
    int64_t value_b;
    double scalar_a;
    double scalar_b;
} OmniNiriMutationEdit;

enum {
    OMNI_NIRI_MUTATION_MAX_EDITS = 32
};

typedef struct {
    uint8_t applied;
    uint8_t has_target_window;
    int64_t target_window_index;
    uint8_t has_target_node;
    uint8_t target_node_kind;
    int64_t target_node_index;
    size_t edit_count;
    OmniNiriMutationEdit edits[OMNI_NIRI_MUTATION_MAX_EDITS];
} OmniNiriMutationResult;

/// Build mutation edit plan for a snapshot and mutation request.
/// Returns 0 on success, -1 for invalid args, -2 for range/edit-limit errors.
int32_t omni_niri_mutation_plan(
    const OmniNiriStateColumnInput *columns,
    size_t column_count,
    const OmniNiriStateWindowInput *windows,
    size_t window_count,
    const OmniNiriMutationRequest *request,
    OmniNiriMutationResult *out_result);

typedef enum {
    OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE = 0,
    OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE = 1
} OmniNiriWorkspaceOp;

typedef enum {
    OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW = 0,
    OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE = 1,
    OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN = 2,
    OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND = 3,
    OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS = 4,
    OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY = 5,
    OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS = 6,
    OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW = 7,
    OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW = 8
} OmniNiriWorkspaceEditKind;

typedef struct {
    uint8_t op;
    int64_t source_window_index;
    int64_t source_column_index;
    int64_t max_visible_columns;
} OmniNiriWorkspaceRequest;

typedef struct {
    uint8_t kind;
    int64_t subject_index;
    int64_t related_index;
    int64_t value_a;
    int64_t value_b;
} OmniNiriWorkspaceEdit;

enum {
    OMNI_NIRI_WORKSPACE_MAX_EDITS = 16
};

typedef struct {
    uint8_t applied;
    size_t edit_count;
    OmniNiriWorkspaceEdit edits[OMNI_NIRI_WORKSPACE_MAX_EDITS];
} OmniNiriWorkspaceResult;

/// Build workspace transfer edit plan for source/target snapshots.
/// Returns 0 on success, -1 for invalid args, -2 for range/edit-limit errors.
int32_t omni_niri_workspace_plan(
    const OmniNiriStateColumnInput *source_columns,
    size_t source_column_count,
    const OmniNiriStateWindowInput *source_windows,
    size_t source_window_count,
    const OmniNiriStateColumnInput *target_columns,
    size_t target_column_count,
    const OmniNiriStateWindowInput *target_windows,
    size_t target_window_count,
    const OmniNiriWorkspaceRequest *request,
    OmniNiriWorkspaceResult *out_result);
