-- Diffview plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    DiffviewPrimary            = { fg = c.blue, bold = true },
    DiffviewSecondary          = { fg = c.bright_purple },
    DiffviewFilePanelTitle     = { fg = c.blue, bold = true },
    DiffviewFilePanelCounter   = { fg = c.bright_purple },
    DiffviewFilePanelFileName  = { fg = c.fg },
    DiffviewFilePanelPath      = { fg = c.muted },
    DiffviewFilePanelInsertions = { fg = c.green },
    DiffviewFilePanelDeletions = { fg = c.bright_red },
    DiffviewStatusAdded        = { fg = c.green },
    DiffviewStatusUntracked    = { fg = c.blue },
    DiffviewStatusModified     = { fg = c.blue },
    DiffviewStatusRenamed      = { fg = c.blue },
    DiffviewStatusCopied       = { fg = c.blue },
    DiffviewStatusTypeChange   = { fg = c.blue },
    DiffviewStatusUnmerged     = { fg = c.yellow },
    DiffviewStatusUnknown      = { fg = c.bright_red },
    DiffviewStatusDeleted      = { fg = c.bright_red },
    DiffviewStatusBroken       = { fg = c.bright_red },
  }
end

return M
