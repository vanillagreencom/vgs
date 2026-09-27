-- Indent blankline plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    IblIndent = { fg = c.muted, nocombine = true },
    IblScope  = { fg = c.blue, nocombine = true },
  }
end

return M
