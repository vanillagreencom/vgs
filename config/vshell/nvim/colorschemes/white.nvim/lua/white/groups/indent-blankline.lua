-- Indent blankline plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    IblIndent = { fg = c.fg_gutter, nocombine = true },
    IblScope  = { fg = c.blue1, nocombine = true },
  }
end

return M
