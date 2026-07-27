-- Conform plugin support for Ethereal colorscheme
local Util = require("ethereal.utils")

local M = {}

---@type ethereal.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    ConformProgress = { fg = c.blue },
    ConformDone     = { fg = c.green },
    ConformError    = { fg = c.error },
  }
end

return M
