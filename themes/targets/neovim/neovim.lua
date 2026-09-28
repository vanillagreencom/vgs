-- The vgs theme for Neovim, rendered by vgsh theme apply. lazy.nvim loads it
-- as a plugin spec through lua/plugins/vgs-theme.lua. It adds no plugin, so
-- the spec is empty; the colours are set once Neovim has started, after any
-- colorscheme a plugin loads at startup.
local function apply()
  vim.cmd("highlight clear")
  vim.g.colors_name = "vgs"
  local hl = function(group, spec) vim.api.nvim_set_hl(0, group, spec) end
  hl("Normal", { fg = "#@{color.text}", bg = "#@{color.background}" })
  hl("NormalFloat", { fg = "#@{color.text}", bg = "#@{color.surfaceRaised}" })
  hl("FloatBorder", { fg = "#@{color.borderStrong}", bg = "#@{color.surfaceRaised}" })
  hl("WinSeparator", { fg = "#@{color.border}" })
  hl("Cursor", { fg = "#@{color.onAccent}", bg = "#@{color.accent}" })
  hl("CursorLine", { bg = "#@{color.surfaceRaised}" })
  hl("ColorColumn", { bg = "#@{color.surface}" })
  hl("LineNr", { fg = "#@{color.textFaint}" })
  hl("CursorLineNr", { fg = "#@{color.text}", bold = true })
  hl("SignColumn", { bg = "#@{color.background}" })
  hl("Visual", { bg = "#@{color.borderStrong}" })
  hl("Search", { fg = "#@{color.onAccent}", bg = "#@{color.accent}" })
  hl("IncSearch", { fg = "#@{color.onAccent}", bg = "#@{color.accentHover}" })
  hl("MatchParen", { fg = "#@{color.accent}", bold = true })
  hl("StatusLine", { fg = "#@{color.text}", bg = "#@{color.surfaceRaised}" })
  hl("StatusLineNC", { fg = "#@{color.textMuted}", bg = "#@{color.surface}" })
  hl("TabLine", { fg = "#@{color.textMuted}", bg = "#@{color.surface}" })
  hl("TabLineSel", { fg = "#@{color.text}", bg = "#@{color.background}" })
  hl("TabLineFill", { bg = "#@{color.surface}" })
  hl("Pmenu", { fg = "#@{color.text}", bg = "#@{color.surfaceRaised}" })
  hl("PmenuSel", { fg = "#@{color.onAccent}", bg = "#@{color.accent}" })
  hl("NonText", { fg = "#@{color.textDisabled}" })
  hl("Comment", { fg = "#@{color.textFaint}", italic = true })
  hl("Constant", { fg = "#@{terminal.color6}" })
  hl("String", { fg = "#@{terminal.color2}" })
  hl("Identifier", { fg = "#@{color.text}" })
  hl("Function", { fg = "#@{terminal.color4}" })
  hl("Statement", { fg = "#@{terminal.color5}" })
  hl("Type", { fg = "#@{terminal.color3}" })
  hl("PreProc", { fg = "#@{terminal.color1}" })
  hl("Special", { fg = "#@{color.accent}" })
  hl("Error", { fg = "#@{color.danger}" })
  hl("ErrorMsg", { fg = "#@{color.danger}" })
  hl("WarningMsg", { fg = "#@{color.warning}" })
  hl("DiagnosticError", { fg = "#@{color.danger}" })
  hl("DiagnosticWarn", { fg = "#@{color.warning}" })
  hl("DiagnosticInfo", { fg = "#@{color.info}" })
  hl("DiagnosticHint", { fg = "#@{color.success}" })
  hl("DiffAdd", { fg = "#@{color.success}" })
  hl("DiffChange", { fg = "#@{color.warning}" })
  hl("DiffDelete", { fg = "#@{color.danger}" })
  local slots = {
    "#@{terminal.color0}", "#@{terminal.color1}", "#@{terminal.color2}", "#@{terminal.color3}",
    "#@{terminal.color4}", "#@{terminal.color5}", "#@{terminal.color6}", "#@{terminal.color7}",
    "#@{terminal.color8}", "#@{terminal.color9}", "#@{terminal.color10}", "#@{terminal.color11}",
    "#@{terminal.color12}", "#@{terminal.color13}", "#@{terminal.color14}", "#@{terminal.color15}",
  }
  for i, slot in ipairs(slots) do vim.g["terminal_color_" .. (i - 1)] = slot end
end

if vim.v.vim_did_enter == 1 then
  apply()
else
  vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = apply })
end
return {}
