# mermaid-live.nvim

Live preview for [Mermaid](https://mermaid.js.org/) diagrams from Neovim — opens in your browser with an infinite pan/zoom canvas and updates as you type.

Works on `.mermaid` and `.mmd` files. The whole buffer is treated as the diagram source.

## Features

- Live preview that re-renders on every edit (default poll: 350ms).
- Infinite canvas via [svg-pan-zoom](https://github.com/bumbu/svg-pan-zoom): scroll to zoom, drag to pan.
- Pan/zoom state preserved across re-renders — no snapback while editing.
- Parse errors surface as an overlay without tearing down the canvas.
- Tiny libuv HTTP server bound to `127.0.0.1` on a random port.
- Auto-stop when leaving the buffer (configurable).

## Requirements

- Neovim 0.10+ (uses `vim.uv`)
- A browser (the plugin opens `http://127.0.0.1:<port>/` via `open` / `xdg-open` / `start`)
- Internet on first open (mermaid + svg-pan-zoom are loaded from jsDelivr by default)

## Installation

### lazy.nvim

```lua
{
  "joaodonghia/mermaid-live.nvim",
  ft = { "mermaid" },
  cmd = { "MermaidView", "MermaidStop", "MermaidOpen" },
  opts = {},
  keys = {
    { "<leader>mv", "<cmd>MermaidView<cr>", desc = "Mermaid live preview" },
  },
}
```

### packer.nvim

```lua
use {
  "joaodonghia/mermaid-live.nvim",
  config = function() require("mermaid-live").setup({}) end,
}
```

## Usage

Open a `.mermaid` or `.mmd` file and run `:MermaidView`. A browser tab opens; edits in the buffer stream through immediately.

| Command         | What it does                                  |
| --------------- | --------------------------------------------- |
| `:MermaidView`        | Start the server and open the browser.        |
| `:MermaidServe`       | Start the server only — do not open the browser. |
| `:MermaidStop`        | Tear down the server, autocmds, and state.    |
| `:MermaidOpen`        | Reopen the browser at the running preview URL. |
| `:MermaidTheme {name}`| Set theme: `auto`, `default`, `dark`, `forest`, `neutral`, `base`. |
| `:MermaidThemeToggle` | Cycle: `auto` → `dark` → `default` → `auto`. |
| `:MermaidCleanup`     | Scan localhost for stray mermaid-live servers and shut them down. |

### Browser controls

| Key / gesture  | Effect                              |
| -------------- | ----------------------------------- |
| scroll         | zoom                                |
| drag           | pan                                 |
| `r`            | reset zoom                          |
| `f`            | fit to viewport                     |
| `t` / ◐ button | cycle theme: auto → dark → default (syncs nvim)|

A small dot in the top-right turns red when the browser can't reach the server (e.g. you stopped the preview).

## Configuration

Defaults shown below — call `setup` with anything you want to override.

```lua
require("mermaid-live").setup({
  filetypes = { "mermaid" },         -- buffers eligible for :MermaidView
  poll_interval_ms = 350,            -- browser polling cadence
  theme = "auto",                    -- auto | dark | default | forest | neutral | base
                                     -- "auto" follows the system color scheme (prefers-color-scheme)
  port = 8765,                       -- fixed by default so the browser tab can be reused
                                     -- set to 0 for a random free port
                                     -- on startup, any other mermaid-live server on this
                                     -- port is asked to shut down (via /__shutdown)
  open_browser = true,               -- open browser on :MermaidView
  open_cmd = nil,                    -- override how the browser is launched (see below)
  auto_stop_on_leave = true,         -- stop server on BufLeave
  mermaid_cdn = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js",
  svg_pan_zoom_cdn = "https://cdn.jsdelivr.net/npm/svg-pan-zoom@3.6.1/dist/svg-pan-zoom.min.js",
})
```

### Forcing a new browser window

There is no portable "open default browser in a new window" on macOS — it depends on the browser. The default uses `open <url>` (which reuses the existing browser window/tab). For an actual new window, pass `open_cmd`:

```lua
-- Chrome / Chromium / Brave / Edge / Vivaldi (Chromium-based, honor --new-window):
open_cmd = { "open", "-na", "Google Chrome", "--args", "--new-window" }

-- Firefox:
open_cmd = { "open", "-na", "Firefox", "--args", "-new-window" }

-- Arc ignores --new-window; use AppleScript instead:
open_cmd = function(url)
  vim.fn.jobstart({
    "osascript", "-e",
    string.format([[
      tell application "Arc"
        activate
        make new window
        open location "%s"
      end tell
    ]], url),
  }, { detach = true })
end
```

As a list, the URL is appended automatically as the last argument. As a function, you handle the launch yourself.

## Filetype detection

The plugin registers `.mermaid` and `.mmd` to the `mermaid` filetype via `vim.filetype.add`. If you use lazy-loading by `ft`, make sure your plugin manager loads `mermaid-live.nvim` early enough (or register the filetype yourself in `init`).

## Treesitter

The plugin ships an `after/queries/mermaid/indents.scm` override so Mermaid mindmap blocks inherit indentation via vim's autoindent. The official tree-sitter-mermaid grammar handles flowchart indents but not mindmap.

To get the parser:

```vim
:TSInstall mermaid
```

## License

MIT
