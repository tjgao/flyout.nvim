local M = {}

local task = require("flyout.task")
local ui = require("flyout.ui")
local spinner_notifier = require("flyout.spinner_notifier")
local notifier = require("flyout.notifier")
local templates = require("flyout.templates")

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
local template_singletons = {}
local pipeline_runs = {}
local next_pipeline_run_id = 1
local pipeline_task_to_run = {}
local start_pipeline_step
local clear_pipeline_run
local dap_integration = {
    enabled = false,
    running_prelaunch = false,
    active_starts = {},
}

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

local function task_notify_label(task_info)
    local id = tonumber(task_info and task_info.id) or 0
    local meta = task_info and task_info.meta or nil
    local name = meta and meta.template_name
    if type(name) == "string" and name ~= "" then
        return string.format("%s (#%d)", name, id)
    end
    return string.format("task #%d", id)
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
    local label = task_notify_label(task_info)
    if task_info.status == "success" then
        notifier.notify(string.format("Flyout: %s finished", label))
    elseif task_info.status == "timeout" then
        notifier.notify(string.format("Flyout: %s timed out", label), vim.log.levels.WARN)
    elseif task_info.status == "stopped" or task_info.status == "killed" then
        notifier.notify(string.format("Flyout: %s stopped", label), vim.log.levels.WARN)
    else
        notifier.notify(string.format("Flyout: %s failed", label), vim.log.levels.ERROR)
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

local function confirmation_message(confirm_value, template_name)
    if confirm_value == true then
        return string.format("Run template '%s'?", template_name)
    end
    if type(confirm_value) == "string" and confirm_value ~= "" then
        return confirm_value
    end
    return nil
end

local function confirm_template_run(confirm_value, template_name)
    local msg = confirmation_message(confirm_value, template_name)
    if not msg then
        return true
    end
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    return choice == 1
end

local function template_start_opts(template, run_meta)
    local notify = {}
    if type(template.notify) == "table" then
        notify = vim.deepcopy(template.notify)
    end
    if template.progress ~= nil then
        notify.progress = template.progress
    end
    if next(notify) == nil then
        notify = nil
    end

    return {
        timeout_ms = template.timeout_ms,
        ready_when = template.ready_when,
        notify = notify,
        meta = run_meta,
    }
end

local function task_template_parser(parser)
    if type(parser) ~= "string" or parser == "" or parser == "default" then
        return nil
    end
    return parser
end

local function stop_pipeline_run(run_id)
    local state = pipeline_runs[run_id]
    if not state then
        return
    end

    state.cancelled = true
    for _, task_id in ipairs(state.started_task_ids) do
        local item = task.get(task_id)
        if item and (item.status == "running" or item.status == "stopping" or item.status == "pending") then
            task.stop(task_id)
        end
    end
end

local function stop_active_prelaunch_tasks()
    dap_integration.running_prelaunch = false
    local starts = dap_integration.active_starts
    dap_integration.active_starts = {}
    local stopped_count = 0
    for _, started in ipairs(starts) do
        if started and started.type == "pipeline" and tonumber(started.id) then
            local run_id = tonumber(started.id)
            stopped_count = stopped_count + 1
            stop_pipeline_run(run_id)
            clear_pipeline_run(run_id)
        else
            local id = tonumber(started and started.id)
            if id then
                stopped_count = stopped_count + 1
                pcall(M.stop, id)
            end
        end
    end
    return stopped_count
end

clear_pipeline_run = function(run_id)
    local state = pipeline_runs[run_id]
    if not state then
        return
    end
    if state.singleton and state.template_name then
        if template_singletons[state.template_name] == run_id then
            template_singletons[state.template_name] = nil
        end
    end
    for _, task_id in ipairs(state.started_task_ids) do
        pipeline_task_to_run[task_id] = nil
    end
    pipeline_runs[run_id] = nil
end

local function resolve_templates()
    local list, err = templates.load()
    if not list then
        return nil, err
    end
    local by_name = {}
    for _, item in ipairs(list) do
        by_name[item.name] = item
    end
    return list, by_name
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

            local current = task.get(task_info.id)
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
            notifier.notify(string.format("Flyout: started %s", task_notify_label(task_info)))
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
        local task_info = payload.task
        local pipeline_ref = task_info and task_info.meta and task_info.meta.pipeline_run_id and pipeline_task_to_run[task_info.id]
        if pipeline_ref then
            local state = pipeline_runs[pipeline_ref.run_id]
            if state and not state.cancelled and not state.started_next_for_step[pipeline_ref.step] then
                state.started_next_for_step[pipeline_ref.step] = true
                local _, start_err = start_pipeline_step(pipeline_ref.run_id, pipeline_ref.step + 1)
                if start_err then
                    notifier.notify("Flyout: " .. tostring(start_err), vim.log.levels.ERROR)
                    stop_pipeline_run(pipeline_ref.run_id)
                    clear_pipeline_run(pipeline_ref.run_id)
                end
            end
        end

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

        local pipeline_ref = pipeline_task_to_run[task_info.id]
        if pipeline_ref then
            local state = pipeline_runs[pipeline_ref.run_id]
            if state and not state.cancelled then
                if task_info.status == "success" then
                    if not state.started_next_for_step[pipeline_ref.step] then
                        state.started_next_for_step[pipeline_ref.step] = true
                        local _, start_err = start_pipeline_step(pipeline_ref.run_id, pipeline_ref.step + 1)
                        if start_err then
                            notifier.notify("Flyout: " .. tostring(start_err), vim.log.levels.ERROR)
                            stop_pipeline_run(pipeline_ref.run_id)
                            clear_pipeline_run(pipeline_ref.run_id)
                        end
                    end
                else
                    stop_pipeline_run(pipeline_ref.run_id)
                    clear_pipeline_run(pipeline_ref.run_id)
                end
            end
        end

        local notify_cfg = task_notify_config(task_info)
        local pending = quickfix_postprocess[task_info.id]
        if not pending then
            local parser = ui.get_task_quickfix_parser(task_info.id)
            if type(parser) == "string" and parser ~= "" then
                pending = {
                    parser = parser,
                    task_info = task_info,
                    parsing = false,
                }
                quickfix_postprocess[task_info.id] = pending
            end
        end
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
            notifier.notify(
                string.format("Flyout: command :%s already exists, skipping", cmd_name),
                vim.log.levels.WARN
            )
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

local function start_task_template(template)
    local parser = task_template_parser(template.parser)
    local run_meta = {
        template_name = template.name,
        template_type = "task",
        hidden = template.hidden == true,
    }
    local start_opts = template_start_opts(template, run_meta)

    if template.singleton then
        local existing_id = template_singletons[template.name]
        if existing_id then
            local existing = task.get(existing_id)
            if existing then
                local restarted, rerun_err = task.rerun(existing_id, {
                    cmd = template.cmd,
                    timeout_ms = template.timeout_ms,
                    ready_when = template.ready_when,
                    notify = start_opts.notify,
                    meta = run_meta,
                })
                if not restarted then
                    return nil, rerun_err
                end
                if parser then
                    ui.set_task_quickfix_parser(existing_id, parser)
                else
                    ui.set_task_quickfix_parser(existing_id, nil)
                end
                return restarted
            end
            template_singletons[template.name] = nil
        end
    end

    local started, start_err = task.start(template.cmd, start_opts)
    if not started then
        return nil, start_err
    end

    if template.singleton then
        template_singletons[template.name] = started.id
    end
    if parser then
        ui.set_task_quickfix_parser(started.id, parser)
    else
        ui.set_task_quickfix_parser(started.id, nil)
    end

    return started
end

start_pipeline_step = function(run_id, step_index)
    local state = pipeline_runs[run_id]
    if not state or state.cancelled then
        return nil, "pipeline cancelled"
    end

    if step_index > #state.steps then
        clear_pipeline_run(run_id)
        return true
    end

    local step_template = state.steps[step_index]
    local run_meta = {
        template_name = step_template.name,
        template_type = "task",
        hidden = step_template.hidden == true,
        pipeline_run_id = run_id,
        pipeline_name = state.template_name,
        pipeline_step = step_index,
        pipeline_total_steps = #state.steps,
    }

    local started, start_err = task.start(step_template.cmd, template_start_opts(step_template, run_meta))
    if not started then
        clear_pipeline_run(run_id)
        return nil, start_err
    end

    local parser = task_template_parser(step_template.parser)
    if parser then
        ui.set_task_quickfix_parser(started.id, parser)
    else
        ui.set_task_quickfix_parser(started.id, nil)
    end

    state.current_step = step_index
    state.started_task_ids[#state.started_task_ids + 1] = started.id
    state.started_next_for_step[step_index] = false
    pipeline_task_to_run[started.id] = {
        run_id = run_id,
        step = step_index,
    }

    return started
end

local function start_pipeline_template(template, by_name)
    local pipeline_run_id = next_pipeline_run_id
    next_pipeline_run_id = next_pipeline_run_id + 1

    if template.singleton then
        local existing = template_singletons[template.name]
        if existing and pipeline_runs[existing] then
            stop_pipeline_run(existing)
            clear_pipeline_run(existing)
        end
    end

    local resolved_steps = {}
    for _, step_name in ipairs(template.steps or {}) do
        local step = by_name[step_name]
        if not step then
            return nil, string.format("pipeline '%s': missing step template '%s'", template.name, step_name)
        end
        if step.type ~= "task" then
            return nil, string.format("pipeline '%s': step '%s' must be a task template", template.name, step_name)
        end
        resolved_steps[#resolved_steps + 1] = step
    end

    local state = {
        pipeline_run_id = pipeline_run_id,
        template_name = template.name,
        singleton = template.singleton == true,
        hidden = template.hidden == true,
        steps = resolved_steps,
        current_step = 0,
        started_task_ids = {},
        started_next_for_step = {},
        cancelled = false,
    }
    pipeline_runs[pipeline_run_id] = state
    if state.singleton then
        template_singletons[template.name] = pipeline_run_id
    end

    local started, start_err = start_pipeline_step(pipeline_run_id, 1)
    if not started then
        clear_pipeline_run(pipeline_run_id)
        return nil, start_err
    end

    return {
        id = pipeline_run_id,
        name = template.name,
        type = "pipeline",
        first_task_id = started.id,
    }
end

function M.list_templates()
    return templates.load()
end

function M.save_template(template)
    local list, err = templates.load()
    if not list then
        return nil, err
    end
    local next_list, upsert_err = templates.upsert(list, template)
    if not next_list then
        return nil, upsert_err
    end
    local ok, save_err = templates.save(next_list)
    if not ok then
        return nil, save_err
    end
    return true
end

function M.delete_template(name)
    local list, err = templates.load()
    if not list then
        return nil, err
    end
    local next_list = templates.delete(list, name)
    local ok, save_err = templates.save(next_list)
    if not ok then
        return nil, save_err
    end
    return true
end

function M.run_template(name)
    if type(name) ~= "string" or name == "" then
        return nil, "template name is required"
    end

    local list, by_name = resolve_templates()
    if not list then
        return nil, by_name
    end
    if type(by_name) ~= "table" then
        return nil, "failed to resolve templates"
    end
    local template = by_name[name]
    if not template then
        return nil, string.format("template '%s' not found", name)
    end

    if not confirm_template_run(template.confirm, template.name) then
        return nil, "cancelled"
    end

    if template.type == "pipeline" then
        return start_pipeline_template(template, by_name)
    end

    return start_task_template(template)
end

local function prelaunch_task_names(config)
    if type(config) ~= "table" then
        return {}
    end

    local value = config.preLaunchTask
    local out = {}
    if type(value) == "string" and value ~= "" then
        out[#out + 1] = value
    elseif type(value) == "table" then
        for _, item in ipairs(value) do
            if type(item) == "string" and item ~= "" then
                out[#out + 1] = item
            end
        end
    end
    return out
end

local function off_listener(event, id)
    if id then
        pcall(task.off, event, id)
    end
end

local function wait_for_task_or_pipeline(started, cb)
    local task_id = tonumber(started and started.id)
    local pipeline_run_id = nil
    if started and started.type == "pipeline" then
        pipeline_run_id = tonumber(started.id)
        task_id = tonumber(started.first_task_id)
    end
    if not task_id then
        cb(false, "invalid started task id")
        return
    end

    local done = false
    local ready_listener = nil
    local exit_listener = nil
    local timeout_listener = nil

    local function cleanup()
        off_listener("ready", ready_listener)
        off_listener("exit", exit_listener)
        off_listener("timeout", timeout_listener)
    end

    local function finish(ok, err)
        if done then
            return
        end
        done = true
        cleanup()
        cb(ok, err)
    end

    local function matches(payload)
        local info = payload and payload.task
        if not info then
            return false
        end
        if pipeline_run_id then
            return info.meta and info.meta.pipeline_run_id == pipeline_run_id
        end
        return tonumber(info.id) == task_id
    end

    local function is_pipeline_last_step(info)
        local meta = info and info.meta
        if not meta then
            return false
        end
        local step = tonumber(meta.pipeline_step)
        local total = tonumber(meta.pipeline_total_steps)
        return step and total and step == total
    end

    ready_listener = task.on("ready", function(payload)
        if not matches(payload) then
            return
        end
        local info = payload.task
        if pipeline_run_id then
            if is_pipeline_last_step(info) then
                finish(true)
            end
            return
        end
        finish(true)
    end)

    exit_listener = task.on("exit", function(payload)
        if not matches(payload) then
            return
        end
        local info = payload.task
        if pipeline_run_id then
            if not is_pipeline_last_step(info) then
                return
            end
            if info.status == "success" then
                finish(true)
            else
                finish(false, string.format("preLaunchTask '%s' failed", info.meta and info.meta.pipeline_name or "pipeline"))
            end
            return
        end

        if info.status == "success" then
            finish(true)
        else
            finish(false, string.format("preLaunchTask '%s' failed", info.meta and info.meta.template_name or tostring(info.id)))
        end
    end)

    timeout_listener = task.on("timeout", function(payload)
        if payload and payload.kind == "ready" and matches(payload) then
            local info = payload.task
            finish(false, string.format("preLaunchTask '%s' ready timeout", info.meta and info.meta.template_name or tostring(info.id)))
        elseif payload and payload.kind == "task" and matches(payload) then
            local info = payload.task
            finish(false, string.format("preLaunchTask '%s' timed out", info.meta and info.meta.template_name or tostring(info.id)))
        end
    end)

    local current = task.get(task_id)
    if current then
        if pipeline_run_id then
            if current.meta and current.meta.pipeline_run_id == pipeline_run_id and is_pipeline_last_step(current) and current.status == "success" then
                finish(true)
            end
        else
            if current.ready or current.status == "success" then
                finish(true)
            elseif current.status == "failed" or current.status == "timeout" or current.status == "stopped" or current.status == "killed" then
                finish(false, string.format("preLaunchTask '%s' failed", current.meta and current.meta.template_name or tostring(current.id)))
            end
        end
    end
end

function M.enable_dap(opts)
    opts = opts or {}
    if dap_integration.enabled then
        return true
    end

    local ok, dap = pcall(require, "dap")
    if not ok then
        return nil, "nvim-dap is not available"
    end

    local original_run = dap.run
    dap.listeners.before.event_terminated.flyout_prelaunch_cleanup = stop_active_prelaunch_tasks
    dap.listeners.before.event_exited.flyout_prelaunch_cleanup = stop_active_prelaunch_tasks
    dap.listeners.before.disconnect.flyout_prelaunch_cleanup = stop_active_prelaunch_tasks

    dap.run = function(config, ...)
        local prelaunch = prelaunch_task_names(config)
        if #prelaunch == 0 then
            return original_run(config, ...)
        end
        if dap_integration.running_prelaunch then
            notifier.notify("Flyout: preLaunchTask is already running", vim.log.levels.WARN)
            return
        end

        local list, list_err = M.list_templates()
        if not list then
            notifier.notify("Flyout: " .. tostring(list_err), vim.log.levels.ERROR)
            return
        end
        local by_name = {}
        for _, item in ipairs(list) do
            by_name[item.name] = item
        end
        for _, name in ipairs(prelaunch) do
            if not by_name[name] then
                notifier.notify(string.format("Flyout: preLaunchTask '%s' not found", name), vim.log.levels.ERROR)
                return
            end
        end

        dap_integration.running_prelaunch = true
        dap_integration.active_starts = {}
        local run_args = { ... }

        local function launch_at(index)
            if index > #prelaunch then
                dap_integration.running_prelaunch = false
                local ok_run, run_err = pcall(function()
                    original_run(config, table.unpack(run_args))
                end)
                if not ok_run then
                    notifier.notify("Flyout: failed to start debugger: " .. tostring(run_err), vim.log.levels.ERROR)
                end
                return
            end

            local name = prelaunch[index]
            local started, start_err = M.run_template(name)
            if not started then
                dap_integration.running_prelaunch = false
                notifier.notify("Flyout: " .. tostring(start_err), vim.log.levels.ERROR)
                stop_active_prelaunch_tasks()
                return
            end

            dap_integration.active_starts[#dap_integration.active_starts + 1] = started

            wait_for_task_or_pipeline(started, function(ok_ready, ready_err)
                if not ok_ready then
                    dap_integration.running_prelaunch = false
                    notifier.notify("Flyout: " .. tostring(ready_err), vim.log.levels.ERROR)
                    stop_active_prelaunch_tasks()
                    return
                end
                launch_at(index + 1)
            end)
        end

        notifier.notify(string.format("Flyout: running preLaunchTask(s): %s", table.concat(prelaunch, ", ")))
        launch_at(1)
    end

    dap_integration.enabled = true
    return true
end

function M.stop_active_prelaunch_tasks(opts)
    opts = opts or {}
    local stopped_count = stop_active_prelaunch_tasks()
    if opts.notify ~= false then
        if stopped_count > 0 then
            notifier.notify(string.format("Flyout: stopped %d active preLaunchTask run(s)", stopped_count))
        else
            notifier.notify("Flyout: no active preLaunchTask runs", vim.log.levels.WARN)
        end
    end
    return stopped_count
end

function M.pick_template()
    local list, err = M.list_templates()
    if not list then
        notifier.notify("Flyout: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    if #list == 0 then
        notifier.notify("Flyout: no templates configured", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, template in ipairs(list) do
        table.insert(items, template)
    end

    table.sort(items, function(a, b)
        if a.type ~= b.type then
            return (a.type or "") < (b.type or "")
        end
        return (a.name or "") < (b.name or "")
    end)

    vim.ui.select(items, {
        prompt = "Flyout template",
        format_item = function(item)
            local kind = (item.type or "task"):upper()
            local target = ""
            if item.type == "pipeline" then
                target = string.format("steps:%d", #(item.steps or {}))
            else
                target = item.cmd or ""
            end
            local mode = item.singleton == false and "MULTI" or "SINGLE"
            return string.format("%-9s %-8s %-28s %s", kind, mode, item.name or "", target)
        end,
    }, function(choice)
        if not choice then
            return
        end
        local _, run_err = M.run_template(choice.name)
        if run_err and run_err ~= "cancelled" then
            notifier.notify("Flyout: " .. tostring(run_err), vim.log.levels.ERROR)
        end
    end)
end

function M.setup(opts)
    opts = opts or {}

    local task_opts = opts.task
    if not task_opts then
        task_opts = vim.deepcopy(opts)
        task_opts.ui = nil
        task_opts.quickfix = nil
        task_opts.notify = nil
    end

    task.setup(task_opts)
    ui.setup(opts.ui or {})
    ui.set_template_actions({
        run = function(name)
            local started, err = M.run_template(name)
            if err and err ~= "cancelled" then
                notifier.notify("Flyout: " .. tostring(err), vim.log.levels.ERROR)
            end
            return started, err
        end,
        list = function()
            return M.list_templates()
        end,
        save = function(template)
            return M.save_template(template)
        end,
        delete = function(name)
            return M.delete_template(name)
        end,
    })

    setup_notify_backend(opts.notify or {})

    local quickfix_opts = vim.tbl_deep_extend("force", {}, quickfix_defaults, opts.quickfix or {})
    ui.configure_quickfix(quickfix_opts)
    setup_generated_quickfix_commands(quickfix_opts)
    setup_notifications(opts.notify or {})
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

function M.rerun(task_id, opts)
    return task.rerun(task_id, opts)
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
            pipeline_task_to_run[id] = nil

            for name, singleton_id in pairs(template_singletons) do
                if singleton_id == id then
                    template_singletons[name] = nil
                end
            end
        end
    end

    return result
end

function M.shutdown(opts)
    for id, _ in pairs(progress_state) do
        stop_progress(id)
    end
    quickfix_postprocess = {}
    template_singletons = {}
    pipeline_runs = {}
    pipeline_task_to_run = {}
    spinner_notifier.clear()
    return task.shutdown(opts)
end

function M.open_task_list()
    return ui.open_task_list()
end

function M.open_template_list()
    return ui.open_template_list()
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
        pipeline_task_to_run[id] = nil
        for name, singleton_id in pairs(template_singletons) do
            if singleton_id == id then
                template_singletons[name] = nil
            end
        end
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
