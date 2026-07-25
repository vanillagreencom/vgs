-- Git plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    gitcommitOverflow         = { fg = c.bright_red },
    gitcommitSummary          = { fg = c.green },
    gitcommitComment          = { fg = c.muted, style = opts.styles.comments },
    gitcommitUntracked        = { fg = c.muted },
    gitcommitDiscarded        = { fg = c.muted },
    gitcommitSelected         = { fg = c.muted },
    gitcommitHeader           = { fg = c.bright_purple },
    gitcommitSelectedType     = { fg = c.blue },
    gitcommitUnmergedType     = { fg = c.blue },
    gitcommitDiscardedType    = { fg = c.blue },
    gitcommitBranch           = { fg = c.orange, bold = true },
    gitcommitUntrackedFile    = { fg = c.yellow },
    gitcommitUnmergedFile     = { fg = c.bright_red, bold = true },
    gitcommitDiscardedFile    = { fg = c.bright_red, bold = true },
    gitcommitSelectedFile     = { fg = c.green, bold = true },
  }
end

return M
