-- Akane colorscheme (self-contained; inlined from the upstream Omarchy akane theme).
return {
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = function()
        -- Akane colorscheme for Neovim
        -- Inspired by traditional Japanese aesthetics with crimson and shadow tones

        vim.cmd("hi clear")
        if vim.fn.exists("syntax_on") then
            vim.cmd("syntax reset")
        end

        vim.g.colors_name = "akane"
        vim.o.background = "dark"

        -- Color Palette
        local colors = {
            bg     = "#0E1E36", -- oxford-blue
            fg     = "#F4B999", -- peach
            violet = "#9279AA", -- african-violet
            purple = "#574F72", -- english-violet
            mag    = "#763C5D", -- quinacridone-magenta
            rose   = "#BE6F76", -- old-rose
            blush  = "#C85670", -- blush
            coral  = "#FA7E75", -- coral-pink
            red    = "#D2495B", -- amaranth
            darkp  = "#4A2036", -- dark-purple
        }

        local function hi(group, opts)
            vim.api.nvim_set_hl(0, group, opts)
        end

        -- Enable true colors
        vim.o.termguicolors = true

        -- UI Elements
        hi("Normal", { fg = colors.fg, bg = colors.bg })
        hi("NormalNC", { fg = colors.fg, bg = colors.bg })
        hi("NormalFloat", { fg = colors.fg, bg = colors.bg })
        hi("FloatBorder", { fg = colors.purple, bg = colors.bg })
        hi("WinSeparator", { fg = colors.darkp, bg = colors.bg })
        hi("VertSplit", { fg = colors.darkp, bg = colors.bg })
        hi("LineNr", { fg = colors.purple, bg = colors.bg })
        hi("CursorLine", { bg = colors.darkp })
        hi("CursorLineNr", { fg = colors.fg, bold = true })
        hi("SignColumn", { bg = colors.bg })
        hi("Visual", { bg = colors.purple })
        hi("Search", { fg = colors.bg, bg = colors.violet, bold = true })
        hi("IncSearch", { fg = colors.bg, bg = colors.coral, bold = true })
        hi("MatchParen", { fg = colors.coral, bold = true })
        hi("Pmenu", { fg = colors.fg, bg = colors.darkp })
        hi("PmenuSel", { fg = colors.bg, bg = colors.violet, bold = true })
        hi("PmenuThumb", { bg = colors.violet })
        hi("StatusLine", { fg = colors.fg, bg = colors.purple })
        hi("StatusLineNC", { fg = colors.purple, bg = colors.darkp })
        hi("TabLine", { fg = colors.fg, bg = colors.darkp })
        hi("TabLineSel", { fg = colors.bg, bg = colors.violet, bold = true })
        hi("TabLineFill", { bg = colors.bg })
        hi("Title", { fg = colors.fg, bold = true })
        hi("Directory", { fg = colors.violet, bold = true })
        hi("Whitespace", { fg = colors.purple })

        -- Syntax Highlighting
        hi("Comment", { fg = colors.purple, italic = true })
        hi("Identifier", { fg = colors.blush })
        hi("Function", { fg = colors.violet, bold = true })
        hi("Statement", { fg = colors.violet })
        hi("Conditional", { fg = colors.violet })
        hi("Repeat", { fg = colors.violet })
        hi("Operator", { fg = colors.fg })
        hi("Keyword", { fg = colors.violet, italic = true })
        hi("PreProc", { fg = colors.fg })
        hi("Type", { fg = colors.rose })
        hi("Special", { fg = colors.blush })
        hi("Underlined", { fg = colors.fg, underline = true })
        hi("Todo", { fg = colors.bg, bg = colors.fg, bold = true })
        hi("Constant", { fg = colors.blush })
        hi("String", { fg = colors.fg })
        hi("Character", { fg = colors.fg })
        hi("Number", { fg = colors.coral })
        hi("Boolean", { fg = colors.coral })
        hi("Float", { fg = colors.coral })

        -- Diagnostics
        hi("Error", { fg = colors.red, bold = true })
        hi("WarningMsg", { fg = colors.coral })
        hi("DiagnosticError", { fg = colors.red })
        hi("DiagnosticWarn", { fg = colors.fg })
        hi("DiagnosticInfo", { fg = colors.violet })
        hi("DiagnosticHint", { fg = colors.rose })
        hi("DiagnosticOk", { fg = colors.rose })
        hi("DiagnosticUnderlineError", { undercurl = true, sp = colors.red })
        hi("DiagnosticUnderlineWarn", { undercurl = true, sp = colors.fg })
        hi("DiagnosticUnderlineInfo", { undercurl = true, sp = colors.violet })
        hi("DiagnosticUnderlineHint", { undercurl = true, sp = colors.rose })
        hi("DiagnosticVirtualTextError", { fg = colors.red, bg = colors.darkp })
        hi("DiagnosticVirtualTextWarn", { fg = colors.fg, bg = colors.darkp })
        hi("DiagnosticVirtualTextInfo", { fg = colors.violet, bg = colors.darkp })
        hi("DiagnosticVirtualTextHint", { fg = colors.rose, bg = colors.darkp })

        -- Git/Diff
        hi("DiffAdd", { fg = colors.rose, bg = colors.darkp })
        hi("DiffChange", { fg = colors.violet, bg = colors.darkp })
        hi("DiffDelete", { fg = colors.red, bg = colors.darkp })
        hi("DiffText", { fg = colors.fg, bg = colors.purple, bold = true })
        hi("GitSignsAdd", { fg = colors.rose })
        hi("GitSignsChange", { fg = colors.violet })
        hi("GitSignsDelete", { fg = colors.red })

        -- Treesitter
        hi("@comment", { link = "Comment" })
        hi("@function", { link = "Function" })
        hi("@function.builtin", { link = "Function" })
        hi("@keyword", { link = "Keyword" })
        hi("@keyword.function", { link = "Keyword" })
        hi("@keyword.operator", { link = "Keyword" })
        hi("@type", { link = "Type" })
        hi("@type.builtin", { link = "Type" })
        hi("@string", { link = "String" })
        hi("@number", { link = "Number" })
        hi("@boolean", { link = "Boolean" })
        hi("@float", { link = "Float" })
        hi("@variable", { fg = colors.fg })
        hi("@variable.builtin", { fg = colors.blush, italic = true })
        hi("@constant", { link = "Constant" })
        hi("@constant.builtin", { link = "Constant" })
        hi("@punctuation", { fg = colors.purple })
        hi("@punctuation.bracket", { fg = colors.purple })
        hi("@punctuation.delimiter", { fg = colors.purple })
        hi("@operator", { link = "Operator" })
        hi("@parameter", { fg = colors.rose })
        hi("@property", { fg = colors.rose })
        hi("@field", { fg = colors.rose })
        hi("@constructor", { fg = colors.violet })
        hi("@tag", { fg = colors.violet })
        hi("@tag.attribute", { fg = colors.rose })
        hi("@tag.delimiter", { fg = colors.purple })

        -- LSP Semantic Tokens
        hi("@lsp.type.class", { link = "Type" })
        hi("@lsp.type.decorator", { link = "Function" })
        hi("@lsp.type.enum", { link = "Type" })
        hi("@lsp.type.enumMember", { link = "Constant" })
        hi("@lsp.type.function", { link = "Function" })
        hi("@lsp.type.interface", { link = "Type" })
        hi("@lsp.type.macro", { link = "Function" })
        hi("@lsp.type.method", { link = "Function" })
        hi("@lsp.type.namespace", { link = "Type" })
        hi("@lsp.type.parameter", { link = "@parameter" })
        hi("@lsp.type.property", { link = "@property" })
        hi("@lsp.type.struct", { link = "Type" })
        hi("@lsp.type.type", { link = "Type" })
        hi("@lsp.type.typeParameter", { link = "Type" })
        hi("@lsp.type.variable", { link = "@variable" })

        -- Telescope
        hi("TelescopeBorder", { fg = colors.purple, bg = colors.bg })
        hi("TelescopePromptBorder", { fg = colors.violet, bg = colors.bg })
        hi("TelescopeResultsBorder", { fg = colors.purple, bg = colors.bg })
        hi("TelescopePreviewBorder", { fg = colors.purple, bg = colors.bg })
        hi("TelescopeSelection", { fg = colors.bg, bg = colors.violet, bold = true })
        hi("TelescopeSelectionCaret", { fg = colors.coral })
        hi("TelescopeMatching", { fg = colors.coral, bold = true })
        hi("TelescopePromptPrefix", { fg = colors.violet })

        -- Neo-tree
        hi("NeoTreeNormal", { fg = colors.fg, bg = colors.bg })
        hi("NeoTreeNormalNC", { fg = colors.fg, bg = colors.bg })
        hi("NeoTreeRootName", { fg = colors.violet, bold = true })
        hi("NeoTreeDirectoryName", { fg = colors.violet })
        hi("NeoTreeDirectoryIcon", { fg = colors.violet })
        hi("NeoTreeFileNameOpened", { fg = colors.coral })
        hi("NeoTreeIndentMarker", { fg = colors.purple })
        hi("NeoTreeGitAdded", { fg = colors.rose })
        hi("NeoTreeGitModified", { fg = colors.violet })
        hi("NeoTreeGitDeleted", { fg = colors.red })

        -- Which-key
        hi("WhichKey", { fg = colors.violet, bold = true })
        hi("WhichKeyGroup", { fg = colors.rose })
        hi("WhichKeyDesc", { fg = colors.fg })
        hi("WhichKeySeparator", { fg = colors.purple })
        hi("WhichKeyFloat", { bg = colors.bg })

        -- Notify
        hi("NotifyERRORBorder", { fg = colors.red })
        hi("NotifyWARNBorder", { fg = colors.coral })
        hi("NotifyINFOBorder", { fg = colors.violet })
        hi("NotifyDEBUGBorder", { fg = colors.purple })
        hi("NotifyTRACEBorder", { fg = colors.purple })
        hi("NotifyERRORIcon", { fg = colors.red })
        hi("NotifyWARNIcon", { fg = colors.coral })
        hi("NotifyINFOIcon", { fg = colors.violet })
        hi("NotifyDEBUGIcon", { fg = colors.purple })
        hi("NotifyTRACEIcon", { fg = colors.purple })
        hi("NotifyERRORTitle", { fg = colors.red })
        hi("NotifyWARNTitle", { fg = colors.coral })
        hi("NotifyINFOTitle", { fg = colors.violet })
        hi("NotifyDEBUGTitle", { fg = colors.purple })
        hi("NotifyTRACETitle", { fg = colors.purple })

        -- Indent Blankline
        hi("IblIndent", { fg = colors.darkp })
        hi("IblScope", { fg = colors.purple })

        -- Dashboard
        hi("DashboardShortCut", { fg = colors.violet })
        hi("DashboardHeader", { fg = colors.coral })
        hi("DashboardCenter", { fg = colors.rose })
        hi("DashboardFooter", { fg = colors.purple, italic = true })

        -- Terminal colors
        vim.g.terminal_color_0 = colors.bg      -- black
        vim.g.terminal_color_1 = colors.red     -- red
        vim.g.terminal_color_2 = colors.rose    -- green
        vim.g.terminal_color_3 = colors.fg      -- yellow
        vim.g.terminal_color_4 = colors.purple  -- blue
        vim.g.terminal_color_5 = colors.mag     -- magenta
        vim.g.terminal_color_6 = colors.violet  -- cyan
        vim.g.terminal_color_7 = colors.coral   -- white
        vim.g.terminal_color_8 = colors.darkp   -- bright black
        vim.g.terminal_color_9 = colors.coral   -- bright red
        vim.g.terminal_color_10 = colors.blush  -- bright green
        vim.g.terminal_color_11 = colors.fg     -- bright yellow
        vim.g.terminal_color_12 = colors.violet -- bright blue
        vim.g.terminal_color_13 = colors.rose   -- bright magenta
        vim.g.terminal_color_14 = colors.blush  -- bright cyan
        vim.g.terminal_color_15 = colors.fg     -- bright white
      end,
    },
  },
}
