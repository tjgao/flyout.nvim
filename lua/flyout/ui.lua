local M = {}

local uv = vim.uv
local task = require("flyout.task")
local notifier = require("flyout.notifier")
local ns = vim.api.nvim_create_namespace("flyout-ui")

local col_width = {
    task = 7,
    pid = 8,
    state = 10,
    runtime = 10,
}

local min_command_col_width = 8

local list_padding = {
    x = 2,
    y = 0,
}

local preview_padding = {
    x = 2,
    y = 1,
}

local ui_defaults = {
    preview_enabled = true,
    task_list_width = "50%",
    task_list_height = "25%",
    preview_height = "40%",
    log_terminal_scrollback = 200000,
}

local ui_opts = vim.deepcopy(ui_defaults)

local list_min_width = nil
local preview_gap = 0
local list_zindex = 40
local preview_zindex = 41
local preview_border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" }
local task_list_footer =
"[Enter] open  [s] stop  [dd] delete  [q] exit  [?] help"

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

local log_float_wins = {}
local task_quickfix_parser = {}
local quickfix_parse_state = {}
local update_task_list_preview
local request_task_list_preview_update
local open_preview_terminal
local ensure_log_buffer

local quickfix_presets = {
    gcc = {
        efm =
        "%E%f:%l:%c: error: %m,%E%f:%l: error: %m,%W%f:%l:%c: warning: %m,%W%f:%l: warning: %m,%I%f:%l:%c: note: %m,%I%f:%l: note: %m,%E%f:%l:%c: fatal error: %m,%E%f:%l: fatal error: %m,%-G%.%#",
    },
    msvc = {
        efm = "%f(%l,%c): %t%*[^:]: %m,%f(%l): %t%*[^:]: %m,%-G%.%#",
    },
    rust = {
        efm = [=[%Eerror\[%*[^]]\]: %m,%Wwarning\[%*[^]]\]: %m,%C %#--> %f:%l:%c,%C %m,%-G%.%#]=],
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

local function is_valid_errorformat(efm)
    if type(efm) ~= "string" or efm == "" then
        return false
    end
    return pcall(vim.fn.setqflist, {}, " ", {
        lines = {},
        efm = efm,
    })
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

local function resolve_task_list_open_position(width, height, preview_height)
    local list_col = math.max(0, math.floor((vim.o.columns - (width + 2)) / 2))
    local list_row = math.floor((vim.o.lines - height) / 2 - 1)

    if ui_opts.preview_enabled then
        local pheight = math.max(6, math.floor(preview_height or height))
        local combined_outer_height = height + pheight + preview_gap + 3
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
    notifier.notify("Flyout: " .. err, vim.log.levels.ERROR)
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

local function resolve_task_list_height()
    local fallback = "25%"
    local min_height = 8
    local height = resolve_width(ui_opts.task_list_height, vim.o.lines, fallback)
    height = math.max(min_height, math.floor(height))
    height = math.min(height, math.max(min_height, vim.o.lines - 4))
    return height
end

local function resolve_preview_height(list_height)
    local fallback = "40%"
    local height = resolve_width(ui_opts.preview_height, vim.o.lines, fallback)
    height = math.max(6, math.floor(height))
    height = math.min(height, math.max(6, vim.o.lines - 4))
    return height
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

    if item.status == "timeout" then
        return "TIMEOUT", "DiagnosticError"
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
    local preview_height = resolve_preview_height(list_height)
    local preview_col = 0
    local preview_row = 0

    local combined_outer_height = list_height + preview_height + preview_gap + 3
    if combined_outer_height > vim.o.lines then
        close_task_list_preview()
        center_task_list_window()
        return false
    end

    local list_col = math.max(0, math.floor((vim.o.columns - (list_width + 2)) / 2))
    local start_row = math.max(0, math.floor((vim.o.lines - combined_outer_height) / 2 - 1))
    cfg.col = list_col
    cfg.row = start_row
    cfg.zindex = list_zindex
    preview_col = list_col
    preview_row = start_row + list_height + preview_gap + 1

    vim.api.nvim_win_set_config(list_state.win, cfg)

    if list_state.preview_win and vim.api.nvim_win_is_valid(list_state.preview_win) then
        local preview_cfg = vim.api.nvim_win_get_config(list_state.preview_win)
        preview_cfg.row = math.max(0, math.floor(preview_row))
        preview_cfg.col = math.max(0, math.floor(preview_col))
        preview_cfg.width = preview_width
        preview_cfg.height = preview_height
        preview_cfg.zindex = preview_zindex
        preview_cfg.border = preview_border
        preview_cfg.focusable = false
        preview_cfg.footer = task_list_footer
        preview_cfg.footer_pos = "center"
        vim.api.nvim_win_set_config(list_state.preview_win, preview_cfg)
        vim.wo[list_state.preview_win].number = false
        vim.wo[list_state.preview_win].relativenumber = false
        return true
    end

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
        relative = "editor",
        border = preview_border,
        row = math.max(0, math.floor(preview_row)),
        col = math.max(0, math.floor(preview_col)),
        width = preview_width,
        height = preview_height,
        zindex = preview_zindex,
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
            vim.api.nvim_buf_set_lines(
                preview_buf,
                0,
                -1,
                false,
                with_preview_padding({ "Select a task to preview output." })
            )
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

    open_preview_terminal(task_id, preview_win)
    list_state.preview_task_id = task_id
    list_state.preview_started_at = task_info.started_at
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
        notifier.notify("Flyout: no task selected", vim.log.levels.WARN)
        return
    end
    action(task_id)
    render_task_list()
end

local function select_task_quickfix_parser(task_id, always_pick, callback)
    local id = tonumber(task_id)
    if not id then
        return
    end

    local current = task_quickfix_parser[id]
    if not always_pick and type(current) == "string" and current ~= "" then
        callback(current, false)
        return
    end

    local parsers = M.quickfix_parsers()
    local items = {
        {
            id = "none",
            label = "none (disable)",
        },
    }

    for _, name in ipairs(parsers) do
        table.insert(items, {
            id = name,
            label = name,
        })
    end

    vim.ui.select(items, {
        prompt = string.format("Flyout quickfix parser for #%d", id),
        kind = "list",
        snacks = {
            focus = "list",
        },
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if not choice then
            return
        end

        if choice.id == "none" then
            task_quickfix_parser[id] = nil
            notifier.notify(string.format("Flyout: disabled quickfix parser for task #%d", id), vim.log.levels.INFO, {
                timeout = 1500,
                hide_from_history = true,
            })
            callback(nil, true)
            return
        end

        task_quickfix_parser[id] = choice.id
        callback(choice.id, false)
    end)
end

local function run_task_quickfix_from_list(always_pick)
    local task_id = current_task_id_from_list()
    if not task_id then
        notifier.notify("Flyout: no task selected", vim.log.levels.WARN)
        return
    end

    select_task_quickfix_parser(task_id, always_pick, function(parser, disabled)
        render_task_list()
        if disabled or not parser then
            return
        end
        M.open_task_quickfix(task_id, {
            parser = parser,
        })
    end)
end

local function open_task_list_help()
    local lines = {
        "Flyout Task List Help",
        "",
        "Enter  Open log float",
        "S      Open log split",
        "V      Open log vsplit",
        "T      Open log tab",
        "x      Parse quickfix (pick if unset)",
        "X      Change quickfix parser",
        "s      Stop task",
        "r      Rerun task",
        "dd     Delete task",
        "c      Clear finished tasks",
        "R      Refresh list",
        "q/Esc  Close task list",
        "",
        "Press q or Esc to close this help.",
    }

    local width = 54
    local height = #lines
    local buf, win = make_float("Flyout Help", width, height)
    ensure_log_buffer(buf)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.keymap.set("n", "q", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "<Esc>", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, silent = true })
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

local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local content = fd:read("*a")
    fd:close()
    return content
end

local function unlink_file(path)
    if path and path ~= "" then
        pcall(uv.fs_unlink, path)
    end
end

local function stop_quickfix_parse_ui(task_id)
    local state = quickfix_parse_state[task_id]
    if not state then
        return
    end

    if state.timer and not state.timer:is_closing() then
        state.timer:stop()
        state.timer:close()
    end

    if state.handle and type(state.handle) == "table" then
        notifier.close(state.handle)
    end
end

local function finish_quickfix_parse(task_id, payload)
    local state = quickfix_parse_state[task_id]
    if not state then
        return
    end

    stop_quickfix_parse_ui(task_id)
    quickfix_parse_state[task_id] = nil

    for _, cb in ipairs(state.callbacks or {}) do
        pcall(cb, payload or {})
    end
end

local function begin_quickfix_parse(task_id, cmd, on_done)
    local state = quickfix_parse_state[task_id]
    if state then
        if on_done then
            table.insert(state.callbacks, on_done)
        end
        return false
    end

    local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
    state = {
        idx = 1,
        timer = nil,
        handle = nil,
        callbacks = {},
    }
    if on_done then
        table.insert(state.callbacks, on_done)
    end
    quickfix_parse_state[task_id] = state

    local function push()
        local frame = frames[state.idx]
        state.idx = (state.idx % #frames) + 1
        local handle = notifier.notify(string.format("%s parsing quickfix #%d: %s", frame, task_id, cmd), vim.log.levels.INFO, {
            replace = state.handle,
            title = "Flyout",
            timeout = false,
            hide_from_history = true,
        })
        if handle ~= nil then
            state.handle = handle
        end
    end

    push()
    local timer = uv.new_timer()
    if timer then
        state.timer = timer
        timer:start(120, 120, function()
            vim.schedule(function()
                if quickfix_parse_state[task_id] ~= state then
                    return
                end
                push()
            end)
        end)
    end

    return true
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

local function shell_quote_single(value)
    return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

local function terminal_follow_command(path)
    return string.format("tail -n +1 -f -- %s", shell_quote_single(path))
end

local function terminal_scrollback_value()
    local value = tonumber(ui_opts.log_terminal_scrollback)
    if not value then
        value = 200000
    end
    value = math.floor(value)
    if value == -1 then
        return 1000000
    end
    if value < 1 then
        return 1
    end
    return value
end

local function attach_terminal_log_view(task_id, buf, win, opts)
    local task_info, err = task.get(task_id)
    if not task_info then
        notify_err(err)
        return
    end

    opts = opts or {}
    local allow_close = opts.allow_close ~= false
    local allow_task_actions = opts.allow_task_actions ~= false
    local allow_open_targets = opts.allow_open_targets == true

    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buflisted = false

    local cmd = terminal_follow_command(task_info.output_path)
    local ok_termopen, chan = pcall(function()
        return vim.api.nvim_win_call(win, function()
            return vim.fn.jobstart({ "sh", "-c", cmd }, { term = true })
        end)
    end)
    if not ok_termopen or type(chan) ~= "number" or chan <= 0 then
        notify_err("failed to open terminal log view")
        return
    end

    set_log_buffer_name(buf, task_id, task_info.cmd)
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
            set_log_buffer_name(buf, task_id, task_info.cmd)
        end
    end)

    pcall(vim.api.nvim_set_option_value, "scrollback", terminal_scrollback_value(), { buf = buf })

    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
        vim.wo[win].cursorline = false
        vim.defer_fn(function()
            if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
                scroll_win_to_bottom(win, buf)
            end
        end, 60)
    end

    if allow_close then
        vim.keymap.set("n", "q", function()
            local target = nil
            if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
                target = win
            else
                local current = vim.api.nvim_get_current_win()
                if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == buf then
                    target = current
                end
            end

            if target and vim.api.nvim_win_is_valid(target) then
                vim.api.nvim_win_close(target, true)
            end
        end, { buffer = buf, silent = true })
        vim.keymap.set("n", "<Esc>", function()
            local target = nil
            if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
                target = win
            else
                local current = vim.api.nvim_get_current_win()
                if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == buf then
                    target = current
                end
            end

            if target and vim.api.nvim_win_is_valid(target) then
                vim.api.nvim_win_close(target, true)
            end
        end, { buffer = buf, silent = true })
    end

    if allow_task_actions then
        vim.keymap.set("n", "s", function()
            local _, stop_err = task.stop(task_id)
            if stop_err then
                notify_err(stop_err)
            end
        end, { buffer = buf, silent = true })
        vim.keymap.set("n", "r", function()
            local restarted, restart_err = task.rerun(task_id)
            if not restarted then
                notify_err(restart_err)
                return
            end
        end, { buffer = buf, silent = true })
    end

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
            local float_win = log_float_wins[task_id]
            if float_win and (not vim.api.nvim_win_is_valid(float_win) or vim.api.nvim_win_get_buf(float_win) == buf) then
                log_float_wins[task_id] = nil
            end
        end,
    })
end

open_preview_terminal = function(task_id, preview_win)
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
        return
    end

    local preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(preview_win, preview_buf)
    attach_terminal_log_view(task_id, preview_buf, preview_win, {
        allow_close = false,
        allow_task_actions = false,
        allow_open_targets = false,
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
    attach_terminal_log_view(task_id, buf, win, { show_header = false })

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
    attach_terminal_log_view(task_id, buf, win, {
        show_header = true,
        allow_task_actions = false,
        allow_open_targets = true,
    })

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
    opts = opts or {}
    local on_done = type(opts.on_done) == "function" and opts.on_done or nil
    local show_parse_ui = on_done == nil
    local function finish(payload)
        local id = tonumber(task_id)
        if id and quickfix_parse_state[id] then
            finish_quickfix_parse(id, payload)
        end
        if on_done then
            pcall(on_done, payload or {})
        end
    end

    local task_info, err = task.get(task_id)
    if not task_info then
        notify_err(err)
        finish({ ok = false, err = err })
        return
    end

    local id = tonumber(task_id)
    if show_parse_ui and id and not begin_quickfix_parse(id, task_info.cmd, on_done) then
        return
    end
    if id and type(opts.parser) == "string" and opts.parser ~= "" then
        task_quickfix_parser[id] = opts.parser
    end
    if id and (not opts.parser or opts.parser == "") and task_quickfix_parser[id] then
        opts.parser = task_quickfix_parser[id]
    end
    local efm, efm_err = resolve_quickfix_errorformat(opts)
    if not efm then
        notify_err(efm_err)
        finish({ ok = false, err = efm_err })
        return
    end

    if not is_valid_errorformat(efm) then
        local parser_name = opts.parser or "default"
        local parser_key = type(parser_name) == "string" and parser_name:lower() or nil
        local builtin = parser_key and quickfix_presets[parser_key] and quickfix_presets[parser_key].efm or nil
        if builtin and builtin ~= efm and is_valid_errorformat(builtin) then
            efm = builtin
        else
            local msg = string.format("invalid quickfix errorformat for parser '%s'", parser_name)
            notify_err(msg)
            finish({ ok = false, err = msg })
            return
        end
    end

    local worker_script = vim.api.nvim_get_runtime_file("lua/flyout/quickfix_worker.lua", false)[1]
    if not worker_script then
        notify_err("quickfix worker script not found")
        finish({ ok = false, err = "quickfix worker script not found" })
        return
    end

    local out_file = vim.fn.tempname()

    vim.system({
        vim.v.progpath,
        "--clean",
        "--headless",
        "--noplugin",
        "-u",
        "NONE",
        "-l",
        worker_script,
    }, {
        text = true,
        env = {
            FLYOUT_QF_LOG = task_info.output_path,
            FLYOUT_QF_EFM = efm,
            FLYOUT_QF_OUT = out_file,
        },
    }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                unlink_file(out_file)
                local stderr = (obj.stderr or ""):gsub("%s+$", "")
                if stderr == "" then
                    stderr = "quickfix parser worker failed"
                end
                local parser_name = opts.parser or task_quickfix_parser[id] or "default"
                local msg = string.format("quickfix parser '%s' failed: %s", parser_name, stderr)
                notify_err(msg)
                finish({ ok = false, err = msg })
                return
            end

            local payload = read_file(out_file)
            unlink_file(out_file)
            if type(payload) ~= "string" then
                notify_err("failed to read quickfix parser output")
                finish({ ok = false, err = "failed to read quickfix parser output" })
                return
            end

            local ok_decode, items = pcall(vim.json.decode, payload)
            if not ok_decode or type(items) ~= "table" then
                notify_err("failed to decode quickfix parser output")
                finish({ ok = false, err = "failed to decode quickfix parser output" })
                return
            end

            local title = opts.title or string.format("Flyout #%d: %s", task_info.id, task_info.cmd)
            local ok_set, set_err = pcall(vim.fn.setqflist, {}, " ", {
                title = title,
                items = items,
            })
            if not ok_set then
                notify_err(tostring(set_err))
                finish({ ok = false, err = tostring(set_err) })
                return
            end

            local qf = vim.fn.getqflist({ size = 1 })
            local size = tonumber(qf.size) or 0
            if size < 1 then
                finish({ ok = true, count = 0 })
                return
            end

            local origin_win = vim.api.nvim_get_current_win()
            vim.cmd("copen")
            if origin_win and vim.api.nvim_win_is_valid(origin_win) then
                vim.api.nvim_set_current_win(origin_win)
            end
            finish({ ok = true, count = size })
        end)
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

function M.get_task_quickfix_parser(task_id)
    local id = tonumber(task_id)
    if not id then
        return nil
    end
    return task_quickfix_parser[id]
end

function M.release_task_resources(task_id)
    local id = tonumber(task_id)
    if not id then
        return
    end

    task_quickfix_parser[id] = nil
    if quickfix_parse_state[id] then
        stop_quickfix_parse_ui(id)
        quickfix_parse_state[id] = nil
    end

    local float_win = log_float_wins[id]
    if float_win and vim.api.nvim_win_is_valid(float_win) then
        pcall(vim.api.nvim_win_close, float_win, true)
    end
    log_float_wins[id] = nil

    local prefix = string.format("#%d:", id)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local ft = vim.bo[buf].filetype
            if ft == "flyout-log" then
                local name = vim.api.nvim_buf_get_name(buf)
                if type(name) == "string" and name:sub(1, #prefix) == prefix then
                    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                        if vim.api.nvim_win_is_valid(win) then
                            pcall(vim.api.nvim_win_close, win, true)
                        end
                    end
                    if vim.api.nvim_buf_is_valid(buf) then
                        pcall(vim.api.nvim_buf_delete, buf, { force = true })
                    end
                end
            end
        end
    end

    if list_state.preview_task_id == id then
        list_state.preview_task_id = nil
        list_state.preview_started_at = nil
        request_task_list_preview_update()
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
    local list_height = resolve_task_list_height()
    local preview_height = resolve_preview_height(list_height)
    list_min_width =
        math.max(required_list_width, resolve_width(ui_opts.task_list_width, vim.o.columns, required_list_width))

    if list_state.win and vim.api.nvim_win_is_valid(list_state.win) then
        vim.api.nvim_set_current_win(list_state.win)
        render_task_list()
        return
    end

    local buf, win = make_float("Flyout Tasks", list_min_width, list_height)
    local list_open_pos = resolve_task_list_open_position(list_min_width, list_height, preview_height)
    vim.api.nvim_win_set_config(win, {
        relative = "editor",
        border = "rounded",
        row = list_open_pos.row,
        col = list_open_pos.col,
        width = list_min_width,
        height = list_height,
        zindex = list_zindex,
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
    vim.keymap.set("n", "<Esc>", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, silent = true })

    vim.keymap.set("n", "R", render_task_list, { buffer = buf, silent = true })
    vim.keymap.set("n", "?", open_task_list_help, { buffer = buf, silent = true })
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
        end)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "r", function()
        with_selected_task(function(task_id)
            local started, err = task.rerun(task_id)
            if not started then
                notify_err(err)
                return
            end
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
        notifier.notify("Flyout: cleared finished tasks")
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "dd", function()
        with_selected_task(function(task_id)
            local _, err = task.delete(task_id)
            if err then
                notify_err(err)
                return
            end
            M.release_task_resources(task_id)
        end)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "x", function()
        run_task_quickfix_from_list(false)
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "X", function()
        run_task_quickfix_from_list(true)
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
