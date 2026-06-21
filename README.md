# flyout.nvim

A lightweight background task launcher/manager for Neovim.

## Features

- Run shell commands asynchronously via `:Flyout ...`
- Track task status in a task-list UI (`:FlyoutTasks`)
- Stop and rerun tasks
- Live output viewer (float/split/vsplit/tab)
- Shared output polling for multiple viewers of the same task

## Commands

- `:Flyout {cmd}` - start a task
- `:FlyoutStop {id}` - stop a task
- `:FlyoutRerun {id}` - rerun a task (same task entry/log file)
- `:FlyoutTasks` - open task list window
- `:FlyoutLog {id}` - open floating log window for a task

## Task List Keys

- `<Enter>` open floating log for selected task
- `S` open log in split
- `V` open log in vsplit
- `T` open log in tab
- `s` stop selected task
- `r` rerun selected task
- `c` clear finished tasks
- `R` refresh list
- `q` close task list

## Setup

```lua
require("flyout").setup({
    task = {
        stop_timeout_ms = 3000,
        cleanup_output_on_stop = false,
    },
    ui = {
        -- enable/disable preview window in :FlyoutTasks
        preview_enabled = true,

        -- "side_by_side" (default) or "top_bottom"
        preview_layout = "side_by_side",

        -- task list width in columns or percent string
        -- examples: 56, "35%"
        task_list_width = nil,

        -- preview width in columns or percent string
        -- only used by side_by_side layout
        -- examples: 50, "40%"
        preview_width = 44,
    },
})
```

### Width Rules

- `task_list_width` and `preview_width` accept either:
  - integer columns (for example `56`)
  - percent string (for example `"35%"`)
- task-list width is clamped to a minimum required width for fields
- in `top_bottom` layout, preview width follows task-list width

## Notes

- Flyout runs commands as non-interactive background tasks.
- TTY-interactive programs are not supported in Flyout mode.
- On `VimLeavePre`, Flyout sends `SIGTERM` to active tasks, then `SIGKILL` after a short grace period.
