-- Indent blankline plugin support for Lumon colorscheme
local Util = require("lumon.utils")

local M = {}

---@type lumon.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    IblIndent = { fg = c.fg_gutter, nocombine = true },
    IblScope  = { fg = c.blue1, nocombine = true },
  }
end

return M
