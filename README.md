# flyout.nvim

Flyout is a task runner for Neovim focused on fast iteration loops:

- run shell commands asynchronously
- define reusable task templates and pipelines
- monitor status and logs in a focused UI
- parse command output into quickfix
- integrate with `nvim-dap` via `preLaunchTask`

## When to Choose Flyout

Choose Flyout if you want:

- a focused task runner with minimal setup friction
- project-local, versioned task definitions in `.flyout/templates.lua`
- first-class pipeline controls directly in the task list UI
- built-in parser-to-quickfix workflow for fast error navigation
- `nvim-dap` `preLaunchTask` support without extra task adapters
- a workflow optimized for solo or small-team repos

If your priority is broad ecosystem integrations and highly extensible task orchestration, `overseer.nvim` may be a better fit.

## Highlights

- Single tasks and multi-step pipelines
- Per-project templates file: `.flyout/templates.lua`
- Template editor and picker UI (`:FlyoutTemplates`, `:FlyoutPick`)
- Smart task lifecycle: stop, rerun, clear, singleton reuse
- Pipeline-aware actions in UI (`s`, `r`, `dd`, `za`)
- Built-in quickfix parser flow (`x`, `X`, `:FlyoutQuickfix`)
- Optional notifier backends (`vim`, `fy`, `snacks`, `nvim-notify`, `mini.notify`, `auto`)
- `nvim-dap` integration (`preLaunchTask`, including sequential task lists)

## Installation

### lazy.nvim

```lua
{
    "tjgao/flyout.nvim",
    dependencies = {
        -- optional if you want notify_backend = "fy"
        "tjgao/fy.nvim",
    },
    config = function()
        require("flyout").setup()
    end,
}
```

## Commands

- `:Flyout {cmd}` - start an ad-hoc task
- `:FlyoutStop {id}` - stop a running task
- `:FlyoutRerun {id}` - rerun task in-place
- `:FlyoutTasks` - open task list
- `:FlyoutTemplates` - open templates mode directly
- `:FlyoutTemplate {name}` - run template by name
- `:FlyoutPick` - pick and run template/pipeline with `vim.ui.select`
- `:FlyoutLog {id}` - open floating log for task
- `:FlyoutQuickfix {parser} {cmd}` - run command and parse output to quickfix
- `:FlyoutStopPrelaunch` - emergency stop for active DAP prelaunch runs

## Task List Keys

- `Enter` open log float (or run selected template in templates mode)
- `S` / `V` / `T` open log in split / vsplit / tab
- `s` stop selected task (pipeline row stops the whole pipeline run)
- `r` rerun selected task (pipeline row reruns whole pipeline)
- `dd` delete selected task (pipeline row deletes whole pipeline run)
- `x` parse task output into quickfix (pick parser if unset)
- `X` change quickfix parser for selected task
- `za` expand/collapse pipeline rows
- `a` create a template from selected task
- `A` add template
- `C` copy template
- `E` edit template
- `gt` toggle tasks/templates mode
- `c` clear finished tasks
- `R` refresh list
- `?` open in-app help
- `q` / `Esc` close task list

## Templates and Pipelines

Flyout stores templates in `.flyout/templates.lua` (project-local).

Example:

```lua
return {
    templates = {
        {
            type = "task",
            name = "build",
            cmd = "make",
            parser = "gcc",
            singleton = true,
            hidden = false,
            confirm = false,
            timeout_ms = 0,
            ready_when = "Build complete",
            notify = {
                start = true,
                ["end"] = true,
                progress = { enabled = false },
            },
        },
        {
            type = "task",
            name = "test",
            cmd = "make test",
            parser = "gcc",
            singleton = true,
        },
        {
            type = "pipeline",
            name = "build+test",
            steps = { "build", "test" },
            singleton = true,
            hidden = false,
            confirm = "Run build+test pipeline?",
        },
    },
}
```

Template rules:

- `type` is `"task"` or `"pipeline"`
- task templates require `cmd`
- pipeline templates require non-empty `steps` list
- pipeline steps must reference existing task templates
- `notification` is not valid; use `notify`

## DAP preLaunchTask Integration

Enable once during DAP setup:

```lua
require("flyout").setup()
require("flyout").enable_dap()
```

Then use `preLaunchTask` in DAP launch configs:

```lua
{
    type = "cppdbg",
    request = "launch",
    name = "Debug app",
    program = "${workspaceFolder}/bin/app",
    cwd = "${workspaceFolder}",
    preLaunchTask = { "build", "test" },
}
```

Behavior:

- accepts `preLaunchTask = "name"` or list of names
- runs entries sequentially before debugger starts
- supports both task and pipeline templates
- aborts debug launch if prelaunch task fails/times out
- auto-cleans active prelaunch runs on DAP terminate/exit/disconnect
- manual fallback: `:FlyoutStopPrelaunch`

## Flyout vs overseer.nvim

`overseer.nvim` is a great, mature task system with broad extensibility.
Flyout is currently optimized for a narrower workflow: quick task loops + DAP prelaunch + clean project-local templates.

Why people may prefer Flyout:

- Simpler mental model: task templates and pipelines are just `.flyout/templates.lua`
- Pipeline-first task list UX (`za`, pipeline-aware `s`/`r`/`dd`)
- Fast template flow from UI (`A`, `a`, `C`, `E`, `:FlyoutPick`)
- Tight `nvim-dap` preLaunchTask bridge with sequential lists and cleanup hooks
- Lightweight setup and straightforward defaults for solo projects

If you need deep integration points and a larger plugin ecosystem, Overseer may be a better fit.
If you want a focused runner/debug prelaunch workflow with minimal ceremony, Flyout is usually the better fit.

## Configuration

```lua
require("flyout").setup({
    task = {
        stop_timeout_ms = 3000,
        cleanup_output_on_stop = false,
        timeout_ms = 0,
        ready_timeout_ms = 0,
    },
    ui = {
        preview_enabled = true,
        task_list_width = "50%",   -- number or percent string
        task_list_height = "25%",  -- number or percent string
        preview_height = "40%",    -- number or percent string
        log_terminal_scrollback = 200000,
    },
    quickfix = {
        generate_commands = true,
        command_prefix = "F",
        command_completion = "auto", -- auto | shellcmd | file | none
        parsers = {
            -- mylang = { efm = "%f:%l:%c: %m" },
        },
    },
    notify = {
        notify_backend = "auto", -- auto | vim | fy | flyout | snacks | nvim-notify | mini.notify
        override_vim_notify = false,
        start = true,
        ["end"] = true,
        progress = {
            enabled = false,
            interval_ms = 120,
            -- frames = { ... },
        },
    },
})
```

Built-in quickfix parser names:

- `gcc`, `msvc`, `rust`, `go`, `py`, `pyt`, `tsc`, `js`, `java`, `lua`

## API (Common)

- `require("flyout").start(cmd, opts)`
- `require("flyout").stop(task_id)`
- `require("flyout").rerun(task_id)`
- `require("flyout").run_template(name)`
- `require("flyout").pick_template()`
- `require("flyout").enable_dap()`
- `require("flyout").stop_active_prelaunch_tasks({ notify = true|false })`

## Notes

- Commands run as background, non-interactive processes.
- On `VimLeavePre`, Flyout requests task stop and then force-kills after a short grace period.
