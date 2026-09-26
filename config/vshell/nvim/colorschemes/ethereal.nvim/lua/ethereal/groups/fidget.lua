-- Fidget plugin support for Ethereal colorscheme
local Util = require("ethereal.utils")

local M = {}

---@type ethereal.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    FidgetTask = { fg = c.comment },
    FidgetTitle = { fg = c.blue, bold = true },
  }
end

return M
