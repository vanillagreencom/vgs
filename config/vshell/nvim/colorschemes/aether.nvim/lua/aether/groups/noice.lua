-- Noice plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    NoiceCompletionItemKindDefault  = { fg = c.dark_fg },
    NoiceCompletionItemKindKeyword  = { fg = c.bright_purple },
    NoiceCompletionItemKindVariable = { fg = c.fg },
    NoiceCompletionItemKindConstant = { fg = c.orange },
    NoiceCompletionItemKindReference = { fg = c.orange },
    NoiceCompletionItemKindValue    = { fg = c.orange },
    NoiceCompletionItemKindFunction = { fg = c.bright_red },
    NoiceCompletionItemKindMethod   = { fg = c.bright_red },
    NoiceCompletionItemKindConstructor = { fg = c.blue },
    NoiceCompletionItemKindClass    = { fg = c.yellow },
    NoiceCompletionItemKindInterface = { fg = c.yellow },
    NoiceCompletionItemKindStruct   = { fg = c.yellow },
    NoiceCompletionItemKindEvent    = { fg = c.bright_purple },
    NoiceCompletionItemKindEnum     = { fg = c.yellow },
    NoiceCompletionItemKindUnit     = { fg = c.orange },
    NoiceCompletionItemKindModule   = { fg = c.blue },
    NoiceCompletionItemKindProperty = { fg = c.cyan },
    NoiceCompletionItemKindField    = { fg = c.cyan },
    NoiceCompletionItemKindTypeParameter = { fg = c.yellow },
    NoiceCompletionItemKindEnumMember = { fg = c.cyan },
    NoiceCompletionItemKindOperator = { fg = c.cyan },
    NoiceCompletionItemKindSnippet  = { fg = c.green },
    NoiceCmdline                    = { bg = c.bg_popup },
    NoiceCmdlineIcon                = { fg = c.blue },
    NoiceCmdlineIconSearch          = { fg = c.yellow },
    NoiceCmdlinePopup               = { bg = c.bg_popup },
    NoiceCmdlinePopupBorder         = { fg = c.border_highlight, bg = c.bg_popup },
    NoiceCmdlinePopupBorderSearch   = { fg = c.border_highlight, bg = c.bg_popup },
    NoiceConfirm                    = { bg = c.bg_popup },
    NoiceConfirmBorder              = { fg = c.border_highlight, bg = c.bg_popup },
  }
end

return M
