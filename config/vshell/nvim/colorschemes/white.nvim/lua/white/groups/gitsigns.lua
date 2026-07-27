-- Gitsigns plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  return {
    GitSignsAdd = { fg = c.git.add },
    GitSignsChange = { fg = c.git.change },
    GitSignsDelete = { fg = c.git.delete },
  }
end

return M
