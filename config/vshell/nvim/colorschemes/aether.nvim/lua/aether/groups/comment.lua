-- Comment plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    CommentNormal = { fg = c.muted, style = opts.styles.comments },
    CommentBold   = { fg = c.muted, bold = true },
    CommentItalic = { fg = c.muted, italic = true },
    CommentURL    = { fg = c.blue, underline = true },
  }
end

return M
