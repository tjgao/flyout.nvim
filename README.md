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
- `:FlyoutQuickfix {parser} {cmd}` - run command as Flyout task, parse output with parser, then auto-open quickfix on first parsed entry

## Task List Keys

- `<Enter>` open floating log for selected task
- `S` open log in split
- `V` open log in vsplit
- `T` open log in tab
- `s` stop selected task
- `r` rerun selected task
- `x` parse selected task log into quickfix
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

        -- task list width in columns or percent string
        -- examples: 56, "35%"
        -- default is "50%"
        task_list_width = "50%",
    },
    quickfix = {
        -- auto-generate parser commands like :Fgcc, :Fmsvc, :Frust
        generate_commands = true,

        -- prefix for generated commands (for example "F" => :Fgcc)
        command_prefix = "F",

        -- optional: add or override parser definitions
        parsers = {
            -- custom parser
            -- mylang = { efm = "%E%f:%l:%c: %m" },

            -- override built-in parser
            -- gcc = { efm = "%f:%l:%c: %m" },
        },
    },
})
```

### Quickfix Parsers

- Built-in parser names: `gcc`, `msvc`, `rust`, `go`, `py`, `pyt`, `tsc`, `js`, `java`, `lua`
- Generated commands use parser names with your prefix:
  `:Fgcc`, `:Fmsvc`, `:Frust`, `:Fgo`, `:Fpy`, `:Fpyt`, `:Ftsc`, `:Fjs`, `:Fjava`, `:Flua`
- You can extend or override parser definitions with `quickfix.parsers`

### Width Rules

- `task_list_width` accepts either:
  - integer columns (for example `56`)
  - percent string (for example `"35%"`)
- task-list width is clamped to a minimum required width for fields
- task list and preview are always shown in a top-bottom layout
- preview width follows task-list width

## Notes

- Flyout runs commands as non-interactive background tasks.
- TTY-interactive programs are not supported in Flyout mode.
- On `VimLeavePre`, Flyout sends `SIGTERM` to active tasks, then `SIGKILL` after a short grace period.
