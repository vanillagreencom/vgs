-- Flash plugin support for Lumon colorscheme
local Util = require("lumon.utils")

local M = {}

---@type lumon.HighlightsFn
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
