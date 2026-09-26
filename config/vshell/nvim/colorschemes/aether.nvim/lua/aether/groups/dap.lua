-- Dap plugin support for Aether colorscheme
local Util = require("aether.utils")

local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    DapBreakpoint          = { fg = c.bright_red },
    DapBreakpointCondition = { fg = c.yellow },
    DapBreakpointRejected  = { fg = c.muted },
    DapLogPoint            = { fg = c.blue },
    DapStopped             = { fg = c.green },
    DapStoppedLine         = { bg = Util.blend_bg(c.yellow, 0.2) },
    DapUIBreakpointsCurrentLine = { fg = c.green, bold = true },
    DapUIBreakpointsDisabledLine = { fg = c.muted },
    DapUIBreakpointsInfo   = { fg = c.green },
    DapUIBreakpointsPath   = { fg = c.cyan },
    DapUIDecoration        = { fg = c.blue },
    DapUIFloatBorder       = { fg = c.border_highlight },
    DapUILineNumber        = { fg = c.cyan },
    DapUIModifiedValue     = { fg = c.cyan, bold = true },
    DapUIPlayPause         = { fg = c.green },
    DapUIRestart           = { fg = c.green },
    DapUIScope             = { fg = c.cyan },
    DapUISource            = { fg = c.bright_purple },
    DapUIStepBack          = { fg = c.cyan },
    DapUIStepInto          = { fg = c.cyan },
    DapUIStepOut           = { fg = c.cyan },
    DapUIStepOver          = { fg = c.cyan },
    DapUIStop              = { fg = c.bright_red },
    DapUIStoppedThread     = { fg = c.cyan },
    DapUIThread            = { fg = c.green },
    DapUIType              = { fg = c.bright_purple },
    DapUIValue             = { fg = c.fg },
    DapUIVariable          = { fg = c.fg },
    DapUIWatchesEmpty      = { fg = c.bright_red },
    DapUIWatchesError      = { fg = c.bright_red },
    DapUIWatchesValue      = { fg = c.green },
  }
end

return M
