local M = {}
local notifier = require("flyout.notifier")

local state = {
    items = {},
    aggregate_handle = nil,
}

local function is_mini_backend()
    return notifier.backend() == "mini.notify"
end

local function render_mini_aggregate()
    local rows = {}
    for id, entry in pairs(state.items) do
        if type(entry.text) == "string" and entry.text ~= "" then
            table.insert(rows, { id = id, text = entry.text })
        end
    end

    if #rows == 0 then
        notifier.close(state.aggregate_handle)
        state.aggregate_handle = nil
        return
    end

    table.sort(rows, function(a, b)
        return a.id < b.id
    end)

    local lines = {}
    for _, row in ipairs(rows) do
        table.insert(lines, row.text)
    end

    state.aggregate_handle = notifier.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
        replace = state.aggregate_handle,
        title = "Flyout running tasks",
        timeout = false,
        hide_from_history = true,
    })
end

function M.set(task_id, text)
    local id = tonumber(task_id)
    if not id then
        return
    end

    local entry = state.items[id]
    if not entry then
        entry = {
            handle = nil,
            text = nil,
        }
        state.items[id] = entry
    end

    if is_mini_backend() then
        entry.text = text
        render_mini_aggregate()
        return
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

    if is_mini_backend() then
        state.items[id] = nil
        render_mini_aggregate()
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
