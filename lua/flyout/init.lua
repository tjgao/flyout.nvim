local M = {}

local task = require("flyout.task")
local ui = require("flyout.ui")
local spinner_notifier = require("flyout.spinner_notifier")
local notifier = require("flyout.notifier")

local quickfix_defaults = {
    generate_commands = true,
    command_prefix = "F",
    command_completion = "auto",
}

local notification_defaults = {
    start = true,
    ["end"] = true,
    progress = {
        enabled = false,
        interval_ms = 120,
        frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    },
}

local generated_quickfix_commands = {}
local event_listener_ids = {}
local progress_state = {}
local quickfix_postprocess = {}

local function is_progress_active_status(status)
    return status == "pending" or status == "running"
end

local function normalize_quickfix_prefix(prefix)
    if type(prefix) ~= "string" or prefix == "" then
        return quickfix_defaults.command_prefix
    end
    if not prefix:match("^[A-Za-z][A-Za-z0-9]*$") then
        return quickfix_defaults.command_prefix
    end
    return prefix
end

local function resolve_command_completion(value)
    if value == "none" then
        return nil
    end
    if value == "shellcmd" or value == "file" then
        return value
    end

    if vim.fn.has("wsl") == 1 then
        return nil
    end
    return "shellcmd"
end

local function clear_generated_quickfix_commands()
    for _, name in ipairs(generated_quickfix_commands) do
        pcall(vim.api.nvim_del_user_command, name)
    end
    generated_quickfix_commands = {}
end

local function normalize_notify_config(global_defaults, override)
    local cfg = vim.tbl_deep_extend("force", {}, global_defaults or notification_defaults)
    if type(override) ~= "table" then
        return cfg
    end

    if override.start ~= nil then
        cfg.start = override.start == true
    end
    if override["end"] ~= nil then
        cfg["end"] = override["end"] == true
    end

    local progress = override.progress
    if type(progress) == "boolean" then
        cfg.progress.enabled = progress
    elseif type(progress) == "table" then
        if progress.enabled ~= nil then
            cfg.progress.enabled = progress.enabled == true
        end
        if progress.interval_ms ~= nil then
            local interval = tonumber(progress.interval_ms)
            if interval and interval > 0 then
                cfg.progress.interval_ms = math.floor(interval)
            end
        end
        if type(progress.frames) == "table" and #progress.frames > 0 then
            local frames = {}
            for _, frame in ipairs(progress.frames) do
                if type(frame) == "string" and frame ~= "" then
                    table.insert(frames, frame)
                end
            end
            if #frames > 0 then
                cfg.progress.frames = frames
            end
        end
    end

    return cfg
end

local function task_notify_config(task_info)
    local override = task_info and task_info.notify or nil
    return normalize_notify_config(M.notification_opts or notification_defaults, override)
end

local function stop_progress(task_id)
    local state = progress_state[task_id]
    if not state then
        return
    end

    if state.timer and not state.timer:is_closing() then
        state.timer:stop()
        state.timer:close()
    end
    spinner_notifier.remove(task_id)

    progress_state[task_id] = nil
end

local function notify_task_end(task_info)
    if task_info.status == "success" then
        notifier.notify(string.format("Flyout: task #%d finished", task_info.id))
    elseif task_info.status == "timeout" then
        notifier.notify(string.format("Flyout: task #%d timed out", task_info.id), vim.log.levels.WARN)
    elseif task_info.status == "stopped" or task_info.status == "killed" then
        notifier.notify(string.format("Flyout: task #%d stopped", task_info.id), vim.log.levels.WARN)
    else
        notifier.notify(string.format("Flyout: task #%d failed", task_info.id), vim.log.levels.ERROR)
    end
end

local function complete_quickfix_postprocess(task_id)
    local pending = quickfix_postprocess[task_id]
    if not pending then
        return
    end

    quickfix_postprocess[task_id] = nil
    stop_progress(task_id)

    if pending.notify_cfg and pending.notify_cfg["end"] and pending.task_info then
        notify_task_end(pending.task_info)
    end
end

local function start_progress(task_info, notify_cfg)
    if not notify_cfg.progress.enabled then
        return
    end

    stop_progress(task_info.id)

    local frames = notify_cfg.progress.frames
    if type(frames) ~= "table" or #frames == 0 then
        frames = notification_defaults.progress.frames
    end

    local timer = vim.uv.new_timer()
    if not timer then
        return
    end

    local state = {
        timer = timer,
        idx = 1,
    }
    progress_state[task_info.id] = state

    local interval = notify_cfg.progress.interval_ms
    if type(interval) ~= "number" or interval <= 0 then
        interval = notification_defaults.progress.interval_ms
    end

    timer:start(0, interval, function()
        vim.schedule(function()
            if progress_state[task_info.id] ~= state then
                return
            end

            local current, err = task.get(task_info.id)
            if not current then
                stop_progress(task_info.id)
                quickfix_postprocess[task_info.id] = nil
                return
            end
            local quickfix_pending = quickfix_postprocess[current.id]
            local quickfix_parsing = quickfix_pending and quickfix_pending.parsing == true
            if not is_progress_active_status(current.status) and not quickfix_pending then
                stop_progress(task_info.id)
                return
            end

            local frame = frames[state.idx]
            state.idx = (state.idx % #frames) + 1
            local msg = string.format("%s #%d %s", frame, current.id, current.cmd)
            if quickfix_parsing then
                msg = string.format("%s #%d parsing quickfix: %s", frame, current.id, current.cmd)
            end
            spinner_notifier.set(current.id, msg)
        end)
    end)
end

local function clear_event_listeners()
    for _, item in ipairs(event_listener_ids) do
        task.off(item.event, item.id)
    end
    event_listener_ids = {}
end

local function add_listener(event, callback)
    local id, err = task.on(event, callback)
    if not id then
        notifier.notify("Flyout: " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    table.insert(event_listener_ids, {
        event = event,
        id = id,
    })
end

local function setup_notifications(opts)
    M.notification_opts = normalize_notify_config(notification_defaults, opts or {})

    clear_event_listeners()

    add_listener("start", function(payload)
        local task_info = payload.task
        local notify_cfg = task_notify_config(task_info)
        if notify_cfg.start then
            notifier.notify(string.format("Flyout: started task #%d", task_info.id))
        end
        start_progress(task_info, notify_cfg)

        local parser = ui.get_task_quickfix_parser(task_info.id)
        if type(parser) == "string" and parser ~= "" and not quickfix_postprocess[task_info.id] then
            quickfix_postprocess[task_info.id] = {
                parser = parser,
                task_info = task_info,
                parsing = false,
            }
        end
    end)

    add_listener("ready", function(payload)
        stop_progress(payload.task.id)
    end)

    add_listener("timeout", function(payload)
        if payload.kind == "ready" then
            stop_progress(payload.task.id)
            return
        end
        stop_progress(payload.task.id)
    end)

    add_listener("exit", function(payload)
        local task_info = payload.task
        local notify_cfg = task_notify_config(task_info)
        local pending = quickfix_postprocess[task_info.id]
        if pending then
            pending.task_info = task_info
            pending.notify_cfg = notify_cfg
            if task_info.status == "stopped" or task_info.status == "killed" then
                complete_quickfix_postprocess(task_info.id)
                return
            end

            pending.parsing = true
            ui.open_task_quickfix(task_info.id, {
                parser = pending.parser,
                on_done = function()
                    complete_quickfix_postprocess(task_info.id)
                end,
            })
            return
        end

        stop_progress(task_info.id)
        if notify_cfg["end"] then
            notify_task_end(task_info)
        end
    end)
end

local function setup_notify_backend(opts)
    local ok, err = notifier.setup(opts or {})
    if not ok then
        vim.notify("Flyout: " .. tostring(err), vim.log.levels.ERROR)
    end
end

local function setup_generated_quickfix_commands(opts)
    clear_generated_quickfix_commands()

    if opts.generate_commands == false then
        return
    end

    local prefix = normalize_quickfix_prefix(opts.command_prefix)
    local completion = resolve_command_completion(opts.command_completion)
    local parsers = ui.quickfix_parsers()
    for _, parser in ipairs(parsers) do
        local cmd_name = prefix .. parser
        if vim.fn.exists(":" .. cmd_name) == 2 then
            notifier.notify(string.format("Flyout: command :%s already exists, skipping", cmd_name), vim.log.levels.WARN)
        else
            local cmd_opts = {
                nargs = "+",
            }
            if completion then
                cmd_opts.complete = completion
            end
            vim.api.nvim_create_user_command(cmd_name, function(copts)
                local _, err = M.run_quickfix(parser, copts.args)
                if err then
                    notifier.notify("Flyout: " .. err, vim.log.levels.ERROR)
                    return
                end
            end, cmd_opts)
            table.insert(generated_quickfix_commands, cmd_name)
        end
    end
end

function M.setup(opts)
    opts = opts or {}

    local task_opts = opts.task
    if not task_opts then
        task_opts = vim.deepcopy(opts)
        task_opts.ui = nil
        task_opts.quickfix = nil
        task_opts.notifications = nil
    end

    task.setup(task_opts)
    ui.setup(opts.ui or {})

    setup_notify_backend(opts.notifications or {})

    local quickfix_opts = vim.tbl_deep_extend("force", {}, quickfix_defaults, opts.quickfix or {})
    ui.configure_quickfix(quickfix_opts)
    setup_generated_quickfix_commands(quickfix_opts)
    setup_notifications(opts.notifications or {})
end

function M.start(cmd, opts)
    local start_opts = opts or {}
    local task_start_opts = {
        timeout_ms = start_opts.timeout_ms,
        ready_when = start_opts.ready_when,
        notify = start_opts.notify,
    }

    local started, err = task.start(cmd, task_start_opts)
    if not started then
        return nil, err
    end

    return started
end

function M.stop(task_id, opts)
    return task.stop(task_id, opts)
end

function M.rerun(task_id)
    return task.rerun(task_id)
end

function M.list()
    return task.list()
end

function M.get(task_id)
    return task.get(task_id)
end

function M.read_output(task_id, opts)
    return task.read_output(task_id, opts)
end

function M.clear_finished(opts)
    local before = task.list()
    local before_ids = {}
    for _, item in ipairs(before) do
        before_ids[item.id] = true
    end

    local result = task.clear_finished(opts)

    local after = task.list()
    local after_ids = {}
    for _, item in ipairs(after) do
        after_ids[item.id] = true
    end

    for id, _ in pairs(before_ids) do
        if not after_ids[id] then
            stop_progress(id)
            quickfix_postprocess[id] = nil
            ui.release_task_resources(id)
        end
    end

    return result
end

function M.shutdown(opts)
    for id, _ in pairs(progress_state) do
        stop_progress(id)
    end
    quickfix_postprocess = {}
    spinner_notifier.clear()
    return task.shutdown(opts)
end

function M.open_task_list()
    return ui.open_task_list()
end

function M.open_task_log(task_id)
    return ui.open_task_log(task_id)
end

function M.open_task_log_split(task_id)
    return ui.open_task_log_split(task_id)
end

function M.open_task_log_vsplit(task_id)
    return ui.open_task_log_vsplit(task_id)
end

function M.open_task_log_tab(task_id)
    return ui.open_task_log_tab(task_id)
end

function M.open_task_quickfix(task_id, opts)
    return ui.open_task_quickfix(task_id, opts)
end

function M.delete(task_id, opts)
    local deleted, err = task.delete(task_id, opts)
    if not deleted then
        return nil, err
    end

    local id = tonumber(task_id)
    if id then
        stop_progress(id)
        quickfix_postprocess[id] = nil
        ui.release_task_resources(id)
    end

    return deleted
end

function M.run_quickfix(parser, cmd)
    if type(cmd) ~= "string" or vim.trim(cmd) == "" then
        return nil, "command must be a non-empty string"
    end

    local started, start_err = M.start(cmd)
    if not started then
        return nil, start_err
    end

    ui.set_task_quickfix_parser(started.id, parser)
    quickfix_postprocess[started.id] = {
        parser = parser,
        task_info = started,
        parsing = false,
    }
    return started
end

function M.quickfix_parsers()
    return ui.quickfix_parsers()
end

function M.on(event, callback)
    return task.on(event, callback)
end

function M.off(event, listener_id)
    return task.off(event, listener_id)
end

return M
