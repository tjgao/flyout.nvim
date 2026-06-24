local M = {}

local notify_fn = vim.notify

local function resolve_notify_function(opts)
    if type(opts.notify) == "function" then
        return opts.notify
    end

    local backend = opts.notify_backend
    if type(backend) == "string" and backend == "flyout" then
        local ok, flyout_notify = pcall(require, "flyout.notify")
        if not ok then
            return nil, "failed to load flyout.notify backend"
        end
        if type(flyout_notify.setup) == "function" then
            flyout_notify.setup({
                override_vim_notify = false,
            })
        end
        if type(flyout_notify.notify) == "function" then
            return flyout_notify.notify
        end
        if type(flyout_notify) == "function" then
            return flyout_notify
        end
        return nil, "invalid flyout.notify backend"
    end

    return vim.notify
end

function M.setup(opts)
    opts = opts or {}
    local fn, err = resolve_notify_function(opts)
    if not fn then
        notify_fn = vim.notify
        return nil, err
    end
    notify_fn = fn
    return true
end

function M.notify(msg, level, opts)
    return notify_fn(msg, level, opts)
end

function M.close(handle)
    if handle and type(handle) == "table" and type(handle.close) == "function" then
        pcall(handle.close, handle)
    end
end

return M
