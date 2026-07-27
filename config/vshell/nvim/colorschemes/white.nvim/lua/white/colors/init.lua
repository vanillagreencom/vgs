local Util = require("white.utils")

local M = {}

---@class Palette
local default_palette = {
	bg = "#ffffff",
	bg_dark = "#f5f5f5",
	bg_dark1 = "#f5f5f5",
	bg_highlight = "#e8e8e8",

	-- Luminance tiers (T1=faintest chrome → T7=darkest focus)
	-- For light theme: darker = more prominent against white background
	-- T1: #c0c0c0 ~1.6:1 - gutter, line numbers
	-- T2: #6e6e6e ~5.3:1 - comments (WCAG AA compliant)
	-- T3: #4a4a4a ~9.0:1 - operators, punctuation
	-- T4: #3a3a3a ~11.5:1 - strings, numbers, secondary data
	-- T5: #2e2e2e ~13.3:1 - variables, identifiers, properties
	-- T6: #1a1a1a ~17.4:1 - types, statements, control flow
	-- T7: #000000 ~21.0:1 - functions, keywords, main foreground
	--
	-- 8 extra shades (not in colors.toml):
	-- #f5f5f5, #e8e8e8, #b0b0b0, #a0a0a0, #909090, #808080, #6e6e6e, #5a5a5a

	blue = "#1a1a1a",     -- T6: statements, directories, titles
	blue0 = "#b0b0b0",    -- selection bg
	blue1 = "#2e2e2e",    -- T5: borders, pmenu match
	blue2 = "#3a3a3a",    -- T4: info diagnostic
	blue5 = "#4a4a4a",    -- T3: operators, punctuation delimiters
	blue6 = "#3e3e3e",    -- T4: string.regexp
	blue7 = "#e8e8e8",    -- diff change bg

	comment = "#6e6e6e",  -- T2: WCAG AA 5.3:1 minimum
	cyan = "#3e3e3e",     -- T4: preprocessor, macros, special

	dark3 = "#a0a0a0",    -- between T1-T2: nontext, ignored
	dark5 = "#808080",    -- concealed text

	fg = "#000000",       -- T7: main foreground (pure black)
	fg_dark = "#1a1a1a",  -- T6: messages, fallback text
	fg_gutter = "#c0c0c0", -- T1: line numbers, gutter

	green = "#3a3a3a",    -- T4: strings, characters
	green1 = "#2e2e2e",   -- T5: properties, variable.member
	green2 = "#2e2e2e",   -- T5: git add

	magenta = "#2e2e2e",  -- T5: constructors
	magenta2 = "#2e2e2e", -- T5: variables, identifiers

	orange = "#3a3a3a",   -- T4: numbers, booleans
	purple = "#000000",   -- T7: keywords, constants, conditionals

	red = "#1a1a1a",      -- T6: tags
	red1 = "#000000",     -- T7: error, git delete (max visibility)

	teal = "#5a5a5a",     -- T3: hints, markup links
	terminal_black = "#c0c0c0", -- T1

	yellow = "#1a1a1a",   -- T6: types, labels, parameters, warnings

	-- Git colors will be calculated from the palette colors above
	git = {},

	special_char = "#2e2e2e", -- T5
}

---@param opts? white.Config
function M.setup(opts)
	opts = require("white.config").extend(opts)

	-- Color Palette
	---@class ColorScheme: Palette
	local colors = vim.deepcopy(default_palette)

	if opts.colors and next(opts.colors) then
		colors = vim.tbl_deep_extend("force", colors, opts.colors)
	end

	Util.bg = colors.bg
	Util.fg = colors.fg

	colors.none = "NONE"

	-- Always update git colors to use the palette colors (either default or injected)
	-- This ensures git colors are derived from the theme colors
	colors.git.add = colors.green2 or colors.green
	colors.git.delete = colors.red1 or colors.red
	colors.git.change = colors.orange or colors.yellow

	-- Diff colors
	colors.diff = {
		add = Util.blend_bg(colors.green2 or colors.green, 0.25),
		delete = Util.blend_bg(colors.red1 or colors.red, 0.25),
		change = Util.blend_bg(colors.blue7 or colors.blue, 0.15),
		text = colors.blue7 or colors.blue,
	}

	colors.git.ignore = colors.dark3
	colors.black = Util.blend_bg(colors.bg, 0.8, colors.bg)
	colors.border_highlight = Util.blend_bg(colors.blue1, 0.8)
	colors.border = Util.blend_bg(colors.fg, 0.15)

	-- Popups and statusline get a subtle background
	colors.bg_popup = colors.bg_dark
	colors.bg_statusline = colors.bg_dark

	-- Sidebar and Floats are configurable
	colors.bg_sidebar = opts.styles.sidebars == "transparent" and colors.none
		or opts.styles.sidebars == "dark" and colors.bg_dark
		or colors.bg

	colors.bg_float = opts.styles.floats == "transparent" and colors.none
		or opts.styles.floats == "dark" and colors.bg_dark
		or colors.bg

	colors.bg_visual = Util.blend_bg(colors.blue0, 0.4)
	colors.bg_search = colors.blue0
	colors.fg_sidebar = colors.fg
	colors.fg_float = colors.fg

	colors.error = colors.red1
	colors.todo = colors.blue
	colors.warning = colors.yellow
	colors.info = colors.blue2
	colors.hint = colors.teal

	-- Create blended colors for subtle highlights
	colors.subtle_bg = Util.blend_bg(colors.fg, 0.06)
	colors.cursorline_bg = Util.blend_bg(colors.fg, 0.05)
	colors.selection_bg = Util.blend_bg(colors.fg, 0.12)
	colors.float_bg = Util.blend_bg(colors.fg, 0.04)

	colors.rainbow = {
		colors.blue,
		colors.yellow,
		colors.green,
		colors.teal,
		colors.magenta,
		colors.purple,
		colors.orange,
		colors.red,
	}

	-- Terminal colors (mapped directly from colors.toml ANSI values)
	colors.terminal = {
		black = "#ffffff",           -- color0
		black_bright = "#c0c0c0",    -- color8
		red = "#2a2a2a",             -- color1
		red_bright = "#2a2a2a",      -- color9
		green = "#3a3a3a",           -- color2
		green_bright = "#3a3a3a",    -- color10
		yellow = "#4a4a4a",          -- color3
		yellow_bright = "#4a4a4a",   -- color11
		blue = "#1a1a1a",            -- color4
		blue_bright = "#1a1a1a",     -- color12
		magenta = "#2e2e2e",         -- color5
		magenta_bright = "#2e2e2e",  -- color13
		cyan = "#3e3e3e",            -- color6
		cyan_bright = "#3e3e3e",     -- color14
		white = "#000000",           -- color7
		white_bright = "#000000",    -- color15
	}

	-- Call user's on_colors callback for further customization
	opts.on_colors(colors)

	return colors, opts
end

return M
