# Bauhaus — Neovim colorscheme

[![Neovim](https://img.shields.io/badge/Neovim-%3E%3D0.9-57A143?logo=neovim)](https://neovim.io) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![CI](https://img.shields.io/github/actions/workflow/status/somerocketeer/bauhaus.nvim/lint.yml?logo=github&label=CI)](https://github.com/somerocketeer/bauhaus.nvim/actions/workflows/lint.yml) [![Code Style: Stylua](https://img.shields.io/badge/Code%20Style-Stylua-2c3e50.svg)](https://github.com/JohnnyMorganz/StyLua) [![Release](https://img.shields.io/github/v/release/somerocketeer/bauhaus.nvim?display_name=tag)](https://github.com/somerocketeer/bauhaus.nvim/releases)

Bauhaus-inspired dark theme: warm coral and sand accents over cool slate/teal surfaces.

Usage (Lazy.nvim)
```lua
return {
  {
    "somerocketeer/bauhaus.nvim",
    name = "bauhaus-nvim",
    priority = 1000,
    config = function()
      require("bauhaus").setup({ transparent = false })
      vim.cmd.colorscheme("bauhaus")
    end,
  },
}
```

Packer.nvim
```lua
use({
"somerocketeer/bauhaus.nvim",
  config = function()
    require("bauhaus").setup({ transparent = false })
    vim.cmd.colorscheme("bauhaus")
  end,
})
```

vim-plug
```vim
Plug 'somerocketeer/bauhaus.nvim'
lua << EOF
require("bauhaus").setup({ transparent = false })
vim.cmd.colorscheme("bauhaus")
EOF
```

Options
- transparent (boolean): if true, main editor backgrounds are set to NONE.
- user_overrides (function): optional callback executed after highlights are applied.

Palette
See lua/bauhaus/palette.lua for the canonical palette values.

Lualine
Add to your lualine config:

```lua
require('lualine').setup({
  options = { theme = 'bauhaus' },
})
```

CI / Lint
- Stylua formatting can be run locally:
  stylua lua/ colors/
- Example GitHub Action is provided in .github/workflows/lint.yml
