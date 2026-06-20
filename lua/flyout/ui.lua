local M = {}

local uv = vim.uv
local task = require("flyout.task")
local ns = vim.api.nvim_create_namespace("flyout-ui")
local log_ns = vim.api.nvim_create_namespace("flyout-log")

local col_width = {
    task = 7,
    pid = 8,
    state = 10,
}

local command_col_width = 20

local list_padding = {
    x = 2,
    y = 1,
}

local list_min_width = nil
local preview_min_width = 44
local preview_gap = 2

local list_state = {
    buf = nil,
    win = nil,
    timer = nil,
    line_to_task_id = {},
    selectable_start = nil,
    selectable_end = nil,
    preview_win = nil,
    preview_task_id = nil,
    preview_update_timer = nil,
}

local log_streams = {}
local log_float_wins = {}
local attach_log_view
local update_task_list_preview
local request_task_list_preview_update
local ensure_log_buffer

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

local function stop_timer(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

local function notify_err(err)
    vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
end

local function task_list_required_width()
    local fields = col_width.task + 1 + col_width.pid + 1 + col_width.state + 1 + command_col_width
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

local function display_state(item)
    if item.status == "pending" then
        return "PENDING", "DiagnosticWarn"
    end

    if item.status == "running" or item.status == "stopping" then
        return "RUNNING", "DiagnosticWarn"
    end

    if item.status == "success" and item.exit_code == 0 then
        return "DONE", "DiagnosticOk"
    end

    if item.status == "failed" and item.exit_code ~= nil then
        return "FAILED", "DiagnosticError"
    end

    return "n/a", "Comment"
end

local function display_pid(item)
    if item.pid then
        return tostring(item.pid), nil
    end
    return "n/a", "Comment"
end

local function format_task_line(item)
    local pid = display_pid(item)
    local state = display_state(item)
    local cmd = truncate_display(item.cmd, command_col_width)

    return string.format(
        "%-" .. col_width.task .. "s %" .. col_width.pid .. "s %-" .. col_width.state .. "s %s",
        "#" .. item.id,
        pid,
        state,
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
    local lines = {}
    local left_pad = string.rep(" ", list_padding.x)
    local first_task_line = list_padding.y + 1

    for _ = 1, list_padding.y do
        table.insert(lines, "")
    end

    list_state.line_to_task_id = {}
    local field_hl = {}
    local pid_col = list_padding.x + col_width.task + 1
    local state_col = list_padding.x + col_width.task + 1 + col_width.pid + 1

    for _, item in ipairs(tasks) do
        local pid, pid_hl = display_pid(item)
        local state, state_hl = display_state(item)
        local line = left_pad .. format_task_line(item) .. left_pad
        table.insert(lines, line)
        list_state.line_to_task_id[#lines] = item.id

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
    stop_timer(list_state.preview_update_timer)
    list_state.preview_update_timer = nil
    if list_state.preview_win and vim.api.nvim_win_is_valid(list_state.preview_win) then
        vim.api.nvim_win_close(list_state.preview_win, true)
    end
    list_state.preview_win = nil
    list_state.preview_task_id = nil
end

local function ensure_task_list_preview_window()
    if not (list_state.win and vim.api.nvim_win_is_valid(list_state.win)) then
        close_task_list_preview()
        return false
    end

    local required_list_width = list_min_width or task_list_required_width()
    local cfg = vim.api.nvim_win_get_config(list_state.win)
    local list_width = tonumber(cfg.width) or 0
    local list_height = tonumber(cfg.height) or 0
    local list_row = tonumber(cfg.row) or 0

    if list_width < required_list_width then
        cfg.width = required_list_width
        vim.api.nvim_win_set_config(list_state.win, cfg)
        list_width = required_list_width
    end

    local preview_width = preview_min_width
    local combined_outer_width = list_width + preview_width + preview_gap + 4
    if combined_outer_width > vim.o.columns then
        close_task_list_preview()
        center_task_list_window()
        return false
    end

    local start_col = math.max(0, math.floor((vim.o.columns - combined_outer_width) / 2))
    local list_col = start_col
    local preview_col = list_col + list_width + preview_gap + 2

    cfg.col = list_col
    vim.api.nvim_win_set_config(list_state.win, cfg)

    if list_state.preview_win and vim.api.nvim_win_is_valid(list_state.preview_win) then
        local preview_cfg = vim.api.nvim_win_get_config(list_state.preview_win)
        preview_cfg.row = math.max(0, math.floor(list_row))
        preview_cfg.col = math.max(0, math.floor(preview_col))
        preview_cfg.width = preview_width
        preview_cfg.height = math.max(6, math.floor(list_height))
        vim.api.nvim_win_set_config(list_state.preview_win, preview_cfg)
        return true
    end

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
        relative = "editor",
        border = "rounded",
        row = math.max(0, math.floor(list_row)),
        col = math.max(0, math.floor(preview_col)),
        width = preview_width,
        height = math.max(6, math.floor(list_height)),
        title = "Flyout Preview",
        title_pos = "center",
        style = "minimal",
    })

    list_state.preview_win = preview_win
    list_state.preview_task_id = nil
    ensure_log_buffer(preview_buf)
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "Select a task to preview output." })
    vim.bo[preview_buf].modifiable = false

    vim.api.nvim_create_autocmd("WinClosed", {
        once = true,
        callback = function(args)
            if tonumber(args.match) == preview_win then
                list_state.preview_win = nil
                list_state.preview_task_id = nil
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
        local preview_win = list_state.preview_win
        if preview_win and vim.api.nvim_win_is_valid(preview_win) then
            local preview_buf = vim.api.nvim_create_buf(false, true)
            ensure_log_buffer(preview_buf)
            vim.bo[preview_buf].modifiable = true
            vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "Select a task to preview output." })
            vim.bo[preview_buf].modifiable = false
            vim.api.nvim_win_set_buf(preview_win, preview_buf)
        end
        return
    end

    if list_state.preview_task_id == task_id then
        return
    end

    local preview_win = list_state.preview_win
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
        return
    end

    local preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(preview_win, preview_buf)
    attach_log_view(task_id, preview_buf, preview_win, {
        show_header = true,
        allow_close = false,
    })
    list_state.preview_task_id = task_id
    if vim.api.nvim_win_is_valid(preview_win) and vim.api.nvim_win_get_buf(preview_win) == preview_buf then
        vim.api.nvim_win_set_cursor(preview_win, { vim.api.nvim_buf_line_count(preview_buf), 0 })
    end
end

request_task_list_preview_update = function()
    if not (list_state.buf and vim.api.nvim_buf_is_valid(list_state.buf)) then
        return
    end

    stop_timer(list_state.preview_update_timer)
    list_state.preview_update_timer = uv.new_timer()
    list_state.preview_update_timer:start(60, 0, function()
        vim.schedule(function()
            stop_timer(list_state.preview_update_timer)
            list_state.preview_update_timer = nil
            if not (list_state.buf and vim.api.nvim_buf_is_valid(list_state.buf)) then
                return
            end
            update_task_list_preview()
        end)
    end)
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
    list_state.timer:start(0, 700, function()
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

local function parse_ansi_line(line)
    line = normalize_output_line(line)

    local pieces = {}
    local spans = {}
    local col = 0
    local idx = 1
    local active_hl = nil

    while true do
        local s, e, codes = line:find("\27%[([%d;]*)m", idx)
        local text_end = s and (s - 1) or #line
        if text_end >= idx then
            local chunk = line:sub(idx, text_end)
            local chunk_len = #chunk
            table.insert(pieces, chunk)
            if active_hl and chunk_len > 0 then
                table.insert(spans, {
                    start_col = col,
                    end_col = col + chunk_len,
                    hl_group = active_hl,
                })
            end
            col = col + chunk_len
        end

        if not s then
            break
        end

        if codes == "" then
            active_hl = nil
        else
            for code_str in codes:gmatch("%d+") do
                local code = tonumber(code_str)
                if code == 0 or code == 39 then
                    active_hl = nil
                elseif ansi_hl_by_code[code] then
                    active_hl = ansi_hl_by_code[code]
                end
            end
        end

        idx = e + 1
    end

    return table.concat(pieces), spans
end

local function close_current_window_for_buffer(buf)
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == buf then
        vim.api.nvim_win_close(current, true)
    end
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
    vim.bo[view.buf].modifiable = true
    vim.api.nvim_buf_set_lines(view.buf, 0, view.header_lines, false, header)
    vim.bo[view.buf].modifiable = false
end

local function stream_clear_body(view)
    if not vim.api.nvim_buf_is_valid(view.buf) then
        return
    end
    vim.bo[view.buf].modifiable = true
    vim.api.nvim_buf_set_lines(view.buf, view.header_lines, -1, false, {})
    vim.bo[view.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(view.buf, log_ns, view.header_lines, -1)
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
    for i, raw_line in ipairs(lines) do
        local plain, spans = parse_ansi_line(raw_line)
        rendered[i] = plain
        if #spans > 0 then
            highlights[i] = spans
        end
    end

    local start_idx = vim.api.nvim_buf_line_count(view.buf)
    vim.bo[view.buf].modifiable = true
    vim.api.nvim_buf_set_lines(view.buf, -1, -1, false, rendered)
    vim.bo[view.buf].modifiable = false

    for rel, spans in pairs(highlights) do
        local row = start_idx + rel - 1
        for _, span in ipairs(spans) do
            vim.api.nvim_buf_set_extmark(view.buf, log_ns, row, span.start_col, {
                end_col = span.end_col,
                hl_group = span.hl_group,
            })
        end
    end

    if follow and view.win and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == view.buf then
        local new_last_line = vim.api.nvim_buf_line_count(view.buf)
        vim.api.nvim_win_set_cursor(view.win, { new_last_line, 0 })
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
    local view = {
        task_id = task_id,
        buf = buf,
        win = win,
        header_lines = header_lines,
    }

    vim.bo[buf].modifiable = true
    if header_lines > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            string.format("Task #%d [%s]", task_info.id, task_info.status),
            task_info.cmd,
            string.rep("-", 80),
        })
    else
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end
    vim.bo[buf].modifiable = false

    local stream = ensure_log_stream(task_id, task_info)
    local source_view = nil
    for _, existing in pairs(stream.views) do
        source_view = existing
        break
    end
    if source_view and vim.api.nvim_buf_is_valid(source_view.buf) then
        local body_lines = vim.api.nvim_buf_get_lines(source_view.buf, source_view.header_lines, -1, false)
        if #body_lines > 0 then
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, header_lines, -1, false, body_lines)
            vim.bo[buf].modifiable = false
        end
    end
    stream.views[buf] = view

    if allow_close then
        vim.keymap.set("n", "q", function()
            close_current_window_for_buffer(buf)
        end, { buffer = buf, silent = true })
    end
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
    vim.keymap.set("n", "G", function()
        if view.win and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == buf then
            local total = vim.api.nvim_buf_line_count(buf)
            vim.api.nvim_win_set_cursor(view.win, { total, 0 })
        end
    end, { buffer = buf, silent = true })

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
end

function M.open_task_log(task_id)
    local existing_win = log_float_wins[task_id]
    if existing_win and vim.api.nvim_win_is_valid(existing_win) then
        vim.api.nvim_set_current_win(existing_win)
        return
    end

    local buf, win = make_float(string.format("Flyout Log #%d", task_id), 110, 28)
    log_float_wins[task_id] = win
    attach_log_view(task_id, buf, win, { show_header = true })
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
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

function M.open_task_list()
    local required_list_width = task_list_required_width()
    list_min_width = required_list_width

    if list_state.win and vim.api.nvim_win_is_valid(list_state.win) then
        vim.api.nvim_set_current_win(list_state.win)
        render_task_list()
        return
    end

    local buf, win = make_float(
        "Flyout Tasks",
        required_list_width,
        18,
        "[Enter] float log  [S] split  [V] vsplit  [T] tab  [s] stop  [r] rerun  [c] clear  [R] refresh  [q] close"
    )
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
