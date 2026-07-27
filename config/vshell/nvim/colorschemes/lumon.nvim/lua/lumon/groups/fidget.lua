-- Fidget plugin support for Lumon colorscheme
local Util = require("lumon.utils")

local M = {}

---@type lumon.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    FidgetTask = { fg = c.comment },
    FidgetTitle = { fg = c.blue, bold = true },
  }
end

return M
