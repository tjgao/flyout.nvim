local M = {}

local task = require("flyout.task")
local ui = require("flyout.ui")

local quickfix_defaults = {
    generate_commands = true,
    command_prefix = "F",
}

local generated_quickfix_commands = {}

local function is_active_status(status)
    return status == "pending" or status == "running" or status == "stopping"
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

local function clear_generated_quickfix_commands()
    for _, name in ipairs(generated_quickfix_commands) do
        pcall(vim.api.nvim_del_user_command, name)
    end
    generated_quickfix_commands = {}
end

local function watch_task_and_open_quickfix(task_id, parser)
    local timer = vim.uv.new_timer()
    if not timer then
        vim.notify("Flyout: failed to create quickfix watcher", vim.log.levels.ERROR)
        return
    end

    local function stop_timer()
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end

    timer:start(0, 500, function()
        vim.schedule(function()
            local task_info, err = task.get(task_id)
            if not task_info then
                stop_timer()
                vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
                return
            end

            if is_active_status(task_info.status) then
                return
            end

            stop_timer()
            ui.open_task_quickfix(task_id, { parser = parser })
        end)
    end)
end

local function setup_generated_quickfix_commands(opts)
    clear_generated_quickfix_commands()

    if opts.generate_commands == false then
        return
    end

    local prefix = normalize_quickfix_prefix(opts.command_prefix)
    local parsers = ui.quickfix_parsers()
    for _, parser in ipairs(parsers) do
        local cmd_name = prefix .. parser
        if vim.fn.exists(":" .. cmd_name) == 2 then
            vim.notify(string.format("Flyout: command :%s already exists, skipping", cmd_name), vim.log.levels.WARN)
        else
            vim.api.nvim_create_user_command(cmd_name, function(copts)
                local started, err = M.run_quickfix(parser, copts.args)
                if not started then
                    vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
                    return
                end
                vim.notify(string.format("Flyout: started task #%d", started.id))
            end, {
                nargs = "+",
                complete = "shellcmd",
            })
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
    end

    task.setup(task_opts)
    ui.setup(opts.ui or {})

    local quickfix_opts = vim.tbl_deep_extend("force", {}, quickfix_defaults, opts.quickfix or {})
    ui.configure_quickfix(quickfix_opts)
    setup_generated_quickfix_commands(quickfix_opts)
end

function M.start(cmd)
    return task.start(cmd)
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
    return task.clear_finished(opts)
end

function M.shutdown(opts)
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

function M.run_quickfix(parser, cmd)
    if type(cmd) ~= "string" or vim.trim(cmd) == "" then
        return nil, "command must be a non-empty string"
    end

    local started, start_err = task.start(cmd)
    if not started then
        return nil, start_err
    end

    ui.set_task_quickfix_parser(started.id, parser)
    watch_task_and_open_quickfix(started.id, parser)
    return started
end

function M.quickfix_parsers()
    return ui.quickfix_parsers()
end

return M
