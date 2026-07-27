-- Gitsigns plugin support for Lumon colorscheme
local Util = require("lumon.utils")

local M = {}

---@type lumon.HighlightsFn
function M.get(c, opts)
  return {
    GitSignsAdd = { fg = c.git.add },
    GitSignsChange = { fg = c.git.change },
    GitSignsDelete = { fg = c.git.delete },
  }
end

return M
