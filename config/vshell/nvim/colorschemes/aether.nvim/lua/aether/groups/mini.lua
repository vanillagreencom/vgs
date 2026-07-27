-- Mini plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    -- Mini.nvim modules
    MiniCompletionActiveParameter = { underline = true },
    MiniCursorword                = { bg = c.lighter_bg },
    MiniCursorwordCurrent         = { bg = c.lighter_bg },
    MiniIndentscopeSymbol         = { fg = c.blue, nocombine = true },
    MiniIndentscopePrefix         = { nocombine = true },
    MiniJump                      = { bg = c.purple, fg = c.black },
    MiniJump2dSpot                = { fg = c.bright_purple, bold = true, nocombine = true },
    MiniStarterCurrent            = { nocombine = true },
    MiniStarterFooter             = { fg = c.yellow, italic = true },
    MiniStarterHeader             = { fg = c.blue, bold = true },
    MiniStarterInactive           = { fg = c.muted },
    MiniStarterItem               = { fg = c.fg },
    MiniStarterItemBullet         = { fg = c.border_highlight },
    MiniStarterItemPrefix         = { fg = c.warning },
    MiniStarterSection            = { fg = c.blue, bold = true },
    MiniStarterQuery              = { fg = c.info },
    MiniStatuslineDevinfo         = { fg = c.dark_fg, bg = c.lighter_bg },
    MiniStatuslineFileinfo        = { fg = c.dark_fg, bg = c.lighter_bg },
    MiniStatuslineFilename        = { fg = c.dark_fg, bg = c.muted },
    MiniStatuslineInactive        = { fg = c.blue, bg = c.bg_statusline },
    MiniStatuslineModeCommand     = { fg = c.black, bg = c.yellow, bold = true },
    MiniStatuslineModeInsert      = { fg = c.black, bg = c.green, bold = true },
    MiniStatuslineModeNormal      = { fg = c.black, bg = c.blue, bold = true },
    MiniStatuslineModeOther       = { fg = c.black, bg = c.cyan, bold = true },
    MiniStatuslineModeReplace     = { fg = c.black, bg = c.red, bold = true },
    MiniStatuslineModeVisual      = { fg = c.black, bg = c.purple, bold = true },
    MiniSurround                  = { bg = c.orange, fg = c.black },
    MiniTablineCurrent            = { fg = c.fg, bg = c.lighter_bg, bold = true },
    MiniTablineFill               = { bg = c.black },
    MiniTablineHidden             = { fg = c.dark_fg, bg = c.bg_statusline },
    MiniTablineModifiedCurrent    = { fg = c.warning, bg = c.lighter_bg, bold = true },
    MiniTablineModifiedHidden     = { fg = c.dark_fg, bg = c.bg_statusline },
    MiniTablineModifiedVisible    = { fg = c.warning, bg = c.bg_statusline },
    MiniTablineTabpagesection     = { fg = c.black, bg = c.blue, bold = true },
    MiniTablineVisible            = { fg = c.fg, bg = c.bg_statusline },
    MiniTestEmphasis              = { bold = true },
    MiniTestFail                  = { fg = c.bright_red, bold = true },
    MiniTestPass                  = { fg = c.green, bold = true },
    MiniTrailspace                = { bg = c.red },
  }
end

return M
