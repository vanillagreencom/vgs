-- Fidget plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    FidgetTask = { fg = c.comment },
    FidgetTitle = { fg = c.blue, bold = true },
  }
end

return M
