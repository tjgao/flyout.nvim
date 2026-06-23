local M = {}

local state = {
    items = {},
}

local function next_notif_id(task_id)
    return string.format("flyout-spinner-%d-%d", task_id, vim.uv.hrtime())
end

function M.set(task_id, text)
    local id = tonumber(task_id)
    if not id then
        return
    end

    local entry = state.items[id]
    if not entry then
        entry = {
            notif_id = next_notif_id(id),
            handle = nil,
        }
        state.items[id] = entry
    end

    entry.handle = vim.notify(text, vim.log.levels.INFO, {
        id = entry.notif_id,
        title = "Flyout",
        timeout = false,
        hide_from_history = true,
    })
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

    if entry.handle and type(entry.handle) == "table" and type(entry.handle.close) == "function" then
        pcall(entry.handle.close, entry.handle)
    end

    pcall(vim.notify, " ", vim.log.levels.INFO, {
        id = entry.notif_id,
        timeout = 1,
        hide_from_history = true,
    })

    state.items[id] = nil
end

function M.clear()
    for id, _ in pairs(state.items) do
        M.remove(id)
    end
end

return M
