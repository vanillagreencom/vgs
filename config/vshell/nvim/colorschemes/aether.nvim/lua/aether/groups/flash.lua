-- Flash plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    FlashBackdrop = { fg = c.muted },
    FlashCurrent  = { fg = c.black, bg = c.orange, bold = true },
    FlashLabel    = { fg = c.black, bg = c.purple, bold = true },
    FlashMatch    = { fg = c.cyan, bg = c.lighter_bg, bold = true },
    FlashPrompt   = { link = "NormalFloat" },
  }
end

return M
