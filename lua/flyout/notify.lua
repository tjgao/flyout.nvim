-- notify.lua
-- A full-featured notification plugin with snacks.nvim-style aesthetics
-- Usage:
--   local notify = require("notify")
--   notify.setup()  -- overrides vim.notify
--   local handle = notify("message", vim.log.levels.INFO, { title = "My Plugin" })
--   handle:close()

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

-- ─── Config ───────────────────────────────────────────────────────────────────

local default_config = {
    timeout = 3000,                  -- ms before auto-dismiss (false to disable)
    max_height = 25,                 -- max body lines before "more ..." footer
    padding = { top = 0, right = 2, bottom = 0, left = 2 },
    margin = { top = 1, right = 2 }, -- from top-right edge
    gap = 1,                         -- vertical gap between stacked notifications
    animate = true,
    fps = 60,
    stages = {
        enter = { { blend = 100 }, { blend = 60 }, { blend = 0 } },
        exit = { { blend = 0 }, { blend = 60 }, { blend = 100 } },
    },
    icons = {
        ERROR = "󰅚 ",
        WARN = "󰀪 ",
        INFO = "󰋼 ",
        DEBUG = "",
        TRACE = "󰅩 ",
    },
    highlights = {
        ERROR = {
            border = "NotifyERRORBorder",
            icon = "NotifyERRORIcon",
            title = "NotifyERRORTitle",
            body = "NotifyERRORBody",
            footer = "NotifyERRORFooter",
        },
        WARN = {
            border = "NotifyWARNBorder",
            icon = "NotifyWARNIcon",
            title = "NotifyWARNTitle",
            body = "NotifyWARNBody",
            footer = "NotifyWARNFooter",
        },
        INFO = {
            border = "NotifyINFOBorder",
            icon = "NotifyINFOIcon",
            title = "NotifyINFOTitle",
            body = "NotifyINFOBody",
            footer = "NotifyINFOFooter",
        },
        DEBUG = {
            border = "NotifyDEBUGBorder",
            icon = "NotifyDEBUGIcon",
            title = "NotifyDEBUGTitle",
            body = "NotifyDEBUGBody",
            footer = "NotifyDEBUGFooter",
        },
        TRACE = {
            border = "NotifyTRACEBorder",
            icon = "NotifyTRACEIcon",
            title = "NotifyTRACETitle",
            body = "NotifyTRACEBody",
            footer = "NotifyTRACEFooter",
        },
    },
}

local config = vim.deepcopy(default_config)

-- ─── Highlight Setup (colorscheme-adaptive) ───────────────────────────────────

-- Extract a highlight fg/bg attribute, without following links.
local function get_hl_attr(name, attr)
    local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl and hl[attr] then
        return hl[attr]
    end
end

local function resolve_fg(groups, fallback)
    for _, g in ipairs(groups) do
        local v = get_hl_attr(g, "fg")
        if v then
            return v
        end
    end
    return fallback
end

local function resolve_bg(groups, fallback)
    for _, g in ipairs(groups) do
        local v = get_hl_attr(g, "bg")
        if v then
            return v
        end
    end
    return fallback
end

-- Diagnostic highlight groups to source accent colors from, per level.
local level_accent_groups = {
    ERROR = { "DiagnosticSignError", "DiagnosticError", "DiagnosticVirtualTextError" },
    WARN = { "DiagnosticSignWarn", "DiagnosticWarn", "DiagnosticVirtualTextWarn" },
    INFO = { "DiagnosticSignInfo", "DiagnosticInfo", "DiagnosticVirtualTextInfo" },
    DEBUG = { "DiagnosticSignHint", "DiagnosticHint", "DiagnosticVirtualTextHint" },
    TRACE = { "Comment" },
}
local level_fallbacks = {
    ERROR = 0xf87171,
    WARN = 0xfbbf24,
    INFO = 0x4ade80,
    DEBUG = 0xa78bfa,
    TRACE = 0x94a3b8,
}

local function setup_highlights()
    local bg = resolve_bg({ "NormalFloat", "Normal" }, 0x1e1e2e)
    local fg_body = resolve_fg({ "NormalFloat", "Normal" }, 0xcdd6f4)
    local fg_dim = resolve_fg({ "Comment" }, 0x6c7086)

    for level, groups in pairs(level_accent_groups) do
        local accent = resolve_fg(groups, level_fallbacks[level])
        local hl = config.highlights[level]
        api.nvim_set_hl(0, hl.border, { fg = accent, bg = bg, default = false })
        api.nvim_set_hl(0, hl.icon, { fg = accent, bg = bg, bold = true, default = false })
        api.nvim_set_hl(0, hl.title, { fg = accent, bg = bg, bold = true, default = false })
        api.nvim_set_hl(0, hl.body, { fg = fg_body, bg = bg, default = false })
        api.nvim_set_hl(0, hl.footer, { fg = fg_dim, bg = bg, italic = true, default = false })
    end

    api.nvim_set_hl(0, "NotifyBackground", { bg = bg, default = false })
    api.nvim_set_hl(0, "NotifyDimText", { fg = fg_dim, bg = bg, default = false })
end

-- ─── Level Utilities ─────────────────────────────────────────────────────────

local level_names = {
    [vim.log.levels.ERROR] = "ERROR",
    [vim.log.levels.WARN] = "WARN",
    [vim.log.levels.INFO] = "INFO",
    [vim.log.levels.DEBUG] = "DEBUG",
    [vim.log.levels.TRACE] = "TRACE",
}

local function level_name(level)
    if type(level) == "string" then
        return level:upper()
    end
    return level_names[level] or "INFO"
end

-- ─── Layout ───────────────────────────────────────────────────────────────────

-- Active notifications (bottom of list = bottom of screen stack)
local stack = {} -- list of handle objects, ordered bottom→top visually
local next_id = 0

local function editor_size()
    return { width = vim.o.columns, height = vim.o.lines }
end

-- Compute the row (top edge) for each slot in the stack.
-- Slot 1 = top-most (nearest screen top); stack grows downward.
local function layout_rows()
    local ed = editor_size()
    local rows = {}
    local y = config.margin.top
    for i = 1, #stack do
        local h = stack[i]
        local win_w = h._win_width or 30
        local col = ed.width - win_w - config.margin.right - 2 -- -2 for border
        rows[i] = { row = y, col = col }
        y = y + (h._win_height or 3) + config.gap
    end
    return rows
end

local function reflow()
    local rows = layout_rows()
    for i, h in ipairs(stack) do
        local pos = rows[i]
        if pos and h._winnr and api.nvim_win_is_valid(h._winnr) then
            api.nvim_win_set_config(h._winnr, {
                relative = "editor",
                row = pos.row + (h._y_offset or 0),
                col = pos.col,
            })
        end
    end
end

-- ─── Animation ───────────────────────────────────────────────────────────────

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function animate_stages(handle, stages, on_done)
    if not config.animate or #stages == 0 then
        if on_done then
            on_done()
        end
        return
    end

    local interval = math.floor(1000 / config.fps)
    local stage_idx = 1
    local step_count = 3 -- steps per stage
    local step = 0
    local timer = uv.new_timer()
    if not timer then
        if on_done then
            on_done()
        end
        return
    end
    handle._anim_timer = timer

    timer:start(
        0,
        interval,
        vim.schedule_wrap(function()
            if not handle._winnr or not api.nvim_win_is_valid(handle._winnr) then
                timer:stop()
                timer:close()
                return
            end

            local stage = stages[stage_idx]
            if not stage then
                timer:stop()
                timer:close()
                if on_done then
                    on_done()
                end
                return
            end

            step = step + 1
            local t = step / step_count

            -- blend
            local target_blend = stage.blend or 0
            local cur_blend = vim.api.nvim_get_option_value("winblend", { win = handle._winnr })
            local new_blend = math.floor(lerp(cur_blend, target_blend, t))
            pcall(vim.api.nvim_set_option_value, "winblend", math.max(0, math.min(100, new_blend)), {
                win = handle._winnr,
            })

            -- y offset
            if stage.dy then
                handle._y_offset = (handle._y_offset or 0) + stage.dy * (1 / step_count)
                reflow()
            end

            if step >= step_count then
                step = 0
                stage_idx = stage_idx + 1
            end
        end)
    )
end

local function stop_anim(handle)
    if handle._anim_timer then
        pcall(function()
            handle._anim_timer:stop()
            handle._anim_timer:close()
        end)
        handle._anim_timer = nil
    end
end

-- ─── Window / Buffer Construction ────────────────────────────────────────────

-- Truncate a string to fit within max_display_width cols, appending "…" if cut.
local function truncate(s, max_cols)
    local w = vim.fn.strdisplaywidth(s)
    if w <= max_cols then
        return s
    end
    -- Binary-ish trim by chars until it fits with ellipsis
    local out = s
    while vim.fn.strdisplaywidth(out .. "…") > max_cols and #out > 0 do
        out = out:sub(1, -2)
    end
    return out .. "…"
end

-- Compute adaptive inner content width (excludes padding and border).
--   max  = floor(editor_width * 0.30) - padding - 2 (border)
--   min  = max(widest_content_line, 25)
-- content_lines: raw message lines (before truncation) + optional title string
local function compute_inner_width(msg, title, lvl_name)
    local ed = editor_size()
    local pad = config.padding.left + config.padding.right
    local icon = config.icons[lvl_name] or " "

    local max_inner = math.floor(ed.width * 0.30) - pad - 2

    -- Measure title
    local widest = 25 -- absolute minimum
    if title and title ~= "" then
        widest = math.max(widest, vim.fn.strdisplaywidth(icon) + 1 + vim.fn.strdisplaywidth(title))
    end

    -- Measure every body line (icon prefix only on first line when no title)
    local raw_lines = vim.split(msg, "\n", { plain = true })
    local no_title = not (title and title ~= "")
    for i, raw in ipairs(raw_lines) do
        local prefix_w = (no_title and i == 1) and (vim.fn.strdisplaywidth(icon) + 1) or 0
        widest = math.max(widest, prefix_w + vim.fn.strdisplaywidth(raw))
    end

    return math.min(widest, max_inner)
end

-- Build buffer lines and highlight specs.
-- win_w here is the INNER width (no padding, no border).
-- Returns: lines, hls, has_more (bool)
local function build_content(msg, lvl_name, opts, inner_w)
    local hl = config.highlights[lvl_name] or config.highlights.INFO
    local icon = config.icons[lvl_name] or " "
    local title = opts.title

    local pad_l = string.rep(" ", config.padding.left)
    local pad_r = string.rep(" ", config.padding.right)
    -- inner_w is passed in directly — no further subtraction needed

    local lines = {}
    local hls = {} -- { line_idx, col_start, col_end, hl_group }

    -- ── Body rows: split on newlines, no wrapping, truncate each line
    -- When there's no title, prefix the icon on the first body line.
    local raw_lines = vim.split(msg, "\n", { plain = true })
    local no_title = not (title and title ~= "")

    for idx, raw in ipairs(raw_lines) do
        local prefix = pad_l
        local icon_hl_end = nil
        if no_title and idx == 1 then
            prefix = pad_l .. icon .. " "
            icon_hl_end = config.padding.left + vim.fn.strdisplaywidth(icon)
        end
        local available = inner_w - (vim.fn.strdisplaywidth(prefix) - config.padding.left)
        local text = truncate(raw, available)
        local full_line = prefix .. text .. pad_r
        table.insert(lines, full_line)
        local line_idx = #lines - 1
        if icon_hl_end then
            table.insert(hls, { line_idx, config.padding.left, icon_hl_end, hl.icon })
            table.insert(hls, { line_idx, icon_hl_end + 1, -1, hl.body })
        else
            table.insert(hls, { line_idx, 0, -1, hl.body })
        end
    end

    -- ── Height cap: show first max_height lines, footer if more exist
    local has_more = false
    local total_body = #lines
    if total_body > config.max_height then
        has_more = true
        local kept = {}
        for i = 1, config.max_height do
            kept[i] = lines[i]
        end
        hls = vim.tbl_filter(function(h)
            return h[1] < config.max_height
        end, hls)
        lines = kept

        local hidden = total_body - config.max_height
        local footer_text = string.format("↓ %d more line%s", hidden, hidden == 1 and "" or "s")
        local footer_line = pad_l .. truncate(footer_text, inner_w) .. pad_r
        table.insert(lines, footer_line)
        table.insert(hls, { #lines - 1, 0, -1, hl.footer })
    end

    return lines, hls, has_more
end

local function make_win_title(title, lvl_name, inner_w)
    local icon = config.icons[lvl_name] or " "
    if title and title ~= "" then
        local t = truncate(icon .. " " .. title, inner_w)
        return { { " " .. t .. " ", (config.highlights[lvl_name] or config.highlights.INFO).title } }
    else
        -- no title: just show the icon in the border
        return { { " " .. icon .. " ", (config.highlights[lvl_name] or config.highlights.INFO).icon } }
    end
end

local function make_border(lvl_name)
    local hl = config.highlights[lvl_name] or config.highlights.INFO
    local function C(char)
        return { char, hl.border }
    end
    return {
        C("╭"),
        C("─"),
        C("╮"),
        C("│"),
        C("╯"),
        C("─"),
        C("╰"),
        C("│"),
    }
end

-- ─── Handle Object ────────────────────────────────────────────────────────────

local Handle = {}
Handle.__index = Handle

function Handle:_open(msg, lvl_name, opts)
    local inner_w = compute_inner_width(msg, opts.title, lvl_name)
    local win_w = inner_w + config.padding.left + config.padding.right
    local lines, hls = build_content(msg, lvl_name, opts, inner_w)
    local win_h = math.min(#lines, config.max_height + 3)

    self._win_width = win_w
    self._win_height = win_h + 2 -- +2 for border

    -- buffer
    local bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    vim.api.nvim_set_option_value("filetype", "notify", { buf = bufnr })

    -- apply highlights
    local ns = api.nvim_create_namespace("notify_hl_" .. self.id)
    for _, h in ipairs(hls) do
        local line, cs, ce, group = h[1], h[2], h[3], h[4]
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, cs, {
            end_col = ce,
            hl_group = group,
        })
    end

    -- initial position (will be corrected by reflow)
    local ed = editor_size()
    local col = ed.width - win_w - config.margin.right

    local winnr = api.nvim_open_win(bufnr, false, {
        relative = "editor",
        row = ed.height - 4,
        col = col,
        width = win_w,
        height = win_h,
        style = "minimal",
        border = make_border(lvl_name),
        title = make_win_title(opts.title, lvl_name, inner_w),
        title_pos = "center",
        focusable = false,
        noautocmd = true,
    })

    vim.api.nvim_set_option_value(
        "winhl",
        "Normal:NotifyBackground,FloatBorder:" .. (config.highlights[lvl_name] or config.highlights.INFO).border,
        { win = winnr }
    )
    vim.api.nvim_set_option_value("winblend", config.animate and 100 or 0, { win = winnr })
    vim.api.nvim_set_option_value("wrap", false, { win = winnr })
    vim.api.nvim_set_option_value("cursorline", false, { win = winnr })

    self._bufnr = bufnr
    self._winnr = winnr
    self._y_offset = 0
    self._closed = false

    -- slot already reserved in stack by M.notify; just reflow and animate
    reflow()

    -- enter animation
    animate_stages(self, config.stages.enter, nil)

    -- auto-dismiss
    if opts.timeout ~= false then
        local timeout = opts.timeout or config.timeout
        if timeout and timeout > 0 then
            self._timeout_timer = uv.new_timer()
            self._timeout_timer:start(
                timeout,
                0,
                vim.schedule_wrap(function()
                    self:close()
                end)
            )
        end
    end
end

function Handle:close()
    if self._closed then
        return
    end
    self._closed = true

    -- cancel auto-dismiss timer
    if self._timeout_timer then
        pcall(function()
            self._timeout_timer:stop()
            self._timeout_timer:close()
        end)
        self._timeout_timer = nil
    end

    stop_anim(self)

    local function do_close()
        if self._winnr and api.nvim_win_is_valid(self._winnr) then
            api.nvim_win_close(self._winnr, true)
        end
        if self._bufnr and api.nvim_buf_is_valid(self._bufnr) then
            api.nvim_buf_delete(self._bufnr, { force = true })
        end
        -- remove from stack
        for i, h in ipairs(stack) do
            if h.id == self.id then
                table.remove(stack, i)
                break
            end
        end
        reflow()
    end

    if config.animate then
        animate_stages(self, config.stages.exit, vim.schedule_wrap(do_close))
    else
        do_close()
    end
end

-- Alias
Handle.hide = Handle.close
Handle.dismiss = Handle.close

function Handle:update(msg, opts)
    opts = opts or {}
    if self._closed or not self._bufnr or not api.nvim_buf_is_valid(self._bufnr) then
        return
    end
    local lvl_name = self._lvl_name
    local merged = vim.tbl_extend("force", self._opts, opts)
    local inner_w = compute_inner_width(msg, merged.title, lvl_name)
    local win_w = inner_w + config.padding.left + config.padding.right
    local lines, hls = build_content(msg, lvl_name, merged, inner_w)

    vim.api.nvim_set_option_value("modifiable", true, { buf = self._bufnr })
    api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = self._bufnr })

    local ns = api.nvim_create_namespace("notify_hl_" .. self.id)
    api.nvim_buf_clear_namespace(self._bufnr, ns, 0, -1)
    for _, h in ipairs(hls) do
        pcall(vim.api.nvim_buf_set_extmark, self._bufnr, ns, h[1], h[2], {
            end_col = h[3],
            hl_group = h[4],
        })
    end

    local win_h = math.min(#lines, config.max_height + 3)
    self._win_width = win_w
    self._win_height = win_h + 2
    if self._winnr and api.nvim_win_is_valid(self._winnr) then
        api.nvim_win_set_config(self._winnr, {
            width = win_w,
            height = win_h,
            title = make_win_title(merged.title, lvl_name, inner_w),
            title_pos = "center",
        })
    end
    reflow()
end

-- ─── Public API ──────────────────────────────────────────────────────────────

---@param msg string
---@param level? number|string  vim.log.levels constant or string
---@param opts? { title?: string, timeout?: number|false, replace?: table }
---@return table handle
function M.notify(msg, level, opts)
    opts = opts or {}
    local lvl_name = level_name(level or vim.log.levels.INFO)

    -- replace an existing notification
    if opts.replace and not opts.replace._closed then
        opts.replace:update(msg, opts)
        return opts.replace
    end

    -- Pre-compute dimensions now (before vim.schedule) so layout_rows sees
    -- correct sizes even if multiple notifications are queued in the same tick.
    local inner_w = compute_inner_width(msg, opts.title, lvl_name)
    local win_w = inner_w + config.padding.left + config.padding.right
    local lines = build_content(msg, lvl_name, opts, inner_w) -- just for line count
    local win_h = math.min(#lines, config.max_height + 3)

    next_id = next_id + 1
    local handle = setmetatable({
        id = next_id,
        _lvl_name = lvl_name,
        _opts = opts,
        _win_width = win_w,
        _win_height = win_h + 2,
    }, Handle)

    -- Reserve the stack slot now (synchronously) so order is always insertion order.
    table.insert(stack, handle)

    -- Open the window in a scheduled callback (safe from fast contexts).
    vim.schedule(function()
        handle:_open(msg, lvl_name, opts)
    end)

    return handle
end

---Dismiss all active notifications
function M.dismiss_all()
    -- copy because close() mutates stack
    local handles = {}
    for _, h in ipairs(stack) do
        table.insert(handles, h)
    end
    for _, h in ipairs(handles) do
        h:close()
    end
end

---@param opts? table  override config
function M.setup(opts)
    opts = opts or {}
    local override_vim_notify = opts.override_vim_notify ~= false
    local merged = vim.deepcopy(opts)
    merged.override_vim_notify = nil
    config = vim.tbl_deep_extend("force", default_config, merged)
    setup_highlights()

    -- Re-run highlights on colorscheme change
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("NotifyHighlights", { clear = true }),
        callback = setup_highlights,
    })

    -- Handle window resize: reflow the stack
    vim.api.nvim_create_autocmd("VimResized", {
        group = vim.api.nvim_create_augroup("NotifyResize", { clear = true }),
        callback = reflow,
    })

    -- Override vim.notify
    if override_vim_notify then
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg, level, nopts)
            return M.notify(msg, level, nopts)
        end
    end
end

-- Allow direct call:  require("notify")("msg", level, opts)
setmetatable(M, {
    __call = function(_, ...)
        return M.notify(...)
    end,
})

return M
