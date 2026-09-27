-- Gitsigns plugin support for Ethereal colorscheme
local Util = require("ethereal.utils")

local M = {}

---@type ethereal.HighlightsFn
function M.get(c, opts)
  return {
    GitSignsAdd = { fg = c.git.add },
    GitSignsChange = { fg = c.git.change },
    GitSignsDelete = { fg = c.git.delete },
  }
end

return M
