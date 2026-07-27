# Nagai Twilight — Neovim colorscheme

Nagai Twilight leans into dusky purples and neon sunsets drawn from the Omarchy palette. Ships as a standalone Neovim colorscheme with optional statusline integrations.

[![Neovim](https://img.shields.io/badge/Neovim-%3E%3D0.9-57A143?logo=neovim)](https://neovim.io)

## Usage

### Lazy.nvim
```lua
return {
  {
    "somerocketeer/nagai-twilight.nvim",
    priority = 1000,
    config = function()
      require("nagai_twilight").setup({ transparent = false })
      vim.cmd.colorscheme("nagai-twilight")
    end,
  },
}
```

### packer.nvim
```lua
use({
  "somerocketeer/nagai-twilight.nvim",
  config = function()
    require("nagai_twilight").setup({ transparent = false })
    vim.cmd.colorscheme("nagai-twilight")
  end,
})
```

### vim-plug
```vim
Plug 'somerocketeer/nagai-twilight.nvim'
lua <<'LUA'
require("nagai_twilight").setup({ transparent = false })
vim.cmd.colorscheme("nagai-twilight")
LUA
```

## Options
- `transparent` (boolean): if `true`, leaves editor backgrounds untouched.
- `user_overrides` (function): optional callback run after highlights apply.

## Extras
- Lualine theme: `require('lualine').setup({ options = { theme = 'nagai-twilight' } })`
- Mini.statusline mode colors and built-in highlight groups for common Lazy.nvim plugins.

## Palette
See [`lua/nagai_twilight/palette.lua`](lua/nagai_twilight/palette.lua) for canonical color definitions.

## License
Released under the MIT license. See [LICENSE](LICENSE).
