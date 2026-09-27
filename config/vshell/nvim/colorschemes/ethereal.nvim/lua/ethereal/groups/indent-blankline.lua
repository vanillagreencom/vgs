-- Indent blankline plugin support for Ethereal colorscheme
local Util = require("ethereal.utils")

local M = {}

---@type ethereal.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    IblIndent = { fg = c.fg_gutter, nocombine = true },
    IblScope  = { fg = c.blue1, nocombine = true },
  }
end

return M
