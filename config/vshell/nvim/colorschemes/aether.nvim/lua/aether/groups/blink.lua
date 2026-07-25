-- Blink plugin support for Aether colorscheme
local Util = require("aether.utils")

local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    BlinkCmpMenu              = { bg = c.bg_popup, fg = c.fg },
    BlinkCmpMenuBorder        = { bg = c.bg_popup, fg = c.border_highlight },
    BlinkCmpMenuSelection     = { bg = Util.blend_bg(c.muted, 0.8) },
    BlinkCmpLabel             = { fg = c.fg },
    BlinkCmpLabelDeprecated   = { fg = c.muted, strikethrough = true },
    BlinkCmpLabelMatch        = { fg = c.blue, bold = true },
    BlinkCmpLabelDescription  = { fg = c.dark_fg },
    BlinkCmpLabelDetail       = { fg = c.muted },
    BlinkCmpKind              = { fg = c.bright_purple },
    BlinkCmpKindClass         = { fg = c.yellow },
    BlinkCmpKindColor         = { fg = c.cyan },
    BlinkCmpKindConstant      = { fg = c.orange },
    BlinkCmpKindConstructor   = { fg = c.blue },
    BlinkCmpKindEnum          = { fg = c.yellow },
    BlinkCmpKindEnumMember    = { fg = c.cyan },
    BlinkCmpKindEvent         = { fg = c.bright_purple },
    BlinkCmpKindField         = { fg = c.cyan },
    BlinkCmpKindFile          = { fg = c.fg },
    BlinkCmpKindFolder        = { fg = c.blue },
    BlinkCmpKindFunction      = { fg = c.bright_red },
    BlinkCmpKindInterface     = { fg = c.yellow },
    BlinkCmpKindKeyword       = { fg = c.bright_purple },
    BlinkCmpKindMethod        = { fg = c.bright_red },
    BlinkCmpKindModule        = { fg = c.blue },
    BlinkCmpKindOperator      = { fg = c.cyan },
    BlinkCmpKindProperty      = { fg = c.cyan },
    BlinkCmpKindReference     = { fg = c.orange },
    BlinkCmpKindSnippet       = { fg = c.green },
    BlinkCmpKindStruct        = { fg = c.yellow },
    BlinkCmpKindText          = { fg = c.fg },
    BlinkCmpKindTypeParameter = { fg = c.yellow },
    BlinkCmpKindUnit          = { fg = c.orange },
    BlinkCmpKindValue         = { fg = c.orange },
    BlinkCmpKindVariable      = { fg = c.fg },
    BlinkCmpDoc               = { bg = c.bg_float, fg = c.fg },
    BlinkCmpDocBorder         = { bg = c.bg_float, fg = c.border_highlight },
    BlinkCmpSignatureHelp     = { bg = c.bg_float, fg = c.fg },
    BlinkCmpSignatureHelpBorder = { bg = c.bg_float, fg = c.border_highlight },
    BlinkCmpSignatureHelpActiveParameter = { fg = c.blue, bold = true },
  }
end

return M
