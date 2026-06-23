local M = {}

local uv = vim.uv

local tasks = {}
local next_id = 1

local default_opts = {
    stop_timeout_ms = 3000,
    cleanup_output_on_stop = false,
    timeout_ms = 0,
    ready_timeout_ms = 0,
    force_color = true,
    force_color_env = {
        CLICOLOR_FORCE = "1",
        FORCE_COLOR = "1",
    },
}

local listeners = {
    start = {},
    ready = {},
    exit = {},
    timeout = {},
}
local next_listener_id = 1

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
    return (line:gsub("\27%[[%d;]*m", ""))
end

local function read_output_chunk(path, start_line, max_lines)
    if not uv.fs_stat(path) then
        return {
            lines = {},
            next_line = start_line,
            eof = true,
        }
    end

    local fd = io.open(path, "r")
    if not fd then
        return nil, "failed to open output file"
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
    }
end

local function emit_event(event, payload)
    local handlers = listeners[event]
    if not handlers then
        return
    end

    for _, callback in pairs(handlers) do
        pcall(callback, payload)
    end
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

local function normalize_ready_when(ready_when, fallback_timeout_ms)
    if ready_when == nil then
        return nil
    end

    if type(ready_when) == "string" then
        if ready_when == "" then
            return nil, "ready_when pattern must be non-empty"
        end
        return {
            pattern = ready_when,
            match = "plain",
            count = 1,
            timeout_ms = tonumber(fallback_timeout_ms) or 0,
        }
    end

    if type(ready_when) ~= "table" then
        return nil, "ready_when must be a string or table"
    end

    local pattern = ready_when.pattern
    if type(pattern) ~= "string" or pattern == "" then
        return nil, "ready_when.pattern must be a non-empty string"
    end

    local match = ready_when.match
    if match == nil then
        match = "plain"
    end
    if match ~= "plain" and match ~= "regex" then
        return nil, "ready_when.match must be 'plain' or 'regex'"
    end

    if match == "regex" then
        local ok, err = pcall(function()
            local _ = string.find("", pattern)
        end)
        if not ok then
            return nil, "invalid ready_when regex: " .. tostring(err)
        end
    end

    local count = tonumber(ready_when.count) or 1
    count = math.floor(count)
    if count < 1 then
        return nil, "ready_when.count must be >= 1"
    end

    local timeout_ms = ready_when.timeout_ms
    if timeout_ms == nil then
        timeout_ms = fallback_timeout_ms
    end
    timeout_ms = tonumber(timeout_ms) or 0
    timeout_ms = math.max(0, math.floor(timeout_ms))

    return {
        pattern = pattern,
        match = match,
        count = count,
        timeout_ms = timeout_ms,
    }
end

local function resolve_run_opts(global_opts, start_opts)
    start_opts = start_opts or {}

    local timeout_ms = start_opts.timeout_ms
    if timeout_ms == nil then
        timeout_ms = global_opts.timeout_ms
    end
    timeout_ms = tonumber(timeout_ms) or 0
    timeout_ms = math.max(0, math.floor(timeout_ms))

    local ready_when, ready_err = normalize_ready_when(start_opts.ready_when, global_opts.ready_timeout_ms)
    if ready_err then
        return nil, ready_err
    end

    return {
        timeout_ms = timeout_ms,
        ready_when = ready_when,
        notify = start_opts.notify,
    }
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
        ready = task.ready,
        ready_at = task.ready_at,
        notify = task.notify,
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
    if task.timeout_timer and not task.timeout_timer:is_closing() then
        task.timeout_timer:stop()
        task.timeout_timer:close()
    end
    if task.ready_timer and not task.ready_timer:is_closing() then
        task.ready_timer:stop()
        task.ready_timer:close()
    end
    task.stop_timer = nil
    task.timeout_timer = nil
    task.ready_timer = nil
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
        if task.timeout_reached then
            task.status = "timeout"
        elseif obj.signal == 15 then
            task.status = "stopped"
        elseif obj.signal == 9 then
            task.status = "killed"
        else
            task.status = "stopped"
        end
        maybe_delete_output(task, opts)
        emit_event("exit", {
            task = public_task(task),
        })
        return
    end

    if obj.code == 0 then
        task.status = "success"
    else
        task.status = "failed"
    end

    emit_event("exit", {
        task = public_task(task),
    })
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

local function line_matches_ready(ready_when, line)
    if ready_when.match == "regex" then
        return line:find(ready_when.pattern) ~= nil
    end
    return line:find(ready_when.pattern, 1, true) ~= nil
end

local function start_ready_watcher(task)
    if not task.ready_when then
        return
    end

    local timer = uv.new_timer()
    if not timer then
        return
    end

    task.ready_timer = timer
    local check_interval = 300
    timer:start(0, check_interval, function()
        vim.schedule(function()
            local current = tasks[task.id]
            if not current or not is_active(current) then
                if timer and not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                return
            end

            if current.ready then
                if timer and not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                current.ready_timer = nil
                return
            end

            local timeout_ms = current.ready_when.timeout_ms or 0
            if timeout_ms > 0 and current.started_at and (now_ms() - current.started_at) >= timeout_ms then
                if timer and not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                current.ready_timer = nil
                emit_event("timeout", {
                    kind = "ready",
                    task = public_task(current),
                })
                return
            end

            local chunk, chunk_err = read_output_chunk(current.output_path, current.ready_next_line or 1, 300)
            if not chunk then
                vim.notify("Flyout: " .. tostring(chunk_err), vim.log.levels.ERROR)
                return
            end

            current.ready_next_line = chunk.next_line

            for _, raw_line in ipairs(chunk.lines) do
                local plain = strip_ansi(raw_line)
                if line_matches_ready(current.ready_when, plain) then
                    current.ready_match_count = current.ready_match_count + 1
                    if current.ready_match_count >= current.ready_when.count then
                        current.ready = true
                        current.ready_at = now_ms()
                        if timer and not timer:is_closing() then
                            timer:stop()
                            timer:close()
                        end
                        current.ready_timer = nil
                        emit_event("ready", {
                            task = public_task(current),
                            count = current.ready_match_count,
                            line = plain,
                        })
                        return
                    end
                end
            end
        end)
    end)
end

local function start_task_timeout(task, opts)
    local timeout_ms = (task.run_opts and task.run_opts.timeout_ms) or 0
    if timeout_ms <= 0 then
        return
    end

    local timer = uv.new_timer()
    if not timer then
        return
    end

    task.timeout_timer = timer
    timer:start(timeout_ms, 0, function()
        vim.schedule(function()
            local current = tasks[task.id]
            if not current or not is_active(current) then
                if timer and not timer:is_closing() then
                    timer:close()
                end
                return
            end

            current.timeout_reached = true
            emit_event("timeout", {
                kind = "task",
                task = public_task(current),
            })
            M.stop(current.id, {
                stop_timeout_ms = opts.stop_timeout_ms,
            })
        end)
    end)
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
    task.timeout_reached = false
    task.stop_timer = nil
    task.timeout_timer = nil
    task.ready_timer = nil
    task.exit_code = nil
    task.signal = nil
    task.proc = proc_or_err
    task.pid = proc_or_err.pid
    task.ready = false
    task.ready_at = nil
    task.ready_match_count = 0
    task.ready_next_line = 1

    start_task_timeout(task, opts)
    start_ready_watcher(task)

    return task
end

function M.setup(opts)
    M.opts = vim.tbl_deep_extend("force", {}, default_opts, opts or {})
    startup_cleanup_output_dir()
end

function M.start(cmd, start_opts)
    if type(cmd) ~= "string" or vim.trim(cmd) == "" then
        return nil, "command must be a non-empty string"
    end

    local opts = M.opts or default_opts
    local run_opts, run_opts_err = resolve_run_opts(opts, start_opts)
    if not run_opts then
        return nil, run_opts_err
    end

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
        run_opts = run_opts,
        ready_when = run_opts.ready_when,
        notify = run_opts.notify,
        ready = false,
        ready_at = nil,
        ready_match_count = 0,
        ready_next_line = 1,
        timeout_reached = false,
    }

    local started, start_err = launch_task(task, opts)
    if not started then
        return nil, start_err
    end

    tasks[task_id] = task

    emit_event("start", {
        task = public_task(task),
    })

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
    local run_opts = task.run_opts or {
        timeout_ms = opts.timeout_ms,
        ready_when = nil,
    }
    task.run_opts = run_opts
    task.ready_when = run_opts.ready_when
    task.notify = run_opts.notify
    local restarted, restart_err = launch_task(task, opts)
    if not restarted then
        return nil, restart_err
    end

    emit_event("start", {
        task = public_task(task),
    })

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

function M.on(event, callback)
    if type(event) ~= "string" or not listeners[event] then
        return nil, "unknown event: " .. tostring(event)
    end
    if type(callback) ~= "function" then
        return nil, "callback must be a function"
    end

    local id = next_listener_id
    next_listener_id = next_listener_id + 1
    listeners[event][id] = callback
    return id
end

function M.off(event, listener_id)
    if type(event) ~= "string" or not listeners[event] then
        return false
    end
    listeners[event][listener_id] = nil
    return true
end

M.opts = vim.deepcopy(default_opts)

return M
