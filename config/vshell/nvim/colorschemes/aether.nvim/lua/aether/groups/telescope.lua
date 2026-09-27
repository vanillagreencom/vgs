-- Telescope plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    TelescopeSelection        = { fg = c.fg, bg = c.lighter_bg },
    TelescopeSelectionCaret   = { fg = c.fg, bg = c.lighter_bg },
    TelescopeMultiSelection   = { fg = c.fg, bg = c.lighter_bg },
    TelescopeNormal           = "NormalFloat",
    TelescopeBorder           = "FloatBorder",
    TelescopeMatching         = { fg = c.cyan, bold = true },

    TelescopePromptNormal     = { bg = c.bg_popup },
    TelescopePromptBorder     = { fg = c.border_highlight, bg = c.bg_popup },
    TelescopePromptTitle      = { fg = c.blue, bold = true },
    TelescopePromptPrefix     = { fg = c.fg },

    TelescopePreviewNormal    = "NormalFloat",
    TelescopePreviewBorder    = "FloatBorder",
    TelescopePreviewTitle     = { fg = c.blue, bold = true },
    TelescopePreviewLine      = { bg = c.lighter_bg },
    TelescopePreviewMatch     = { fg = c.cyan, bg = c.lighter_bg },

    TelescopeResultsNormal    = "NormalFloat",
    TelescopeResultsBorder    = "FloatBorder",
    TelescopeResultsTitle     = { fg = c.bright_red, bold = true },

    TelescopeResultsDirectory = { fg = c.blue, bold = true },
  }
end

return M
