local M = {}
local notifier = require("flyout.notifier")

local state = {
    items = {},
}

function M.set(task_id, text)
    local id = tonumber(task_id)
    if not id then
        return
    end

    local entry = state.items[id]
    if not entry then
        entry = {
            handle = nil,
        }
        state.items[id] = entry
    end

    local handle = notifier.notify(text, vim.log.levels.INFO, {
        replace = entry.handle,
        title = "Flyout running task",
        timeout = false,
        hide_from_history = true,
    })
    if handle ~= nil then
        entry.handle = handle
    end
end

function M.remove(task_id)
    local id = tonumber(task_id)
    if not id then
        return
    end

    local entry = state.items[id]
    if not entry then
        return
    end

    notifier.close(entry.handle)

    state.items[id] = nil
end

function M.clear()
    for id, _ in pairs(state.items) do
        M.remove(id)
    end
end

return M
