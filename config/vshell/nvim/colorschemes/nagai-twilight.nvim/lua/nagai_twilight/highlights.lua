local C = require("nagai_twilight.palette")

local M = {}

local function hi(group, value)
  vim.api.nvim_set_hl(0, group, value)
end

local function hi_link(group, target)
  vim.api.nvim_set_hl(0, group, { link = target, default = false })
end

function M.apply(opts)
  opts = opts or {}
  local transparent = opts.transparent
  local editor_bg = transparent and "NONE" or C.bg
  local float_bg = transparent and editor_bg or C.surface0
  local status_bg = transparent and editor_bg or C.surface0
  local border = transparent and C.surface2 or C.border

  -- Core UI
  hi("Normal", { fg = C.fg, bg = editor_bg })
  hi("NormalNC", { fg = C.fg_dark, bg = editor_bg })
  hi("NormalFloat", { fg = C.fg, bg = float_bg })
  hi("FloatBorder", { fg = C.blue, bg = float_bg })
  hi("WinSeparator", { fg = border })
  hi("SignColumn", { fg = C.comment, bg = editor_bg })
  hi("ColorColumn", { bg = C.surface0 })
  hi("CursorLine", { bg = C.bg_highlight })
  hi("CursorColumn", { bg = C.bg_highlight })
  hi("CursorLineNr", { fg = C.magenta, bold = true })
  hi("LineNr", { fg = C.muted })
  hi("LineNrAbove", { fg = C.muted })
  hi("LineNrBelow", { fg = C.muted })
  hi("Visual", { bg = C.visual })
  hi("VisualNOS", { bg = C.visual })
  hi("Search", { fg = C.bg, bg = C.blue, bold = true })
  hi("IncSearch", { fg = C.bg, bg = C.yellow, bold = true })
  hi("CurSearch", { fg = C.bg, bg = C.magenta, bold = true })
  hi("MatchParen", { fg = C.pink, bold = true })
  hi("Pmenu", { fg = C.fg, bg = float_bg })
  hi("PmenuSel", { fg = C.fg, bg = C.selection, bold = true })
  hi("PmenuSbar", { bg = C.surface1 })
  hi("PmenuThumb", { bg = C.surface2 })
  hi("StatusLine", { fg = C.fg, bg = status_bg })
  hi("StatusLineNC", { fg = C.comment, bg = editor_bg })
  hi("TabLine", { fg = C.comment, bg = editor_bg })
  hi("TabLineSel", { fg = C.magenta, bg = status_bg, bold = true })
  hi("TabLineFill", { bg = editor_bg })
  hi("VertSplit", { fg = border })
  hi("Folded", { fg = C.comment, bg = float_bg })
  hi("FoldColumn", { fg = C.comment, bg = editor_bg })
  hi("Whitespace", { fg = C.surface2 })

  -- Diagnostics
  hi("DiagnosticError", { fg = C.red })
  hi("DiagnosticWarn", { fg = C.yellow })
  hi("DiagnosticInfo", { fg = C.blue })
  hi("DiagnosticHint", { fg = C.cyan })
  hi("DiagnosticOk", { fg = C.green })
  hi("DiagnosticUnderlineError", { undercurl = true, sp = C.red })
  hi("DiagnosticUnderlineWarn", { undercurl = true, sp = C.yellow })
  hi("DiagnosticUnderlineInfo", { undercurl = true, sp = C.blue })
  hi("DiagnosticUnderlineHint", { undercurl = true, sp = C.cyan })
  hi("DiagnosticVirtualTextError", { fg = C.red, bg = "NONE" })
  hi("DiagnosticVirtualTextWarn", { fg = C.yellow, bg = "NONE" })
  hi("DiagnosticVirtualTextInfo", { fg = C.blue, bg = "NONE" })
  hi("DiagnosticVirtualTextHint", { fg = C.cyan, bg = "NONE" })
  hi("DiagnosticSignError", { fg = C.red, bg = editor_bg })
  hi("DiagnosticSignWarn", { fg = C.yellow, bg = editor_bg })
  hi("DiagnosticSignInfo", { fg = C.blue, bg = editor_bg })
  hi("DiagnosticSignHint", { fg = C.cyan, bg = editor_bg })
  hi("DiagnosticSignOk", { fg = C.green, bg = editor_bg })

  -- Treesitter / syntax
  hi("Comment", { fg = C.comment, italic = true })
  hi("Constant", { fg = C.yellow })
  hi("String", { fg = C.green })
  hi("Character", { fg = C.green })
  hi("Number", { fg = C.pink })
  hi("Float", { fg = C.pink })
  hi("Boolean", { fg = C.pink })
  hi("Identifier", { fg = C.fg })
  hi("Function", { fg = C.blue })
  hi("Statement", { fg = C.magenta })
  hi("Conditional", { fg = C.magenta, bold = true })
  hi("Repeat", { fg = C.magenta, bold = true })
  hi("Label", { fg = C.blue })
  hi("Operator", { fg = C.fg_dark })
  hi("Keyword", { fg = C.pink, bold = true })
  hi("Exception", { fg = C.red })
  hi("PreProc", { fg = C.cyan })
  hi("Include", { fg = C.cyan })
  hi("Define", { fg = C.cyan })
  hi("Macro", { fg = C.yellow })
  hi("Type", { fg = C.yellow })
  hi("StorageClass", { fg = C.teal })
  hi("Structure", { fg = C.teal })
  hi("Typedef", { fg = C.teal })
  hi("Special", { fg = C.blue })
  hi("SpecialComment", { fg = C.comment, italic = true })
  hi("Tag", { fg = C.pink })
  hi("Delimiter", { fg = C.comment })
  hi("@punctuation.delimiter", { fg = C.comment })
  hi("@punctuation.bracket", { fg = C.comment })
  hi("@punctuation.special", { fg = C.comment })
  hi_link("@keyword", "Keyword")
  hi_link("@type", "Type")
  hi_link("@function", "Function")
  hi_link("@function.builtin", "Function")
  hi_link("@function.call", "Function")
  hi_link("@function.macro", "Macro")
  hi_link("@constructor", "Type")
  hi("@variable", { fg = C.fg })
  hi("@variable.builtin", { fg = C.pink, italic = true })
  hi("@variable.member", { fg = C.fg })
  hi("@field", { fg = C.fg_dark })
  hi("@property", { fg = C.fg_dark })
  hi("@parameter", { fg = C.pink })
  hi("@constant", { fg = C.yellow })
  hi("@constant.builtin", { fg = C.pink })
  hi("@string", { fg = C.green })
  hi("@string.escape", { fg = C.teal })
  hi("@string.regex", { fg = C.green })
  hi("@string.special", { fg = C.teal })
  hi("@comment.todo", { fg = C.yellow, bold = true })
  hi("@comment.note", { fg = C.blue, bold = true })
  hi("@comment.warning", { fg = C.yellow, bold = true })
  hi("@comment.error", { fg = C.red, bold = true })
  hi("@markup.italic", { italic = true })
  hi("@markup.bold", { bold = true })
  hi("@markup.strikethrough", { strikethrough = true })
  hi("@markup.underline", { underline = true })
  hi("@markup.heading", { fg = C.magenta, bold = true })
  hi("@markup.link", { fg = C.blue, underline = true })
  hi("@markup.list", { fg = C.magenta })
  hi("@markup.quote", { fg = C.teal, italic = true })

  -- Markdown
  hi("markdownHeadingDelimiter", { fg = C.magenta })
  hi("markdownUrl", { fg = C.blue, underline = true })
  hi("markdownLinkText", { fg = C.magenta, underline = true })
  hi("markdownCode", { fg = C.green })
  hi("markdownCodeBlock", { fg = C.green })

  -- Diff & Git
  hi("DiffAdd", { fg = C.green, bg = "NONE" })
  hi("DiffChange", { fg = C.blue, bg = "NONE" })
  hi("DiffDelete", { fg = C.red, bg = "NONE" })
  hi("DiffText", { fg = C.blue, bg = "NONE", bold = true })
  hi("GitSignsAdd", { fg = C.green })
  hi("GitSignsChange", { fg = C.blue })
  hi("GitSignsDelete", { fg = C.red })

  -- Telescope
  hi("TelescopeBorder", { fg = C.blue, bg = float_bg })
  hi("TelescopeNormal", { fg = C.fg, bg = float_bg })
  hi("TelescopeTitle", { fg = C.magenta, bold = true })

  -- WhichKey
  hi("WhichKey", { fg = C.magenta, bold = true })
  hi("WhichKeyGroup", { fg = C.magenta })
  hi("WhichKeySeparator", { fg = C.comment })
  hi("WhichKeyDesc", { fg = C.fg })
  hi("WhichKeyValue", { fg = C.blue })

  -- Lazy.nvim UI
  hi("LazyButtonActive", { fg = C.bg, bg = C.magenta, bold = true })
  hi("LazyH1", { fg = C.bg, bg = C.magenta, bold = true })
  hi("LazyProgressDone", { fg = C.magenta })

  -- Alpha / dashboards
  hi("AlphaHeader", { fg = C.magenta, bold = true })
  hi("AlphaFooter", { fg = C.comment })
  hi("AlphaShortcut", { fg = C.magenta, bold = true })
  hi("AlphaButton", { fg = C.blue })

  -- Mini.nvim statusline mode colors
  hi("MiniStatuslineModeNormal", { fg = C.bg_dark, bg = C.blue, bold = true })
  hi("MiniStatuslineModeInsert", { fg = C.bg_dark, bg = C.bright_cyan, bold = true })
  hi("MiniStatuslineModeVisual", { fg = C.bg_dark, bg = C.pink, bold = true })
  hi("MiniStatuslineModeReplace", { fg = C.bg_dark, bg = C.red, bold = true })
  hi("MiniStatuslineModeCommand", { fg = C.bg_dark, bg = C.yellow, bold = true })

  -- Lualine groups (fallback when lualine theme not used)
  hi("lualine_a_normal", { fg = C.bg_dark, bg = C.blue, bold = true })
  hi("lualine_a_insert", { fg = C.bg_dark, bg = C.bright_cyan, bold = true })
  hi("lualine_a_visual", { fg = C.bg_dark, bg = C.pink, bold = true })
  hi("lualine_a_replace", { fg = C.bg_dark, bg = C.red, bold = true })
  hi("lualine_a_command", { fg = C.bg_dark, bg = C.yellow, bold = true })

  -- Misc
  hi("DiagnosticUnnecessary", { fg = C.comment, italic = true })
  hi("DiagnosticDeprecated", { fg = C.comment, strikethrough = true })
end

return M
