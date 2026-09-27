-- Comment plugin support for Lumon colorscheme
local Util = require("lumon.utils")

local M = {}

---@type lumon.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    CommentNormal = { fg = c.comment, style = opts.styles.comments },
    CommentBold   = { fg = c.comment, bold = true },
    CommentItalic = { fg = c.comment, italic = true },
    CommentURL    = { fg = c.blue, underline = true },
  }
end

return M
