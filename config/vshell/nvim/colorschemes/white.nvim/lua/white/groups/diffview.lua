-- Diffview plugin support for white colorscheme
local Util = require("white.utils")

local M = {}

---@type white.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    DiffviewPrimary            = { fg = c.blue, bold = true },
    DiffviewSecondary          = { fg = c.purple },
    DiffviewFilePanelTitle     = { fg = c.blue, bold = true },
    DiffviewFilePanelCounter   = { fg = c.purple },
    DiffviewFilePanelFileName  = { fg = c.fg },
    DiffviewFilePanelPath      = { fg = c.comment },
    DiffviewFilePanelInsertions = { fg = c.green },
    DiffviewFilePanelDeletions = { fg = c.red },
    DiffviewStatusAdded        = { fg = c.green },
    DiffviewStatusUntracked    = { fg = c.blue },
    DiffviewStatusModified     = { fg = c.blue },
    DiffviewStatusRenamed      = { fg = c.blue },
    DiffviewStatusCopied       = { fg = c.blue },
    DiffviewStatusTypeChange   = { fg = c.blue },
    DiffviewStatusUnmerged     = { fg = c.yellow },
    DiffviewStatusUnknown      = { fg = c.red },
    DiffviewStatusDeleted      = { fg = c.red },
    DiffviewStatusBroken       = { fg = c.red },
  }
end

return M
