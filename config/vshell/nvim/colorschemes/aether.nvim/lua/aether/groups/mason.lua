-- Mason plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    MasonHeader                  = { fg = c.black, bg = c.blue, bold = true },
    MasonHeaderSecondary         = { fg = c.black, bg = c.purple, bold = true },
    MasonHighlight               = { fg = c.blue },
    MasonHighlightBlock          = { fg = c.black, bg = c.blue },
    MasonHighlightBlockBold      = { fg = c.black, bg = c.blue, bold = true },
    MasonHighlightSecondary      = { fg = c.bright_purple },
    MasonHighlightBlockSecondary = { fg = c.black, bg = c.purple },
    MasonHighlightBlockBoldSecondary = { fg = c.black, bg = c.purple, bold = true },
    MasonMuted                   = { fg = c.muted },
    MasonMutedBlock              = { fg = c.fg, bg = c.dark_bg },
    MasonMutedBlockBold          = { fg = c.fg, bg = c.dark_bg, bold = true },
    MasonError                   = { fg = c.bright_red },
    MasonWarning                 = { fg = c.warning },
    MasonHeading                 = { fg = c.blue, bold = true },
  }
end

return M
