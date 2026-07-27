-- Lint plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    LintError   = { fg = c.error },
    LintWarning = { fg = c.warning },
    LintInfo    = { fg = c.info },
    LintHint    = { fg = c.hint },
  }
end

return M
