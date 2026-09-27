# white.nvim

A monochrome colorscheme for Neovim. No color. Just light and dark.

white uses a 7-tier luminance hierarchy on a pure white `#ffffff` background to create visual structure through darkness alone. Important code is dark. Everything else fades.

## Design

```
T1  #c0c0c0  ░░░░░░░░░░                     gutter, line numbers
T2  #6e6e6e  ░░░░░░░░░░░░░░                 comments (WCAG AA)
T3  #4a4a4a  ░░░░░░░░░░░░░░░░               operators, brackets
T4  #3a3a3a  ░░░░░░░░░░░░░░░░░░             strings, numbers
T5  #2e2e2e  ░░░░░░░░░░░░░░░░░░░░░░         variables, properties
T6  #1a1a1a  ░░░░░░░░░░░░░░░░░░░░░░░░░░     keywords, types
T7  #000000  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░   functions, foreground
```

Bold is reserved for structural elements: functions, keywords, types. Comments are italic. Brackets fade. Your eyes land on what matters.

## Install

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "bjarneo/white.nvim",
  lazy = false,
  priority = 1000,
  config = function()
    require("white").setup()
    vim.cmd.colorscheme("white")
  end,
}
```

## Configuration

```lua
require("white").setup({
  transparent = false,
  styles = {
    comments = { italic = true },
    keywords = { italic = true },
    functions = {},
    variables = {},
    sidebars = "dark",
    floats = "dark",
  },
  dim_inactive = false,

  -- Override palette colors
  on_colors = function(colors) end,

  -- Override specific highlight groups
  on_highlights = function(hl, colors) end,
})
```

## Plugin Support

Works out of the box with LazyVim and these plugins:

blink.cmp, bufferline.nvim, conform.nvim, diffview.nvim, flash.nvim, fidget.nvim, gitsigns.nvim, indent-blankline.nvim, lazy.nvim, mason.nvim, mini.nvim, neo-tree.nvim, noice.nvim, nvim-dap, nvim-lint, nvim-tree.lua, render-markdown.nvim, snacks.nvim, telescope.nvim, todo-comments.nvim, trouble.nvim, which-key.nvim

Plus full treesitter and LSP semantic token support.

## Lualine

The lualine theme loads automatically when you set the colorscheme.

## License

MIT
