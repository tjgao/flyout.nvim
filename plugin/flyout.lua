local flyout = require("flyout")

local function parse_task_id(value)
    if not value or value == "" then
        return nil, "task id is required"
    end
    local id = tonumber(value)
    if not id then
        return nil, "task id must be a number"
    end
    return id
end

vim.api.nvim_create_user_command("Flyout", function(opts)
    local task, err = flyout.start(opts.args)
    if not task then
        vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
        return
    end

    vim.notify(string.format("Flyout: started task #%d", task.id))
end, {
    nargs = "+",
    complete = "shellcmd",
})

vim.api.nvim_create_user_command("FlyoutStop", function(opts)
    local task_id, parse_err = parse_task_id(opts.args)
    if not task_id then
        vim.notify("Flyout: " .. parse_err, vim.log.levels.ERROR)
        return
    end

    local task, err = flyout.stop(task_id)
    if not task then
        vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
        return
    end

    vim.notify(string.format("Flyout: stopping task #%d", task.id))
end, {
    nargs = 1,
})

vim.api.nvim_create_user_command("FlyoutRerun", function(opts)
    local task_id, parse_err = parse_task_id(opts.args)
    if not task_id then
        vim.notify("Flyout: " .. parse_err, vim.log.levels.ERROR)
        return
    end

    local task, err = flyout.rerun(task_id)
    if not task then
        vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
        return
    end

    vim.notify(string.format("Flyout: started task #%d", task.id))
end, {
    nargs = 1,
})

vim.api.nvim_create_user_command("FlyoutTasks", function()
    flyout.open_task_list()
end, {
    nargs = 0,
})

vim.api.nvim_create_user_command("FlyoutLog", function(opts)
    local task_id, parse_err = parse_task_id(opts.args)
    if not task_id then
        vim.notify("Flyout: " .. parse_err, vim.log.levels.ERROR)
        return
    end
    flyout.open_task_log(task_id)
end, {
    nargs = 1,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        pcall(flyout.shutdown, {
            grace_ms = 80,
            force_kill = true,
        })
    end,
})
