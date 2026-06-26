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
    timeout = 3000,        -- ms before auto-dismiss (false to disable)
    vacant_timeout = 2000, -- ms vacant slot stays before collapsing
    max_height = 25,       -- max body lines before "more ..." footer
    padding = { top = 0, right = 2, bottom = 0, left = 2 },
    margin = { top = 1, right = 2 },
    gap = 1, -- vertical gap between stacked notifications
    -- Animation: set animate=false to disable, fps controls smoothness
    animate = true,
    fps = 60,
    animation = {
        enter_ms = 220,
        exit_ms = 180,
        collapse_ms = 220,
        -- Effects can be string ("fade+slide"), list ({"fade", "slide"}), or false/"none".
        -- Supported: fade, slide, reveal
        enter = { "slide", "reveal" },
        exit = { "slide", "reveal" },
        -- Optional tuning knobs for slide/reveal
        slide_cols = nil, -- auto if nil
        edge_cols = nil,  -- auto if nil
    },
    icons = {
        ERROR = "󰅚",
        WARN = "󰀪",
        INFO = "󰋼",
        DEBUG = "",
        TRACE = "󰅩",
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
    local bg = resolve_bg({ "Normal", "NormalFloat" }, 0x1e1e2e)
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

-- stack: handles + vacant placeholders { _vacant=true, _win_height, _win_width, id }
local stack = {}
local next_id = 0

local function editor_size()
    return { width = vim.o.columns, height = vim.o.lines }
end

-- Logical position of each slot (ignores per-window slide offsets).
local function layout_rows()
    local ed = editor_size()
    local rows = {}
    local y = config.margin.top
    for i, h in ipairs(stack) do
        local win_w = h._win_width or 30
        local col = ed.width - win_w - config.margin.right - 2
        rows[i] = { row = y, col = col }
        y = y + (h._win_height or 3) + config.gap
    end
    return rows
end

-- Reposition every open window to its logical slot.
local function reflow()
    local rows = layout_rows()
    for i, h in ipairs(stack) do
        local pos = rows[i]
        if pos and h._winnr and api.nvim_win_is_valid(h._winnr) and not h._animating then
            api.nvim_win_set_config(h._winnr, {
                relative = "editor",
                row = pos.row,
                col = pos.col,
            })
        end
    end
end

-- Move a single window to an absolute (row, col), bypassing logical layout.
local function win_move(winnr, row, col)
    if row == nil or col == nil then
        return
    end
    pcall(api.nvim_win_set_config, winnr, {
        relative = "editor",
        row = math.floor(tonumber(row) or 0),
        col = math.floor(tonumber(col) or 0),
    })
end

local function slide_edge_cols(win_w)
    local animation = config.animation
    if type(animation) == "table" then
        local edge = tonumber(animation.edge_cols)
        if edge and edge >= 2 then
            return math.floor(edge)
        end
    end
    local w = tonumber(win_w) or 30
    return math.max(2, math.floor(w * 0.12))
end

local function slide_distance_cols(win_w)
    local animation = config.animation
    if type(animation) == "table" then
        local slide = tonumber(animation.slide_cols)
        if slide and slide > 0 then
            return math.floor(slide)
        end
    end
    local w = tonumber(win_w) or 30
    return math.max(4, math.floor(w * 0.2))
end

local function effect_set(values)
    local set = {}
    if type(values) == "string" then
        local text = values:lower()
        if text == "none" then
            return set
        end
        for token in text:gmatch("[^+,%s|]+") do
            set[token] = true
        end
        return set
    end
    if type(values) == "table" then
        for _, value in ipairs(values) do
            if type(value) == "string" then
                set[value:lower()] = true
            end
        end
    end
    return set
end

local function animation_effects(name, fallback)
    local animation = config.animation
    if type(animation) ~= "table" then
        return fallback
    end
    local raw = animation[name]
    if raw == nil then
        return fallback
    end
    if type(raw) == "string" and raw:lower() == "none" then
        return {}
    end
    if raw == false then
        return {}
    end
    if type(raw) == "table" and next(raw) == nil then
        return {}
    end
    local set = effect_set(raw)
    if next(set) == nil then
        return fallback
    end
    return set
end

local function has_effect(effects, name)
    return effects and effects[name] == true
end

-- ─── Animation ───────────────────────────────────────────────────────────────

local function lerp(a, b, t)
    return a + (b - a) * t
end
local function ease(t)
    return t * t * (3 - 2 * t)
end -- smoothstep

local function stop_anim(handle)
    if handle._anim_timer then
        pcall(function()
            handle._anim_timer:stop()
            handle._anim_timer:close()
        end)
        handle._anim_timer = nil
    end
    handle._animating = false
end

local collapse_state = {
    timer = nil,
    moving = {},
}

local function stop_collapse_animation()
    if collapse_state.timer and not collapse_state.timer:is_closing() then
        collapse_state.timer:stop()
        collapse_state.timer:close()
    end
    collapse_state.timer = nil
    for _, h in ipairs(collapse_state.moving) do
        h._animating = false
    end
    collapse_state.moving = {}
end

local function animation_ms(name, fallback)
    local animation = config.animation
    if type(animation) ~= "table" then
        return fallback
    end
    local value = tonumber(animation[name])
    if not value or value <= 0 then
        return fallback
    end
    return math.floor(value)
end

-- Animate a single window.
-- keyframe fields: blend (0=opaque,100=invisible), col, row  (absolute editor coords)
-- Missing fields are held at their current value.
local function animate_to(handle, keyframes, on_done, duration_ms)
    if not config.animate or #keyframes == 0 then
        if on_done then
            on_done()
        end
        return
    end

    stop_anim(handle)
    handle._animating = true

    local rows = layout_rows()
    local slot_pos = nil
    for i, h in ipairs(stack) do
        if h.id == handle.id then
            slot_pos = rows[i]
            break
        end
    end
    if not slot_pos then
        handle._animating = false
        if on_done then
            on_done()
        end
        return
    end

    local interval = math.floor(1000 / config.fps)
    local ms = tonumber(duration_ms) or 200
    if ms <= 0 then
        ms = 200
    end
    local steps_per = math.max(1, math.floor((config.fps * ms) / 1000))
    local kf_idx = 1
    local step = 0

    local ok, cb = pcall(api.nvim_win_get_option, handle._winnr, "winblend")
    local cur_blend = ok and cb or 0
    local cur_col = slot_pos.col
    local cur_row = slot_pos.row
    local cur_width = handle._win_width or 30
    local cur_height = handle._win_height or 3

    -- Read actual window position as starting point
    local winfo = api.nvim_win_get_config(handle._winnr)
    if winfo and winfo.col then
        cur_col = winfo.col
    end
    if winfo and winfo.row then
        cur_row = winfo.row
    end
    if winfo and winfo.width then
        cur_width = winfo.width
    end
    if winfo and winfo.height then
        cur_height = winfo.height
    end

    local timer = uv.new_timer()
    handle._anim_timer = timer

    timer:start(
        0,
        interval,
        vim.schedule_wrap(function()
            if not handle._winnr or not api.nvim_win_is_valid(handle._winnr) then
                handle._animating = false
                timer:stop()
                timer:close()
                return
            end
            local kf = keyframes[kf_idx]
            if not kf then
                handle._animating = false
                timer:stop()
                timer:close()
                if handle._pending_update and not handle._closed then
                    local pending = handle._pending_update
                    handle._pending_update = nil
                    handle:update(pending.msg, pending.opts)
                end
                if on_done then
                    on_done()
                end
                return
            end

            step = step + 1
            local t = ease(math.min(step / steps_per, 1))

            local new_col = kf.col ~= nil and lerp(cur_col, kf.col, t) or nil
            local new_row = kf.row ~= nil and lerp(cur_row, kf.row, t) or nil
            local new_width = kf.width ~= nil and lerp(cur_width, kf.width, t) or nil
            local new_height = kf.height ~= nil and lerp(cur_height, kf.height, t) or nil

            if kf.right_edge ~= nil then
                local width_for_col = new_width ~= nil and new_width or cur_width
                new_col = kf.right_edge - width_for_col
            end

            if kf.blend ~= nil then
                local b = math.floor(lerp(cur_blend, kf.blend, t))
                pcall(api.nvim_win_set_option, handle._winnr, "winblend", math.max(0, math.min(100, b)))
            end
            if new_col ~= nil or new_row ~= nil or new_width ~= nil or new_height ~= nil then
                local cfg = {
                    relative = "editor",
                    row = math.floor(new_row ~= nil and new_row or cur_row),
                    col = math.floor(new_col ~= nil and new_col or cur_col),
                }
                if new_width ~= nil then
                    cfg.width = math.max(2, math.floor(new_width))
                end
                if new_height ~= nil then
                    cfg.height = math.max(1, math.floor(new_height))
                end
                pcall(api.nvim_win_set_config, handle._winnr, cfg)
            end

            if t >= 1 then
                step = 0
                kf_idx = kf_idx + 1
                cur_blend = kf.blend ~= nil and kf.blend or cur_blend
                cur_col = kf.col ~= nil and kf.col or cur_col
                cur_row = kf.row ~= nil and kf.row or cur_row
                cur_width = kf.width ~= nil and kf.width or cur_width
                cur_height = kf.height ~= nil and kf.height or cur_height
                if kf.right_edge ~= nil then
                    cur_col = kf.right_edge - cur_width
                end
            end
        end)
    )
end

-- Animate all currently visible windows to their latest layout targets.
local function animate_collapse()
    stop_collapse_animation()

    local ms = animation_ms("collapse_ms", 220)
    local steps_per = math.max(1, math.floor((config.fps * ms) / 1000))
    local interval = math.floor(1000 / config.fps)
    local step = 0

    local targets = layout_rows()
    local moving = {}
    for i = 1, #stack do
        local h = stack[i]
        local t = targets[i]
        if h and t and h._winnr and api.nvim_win_is_valid(h._winnr) then
            local cfg = api.nvim_win_get_config(h._winnr)
            local sr = cfg and cfg.row or t.row
            local sc = cfg and cfg.col or t.col
            if sr ~= t.row or sc ~= t.col then
                h._animating = true
                moving[#moving + 1] = {
                    handle = h,
                    start_row = sr,
                    start_col = sc,
                    target_row = t.row,
                    target_col = t.col,
                }
            end
        end
    end

    if #moving == 0 then
        reflow()
        return
    end

    collapse_state.moving = {}
    for _, item in ipairs(moving) do
        table.insert(collapse_state.moving, item.handle)
    end

    local timer = uv.new_timer()
    collapse_state.timer = timer
    timer:start(
        0,
        interval,
        vim.schedule_wrap(function()
            step = step + 1
            local t = ease(math.min(step / steps_per, 1))

            for _, item in ipairs(moving) do
                local h = item.handle
                if h._winnr and api.nvim_win_is_valid(h._winnr) then
                    win_move(
                        h._winnr,
                        lerp(item.start_row, item.target_row, t),
                        lerp(item.start_col, item.target_col, t)
                    )
                end
            end

            if t >= 1 then
                stop_collapse_animation()
                reflow()
            end
        end)
    )
end

-- ─── Window / Buffer Construction ────────────────────────────────────────────

-- Truncate a string to fit within max_cols display columns, appending "…" if cut.
local ellipsis = "…"
local ellipsis_w = vim.fn.strdisplaywidth(ellipsis)
local function truncate(s, max_cols)
    if vim.fn.strdisplaywidth(s) <= max_cols then
        return s
    end
    local out = s
    -- trim one UTF-8 char at a time until (out + ellipsis) fits
    while #out > 0 and vim.fn.strdisplaywidth(out) + ellipsis_w > max_cols do
        -- step back one UTF-8 character (multi-byte safe)
        out = out:gsub("[\128-\191]*.$", "")
    end
    return out .. ellipsis
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
    api.nvim_buf_set_option(bufnr, "modifiable", false)
    api.nvim_buf_set_option(bufnr, "filetype", "notify")

    -- apply highlights
    local ns = api.nvim_create_namespace("notify_hl_" .. self.id)
    for _, h in ipairs(hls) do
        local line, cs, ce, group = h[1], h[2], h[3], h[4]
        pcall(api.nvim_buf_add_highlight, bufnr, ns, group, line, cs, ce)
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

    api.nvim_win_set_option(
        winnr,
        "winhl",
        "Normal:NotifyBackground,FloatBorder:" .. (config.highlights[lvl_name] or config.highlights.INFO).border
    )
    api.nvim_win_set_option(winnr, "winblend", config.animate and 100 or 0)
    api.nvim_win_set_option(winnr, "wrap", false)
    api.nvim_win_set_option(winnr, "cursorline", false)

    self._bufnr = bufnr
    self._winnr = winnr
    self._closed = false

    -- Find this handle's logical position
    local rows = layout_rows()
    local slot_pos = nil
    for i, h in ipairs(stack) do
        if h.id == self.id then
            slot_pos = rows[i]
            break
        end
    end
    local target_col = slot_pos and slot_pos.col or (ed.width - win_w - config.margin.right)
    local target_row = slot_pos and slot_pos.row or config.margin.top

    if config.animate then
        local effects = animation_effects("enter", { slide = true, reveal = true })
        local use_fade = has_effect(effects, "fade")
        local use_slide = has_effect(effects, "slide")
        local use_reveal = has_effect(effects, "reveal")

        local start_width = win_w
        local start_col = target_col
        if use_reveal then
            local edge = slide_edge_cols(win_w)
            start_width = math.max(2, edge)
            start_col = target_col + (win_w - start_width)
        end
        if use_slide then
            start_col = start_col + slide_distance_cols(win_w)
        end

        pcall(api.nvim_win_set_config, winnr, {
            relative = "editor",
            row = math.floor(target_row),
            col = math.floor(start_col),
            width = start_width,
            height = win_h,
        })
        api.nvim_win_set_option(winnr, "winblend", use_fade and 100 or 0)

        if use_fade or use_slide or use_reveal then
            local enter_keyframe = {
                row = target_row,
                col = target_col,
            }
            if use_reveal then
                enter_keyframe.width = win_w
            end
            if use_fade then
                enter_keyframe.blend = 0
            end
            animate_to(self, { enter_keyframe }, nil, animation_ms("enter_ms", 220))
        else
            win_move(winnr, target_row, target_col)
        end
    else
        win_move(winnr, target_row, target_col)
    end

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

    if self._timeout_timer then
        pcall(function()
            self._timeout_timer:stop()
            self._timeout_timer:close()
        end)
        self._timeout_timer = nil
    end
    if self._vacant_timer then
        pcall(function()
            self._vacant_timer:stop()
            self._vacant_timer:close()
        end)
        self._vacant_timer = nil
    end

    stop_anim(self)

    local function remove_and_collapse()
        local slot_idx = nil
        for i, h in ipairs(stack) do
            if h.id == self.id then
                slot_idx = i
                break
            end
        end
        if not slot_idx then
            return
        end

        table.remove(stack, slot_idx)
        animate_collapse()
    end

    local function do_close_win()
        if self._winnr and api.nvim_win_is_valid(self._winnr) then
            api.nvim_win_close(self._winnr, true)
        end
        if self._bufnr and api.nvim_buf_is_valid(self._bufnr) then
            api.nvim_buf_delete(self._bufnr, { force = true })
        end
        self._winnr = nil
        self._bufnr = nil

        local vacant_timeout = config.vacant_timeout or 3000
        self._vacant_timer = uv.new_timer()
        self._vacant_timer:start(
            vacant_timeout,
            0,
            vim.schedule_wrap(function()
                remove_and_collapse()
            end)
        )
    end

    if config.animate and self._winnr and api.nvim_win_is_valid(self._winnr) then
        local ed = editor_size()
        local winfo = api.nvim_win_get_config(self._winnr)
        local cur_col = winfo and winfo.col or ed.width
        local cur_row = winfo and winfo.row or 0
        local cur_width = winfo and winfo.width or self._win_width or 30
        local effects = animation_effects("exit", { slide = true, reveal = true })
        local use_fade = has_effect(effects, "fade")
        local use_slide = has_effect(effects, "slide")
        local use_reveal = has_effect(effects, "reveal")

        if use_fade or use_slide or use_reveal then
            local target_col = cur_col
            local target_width = cur_width
            if use_reveal then
                local edge = slide_edge_cols(cur_width)
                target_width = math.max(2, edge)
                target_col = target_col + (cur_width - target_width)
            end
            if use_slide then
                target_col = target_col + slide_distance_cols(cur_width)
            end

            local exit_keyframe = {
                row = cur_row,
                col = target_col,
            }
            if use_reveal then
                exit_keyframe.width = target_width
            end
            if use_fade then
                exit_keyframe.blend = 100
            end

            animate_to(self, { exit_keyframe }, vim.schedule_wrap(do_close_win), animation_ms("exit_ms", 180))
        else
            do_close_win()
        end
    else
        do_close_win()
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

    api.nvim_buf_set_option(self._bufnr, "modifiable", true)
    api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    api.nvim_buf_set_option(self._bufnr, "modifiable", false)

    local ns = api.nvim_create_namespace("notify_hl_" .. self.id)
    api.nvim_buf_clear_namespace(self._bufnr, ns, 0, -1)
    for _, h in ipairs(hls) do
        pcall(api.nvim_buf_add_highlight, self._bufnr, ns, h[4], h[1], h[2], h[3])
    end

    local win_h = math.min(#lines, config.max_height + 3)
    if self._animating then
        -- Keep spinner/progress text flowing while animations run. Defer
        -- geometry/reflow updates to animation completion to avoid fighting
        -- window position/size keyframes.
        self._pending_update = {
            msg = msg,
            opts = opts,
        }
        return
    end

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
    local all = vim.deepcopy(stack) -- shallow refs
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
    config = vim.tbl_deep_extend("force", default_config, opts or {})
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
    vim.notify = function(msg, level, nopts)
        return M.notify(msg, level, nopts)
    end
end

-- Allow direct call:  require("notify")("msg", level, opts)
setmetatable(M, {
    __call = function(_, ...)
        return M.notify(...)
    end,
})

return M
