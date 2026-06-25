local flyout = require("flyout")
local shell_completion_enabled = vim.fn.has("wsl") ~= 1

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

local function complete_quickfix(arglead, cmdline)
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local ends_with_space = cmdline:match("%s$") ~= nil

    if #parts <= 1 or (#parts == 2 and not ends_with_space) then
        local out = {}
        for _, parser in ipairs(flyout.quickfix_parsers()) do
            if arglead == "" or parser:sub(1, #arglead) == arglead then
                table.insert(out, parser)
            end
        end
        return out
    end

    if not shell_completion_enabled then
        return {}
    end
    return vim.fn.getcompletion(arglead, "shellcmd")
end

local flyout_cmd_opts = {
    nargs = "+",
}
if shell_completion_enabled then
    flyout_cmd_opts.complete = "shellcmd"
end

vim.api.nvim_create_user_command("Flyout", function(opts)
    local _, err = flyout.start(opts.args)
    if err then
        vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
        return
    end
end, flyout_cmd_opts)

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
end, {
    nargs = 1,
})

vim.api.nvim_create_user_command("FlyoutRerun", function(opts)
    local task_id, parse_err = parse_task_id(opts.args)
    if not task_id then
        vim.notify("Flyout: " .. parse_err, vim.log.levels.ERROR)
        return
    end

    local _, err = flyout.rerun(task_id)
    if err then
        vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
        return
    end
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

vim.api.nvim_create_user_command("FlyoutQuickfix", function(opts)
    local parser = opts.fargs[1]
    local cmd = table.concat(vim.list_slice(opts.fargs, 2), " ")
    if not parser or parser == "" then
        vim.notify("Flyout: parser is required", vim.log.levels.ERROR)
        return
    end
    if vim.trim(cmd) == "" then
        vim.notify("Flyout: command is required", vim.log.levels.ERROR)
        return
    end

    local _, err = flyout.run_quickfix(parser, cmd)
    if err then
        vim.notify("Flyout: " .. err, vim.log.levels.ERROR)
        return
    end
end, {
    nargs = "+",
    complete = complete_quickfix,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        pcall(flyout.shutdown, {
            grace_ms = 80,
            force_kill = true,
        })
    end,
})
