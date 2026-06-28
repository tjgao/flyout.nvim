local M = {}

local default_file = ".flyout/templates.lua"

local function project_root()
    return vim.uv.cwd() or vim.fn.getcwd()
end

local function template_path()
    return project_root() .. "/" .. default_file
end

local function ensure_table(value)
    if type(value) == "table" then
        return value
    end
    return {}
end

local function normalize_confirm(value)
    if value == nil then
        return false
    end
    if value == false then
        return false
    end
    if value == true then
        return true
    end
    if type(value) == "string" then
        if value == "" then
            return false
        end
        return value
    end
    return nil, "confirm must be false, true, or a non-empty string"
end

local function normalize_template(template)
    if type(template) ~= "table" then
        return nil, "template must be a table"
    end

    local out = vim.deepcopy(template)

    if out.notification ~= nil then
        return nil, "template.notification is invalid; use template.notify"
    end

    if out.type == nil then
        out.type = "task"
    end
    if out.type ~= "task" and out.type ~= "pipeline" then
        return nil, "template.type must be 'task' or 'pipeline'"
    end

    if type(out.name) ~= "string" or out.name == "" then
        return nil, "template.name must be a non-empty string"
    end

    if out.singleton == nil then
        out.singleton = true
    else
        out.singleton = out.singleton == true
    end

    if out.hidden == nil then
        out.hidden = false
    else
        out.hidden = out.hidden == true
    end

    local confirm, confirm_err = normalize_confirm(out.confirm)
    if confirm_err then
        return nil, confirm_err
    end
    out.confirm = confirm

    if out.type == "task" then
        if type(out.cmd) ~= "string" or vim.trim(out.cmd) == "" then
            return nil, string.format("template '%s': cmd must be a non-empty string", out.name)
        end
        if out.timeout_ms ~= nil then
            local timeout = tonumber(out.timeout_ms)
            if not timeout then
                return nil, string.format("template '%s': timeout_ms must be a number", out.name)
            end
            out.timeout_ms = math.max(0, math.floor(timeout))
        end
        if out.parser ~= nil and type(out.parser) ~= "string" then
            return nil, string.format("template '%s': parser must be a string", out.name)
        end
        if out.notify ~= nil and type(out.notify) ~= "table" then
            return nil, string.format("template '%s': notify must be a table", out.name)
        end
    else
        if type(out.steps) ~= "table" or #out.steps == 0 then
            return nil, string.format("template '%s': steps must be a non-empty list", out.name)
        end
        for i, step in ipairs(out.steps) do
            if type(step) ~= "string" or step == "" then
                return nil, string.format("template '%s': steps[%d] must be a non-empty string", out.name, i)
            end
        end
    end

    return out
end

local function validate_templates(templates)
    local out = {}
    local seen = {}

    for _, template in ipairs(templates) do
        local normalized, err = normalize_template(template)
        if not normalized then
            return nil, err
        end
        if seen[normalized.name] then
            return nil, string.format("duplicate template name '%s'", normalized.name)
        end
        seen[normalized.name] = true
        table.insert(out, normalized)
    end

    local by_name = {}
    for _, template in ipairs(out) do
        by_name[template.name] = template
    end

    for _, template in ipairs(out) do
        if template.type == "pipeline" then
            for _, step_name in ipairs(template.steps) do
                local step = by_name[step_name]
                if not step then
                    return nil, string.format("pipeline '%s': missing step template '%s'", template.name, step_name)
                end
                if step.type ~= "task" then
                    return nil, string.format("pipeline '%s': step '%s' must be a task template", template.name, step_name)
                end
            end
        end
    end

    return out
end

local function sorted_templates(templates)
    table.sort(templates, function(a, b)
        return a.name < b.name
    end)
    return templates
end

function M.path()
    return template_path()
end

function M.load()
    local path = template_path()
    if vim.uv.fs_stat(path) == nil then
        return {}
    end

    local chunk, load_err = loadfile(path)
    if not chunk then
        return nil, "failed to load templates file: " .. tostring(load_err)
    end

    local ok, data = pcall(chunk)
    if not ok then
        return nil, "failed to execute templates file: " .. tostring(data)
    end

    data = ensure_table(data)
    local templates = ensure_table(data.templates)
    local validated, err = validate_templates(templates)
    if not validated then
        return nil, err
    end
    return sorted_templates(validated)
end

function M.save(templates)
    local validated, err = validate_templates(ensure_table(templates))
    if not validated then
        return nil, err
    end

    local path = template_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local payload = {
        templates = sorted_templates(validated),
    }
    local content = "return " .. vim.inspect(payload, { newline = "\n", indent = "    " }) .. "\n"

    local tmp = path .. ".tmp"
    local fd, open_err = io.open(tmp, "w")
    if not fd then
        return nil, "failed to write templates: " .. tostring(open_err)
    end
    fd:write(content)
    fd:close()

    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        pcall(vim.uv.fs_unlink, tmp)
        return nil, "failed to save templates: " .. tostring(rename_err)
    end

    return true
end

function M.find(templates, name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    for _, template in ipairs(ensure_table(templates)) do
        if template.name == name then
            return template
        end
    end
    return nil
end

function M.upsert(templates, template)
    local list = vim.deepcopy(ensure_table(templates))
    local normalized, err = normalize_template(template)
    if not normalized then
        return nil, err
    end

    local replaced = false
    for i, item in ipairs(list) do
        if item.name == normalized.name then
            list[i] = normalized
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(list, normalized)
    end

    local validated, validate_err = validate_templates(list)
    if not validated then
        return nil, validate_err
    end
    return sorted_templates(validated)
end

function M.delete(templates, name)
    local list = {}
    for _, template in ipairs(ensure_table(templates)) do
        if template.name ~= name then
            table.insert(list, vim.deepcopy(template))
        end
    end
    return sorted_templates(list)
end

function M.default_template()
    return {
        type = "task",
        name = "new_template",
        cmd = "",
        singleton = true,
        hidden = false,
        confirm = false,
    }
end

return M
