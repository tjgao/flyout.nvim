local M = {}

local uv = vim.uv

local tasks = {}
local next_id = 1

local default_opts = {
    stop_timeout_ms = 3000,
    cleanup_output_on_stop = false,
    force_color = true,
    force_color_env = {
        CLICOLOR_FORCE = "1",
        FORCE_COLOR = "1",
    },
}

local instance_id = nil
local random_seeded = false
local random_charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function flyout_root_dir()
    return vim.fn.stdpath("cache") .. "/flyout"
end

local function current_pid()
    if type(uv.os_getpid) == "function" then
        return tonumber(uv.os_getpid()) or tonumber(vim.fn.getpid()) or 0
    end
    return tonumber(vim.fn.getpid()) or 0
end

local function process_is_alive(pid)
    if type(pid) ~= "number" or pid <= 0 then
        return false
    end
    local ok = pcall(uv.kill, pid, 0)
    return ok
end

local function ensure_random_seeded()
    if random_seeded then
        return
    end

    local pid = current_pid()
    local hr = tonumber(uv.hrtime()) or 0
    local seed = math.floor((hr % 2147483647) + pid)
    if seed <= 0 then
        seed = 1
    end

    math.randomseed(seed)
    random_seeded = true
end

local function random_token4()
    ensure_random_seeded()

    local out = {}
    local n = #random_charset
    for i = 1, 4 do
        local idx = math.random(1, n)
        out[i] = random_charset:sub(idx, idx)
    end
    return table.concat(out)
end

local function current_instance_id()
    if instance_id then
        return instance_id
    end

    local pid = current_pid()
    local suffix = random_token4()

    instance_id = string.format("%d-%s", pid, suffix)
    return instance_id
end

local function now_ms()
    return uv.now()
end

local function ensure_output_dir()
    local root = flyout_root_dir()
    vim.fn.mkdir(root, "p")
    local dir = root .. "/" .. current_instance_id()
    vim.fn.mkdir(dir, "p")
    return dir
end

local function startup_cleanup_output_dir()
    local root = flyout_root_dir()
    vim.fn.mkdir(root, "p")

    local scanner = uv.fs_scandir(root)
    if not scanner then
        return
    end

    local keep_instance = current_instance_id()
    while true do
        local name, file_type = uv.fs_scandir_next(scanner)
        if not name then
            break
        end

        if file_type == "directory" then
            local child_path = root .. "/" .. name
            if name ~= keep_instance then
                local child_pid = tonumber(name:match("^(%d+)%-.+$"))
                if not child_pid then
                    vim.fn.delete(child_path, "rf")
                elseif not process_is_alive(child_pid) then
                    vim.fn.delete(child_path, "rf")
                end
            end
        elseif file_type == "file" and name:match("%.log$") then
            vim.fn.delete(root .. "/" .. name)
        end
    end
end

local function cleanup_current_instance_dir()
    local dir = flyout_root_dir() .. "/" .. current_instance_id()
    if uv.fs_stat(dir) then
        vim.fn.delete(dir, "rf")
    end
end

local function wallclock_timestamp_ms()
    local ymd_hms = os.date("%Y%m%d%H%M%S")
    local ms = 0

    if type(uv.gettimeofday) == "function" then
        local ok, tv = pcall(uv.gettimeofday)
        if ok and type(tv) == "table" then
            if type(tv.usec) == "number" then
                ms = math.floor(tv.usec / 1000)
            elseif type(tv.tv_usec) == "number" then
                ms = math.floor(tv.tv_usec / 1000)
            end
        end
    end

    if ms < 0 then
        ms = 0
    elseif ms > 999 then
        ms = 999
    end

    return string.format("%s.%03d", ymd_hms, ms)
end

local function shell_quote_single(value)
    return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

local function new_output_path(task_id)
    local dir = ensure_output_dir()
    local stamp = wallclock_timestamp_ms()
    return string.format("%s/#%d-%s.log", dir, task_id, stamp)
end

local function get_task(task_id)
    local task = tasks[task_id]
    if not task then
        return nil, string.format("task %s not found", tostring(task_id))
    end
    return task
end

local function is_active(task)
    return task.status == "running" or task.status == "stopping"
end

local function public_task(task)
    return {
        id = task.id,
        cmd = task.cmd,
        shell_cmd = task.shell_cmd,
        output_path = task.output_path,
        status = task.status,
        created_at = task.created_at,
        started_at = task.started_at,
        ended_at = task.ended_at,
        stop_requested = task.stop_requested,
        pid = task.pid,
        exit_code = task.exit_code,
        signal = task.signal,
    }
end

local function send_signal(task, signal)
    if not task.pid then
        return false, "missing pid"
    end

    local ok, err = pcall(uv.kill, -task.pid, signal)
    if ok then
        return true
    end

    local ok_pid, err_pid = pcall(uv.kill, task.pid, signal)
    if ok_pid then
        return true
    end

    local kill_cmd = string.format(
        "kill -%d -- -%d >/dev/null 2>&1 || kill -%d %d >/dev/null 2>&1",
        signal,
        task.pid,
        signal,
        task.pid
    )
    local ok_shell, proc = pcall(vim.system, { "sh", "-c", kill_cmd })
    if ok_shell and proc then
        local result = proc:wait(300)
        if result and result.code == 0 then
            return true
        end
    end

    return false, tostring(err or err_pid)
end

local function cleanup_task_runtime(task)
    if task.stop_timer and not task.stop_timer:is_closing() then
        task.stop_timer:stop()
        task.stop_timer:close()
    end
    task.stop_timer = nil
    task.proc = nil
    task.pid = nil
end

local function maybe_delete_output(task, opts)
    if not opts.cleanup_output_on_stop then
        return
    end
    if task.output_path and uv.fs_stat(task.output_path) then
        vim.fn.delete(task.output_path)
    end
end

local function finalize_task(task, obj, opts)
    cleanup_task_runtime(task)

    task.exit_code = obj.code
    task.signal = obj.signal
    task.ended_at = now_ms()

    if task.stop_requested then
        if obj.signal == 15 then
            task.status = "stopped"
        elseif obj.signal == 9 then
            task.status = "killed"
        else
            task.status = "stopped"
        end
        maybe_delete_output(task, opts)
        return
    end

    if obj.code == 0 then
        task.status = "success"
    else
        task.status = "failed"
    end
end

local function build_env_prefix(opts)
    if not opts or opts.force_color == false then
        return ""
    end

    local env_map = opts.force_color_env or {}
    local keys = {}
    for key, _ in pairs(env_map) do
        if type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, string.format("%s=%s", key, shell_quote_single(env_map[key])))
    end

    if #parts == 0 then
        return ""
    end

    return table.concat(parts, " ") .. " "
end

local function build_shell_command(cmd, output_path, opts)
    local path_quoted = shell_quote_single(output_path)
    local env_prefix = build_env_prefix(opts)
    return string.format("(%s%s) > %s 2>&1", env_prefix, cmd, path_quoted)
end

local function launch_task(task, opts)
    local shell_cmd = build_shell_command(task.cmd, task.output_path, opts)
    local task_id = task.id

    local ok, proc_or_err = pcall(vim.system, { "sh", "-c", shell_cmd }, { detach = true }, function(obj)
        vim.schedule(function()
            local current = tasks[task_id]
            if not current then
                return
            end
            finalize_task(current, obj, opts)
        end)
    end)
    if not ok then
        return nil, tostring(proc_or_err)
    end

    task.shell_cmd = shell_cmd
    task.status = "running"
    task.started_at = now_ms()
    task.ended_at = nil
    task.stop_requested = false
    task.stop_timer = nil
    task.exit_code = nil
    task.signal = nil
    task.proc = proc_or_err
    task.pid = proc_or_err.pid

    return task
end

function M.setup(opts)
    M.opts = vim.tbl_deep_extend("force", {}, default_opts, opts or {})
    startup_cleanup_output_dir()
end

function M.start(cmd)
    if type(cmd) ~= "string" or vim.trim(cmd) == "" then
        return nil, "command must be a non-empty string"
    end

    local opts = M.opts or default_opts
    local task_id = next_id
    next_id = next_id + 1

    local output_path = new_output_path(task_id)

    local task = {
        id = task_id,
        cmd = cmd,
        shell_cmd = nil,
        output_path = output_path,
        status = "pending",
        created_at = now_ms(),
        started_at = nil,
        ended_at = nil,
        stop_requested = false,
        stop_timer = nil,
        proc = nil,
        pid = nil,
        exit_code = nil,
        signal = nil,
    }

    local started, start_err = launch_task(task, opts)
    if not started then
        return nil, start_err
    end

    tasks[task_id] = task

    return public_task(task)
end

function M.stop(task_id, stop_opts)
    local task, err = get_task(task_id)
    if not task then
        return nil, err
    end

    if task.status == "stopping" then
        return public_task(task)
    end

    if not is_active(task) then
        return public_task(task)
    end

    local opts = vim.tbl_deep_extend("force", {}, M.opts or default_opts, stop_opts or {})

    task.stop_requested = true
    task.status = "stopping"

    local ok, signal_err = send_signal(task, 15)
    if not ok then
        task.status = "failed"
        return nil, "failed to send SIGTERM: " .. signal_err
    end

    local timer = uv.new_timer()
    if not timer then
        task.status = "failed"
        return nil, "failed to create stop timer"
    end

    timer:start(opts.stop_timeout_ms, 0, function()
        local current = tasks[task_id]
        if not current or not is_active(current) then
            if timer and not timer:is_closing() then
                timer:close()
            end
            return
        end

        send_signal(current, 9)

        if timer and not timer:is_closing() then
            timer:close()
        end
    end)

    task.stop_timer = timer

    return public_task(task)
end

function M.rerun(task_id)
    local task, err = get_task(task_id)
    if not task then
        return nil, err
    end

    local cmd = task.cmd
    local active = is_active(task)

    if active then
        local _, stop_err = M.stop(task_id)
        if stop_err then
            return nil, stop_err
        end

        local wait_start = uv.now()
        while uv.now() - wait_start < (M.opts or default_opts).stop_timeout_ms + 1500 do
            vim.wait(25)
            local latest = tasks[task_id]
            if latest and not is_active(latest) then
                break
            end
        end

        local latest = tasks[task_id]
        if latest and is_active(latest) then
            return nil, string.format("task %d did not stop in time", task_id)
        end
    end

    task.cmd = cmd

    local opts = M.opts or default_opts
    local restarted, restart_err = launch_task(task, opts)
    if not restarted then
        return nil, restart_err
    end

    return public_task(task)
end

function M.list()
    local list = {}
    for _, task in pairs(tasks) do
        table.insert(list, public_task(task))
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

function M.get(task_id)
    local task, err = get_task(task_id)
    if not task then
        return nil, err
    end
    return public_task(task)
end

function M.read_output(task_id, read_opts)
    local task, err = get_task(task_id)
    if not task then
        return nil, err
    end

    local opts = read_opts or {}
    local start_line = tonumber(opts.start_line) or 1
    local max_lines = tonumber(opts.max_lines) or 300

    if start_line < 1 then
        start_line = 1
    end
    if max_lines < 1 then
        max_lines = 1
    end

    if not uv.fs_stat(task.output_path) then
        return {
            lines = {},
            next_line = start_line,
            eof = true,
            path = task.output_path,
        }
    end

    local fd, open_err = io.open(task.output_path, "r")
    if not fd then
        return nil, open_err
    end

    local lines = {}
    local n = 0
    local line_no = 0

    local eof = true
    for line in fd:lines() do
        line_no = line_no + 1
        if line_no >= start_line then
            if n >= max_lines then
                eof = false
                break
            end
            table.insert(lines, line)
            n = n + 1
        end
    end

    fd:close()

    return {
        lines = lines,
        next_line = start_line + n,
        eof = eof,
        path = task.output_path,
    }
end

function M.shutdown(shutdown_opts)
    local opts = vim.tbl_deep_extend("force", {
        grace_ms = 80,
        force_kill = true,
    }, shutdown_opts or {})

    local active_ids = {}

    for task_id, task in pairs(tasks) do
        if is_active(task) then
            task.stop_requested = true
            task.status = "stopping"
            send_signal(task, 15)
            table.insert(active_ids, task_id)
        end
    end

    if #active_ids > 0 then
        if opts.grace_ms and opts.grace_ms > 0 then
            vim.wait(opts.grace_ms)
        end

        if opts.force_kill then
            for _, task_id in ipairs(active_ids) do
                local task = tasks[task_id]
                if task and is_active(task) then
                    send_signal(task, 9)
                end
            end
        end
    end

    cleanup_current_instance_dir()
end

function M.clear_finished(opts)
    opts = vim.tbl_deep_extend("force", {}, M.opts or default_opts, opts or {})
    for task_id, task in pairs(tasks) do
        if not is_active(task) then
            maybe_delete_output(task, opts)
            tasks[task_id] = nil
        end
    end
end

M.opts = vim.deepcopy(default_opts)

return M
