-- Flash plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    FlashBackdrop = { fg = c.comment },
    FlashCurrent  = { fg = c.black, bg = c.orange, bold = true },
    FlashLabel    = { fg = c.black, bg = c.magenta, bold = true },
    FlashMatch    = { fg = c.cyan, bg = c.bg_highlight, bold = true },
    FlashPrompt   = { link = "NormalFloat" },
  }
end

return M
