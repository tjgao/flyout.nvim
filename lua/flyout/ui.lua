local M = {}

local uv = vim.uv
local task = require("flyout.task")
local ns = vim.api.nvim_create_namespace("flyout-ui")
local log_ns = vim.api.nvim_create_namespace("flyout-log")

local col_width = {
    task = 7,
    pid = 8,
    state = 10,
    runtime = 10,
}

local min_command_col_width = 8

local list_padding = {
    x = 2,
    y = 1,
}

local preview_padding = {
    x = 2,
    y = 1,
}

local ui_defaults = {
    preview_enabled = true,
    task_list_width = "50%",
}

local ui_opts = vim.deepcopy(ui_defaults)

local list_min_width = nil
local preview_gap = 0
local task_list_footer =
    "[Enter] float log  [S] split  [V] vsplit  [T] tab  [x] quickfix  [s] stop  [r] rerun  [c] clear  [R] refresh  [q] close"

local list_state = {
    buf = nil,
    win = nil,
    timer = nil,
    line_to_task_id = {},
    selectable_start = nil,
    selectable_end = nil,
    preview_win = nil,
    preview_task_id = nil,
    preview_started_at = nil,
    preview_update_pending = false,
    preview_update_dirty = false,
}

local log_streams = {}
local log_float_wins = {}
local task_quickfix_parser = {}
local attach_log_view
local update_task_list_preview
local request_task_list_preview_update
local ensure_log_buffer
local parse_ansi_line

local ansi_hl_by_code = {
    [30] = "Comment",
    [31] = "DiagnosticError",
    [32] = "DiagnosticOk",
    [33] = "DiagnosticWarn",
    [34] = "Identifier",
    [35] = "Type",
    [36] = "Special",
    [37] = "Normal",
    [90] = "Comment",
    [91] = "DiagnosticError",
    [92] = "DiagnosticOk",
    [93] = "DiagnosticWarn",
    [94] = "Identifier",
    [95] = "Type",
    [96] = "Special",
    [97] = "Normal",
}

local quickfix_presets = {
    gcc = {
        efm = "%E%f:%l:%c: error: %m,%E%f:%l: error: %m,%W%f:%l:%c: warning: %m,%W%f:%l: warning: %m,%I%f:%l:%c: note: %m,%I%f:%l: note: %m,%E%f:%l:%c: fatal error: %m,%E%f:%l: fatal error: %m,%-G%.%#",
    },
    msvc = {
        efm = "%f(%l,%c): %t%*[^:]: %m,%f(%l): %t%*[^:]: %m,%-G%.%#",
    },
    rust = {
        efm = [=[%Eerror%\[%*[^]]%\]: %m,%Wwarning%\[%*[^]]%\]: %m,%C %#--> %f:%l:%c,%C %m,%-G%.%#]=],
    },
    go = {
        efm = "%E%f:%l:%c: %m,%E%f:%l: %m,%W%f:%l:%c: %m,%W%f:%l: %m,%-G%.%#",
    },
    py = {
        efm = [[%ETraceback (most recent call last):,%C  File "%f"\, line %l\, in %m,%C %m,%Z%[%^ :	]%\@=%m,%-G%.%#]],
    },
    pyt = {
        efm = "%E%f:%l: in %m,%W%f:%l: %m,%C%m,%-G%.%#",
    },
    tsc = {
        efm = [[%E%f(%l\,%c): error TS%n: %m,%W%f(%l\,%c): warning TS%n: %m,%-G%.%#]],
    },
    js = {
        efm = "%E%f:%l:%c: error %m,%W%f:%l:%c: warning %m,%-G%.%#",
    },
    java = {
        efm = "%E%f:%l: error: %m,%W%f:%l: warning: %m,%C%m,%-G%.%#",
    },
    lua = {
        efm = "%E%f:%l: %m,%-G%.%#",
    },
}

local quickfix_user_presets = {}

local function merged_quickfix_presets()
    local merged = vim.deepcopy(quickfix_presets)
    for name, parser in pairs(quickfix_user_presets) do
        if type(name) == "string" and type(parser) == "table" and type(parser.efm) == "string" and parser.efm ~= "" then
            merged[name:lower()] = {
                efm = parser.efm,
            }
        end
    end
    return merged
end

local function resolve_quickfix_errorformat(opts)
    local presets = merged_quickfix_presets()

    if opts and type(opts.errorformat) == "string" and opts.errorformat ~= "" then
        return opts.errorformat
    end

    local parser = opts and opts.parser
    if type(parser) ~= "string" or parser == "" or parser == "default" then
        return vim.o.errorformat
    end

    local key = parser:lower()

    local preset = presets[key]
    if not preset then
        return nil, string.format("unknown quickfix parser '%s'", parser)
    end

    return preset.efm
end

local function is_active_status(status)
    return status == "running" or status == "stopping"
end

local function make_float(title, width, height, footer)
    local columns = vim.o.columns
    local lines = vim.o.lines

    local w = math.min(width, columns - 4)
    local h = math.min(height, lines - 4)
    local row = math.floor((lines - h) / 2 - 1)
    local col = math.floor((columns - w) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false

    local cfg = {
        relative = "editor",
        border = "rounded",
        row = math.max(0, row),
        col = math.max(0, col),
        width = w,
        height = h,
        title = title,
        title_pos = "center",
        style = "minimal",
    }
    if footer and footer ~= "" then
        cfg.footer = footer
        cfg.footer_pos = "center"
    end

    local win = vim.api.nvim_open_win(buf, true, cfg)

    return buf, win
end

local function resolve_task_list_open_position(width, height)
    local list_col = math.max(0, math.floor((vim.o.columns - (width + 2)) / 2))
    local list_row = math.floor((vim.o.lines - height) / 2 - 1)

    if ui_opts.preview_enabled then
        local preview_height = math.max(6, math.floor(height))
        local combined_outer_height = height + preview_height + preview_gap + 4
        if combined_outer_height <= vim.o.lines then
            list_row = math.floor((vim.o.lines - combined_outer_height) / 2 - 1)
        end
    end

    return {
        row = math.max(0, list_row),
        col = list_col,
    }
end

local function stop_timer(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

local function notify_err(err)
    vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
end

local function resolve_width(value, total_columns, fallback)
    if type(value) == "number" then
        return math.max(1, math.floor(value))
    end

    if type(value) == "string" then
        local pct = value:match("^(%d+)%%$")
        if pct then
            local n = tonumber(pct)
            if n and n > 0 then
                return math.max(1, math.floor(total_columns * (n / 100)))
            end
        end
    end

    return fallback
end

local function task_list_required_width()
    local fields = col_width.task
        + 1
        + col_width.pid
        + 1
        + col_width.state
        + 1
        + col_width.runtime
        + 1
        + min_command_col_width
    return fields + (list_padding.x * 2)
end

local function truncate_display(str, max_len)
    if not str then
        return ""
    end
    if #str <= max_len then
        return str
    end
    if max_len <= 3 then
        return string.sub(str, 1, max_len)
    end
    return string.sub(str, 1, max_len - 3) .. "..."
end

local function preview_pad_line(line)
    local content = line or ""
    local pad = string.rep(" ", preview_padding.x)
    return pad .. content .. pad
end

local function pad_line_with_cols(line, cols)
    local content = line or ""
    if not cols or cols <= 0 then
        return content
    end
    local pad = string.rep(" ", cols)
    return pad .. content .. pad
end

local function with_preview_padding(lines)
    local out = {}
    for _ = 1, preview_padding.y do
        table.insert(out, "")
    end
    for _, line in ipairs(lines) do
        table.insert(out, preview_pad_line(line))
    end
    for _ = 1, preview_padding.y do
        table.insert(out, "")
    end
    return out
end

local function center_task_list_window()
    if not (list_state.win and vim.api.nvim_win_is_valid(list_state.win)) then
        return
    end

    local cfg = vim.api.nvim_win_get_config(list_state.win)
    local width = tonumber(cfg.width) or task_list_required_width()
    local col = math.floor((vim.o.columns - (width + 2)) / 2)
    cfg.col = math.max(0, col)
    vim.api.nvim_win_set_config(list_state.win, cfg)
end

local function scroll_win_to_bottom(win, buf)
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    if vim.api.nvim_win_get_buf(win) ~= buf then
        return
    end

    local last = vim.api.nvim_buf_line_count(buf)
    if last < 1 then
        last = 1
    end
    local height = vim.api.nvim_win_get_height(win)
    local topline = math.max(1, last - height + 1)

    vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ lnum = last, col = 0, topline = topline, leftcol = 0 })
    end)
end

local function read_tail_lines(path, max_lines)
    if not path or max_lines < 1 or not uv.fs_stat(path) then
        return {}, 1
    end

    local fd = io.open(path, "r")
    if not fd then
        return {}, 1
    end

    local ring = {}
    local total = 0
    for line in fd:lines() do
        total = total + 1
        local idx = ((total - 1) % max_lines) + 1
        ring[idx] = line
    end
    fd:close()

    local count = math.min(total, max_lines)
    if count == 0 then
        return {}, 1
    end

    local out = {}
    if total <= max_lines then
        for i = 1, count do
            out[i] = ring[i]
        end
        return out, total + 1
    end

    local start = ((total - count) % max_lines) + 1
    for i = 1, count do
        local idx = ((start + i - 2) % max_lines) + 1
        out[i] = ring[idx]
    end
    return out, total + 1
end
local function resolve_preview_tail_lines(preview_win)
    local win_height = 30
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        win_height = vim.api.nvim_win_get_height(preview_win)
    end

    return math.max(20, math.floor(win_height * 2))
end

local function build_task_snapshot_buffer(task_info, preview_win)
    local preview_buf = vim.api.nvim_create_buf(false, true)
    ensure_log_buffer(preview_buf)

    local header = {
        string.format("Task #%d [%s]", task_info.id, task_info.status),
        task_info.cmd,
        string.rep("-", 80),
    }

    local max_lines = resolve_preview_tail_lines(preview_win)

    local raw_lines, next_line = read_tail_lines(task_info.output_path, max_lines)
    local body_lines = {}
    local highlights = {}
    local active_hl = nil
    for i, raw_line in ipairs(raw_lines) do
        local plain, spans, next_hl = parse_ansi_line(raw_line, active_hl)
        active_hl = next_hl
        body_lines[i] = plain
        if #spans > 0 then
            highlights[i] = spans
        end
    end

    local all_lines = with_preview_padding(vim.list_extend(header, body_lines))
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, all_lines)
    vim.bo[preview_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(preview_buf, log_ns, 0, -1)

    for rel, spans in pairs(highlights) do
        local row = preview_padding.y + 3 + rel - 1
        for _, span in ipairs(spans) do
            vim.api.nvim_buf_set_extmark(preview_buf, log_ns, row, span.start_col + preview_padding.x, {
                end_col = span.end_col + preview_padding.x,
                hl_group = span.hl_group,
            })
        end
    end

    return preview_buf, next_line
end

local function display_state(item)
    if item.status == "pending" then
        return "PENDING", "DiagnosticWarn"
    end

    if item.status == "running" or item.status == "stopping" then
        return "RUNNING", "DiagnosticWarn"
    end

    if item.status == "stopped" or item.status == "killed" then
        return "STOPPED", "Comment"
    end

    if item.status == "success" and item.exit_code == 0 then
        return "DONE", "DiagnosticOk"
    end

    if item.status == "failed" then
        return "FAILED", "DiagnosticError"
    end

    return "FAILED", "DiagnosticError"
end

local function display_pid(item)
    if item.pid then
        return tostring(item.pid), nil
    end
    return "-", "Comment"
end

local function format_duration_ms(ms)
    local total_seconds = math.max(0, math.floor(ms / 1000))
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

local function display_runtime(item)
    if type(item.started_at) ~= "number" then
        return "-", "Comment"
    end

    local end_at = item.ended_at
    if type(end_at) ~= "number" then
        end_at = uv.now()
    end

    return format_duration_ms(end_at - item.started_at), nil
end

local function format_task_line(item, command_width)
    local pid = display_pid(item)
    local state = display_state(item)
    local runtime = display_runtime(item)
    local cmd = truncate_display(item.cmd or "", command_width)

    return string.format(
        "%-"
        .. col_width.task
        .. "s %"
        .. col_width.pid
        .. "s %-"
        .. col_width.state
        .. "s %"
        .. col_width.runtime
        .. "s %s",
        "#" .. item.id,
        pid,
        state,
        runtime,
        cmd
    )
end

local function render_task_list()
    if not (list_state.buf and vim.api.nvim_buf_is_valid(list_state.buf)) then
        return
    end
    if not (list_state.win and vim.api.nvim_win_is_valid(list_state.win)) then
        return
    end

    local tasks = task.list()
    local list_width = vim.api.nvim_win_get_width(list_state.win)
    local content_width = math.max(1, list_width - (list_padding.x * 2))
    local fixed_width = col_width.task + 1 + col_width.pid + 1 + col_width.state + 1 + col_width.runtime + 1
    local command_width = math.max(1, content_width - fixed_width)
    local lines = {}
    local left_pad = string.rep(" ", list_padding.x)
    local first_task_line = list_padding.y + 1

    for _ = 1, list_padding.y do
        table.insert(lines, "")
    end

    list_state.line_to_task_id = {}
    local field_hl = {}
    local task_col = list_padding.x
    local pid_col = list_padding.x + col_width.task + 1
    local state_col = list_padding.x + col_width.task + 1 + col_width.pid + 1
    local runtime_col = list_padding.x + col_width.task + 1 + col_width.pid + 1 + col_width.state + 1

    for _, item in ipairs(tasks) do
        local pid, pid_hl = display_pid(item)
        local state, state_hl = display_state(item)
        local runtime, runtime_hl = display_runtime(item)
        local task_text = "#" .. item.id
        local line = left_pad .. format_task_line(item, command_width) .. left_pad
        table.insert(lines, line)
        list_state.line_to_task_id[#lines] = item.id

        do
            local line_idx = #lines - 1
            table.insert(field_hl, {
                line = line_idx,
                hl = "DiagnosticInfo",
                start_col = task_col,
                end_col = task_col + #task_text,
            })
        end

        if pid_hl then
            local line_idx = #lines - 1
            local start_col = pid_col + (col_width.pid - #pid)
            table.insert(field_hl, {
                line = line_idx,
                hl = pid_hl,
                start_col = start_col,
                end_col = start_col + #pid,
            })
        end

        if state_hl then
            local line_idx = #lines - 1
            table.insert(field_hl, {
                line = line_idx,
                hl = state_hl,
                start_col = state_col,
                end_col = state_col + #state,
            })
        end

        if runtime_hl then
            local line_idx = #lines - 1
            local start_col = runtime_col + (col_width.runtime - #runtime)
            table.insert(field_hl, {
                line = line_idx,
                hl = runtime_hl,
                start_col = start_col,
                end_col = start_col + #runtime,
            })
        end
    end

    if #tasks == 0 then
        table.insert(lines, left_pad .. "No tasks yet." .. left_pad)
        list_state.selectable_start = #lines
        list_state.selectable_end = #lines
    else
        list_state.selectable_start = first_task_line
        list_state.selectable_end = first_task_line + #tasks - 1
    end

    for _ = 1, list_padding.y do
        table.insert(lines, "")
    end

    local cursor = vim.api.nvim_win_get_cursor(list_state.win)
    vim.bo[list_state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_state.buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(list_state.buf, ns, 0, -1)
    for _, item in ipairs(field_hl) do
        vim.api.nvim_buf_set_extmark(list_state.buf, ns, item.line, item.start_col, {
            end_col = item.end_col,
            hl_group = item.hl,
        })
    end
    vim.bo[list_state.buf].modifiable = false

    local line = math.min(cursor[1], #lines)
    if list_state.selectable_start and line < list_state.selectable_start then
        line = list_state.selectable_start
    end
    if list_state.selectable_end and line > list_state.selectable_end then
        line = list_state.selectable_end
    end
    if line < 1 then
        line = 1
    end
    vim.api.nvim_win_set_cursor(list_state.win, { line, 0 })
    request_task_list_preview_update()
end

local function clamp_task_list_cursor()
    if not (list_state.win and vim.api.nvim_win_is_valid(list_state.win)) then
        return
    end

    local start_line = list_state.selectable_start
    local end_line = list_state.selectable_end
    if not start_line or not end_line then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(list_state.win)
    local line = cursor[1]
    if line < start_line then
        vim.api.nvim_win_set_cursor(list_state.win, { start_line, cursor[2] })
    elseif line > end_line then
        vim.api.nvim_win_set_cursor(list_state.win, { end_line, cursor[2] })
    end

    request_task_list_preview_update()
end

local function current_task_id_from_list()
    if not (list_state.win and vim.api.nvim_win_is_valid(list_state.win)) then
        return nil
    end
    local cursor = vim.api.nvim_win_get_cursor(list_state.win)
    return list_state.line_to_task_id[cursor[1]]
end

local function close_task_list_preview()
    list_state.preview_update_pending = false
    list_state.preview_update_dirty = false
    if list_state.preview_win and vim.api.nvim_win_is_valid(list_state.preview_win) then
        vim.api.nvim_win_close(list_state.preview_win, true)
    end
    list_state.preview_win = nil
    list_state.preview_task_id = nil
    list_state.preview_started_at = nil
end

local function ensure_task_list_preview_window()
    if not (list_state.win and vim.api.nvim_win_is_valid(list_state.win)) then
        close_task_list_preview()
        return false
    end

    if not ui_opts.preview_enabled then
        close_task_list_preview()
        center_task_list_window()
        return false
    end

    local required_list_width = list_min_width or task_list_required_width()
    local cfg = vim.api.nvim_win_get_config(list_state.win)
    local list_width = tonumber(cfg.width) or 0
    local list_height = tonumber(cfg.height) or 0

    if list_width < required_list_width then
        cfg.width = required_list_width
        vim.api.nvim_win_set_config(list_state.win, cfg)
        list_width = required_list_width
    end

    local preview_width = list_width
    local preview_height = math.max(6, math.floor(list_height))
    local preview_col = 0
    local preview_row = 0

    local combined_outer_height = list_height + preview_height + preview_gap + 4
    if combined_outer_height > vim.o.lines then
        close_task_list_preview()
        center_task_list_window()
        return false
    end

    local list_col = math.max(0, math.floor((vim.o.columns - (list_width + 2)) / 2))
    local start_row = math.max(0, math.floor((vim.o.lines - combined_outer_height) / 2 - 1))
    cfg.col = list_col
    cfg.row = start_row
    preview_col = list_col
    preview_row = start_row + list_height + preview_gap + 2

    vim.api.nvim_win_set_config(list_state.win, cfg)

    if list_state.preview_win and vim.api.nvim_win_is_valid(list_state.preview_win) then
        local preview_cfg = vim.api.nvim_win_get_config(list_state.preview_win)
        preview_cfg.row = math.max(0, math.floor(preview_row))
        preview_cfg.col = math.max(0, math.floor(preview_col))
        preview_cfg.width = preview_width
        preview_cfg.height = preview_height
        preview_cfg.focusable = false
        preview_cfg.footer =
        task_list_footer
        preview_cfg.footer_pos = "center"
        vim.api.nvim_win_set_config(list_state.preview_win, preview_cfg)
        vim.wo[list_state.preview_win].number = false
        vim.wo[list_state.preview_win].relativenumber = false
        return true
    end

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
        relative = "editor",
        border = "rounded",
        row = math.max(0, math.floor(preview_row)),
        col = math.max(0, math.floor(preview_col)),
        width = preview_width,
        height = preview_height,
        focusable = false,
        footer = task_list_footer,
        footer_pos = "center",
        style = "minimal",
    })

    list_state.preview_win = preview_win
    list_state.preview_task_id = nil
    vim.wo[preview_win].scrolloff = 0
    vim.wo[preview_win].number = false
    vim.wo[preview_win].relativenumber = false
    ensure_log_buffer(preview_buf)
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, with_preview_padding({ "Select a task to preview output." }))
    vim.bo[preview_buf].modifiable = false

    vim.api.nvim_create_autocmd("WinClosed", {
        once = true,
        callback = function(args)
            if tonumber(args.match) == preview_win then
                list_state.preview_win = nil
                list_state.preview_task_id = nil
                list_state.preview_started_at = nil
            end
        end,
    })

    return true
end

update_task_list_preview = function()
    if not ensure_task_list_preview_window() then
        return
    end

    local task_id = current_task_id_from_list()
    if not task_id then
        list_state.preview_task_id = nil
        list_state.preview_started_at = nil
        local preview_win = list_state.preview_win
        if preview_win and vim.api.nvim_win_is_valid(preview_win) then
            local preview_buf = vim.api.nvim_create_buf(false, true)
            ensure_log_buffer(preview_buf)
            vim.bo[preview_buf].modifiable = true
            vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, with_preview_padding({ "Select a task to preview output." }))
            vim.bo[preview_buf].modifiable = false
            vim.api.nvim_win_set_buf(preview_win, preview_buf)
        end
        return
    end

    local task_info, task_err = task.get(task_id)
    if not task_info then
        notify_err(task_err)
        return
    end

    if list_state.preview_task_id == task_id and list_state.preview_started_at == task_info.started_at then
        return
    end

    local preview_win = list_state.preview_win
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
        return
    end

    if not is_active_status(task_info.status) then
        local snapshot_buf = build_task_snapshot_buffer(task_info, preview_win)
        vim.api.nvim_win_set_buf(preview_win, snapshot_buf)
        list_state.preview_task_id = task_id
        list_state.preview_started_at = task_info.started_at
        scroll_win_to_bottom(preview_win, snapshot_buf)
        return
    end

    local preview_buf, next_line = build_task_snapshot_buffer(task_info, preview_win)
    vim.api.nvim_win_set_buf(preview_win, preview_buf)
    attach_log_view(task_id, preview_buf, preview_win, {
        show_header = true,
        allow_close = false,
        glance_only = true,
        preserve_existing_body = true,
        start_line = next_line,
    })
    list_state.preview_task_id = task_id
    list_state.preview_started_at = task_info.started_at
    scroll_win_to_bottom(preview_win, preview_buf)
end

request_task_list_preview_update = function()
    if not (list_state.buf and vim.api.nvim_buf_is_valid(list_state.buf)) then
        return
    end

    list_state.preview_update_dirty = true
    if list_state.preview_update_pending then
        return
    end

    list_state.preview_update_pending = true

    local function process_preview_update()
        if not (list_state.buf and vim.api.nvim_buf_is_valid(list_state.buf)) then
            list_state.preview_update_pending = false
            list_state.preview_update_dirty = false
            return
        end

        list_state.preview_update_dirty = false
        update_task_list_preview()

        if list_state.preview_update_dirty then
            vim.schedule(process_preview_update)
            return
        end

        list_state.preview_update_pending = false
    end

    vim.schedule(process_preview_update)
end

local function with_selected_task(action)
    local task_id = current_task_id_from_list()
    if not task_id then
        vim.notify("Flyout: no task selected", vim.log.levels.WARN)
        return
    end
    action(task_id)
    render_task_list()
end

local function setup_list_autorefresh()
    stop_timer(list_state.timer)
    list_state.timer = uv.new_timer()
    list_state.timer:start(0, 1000, function()
        vim.schedule(function()
            if not (list_state.buf and vim.api.nvim_buf_is_valid(list_state.buf)) then
                stop_timer(list_state.timer)
                list_state.timer = nil
                return
            end
            render_task_list()
        end)
    end)
end

ensure_log_buffer = function(buf)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "flyout-log"
end

local function normalize_output_line(line)
    if type(line) ~= "string" then
        return ""
    end

    if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
    end

    local last_cr = line:match(".*()\r")
    if last_cr then
        line = line:sub(last_cr + 1)
    end

    return (line:gsub("\r", ""))
end

parse_ansi_line = function(line, active_hl)
    line = normalize_output_line(line)

    local pieces = {}
    local spans = {}
    local col = 0
    local idx = 1
    local current_hl = active_hl

    while true do
        local s, e, codes = line:find("\27%[([%d;]*)m", idx)
        local text_end = s and (s - 1) or #line
        if text_end >= idx then
            local chunk = line:sub(idx, text_end)
            local chunk_len = #chunk
            table.insert(pieces, chunk)
            if current_hl and chunk_len > 0 then
                table.insert(spans, {
                    start_col = col,
                    end_col = col + chunk_len,
                    hl_group = current_hl,
                })
            end
            col = col + chunk_len
        end

        if not s then
            break
        end

        if codes == "" then
            current_hl = nil
        else
            for code_str in codes:gmatch("%d+") do
                local code = tonumber(code_str)
                if code == 0 or code == 39 then
                    current_hl = nil
                elseif ansi_hl_by_code[code] then
                    current_hl = ansi_hl_by_code[code]
                end
            end
        end

        idx = e + 1
    end

    return table.concat(pieces), spans, current_hl
end

local function focus_task_list_window()
    if list_state.win and vim.api.nvim_win_is_valid(list_state.win) then
        vim.api.nvim_set_current_win(list_state.win)
        return true
    end
    return false
end

local function first_normal_window_in_tab()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            local cfg = vim.api.nvim_win_get_config(win)
            if cfg.relative == "" then
                return win
            end
        end
    end
    return nil
end

local function set_log_buffer_name(buf, task_id, cmd)
    local cmd_display = truncate_display(cmd or "", 20)
    if cmd_display == "" then
        cmd_display = "<empty>"
    end

    local base = string.format("#%d: %s", task_id, cmd_display)
    local ok = pcall(vim.api.nvim_buf_set_name, buf, base)
    if ok then
        return
    end

    pcall(vim.api.nvim_buf_set_name, buf, string.format("%s [%d]", base, buf))
end

local function stream_iter_views(stream, callback)
    local stale = {}
    for buf, view in pairs(stream.views) do
        if not vim.api.nvim_buf_is_valid(buf) then
            table.insert(stale, buf)
        else
            callback(view)
        end
    end
    for _, buf in ipairs(stale) do
        stream.views[buf] = nil
    end
end

local function stream_set_header(view, task_info)
    if view.header_lines == 0 or not vim.api.nvim_buf_is_valid(view.buf) then
        return
    end

    local header = {
        string.format("Task #%d [%s]", task_info.id, task_info.status),
        task_info.cmd,
        string.rep("-", 80),
    }

    if view.left_padding_cols and view.left_padding_cols > 0 then
        for i = 1, #header do
            header[i] = preview_pad_line(header[i])
        end
    end

    local header_start = view.top_padding_lines or 0
    local header_end = header_start + view.header_lines
    vim.bo[view.buf].modifiable = true
    vim.api.nvim_buf_set_lines(view.buf, header_start, header_end, false, header)
    vim.bo[view.buf].modifiable = false
end

local function stream_clear_body(view)
    if not vim.api.nvim_buf_is_valid(view.buf) then
        return
    end
    local body_start = (view.top_padding_lines or 0) + view.header_lines
    local body_end = vim.api.nvim_buf_line_count(view.buf) - (view.bottom_padding_lines or 0)
    if body_end < body_start then
        body_end = body_start
    end

    vim.bo[view.buf].modifiable = true
    vim.api.nvim_buf_set_lines(view.buf, body_start, body_end, false, {})
    vim.bo[view.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(view.buf, log_ns, body_start, -1)
    view.ansi_hl_state = nil
end

local function read_all_output_lines(task_id)
    local all = {}
    local start_line = 1
    local last_next_line = 1

    while true do
        local chunk, read_err = task.read_output(task_id, {
            start_line = start_line,
            max_lines = 300,
        })
        if not chunk then
            return nil, read_err
        end

        if #chunk.lines > 0 then
            vim.list_extend(all, chunk.lines)
        end
        last_next_line = chunk.next_line

        if chunk.eof then
            break
        end

        start_line = chunk.next_line
    end

    return {
        lines = all,
        next_line = last_next_line,
    }
end

local function stream_append_lines(view, lines)
    if #lines == 0 or not vim.api.nvim_buf_is_valid(view.buf) then
        return
    end

    local follow = false
    if view.win and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == view.buf then
        local cursor = vim.api.nvim_win_get_cursor(view.win)
        local last_line = vim.api.nvim_buf_line_count(view.buf)
        follow = cursor[1] >= last_line
    end

    local rendered = {}
    local highlights = {}
    local left_padding_cols = view.left_padding_cols or 0
    local active_hl = view.ansi_hl_state
    local line_padding = ""
    if left_padding_cols > 0 then
        line_padding = string.rep(" ", left_padding_cols)
    end
    for i, raw_line in ipairs(lines) do
        local plain, spans, next_hl = parse_ansi_line(raw_line, active_hl)
        active_hl = next_hl
        if left_padding_cols > 0 then
            rendered[i] = line_padding .. plain .. line_padding
        else
            rendered[i] = plain
        end
        if #spans > 0 then
            highlights[i] = spans
        end
    end
    view.ansi_hl_state = active_hl

    local start_idx = vim.api.nvim_buf_line_count(view.buf) - (view.bottom_padding_lines or 0)
    vim.bo[view.buf].modifiable = true
    vim.api.nvim_buf_set_lines(view.buf, start_idx, start_idx, false, rendered)
    vim.bo[view.buf].modifiable = false

    for rel, spans in pairs(highlights) do
        local row = start_idx + rel - 1
        for _, span in ipairs(spans) do
            vim.api.nvim_buf_set_extmark(view.buf, log_ns, row, span.start_col + left_padding_cols, {
                end_col = span.end_col + left_padding_cols,
                hl_group = span.hl_group,
            })
        end
    end

    local max_body_lines = nil
    if view.glance_only then
        max_body_lines = resolve_preview_tail_lines(view.win)
    end
    if type(max_body_lines) == "number" and max_body_lines > 0 then
        local total_lines = vim.api.nvim_buf_line_count(view.buf)
        local body_lines = math.max(
            0,
            total_lines - (view.top_padding_lines or 0) - view.header_lines - (view.bottom_padding_lines or 0)
        )
        local overflow = body_lines - max_body_lines
        if overflow > 0 then
            local delete_start = (view.top_padding_lines or 0) + view.header_lines
            local delete_end = delete_start + overflow
            vim.bo[view.buf].modifiable = true
            vim.api.nvim_buf_set_lines(view.buf, delete_start, delete_end, false, {})
            vim.bo[view.buf].modifiable = false
        end
    end

    if
        follow
        and view.win
        and vim.api.nvim_win_is_valid(view.win)
        and vim.api.nvim_win_get_buf(view.win) == view.buf
    then
        scroll_win_to_bottom(view.win, view.buf)
    end
end

local function ensure_stream_timer(stream)
    if stream.timer and not stream.timer:is_closing() then
        return
    end
    stream.timer = uv.new_timer()
    stream.timer:start(0, 400, function()
        vim.schedule(function()
            local current = log_streams[stream.task_id]
            if not current then
                return
            end

            stream_iter_views(current, function() end)
            if not next(current.views) then
                stop_timer(current.timer)
                log_streams[current.task_id] = nil
                return
            end

            local latest, latest_err = task.get(current.task_id)
            if not latest then
                notify_err(latest_err)
                return
            end

            if latest.started_at ~= current.started_at then
                current.started_at = latest.started_at
                current.next_line = 1
                stream_iter_views(current, stream_clear_body)
            end

            local chunk, read_err = task.read_output(current.task_id, {
                start_line = current.next_line,
                max_lines = 300,
            })
            if not chunk then
                notify_err(read_err)
                return
            end

            current.next_line = chunk.next_line
            stream_iter_views(current, function(view)
                stream_append_lines(view, chunk.lines)
                stream_set_header(view, latest)
            end)

            if chunk.eof and not is_active_status(latest.status) then
                stop_timer(current.timer)
                current.timer = nil
            end
        end)
    end)
end

local function ensure_log_stream(task_id, task_info)
    local stream = log_streams[task_id]
    if stream then
        ensure_stream_timer(stream)
        return stream
    end

    stream = {
        task_id = task_id,
        started_at = task_info.started_at,
        next_line = 1,
        timer = nil,
        views = {},
    }
    log_streams[task_id] = stream
    ensure_stream_timer(stream)
    return stream
end

local function notify_task_restarted(task_id, started_at)
    local stream = log_streams[task_id]
    if not stream then
        return
    end
    stream.started_at = started_at
    stream.next_line = 1
    stream_iter_views(stream, stream_clear_body)
    ensure_stream_timer(stream)
end

attach_log_view = function(task_id, buf, win, opts)
    local task_info, err = task.get(task_id)
    if not task_info then
        notify_err(err)
        return
    end

    opts = opts or {}
    ensure_log_buffer(buf)

    local header_lines = opts.show_header and 3 or 0
    local allow_close = opts.allow_close ~= false
    local allow_task_actions = opts.allow_task_actions ~= false
    local allow_open_targets = opts.allow_open_targets == true
    local focus_task_list_on_close = opts.focus_task_list_on_close == true
    local preserve_existing_body = opts.preserve_existing_body == true
    local start_line_override = tonumber(opts.start_line)
    local glance_only = opts.glance_only == true
    local top_padding_lines = 0
    local bottom_padding_lines = 0
    local left_padding_cols = 0

    if glance_only then
        top_padding_lines = preview_padding.y
        bottom_padding_lines = preview_padding.y
        left_padding_cols = preview_padding.x
    end

    if type(opts.top_padding_lines) == "number" and opts.top_padding_lines >= 0 then
        top_padding_lines = math.floor(opts.top_padding_lines)
    end
    if type(opts.bottom_padding_lines) == "number" and opts.bottom_padding_lines >= 0 then
        bottom_padding_lines = math.floor(opts.bottom_padding_lines)
    end
    if type(opts.left_padding_cols) == "number" and opts.left_padding_cols >= 0 then
        left_padding_cols = math.floor(opts.left_padding_cols)
    end

    local view = {
        task_id = task_id,
        buf = buf,
        win = win,
        header_lines = header_lines,
        glance_only = glance_only,
        top_padding_lines = top_padding_lines,
        bottom_padding_lines = bottom_padding_lines,
        left_padding_cols = left_padding_cols,
        ansi_hl_state = nil,
    }

    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        vim.wo[win].scrolloff = 0
        vim.wo[win].number = not glance_only
        vim.wo[win].relativenumber = false
    end

    if not glance_only then
        set_log_buffer_name(buf, task_id, task_info.cmd)
    end

    vim.bo[buf].modifiable = true
    if header_lines > 0 then
        local header = {
            string.format("Task #%d [%s]", task_info.id, task_info.status),
            task_info.cmd,
            string.rep("-", 80),
        }
        if view.left_padding_cols > 0 then
            for i = 1, #header do
                header[i] = pad_line_with_cols(header[i], view.left_padding_cols)
            end
        end

        local top_padding = {}
        for _ = 1, view.top_padding_lines do
            table.insert(top_padding, "")
        end

        if preserve_existing_body then
            vim.api.nvim_buf_set_lines(buf, 0, view.top_padding_lines + header_lines, false, vim.list_extend(top_padding, header))
        else
            local initial = vim.list_extend(top_padding, header)
            for _ = 1, view.bottom_padding_lines do
                table.insert(initial, "")
            end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
        end
    elseif not preserve_existing_body then
        if view.top_padding_lines > 0 or view.bottom_padding_lines > 0 then
            local initial = {}
            for _ = 1, view.top_padding_lines + view.bottom_padding_lines do
                table.insert(initial, "")
            end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
        else
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
        end
    end
    vim.bo[buf].modifiable = false

    local stream = ensure_log_stream(task_id, task_info)
    if start_line_override and start_line_override > stream.next_line then
        stream.next_line = math.floor(start_line_override)
    end

    if not preserve_existing_body then
        local snapshot, snapshot_err = read_all_output_lines(task_id)
        if not snapshot then
            notify_err(snapshot_err)
        else
            if #snapshot.lines > 0 then
                stream_append_lines(view, snapshot.lines)
            end
            if stream.next_line < snapshot.next_line then
                stream.next_line = snapshot.next_line
            end
        end
    end
    stream.views[buf] = view

    if allow_close then
        vim.keymap.set("n", "q", function()
            local win_to_close = nil
            if view.win and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == buf then
                win_to_close = view.win
            else
                local current = vim.api.nvim_get_current_win()
                if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == buf then
                    win_to_close = current
                end
            end

            if not win_to_close then
                return
            end

            if focus_task_list_on_close then
                focus_task_list_window()
            end

            if vim.api.nvim_win_is_valid(win_to_close) then
                vim.api.nvim_win_close(win_to_close, true)
            end
        end, { buffer = buf, silent = true })
    end
    if allow_task_actions then
        vim.keymap.set("n", "s", function()
            local _, stop_err = task.stop(task_id)
            if stop_err then
                notify_err(stop_err)
                return
            end
            vim.notify(string.format("Flyout: stopping task #%d", task_id))
        end, { buffer = buf, silent = true })
        vim.keymap.set("n", "r", function()
            local restarted, restart_err = task.rerun(task_id)
            if not restarted then
                notify_err(restart_err)
                return
            end
            vim.notify(string.format("Flyout: started task #%d", restarted.id))
            notify_task_restarted(task_id, restarted.started_at)
        end, { buffer = buf, silent = true })
    end
    vim.keymap.set("n", "G", function()
        if view.win and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == buf then
            local total = vim.api.nvim_buf_line_count(buf)
            vim.api.nvim_win_set_cursor(view.win, { total, 0 })
        end
    end, { buffer = buf, silent = true })
    if allow_open_targets then
        vim.keymap.set("n", "<C-s>", function()
            M.open_task_log_split(task_id)
        end, { buffer = buf, silent = true })
        vim.keymap.set("n", "<C-v>", function()
            M.open_task_log_vsplit(task_id)
        end, { buffer = buf, silent = true })
        vim.keymap.set("n", "<C-t>", function()
            M.open_task_log_tab(task_id)
        end, { buffer = buf, silent = true })
    end

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            local current = log_streams[task_id]
            if not current then
                return
            end
            current.views[buf] = nil
            if not next(current.views) then
                stop_timer(current.timer)
                log_streams[task_id] = nil
            end
            local float_win = log_float_wins[task_id]
            if float_win then
                if not vim.api.nvim_win_is_valid(float_win) then
                    log_float_wins[task_id] = nil
                elseif vim.api.nvim_win_get_buf(float_win) == buf then
                    log_float_wins[task_id] = nil
                end
            end
        end,
    })
end

local function open_log_in_split(task_id, kind)
    local _, err = task.get(task_id)
    if err then
        notify_err(err)
        return
    end

    local source_win = vim.api.nvim_get_current_win()
    local source_tab = vim.api.nvim_get_current_tabpage()
    local target_base_win = source_win

    if kind ~= "tab" then
        local current_cfg = vim.api.nvim_win_get_config(source_win)
        if current_cfg.relative ~= "" then
            local normal_win = first_normal_window_in_tab()
            if normal_win then
                target_base_win = normal_win
            end
        end
        if target_base_win and vim.api.nvim_win_is_valid(target_base_win) then
            vim.api.nvim_set_current_win(target_base_win)
        end
    end

    if kind == "split" then
        vim.cmd("split")
    elseif kind == "vsplit" then
        vim.cmd("vsplit")
    elseif kind == "tab" then
        vim.cmd("tabnew")
    end

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    attach_log_view(task_id, buf, win, { show_header = false })

    if source_tab and vim.api.nvim_tabpage_is_valid(source_tab) then
        vim.api.nvim_set_current_tabpage(source_tab)
    end
    if source_win and vim.api.nvim_win_is_valid(source_win) then
        vim.api.nvim_set_current_win(source_win)
    end
end

function M.open_task_log(task_id)
    local existing_win = log_float_wins[task_id]
    if existing_win and vim.api.nvim_win_is_valid(existing_win) then
        vim.api.nvim_set_current_win(existing_win)
        return
    end

    local float_width = math.max(90, math.floor(vim.o.columns * 0.7))
    local float_height = math.max(12, vim.o.lines - 10)
    local buf, win = make_float(
        string.format("Flyout Log #%d", task_id),
        float_width,
        float_height,
        "[Ctrl-S] split  [Ctrl-V] vsplit  [Ctrl-T] tab"
    )
    log_float_wins[task_id] = win
    vim.wo[win].scrolloff = 0
    attach_log_view(task_id, buf, win, {
        show_header = true,
        allow_task_actions = false,
        allow_open_targets = true,
    })
    scroll_win_to_bottom(win, buf)

    vim.api.nvim_create_autocmd("WinClosed", {
        once = true,
        callback = function(args)
            if tonumber(args.match) == win then
                vim.schedule(function()
                    focus_task_list_window()
                end)
            end
        end,
    })
end

function M.open_task_log_split(task_id)
    open_log_in_split(task_id, "split")
end

function M.open_task_log_vsplit(task_id)
    open_log_in_split(task_id, "vsplit")
end

function M.open_task_log_tab(task_id)
    open_log_in_split(task_id, "tab")
end

function M.open_task_quickfix(task_id, opts)
    local task_info, err = task.get(task_id)
    if not task_info then
        notify_err(err)
        return
    end

    local id = tonumber(task_id)
    opts = opts or {}
    if id and type(opts.parser) == "string" and opts.parser ~= "" then
        task_quickfix_parser[id] = opts.parser
    end
    if id and (not opts.parser or opts.parser == "") and task_quickfix_parser[id] then
        opts.parser = task_quickfix_parser[id]
    end
    local snapshot, snapshot_err = read_all_output_lines(task_id)
    if not snapshot then
        notify_err(snapshot_err)
        return
    end

    local plain_lines = {}
    local active_hl = nil
    for i, raw_line in ipairs(snapshot.lines) do
        local plain, _, next_hl = parse_ansi_line(raw_line, active_hl)
        plain_lines[i] = plain
        active_hl = next_hl
    end

    local efm, efm_err = resolve_quickfix_errorformat(opts)
    if not efm then
        notify_err(efm_err)
        return
    end
    local title = opts.title or string.format("Flyout #%d: %s", task_info.id, task_info.cmd)
    local ok, set_err = pcall(vim.fn.setqflist, {}, " ", {
        title = title,
        lines = plain_lines,
        efm = efm,
    })
    if not ok then
        notify_err(tostring(set_err))
        return
    end

    local qf = vim.fn.getqflist({ size = 1 })
    local size = tonumber(qf.size) or 0
    if size < 1 then
        vim.notify(string.format("Flyout: no quickfix entries parsed for task #%d", task_id), vim.log.levels.WARN)
        return
    end

    vim.cmd("copen")
    pcall(function()
        vim.cmd("cfirst")
    end)
end

function M.set_task_quickfix_parser(task_id, parser)
    local id = tonumber(task_id)
    if not id then
        return
    end

    if type(parser) == "string" and parser ~= "" then
        task_quickfix_parser[id] = parser
    else
        task_quickfix_parser[id] = nil
    end
end

function M.quickfix_parsers()
    local names = {}
    for name, _ in pairs(merged_quickfix_presets()) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function M.configure_quickfix(opts)
    opts = opts or {}

    if type(opts.parsers) == "table" then
        quickfix_user_presets = vim.deepcopy(opts.parsers)
    else
        quickfix_user_presets = {}
    end
end

function M.setup(opts)
    ui_opts = vim.tbl_deep_extend("force", {}, ui_defaults, opts or {})
end

function M.open_task_list()
    local required_list_width = task_list_required_width()
    list_min_width =
        math.max(required_list_width, resolve_width(ui_opts.task_list_width, vim.o.columns, required_list_width))

    if list_state.win and vim.api.nvim_win_is_valid(list_state.win) then
        vim.api.nvim_set_current_win(list_state.win)
        render_task_list()
        return
    end

    local buf, win = make_float("Flyout Tasks", list_min_width, 18)
    local list_open_pos = resolve_task_list_open_position(list_min_width, 18)
    vim.api.nvim_win_set_config(win, {
        relative = "editor",
        border = "rounded",
        row = list_open_pos.row,
        col = list_open_pos.col,
        width = list_min_width,
        height = 18,
        title = "Flyout Tasks",
        title_pos = "center",
        style = "minimal",
    })
    list_state.buf = buf
    list_state.win = win
    list_state.selectable_start = nil
    list_state.selectable_end = nil
    vim.bo[buf].filetype = "flyout-tasks"
    vim.wo[win].cursorline = true
    vim.wo[win].cursorlineopt = "line"

    vim.keymap.set("n", "q", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, silent = true })

    vim.keymap.set("n", "R", render_task_list, { buffer = buf, silent = true })
    vim.keymap.set("n", "<CR>", function()
        local task_id = current_task_id_from_list()
        if task_id then
            M.open_task_log(task_id)
        end
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "s", function()
        with_selected_task(function(task_id)
            local _, err = task.stop(task_id)
            if err then
                notify_err(err)
                return
            end
            vim.notify(string.format("Flyout: stopping task #%d", task_id))
        end)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "r", function()
        with_selected_task(function(task_id)
            local started, err = task.rerun(task_id)
            if not started then
                notify_err(err)
                return
            end
            vim.notify(string.format("Flyout: started task #%d", started.id))
            notify_task_restarted(task_id, started.started_at)
        end)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "S", function()
        with_selected_task(M.open_task_log_split)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "V", function()
        with_selected_task(M.open_task_log_vsplit)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "T", function()
        with_selected_task(M.open_task_log_tab)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "c", function()
        task.clear_finished()
        render_task_list()
        vim.notify("Flyout: cleared finished tasks")
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "x", function()
        with_selected_task(M.open_task_quickfix)
    end, { buffer = buf, silent = true })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            stop_timer(list_state.timer)
            close_task_list_preview()
            list_state.buf = nil
            list_state.win = nil
            list_state.line_to_task_id = {}
            list_state.selectable_start = nil
            list_state.selectable_end = nil
            list_state.timer = nil
        end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = clamp_task_list_cursor,
    })

    setup_list_autorefresh()
    render_task_list()
end

return M
