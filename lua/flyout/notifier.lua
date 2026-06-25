local M = {}

local HANDLE_MARK = "_flyout_notify_handle"
local snacks_id_counter = 0
local mini_format_wrapped = false

local active_backend = {
    name = "vim",
    notify = vim.notify,
    module = vim,
    map_replace = nil,
}

local function copy_opts(opts)
    if type(opts) ~= "table" then
        return {}
    end
    return vim.tbl_extend("force", {}, opts)
end

local function wrap_handle(adapter, raw)
    if raw == nil then
        return nil
    end

    local handle = {
        [HANDLE_MARK] = true,
        type = adapter.name,
        m = adapter.module,
        handle = raw,
    }

    return handle
end

local function normalize_replace(opts, adapter)
    if type(opts) ~= "table" then
        return opts
    end

    local replace = opts.replace
    if type(replace) ~= "table" or replace[HANDLE_MARK] ~= true then
        return opts
    end

    if type(adapter.map_replace) == "function" then
        opts.replace = adapter.map_replace(replace)
        return opts
    end

    opts.replace = replace.handle or replace
    return opts
end

local function create_vim_adapter()
    return {
        name = "vim",
        notify = vim.notify,
        module = vim,
    }
end

local function create_custom_adapter(fn)
    return {
        name = "custom",
        notify = fn,
        module = nil,
    }
end

local function create_flyout_adapter()
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
        return {
            name = "flyout",
            notify = flyout_notify.notify,
            module = flyout_notify,
        }
    end
    if type(flyout_notify) == "function" then
        return {
            name = "flyout",
            notify = flyout_notify,
            module = flyout_notify,
        }
    end

    return nil, "invalid flyout.notify backend"
end

local function create_snacks_adapter()
    local ok, snacks = pcall(require, "snacks.notifier")
    if not ok or type(snacks.notify) ~= "function" or type(snacks.hide) ~= "function" then
        return nil
    end

    local function next_snacks_id()
        snacks_id_counter = snacks_id_counter + 1
        return string.format("flyout-%d-%d", snacks_id_counter, vim.uv.hrtime())
    end

    local notify = function(msg, level, opts)
        local o = copy_opts(opts)
        local replace = o.replace
        if type(replace) == "table" then
            replace = replace.id or replace.handle
        end
        if replace ~= nil then
            o.id = replace
            o.replace = nil
        elseif o.id == nil then
            o.id = next_snacks_id()
        end

        snacks.notify(msg, level, o)
        return o.id
    end

    return {
        name = "snacks",
        notify = notify,
        module = snacks,
        map_replace = function(replace)
            return replace.handle
        end,
    }
end

local function create_nvim_notify_adapter()
    local ok, notify_mod = pcall(require, "notify")
    if not ok then
        return nil
    end

    local fn = nil
    if type(notify_mod) == "function" then
        fn = notify_mod
    elseif type(notify_mod.notify) == "function" then
        fn = notify_mod.notify
    end

    if type(fn) ~= "function" then
        return nil
    end

    return {
        name = "nvim-notify",
        notify = fn,
        module = notify_mod,
        map_replace = function(replace)
            return replace.handle or replace
        end,
    }
end

local function create_mini_notify_adapter()
    local ok, mini_notify = pcall(require, "mini.notify")
    if not ok then
        return nil
    end

    if type(mini_notify.add) ~= "function" or type(mini_notify.remove) ~= "function" then
        return nil
    end

    if not mini_format_wrapped
        and type(mini_notify.config) == "table"
        and type(mini_notify.config.content) == "table"
    then
        local prev_format = mini_notify.config.content.format
        mini_notify.config.content.format = function(notif)
            if type(notif) == "table" and type(notif.data) == "table" and notif.data.source == "flyout" then
                return tostring(notif.msg or "")
            end
            if type(prev_format) == "function" then
                return prev_format(notif)
            end
            if type(mini_notify.default_format) == "function" then
                return mini_notify.default_format(notif)
            end
            return tostring(notif.msg or "")
        end
        mini_format_wrapped = true
    end

    local level_names = {}
    for name, num in pairs(vim.log.levels) do
        level_names[num] = name
    end

    local fn = function(msg, level, opts)
        opts = opts or {}

        local level_name = "INFO"
        if type(level) == "string" then
            level_name = level:upper()
        elseif type(level) == "number" and level_names[level] then
            level_name = level_names[level]
        end

        if opts.replace ~= nil and type(mini_notify.update) == "function" then
            local id = opts.replace
            if type(id) == "table" then
                id = id.handle or id.id
            end
            if type(id) == "number" then
                pcall(mini_notify.update, id, {
                    msg = tostring(msg),
                    level = level_name,
                })
                return id
            end
        end

        local id = mini_notify.add(tostring(msg), level_name, nil, { source = "flyout" })
        local timeout = opts.timeout
        if timeout == true then
            timeout = 5000
        end
        if type(timeout) == "number" and timeout > 0 then
            vim.defer_fn(function()
                pcall(mini_notify.remove, id)
            end, timeout)
        end
        return id
    end

    return {
        name = "mini.notify",
        notify = fn,
        module = mini_notify,
        map_replace = function(replace)
            return replace.handle
        end,
    }
end

local function resolve_backend(opts)
    if type(opts.notify) == "function" then
        return create_custom_adapter(opts.notify)
    end

    local backend = opts.notify_backend
    if backend == nil or backend == "" or backend == "auto" then
        local adapter = create_snacks_adapter()
        if adapter then
            return adapter
        end
        adapter = create_nvim_notify_adapter()
        if adapter then
            return adapter
        end
        adapter = create_mini_notify_adapter()
        if adapter then
            return adapter
        end
        adapter = create_flyout_adapter()
        if adapter then
            return adapter
        end
        return create_vim_adapter()
    end

    if backend == "vim" then
        return create_vim_adapter()
    end
    if backend == "flyout" then
        return create_flyout_adapter()
    end
    if backend == "snacks" then
        local adapter = create_snacks_adapter()
        if adapter then
            return adapter
        end
        return nil, "failed to load snacks notifier backend"
    end
    if backend == "nvim-notify" then
        local adapter = create_nvim_notify_adapter()
        if adapter then
            return adapter
        end
        return nil, "failed to load nvim-notify backend"
    end
    if backend == "mini.notify" then
        local adapter = create_mini_notify_adapter()
        if adapter then
            return adapter
        end
        return nil, "failed to load mini.notify backend"
    end

    return nil, "unknown notify backend: " .. tostring(backend)
end

function M.setup(opts)
    opts = opts or {}
    local adapter, name_or_err = resolve_backend(opts)
    if not adapter then
        active_backend = create_vim_adapter()
        return nil, name_or_err
    end

    active_backend = adapter
    return true
end

function M.notify(msg, level, opts)
    local adapter = active_backend
    local notify_opts = normalize_replace(copy_opts(opts), adapter)
    local raw = adapter.notify(msg, level, notify_opts)

    if type(raw) == "table" and raw[HANDLE_MARK] == true then
        return raw
    end

    return wrap_handle(adapter, raw)
end

function M.backend()
    return active_backend.name
end

function M.close(handle)
    if type(handle) ~= "table" or handle[HANDLE_MARK] ~= true then
        return
    end

    if handle.type == "snacks" and type(handle.m) == "table" and type(handle.m.hide) == "function" then
        local id = handle.handle
        if type(id) == "table" then
            id = id.id
        end
        if id ~= nil then
            pcall(handle.m.hide, id)
        else
            pcall(handle.m.hide)
        end
        return
    end

    if handle.type == "flyout" then
        local h = handle.handle
        if type(h) == "table" then
            if type(h.close) == "function" then
                pcall(h.close, h)
                return
            end
            if type(h.hide) == "function" then
                pcall(h.hide, h)
                return
            end
            if type(h.dismiss) == "function" then
                pcall(h.dismiss, h)
                return
            end
        end
    end

    if handle.type == "mini.notify" and type(handle.m) == "table" and type(handle.m.remove) == "function" then
        if type(handle.handle) == "number" then
            pcall(handle.m.remove, handle.handle)
            return
        end
    end

    if handle.type == "nvim-notify" and handle.handle ~= nil then
        local notif_id = handle.handle
        if type(notif_id) == "table" then
            notif_id = notif_id.id
        end
        local m = handle.m
        if type(m) == "table" and notif_id ~= nil then
            local notify_fn = nil
            if type(m.notify) == "function" then
                notify_fn = m.notify
            elseif type(getmetatable(m)) == "table" and type(getmetatable(m).__call) == "function" then
                notify_fn = m
            end
            if type(notify_fn) == "function" then
                pcall(notify_fn, "", vim.log.levels.INFO, {
                    replace = notif_id,
                    timeout = 0,
                    hide_from_history = true,
                    title = "",
                })
                return
            end
        end
    end

    local raw = handle.handle

    if handle.type == "vim" and raw ~= nil then
        local ok, snacks = pcall(require, "snacks.notifier")
        if ok and type(snacks.hide) == "function" then
            local id = raw
            if type(id) == "table" then
                id = id.id
            end
            if id ~= nil then
                pcall(snacks.hide, id)
                return
            end
        end
    end

    if type(raw) == "table" then
        if type(raw.close) == "function" then
            pcall(raw.close, raw)
            return
        end
        if type(raw.hide) == "function" then
            pcall(raw.hide, raw)
            return
        end
        if type(raw.dismiss) == "function" then
            pcall(raw.dismiss, raw)
        end
    end
end

return M
