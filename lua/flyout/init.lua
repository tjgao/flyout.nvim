local M = {}

local task = require("flyout.task")
local ui = require("flyout.ui")

function M.setup(opts)
    opts = opts or {}

    local task_opts = opts.task
    if not task_opts then
        task_opts = vim.deepcopy(opts)
        task_opts.ui = nil
    end

    task.setup(task_opts)
    ui.setup(opts.ui or {})
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

return M
