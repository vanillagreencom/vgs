-- Trouble plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    TroubleText        = { fg = c.dark_fg },
    TroubleCount       = { fg = c.bright_purple, bg = c.muted },
    TroubleNormal      = { fg = c.fg, bg = c.bg_sidebar },
    TroubleTextInformation = { fg = c.info },
    TroubleSignWarning = { fg = c.warning },
    TroubleSignInformation = { fg = c.info },
    TroubleSignHint    = { fg = c.hint },
    TroubleSignError   = { fg = c.bright_red },
    TroubleSignOther   = { fg = c.bright_purple },
    TroubleIndent      = { fg = c.muted },
    TroubleLocation    = { fg = c.muted },
    TroubleFoldIcon    = { fg = c.muted },
    TroubleFile        = { fg = c.blue },
    TroubleCode        = { fg = c.muted },
  }
end

return M
