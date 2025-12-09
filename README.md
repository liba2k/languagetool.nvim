# languagetool.nvim

A Neovim plugin for grammar and spell checking using [LanguageTool](https://languagetool.org/).

## Requirements

- Neovim 0.9+
- A running LanguageTool server (local or remote)
- `curl`

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "liba2k/languagetool.nvim",
  opts = {
    server_url = "http://localhost:8081",
    language = "en-US",
  },
  keys = {
    { "<leader>lc", "<cmd>LTCheck<cr>", desc = "Check line" },
    { "<leader>lc", ":LTCheck<cr>", mode = "v", desc = "Check selection" },
    { "<leader>lb", "<cmd>LTCheckBuffer<cr>", desc = "Check buffer" },
    { "<leader>lf", "<cmd>LTFix<cr>", desc = "Show fixes" },
    { "<leader>lx", "<cmd>LTClear<cr>", desc = "Clear diagnostics" },
  },
}
```

## Configuration

```lua
require("languagetool").setup({
  -- LanguageTool server URL
  server_url = "http://localhost:8081",
  
  -- Language code (e.g., "en-US", "de-DE", "fr")
  language = "en-US",
  
  -- Severity mapping for different issue types
  severity = {
    typographical = vim.diagnostic.severity.HINT,
    grammar = vim.diagnostic.severity.WARN,
    misspelling = vim.diagnostic.severity.ERROR,
    style = vim.diagnostic.severity.INFO,
    default = vim.diagnostic.severity.WARN,
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:LTCheck` | Check current line |
| `:'<,'>LTCheck` | Check visual selection |
| `:LTCheckBuffer` | Check entire buffer |
| `:LTFix` | Show available fixes at cursor |
| `:LTClear` | Clear all LanguageTool diagnostics |

## Features

- Async checking (non-blocking)
- Integrates with Neovim's built-in diagnostics (`vim.diagnostic`)
- Fix picker uses `vim.ui.select` (works with Telescope, fzf-lua, snacks.nvim, etc.)
- Configurable severity levels per issue type

## Running LanguageTool Server

You can run LanguageTool locally using Docker:

```bash
docker run --rm -p 8081:8010 erikvl87/languagetool
```

Or download and run the [standalone server](https://dev.languagetool.org/http-server).

## License

MIT
