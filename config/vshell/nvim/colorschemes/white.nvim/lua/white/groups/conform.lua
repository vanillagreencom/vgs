-- Conform plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    ConformProgress = { fg = c.blue },
    ConformDone     = { fg = c.green },
    ConformError    = { fg = c.error },
  }
end

return M
