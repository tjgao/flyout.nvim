local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local content = fd:read("*a")
    fd:close()
    return content
end

local function write_file(path, content)
    local fd = io.open(path, "w")
    if not fd then
        return false
    end
    fd:write(content)
    fd:close()
    return true
end

local function normalize_output_line(line)
    if type(line) ~= "string" then
        return ""
    end

    if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
    end

    local last_cr = line:match(".*()\r")
    if last_cr then
        line = line:sub(last_cr + 1)
    end

    return (line:gsub("\r", ""))
end

local function strip_ansi(line)
    line = normalize_output_line(line)
    return (line:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""))
end

local function resolve_args()
    if type(_G.arg) == "table" and _G.arg[1] and _G.arg[2] and _G.arg[3] then
        return _G.arg
    end

    local ok, argv = pcall(vim.fn.argv)
    if ok and type(argv) == "table" then
        return argv
    end

    return {}
end

local function resolve_inputs(args)
    local log_path = os.getenv("FLYOUT_QF_LOG")
    local efm = os.getenv("FLYOUT_QF_EFM")
    local out_path = os.getenv("FLYOUT_QF_OUT")
    if log_path and efm and out_path then
        return log_path, efm, out_path
    end

    local efm_path = args[2]
    if not (args[1] and efm_path and args[3]) then
        return nil, nil, nil
    end

    local efm_from_file = read_file(efm_path)
    return args[1], efm_from_file, args[3]
end

local function main(args)
    local log_path, efm, out_path = resolve_inputs(args)

    if not (log_path and efm and out_path) then
        io.stderr:write("missing args\n")
        return 2
    end

    local lines = {}
    local fd = io.open(log_path, "r")
    if fd then
        for raw_line in fd:lines() do
            lines[#lines + 1] = strip_ansi(raw_line)
        end
        fd:close()
    end

    local ok_set, set_err = pcall(vim.fn.setqflist, {}, " ", {
        lines = lines,
        efm = efm,
    })
    if not ok_set then
        io.stderr:write(tostring(set_err) .. "\n")
        return 6
    end
    local parsed = vim.fn.getqflist()
    local items = {}
    for _, item in ipairs(parsed or {}) do
        local out = {
            lnum = tonumber(item.lnum) or 0,
            end_lnum = tonumber(item.end_lnum) or 0,
            col = tonumber(item.col) or 0,
            end_col = tonumber(item.end_col) or 0,
            vcol = tonumber(item.vcol) or 0,
            nr = tonumber(item.nr) or 0,
            valid = tonumber(item.valid) or 0,
            text = type(item.text) == "string" and item.text or "",
            type = type(item.type) == "string" and item.type or "",
            module = type(item.module) == "string" and item.module or "",
            pattern = type(item.pattern) == "string" and item.pattern or "",
        }

        local bufnr = tonumber(item.bufnr) or 0
        if bufnr > 0 then
            local ok_name, name = pcall(vim.api.nvim_buf_get_name, bufnr)
            if ok_name and type(name) == "string" and name ~= "" then
                out.filename = name
            end
        end

        if not out.filename and type(item.filename) == "string" and item.filename ~= "" then
            out.filename = item.filename
        end

        items[#items + 1] = out
    end

    local ok_json, payload = pcall(vim.json.encode, items)
    if not ok_json then
        io.stderr:write("failed to encode quickfix items\n")
        return 4
    end

    if not write_file(out_path, payload) then
        io.stderr:write("failed to write output file\n")
        return 5
    end

    return 0
end

os.exit(main(resolve_args()))
