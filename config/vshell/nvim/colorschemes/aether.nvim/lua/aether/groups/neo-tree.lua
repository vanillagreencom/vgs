-- Neo-tree plugin support for Aether colorscheme
local Util = require("aether.utils")

local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  local dark = opts.styles.sidebars == "transparent" and c.none
    or Util.blend(c.bg_sidebar, 0.8, c.bg)
  -- stylua: ignore
  return {
    NeoTreeDimText             = { fg = c.muted },
    NeoTreeFileName            = { fg = c.fg_sidebar },
    NeoTreeGitModified         = { fg = c.git.change },
    NeoTreeGitStaged           = { fg = c.git.add },
    NeoTreeGitUntracked        = { fg = c.orange },
    NeoTreeGitUnstaged         = { fg = c.git.change },
    NeoTreeGitConflict         = { fg = c.bright_red },
    NeoTreeGitIgnored          = { fg = c.muted },
    NeoTreeGitAdded            = { fg = c.git.add },
    NeoTreeGitDeleted          = { fg = c.bright_red },
    NeoTreeGitRenamed          = { fg = c.orange },
    NeoTreeNormal              = { fg = c.fg_sidebar, bg = c.bg_sidebar },
    NeoTreeNormalNC            = { fg = c.fg_sidebar, bg = c.bg_sidebar },
    NeoTreeTabActive           = { fg = c.blue, bg = c.dark_bg, bold = true },
    NeoTreeTabInactive         = { fg = c.muted, bg = dark },
    NeoTreeTabSeparatorActive  = { fg = c.blue, bg = c.dark_bg },
    NeoTreeTabSeparatorInactive= { fg = c.bg, bg = dark },
    NeoTreeDirectoryIcon       = { fg = c.blue },
    NeoTreeDirectoryName       = { fg = c.blue },
    NeoTreeSymbolicLinkTarget  = { fg = c.cyan },
    NeoTreeRootName            = { fg = c.blue, bold = true },
    NeoTreeFileNameOpened      = { fg = c.fg_sidebar },
  }
end

return M
