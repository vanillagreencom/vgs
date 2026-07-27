-- Snacks plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    SnacksNormal           = { bg = c.bg_float, fg = c.fg },
    SnacksWinBar           = { bg = c.bg_float, fg = c.fg },
    SnacksBackdrop         = { bg = c.dark_bg },
    SnacksNormalNC         = { bg = c.bg_float, fg = c.fg },
    SnacksWinBarNC         = { bg = c.bg_float, fg = c.dark_fg },
    SnacksNotifierInfo     = { fg = c.info },
    SnacksNotifierWarn     = { fg = c.warning },
    SnacksNotifierError    = { fg = c.bright_red },
    SnacksNotifierDebug    = { fg = c.muted },
    SnacksNotifierTrace    = { fg = c.bright_purple },
    SnacksNotifierIconInfo = { fg = c.info },
    SnacksNotifierIconWarn = { fg = c.warning },
    SnacksNotifierIconError = { fg = c.bright_red },
    SnacksNotifierIconDebug = { fg = c.muted },
    SnacksNotifierIconTrace = { fg = c.bright_purple },
    SnacksNotifierTitleInfo = { fg = c.info, bold = true },
    SnacksNotifierTitleWarn = { fg = c.warning, bold = true },
    SnacksNotifierTitleError = { fg = c.bright_red, bold = true },
    SnacksNotifierTitleDebug = { fg = c.muted, bold = true },
    SnacksNotifierTitleTrace = { fg = c.bright_purple, bold = true },
    SnacksNotifierBorderInfo = { fg = c.info },
    SnacksNotifierBorderWarn = { fg = c.warning },
    SnacksNotifierBorderError = { fg = c.bright_red },
    SnacksNotifierBorderDebug = { fg = c.muted },
    SnacksNotifierBorderTrace = { fg = c.bright_purple },
  }
end

return M
