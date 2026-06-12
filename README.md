# Amp Neovim Plugin

This plugin allows the [Amp CLI](https://ampcode.com/manual#cli) to see the file you currently have open in your Neovim instance, along with your cursor position and your text selection.

https://github.com/user-attachments/assets/3a5f136f-7b0a-445f-90be-b4e5b28a7e82

When installed, this plugin allows Neovim to:

- Notify Amp about currently open file
- Notify Amp about selected code
- Send messages to the Amp agent (see [Sending Messages to Amp](#sending-messages-to-amp))
- Read and edit files through the Neovim buffers
- Provide Neovim LSP diagnostics to Amp through the companion Amp plugin
- Automatically reconnects when you restart Neovim in the same directory

## Installation

### Using lazy.nvim

Install the plugin by adding this code to your lazy.vim config:

```lua
  -- Amp Plugin
{
  "sourcegraph/amp.nvim",
  branch = "main",
  lazy = false,
  opts = { auto_start = true, log_level = "info" },
}
```

### Using mini.deps

```lua
local MiniDeps = require('mini.deps')
MiniDeps.add({
  source = 'sourcegraph/amp.nvim',
})

require('amp').setup({ auto_start = true, log_level = "info" })
```

### Using Neovim's Native Package System

```bash
# For automatic loading on startup
git clone https://github.com/sourcegraph/amp.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/start/amp.nvim

# Or for optional loading (use :packadd amp.nvim to load)
git clone https://github.com/sourcegraph/amp.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/opt/amp.nvim
```

Then add to your `init.lua`:

```lua
require('amp').setup({ auto_start = true, log_level = "info" })
```

Once installed, run `amp --ide`.

## LSP Diagnostics

This step is optional. The Neovim plugin works without it, but if you want Amp
to read Neovim LSP diagnostics, install the companion Amp plugin included in
this repo:

```bash
mkdir -p ~/.config/amp/plugins
cp plugin/amp-neovim-diagnostics.ts ~/.config/amp/plugins/
```

Then start Neovim with this plugin enabled and run `amp --ide` in the same
workspace. The companion plugin registers a `get_diagnostics` tool in Amp and
pulls diagnostics from the running Neovim instance through amp.nvim's local
WebSocket protocol.

### Healthcheck

> Check the health of the plugin by running `:checkhealth amp` or to run all healthchecks run `:checkhealth`

## Sending Messages to Amp

The plugin provides a simple `send_message` function that you can use to create your own commands and workflows. Here are two example commands you can add to your configuration, one to send a quick message, and one to send the contents of a buffer (useful for drafting longer messages):

### Example Commands

```lua
-- Send a quick message to the agent
vim.api.nvim_create_user_command("AmpSend", function(opts)
  local message = opts.args
  if message == "" then
    print("Please provide a message to send")
    return
  end

  local amp_message = require("amp.message")
  amp_message.send_message(message)
end, {
  nargs = "*",
  desc = "Send a message to Amp",
})

-- Send entire buffer contents
vim.api.nvim_create_user_command("AmpSendBuffer", function(opts)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")

  local amp_message = require("amp.message")
  amp_message.send_message(content)
end, {
  nargs = "?",
  desc = "Send current buffer contents to Amp",
})

-- Add selected text directly to prompt
vim.api.nvim_create_user_command("AmpPromptSelection", function(opts)
  local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
  local text = table.concat(lines, "\n")

  local amp_message = require("amp.message")
  amp_message.send_to_prompt(text)
end, {
  range = true,
  desc = "Add selected text to Amp prompt",
})

-- Add file+selection reference to prompt
vim.api.nvim_create_user_command("AmpPromptRef", function(opts)
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    print("Current buffer has no filename")
    return
  end

  local relative_path = vim.fn.fnamemodify(bufname, ":.")
  local ref = "@" .. relative_path
  if opts.line1 ~= opts.line2 then
    ref = ref .. "#L" .. opts.line1 .. "-" .. opts.line2
  elseif opts.line1 > 1 then
    ref = ref .. "#L" .. opts.line1
  end

  local amp_message = require("amp.message")
  amp_message.send_to_prompt(ref)
end, {
  range = true,
  desc = "Add file reference (with selection) to Amp prompt",
})
```

## Feature Ideas

Do you have a feature request or an idea? Submit an issue in this repo!

## Development

Uses `stylua` for general formatting, and `lua-language-server` for linting.

```bash
stylua .
nvim --headless --clean -c ':!lua-language-server --check .' -c 'qa'
```

## Cross-Platform Support

The plugin uses the same lockfile directory pattern as the main Amp repository:

- **Windows & macOS**: `~/.local/share/amp/ide`
- **Linux**: `$XDG_DATA_HOME/amp/ide` or `~/.local/share/amp/ide`

You can override the data directory by setting the `AMP_DATA_HOME` environment variable for testing or custom setups.

## Logging

The amp.nvim plugin logs to `~/.cache/nvim/amp.log`.

## Contributing

Contributors should follow the [Sourcegraph Community Code of Conduct](https://sourcegraph.notion.site/Sourcegraph-Community-Code-of-Conduct-c7cef6b270c84fb2882808d4d82995dd).
