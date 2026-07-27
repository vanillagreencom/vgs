local Util = require("ethereal.utils")

local M = {}

---@class Palette
local default_palette = {
	bg = "#060B1E",
	bg_dark = "#060B1E",
	bg_dark1 = "#060B1E",
	bg_highlight = "#060B1E",

	-- Ethereal accent colors
	blue = "#7d82d9",
	blue0 = "#264f78",
	blue1 = "#7d82d9",
	blue2 = "#7d82d9",
	blue5 = "#a3bfd1",
	blue6 = "#b4f9f8",
	blue7 = "#1e3a5f",

	comment = "#6d7db6",
	cyan = "#a3bfd1",

	dark3 = "#6d7db6",
	dark5 = "#F99957",

	fg = "#ffcead",
	fg_dark = "#F99957",
	fg_gutter = "#6d7db6", -- Same as base03/comment for visibility

	green = "#92a593",
	green1 = "#92a593",
	green2 = "#92a593",

	magenta = "#c89dc1",
	magenta2 = "#8e93de",

	orange = "#faaaa9",
	purple = "#c89dc1",

	red = "#ED5B5A",
	red1 = "#ED5B5A",

	teal = "#a3bfd1",
	terminal_black = "#6d7db6",

	yellow = "#E9BB4F",

	-- Git colors will be calculated from the palette colors above
	git = {},

    special_char = "#f7dc9c",
}

---@param opts? ethereal.Config
function M.setup(opts)
	opts = require("ethereal.config").extend(opts)

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

	-- Diff colors using tokyonight approach
	colors.diff = {
		add = Util.blend_bg(colors.green2 or colors.green, 0.25),
		delete = Util.blend_bg(colors.red1 or colors.red, 0.25),
		change = Util.blend_bg(colors.blue7 or colors.blue, 0.15),
		text = colors.blue7 or colors.blue,
	}

	colors.git.ignore = colors.dark3
	colors.black = Util.blend_bg(colors.bg, 0.8, colors.bg)
	colors.border_highlight = Util.blend_bg(colors.blue1, 0.8)
	colors.border = colors.black

	-- Popups and statusline always get a dark background
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
	colors.subtle_bg = Util.blend_bg(colors.fg, 0.10)
	colors.cursorline_bg = Util.blend_bg(colors.fg, 0.20)
	colors.selection_bg = Util.blend_bg(colors.fg, 0.25)
	colors.float_bg = Util.blend_bg(colors.fg, 0.12)

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

	-- Terminal colors
	colors.terminal = {
		black = colors.black,
		black_bright = colors.terminal_black,
		red = colors.red,
		red_bright = colors.red,
		green = colors.green,
		green_bright = colors.green,
		yellow = colors.yellow,
		yellow_bright = colors.yellow,
		blue = colors.blue,
		blue_bright = colors.blue,
		magenta = colors.magenta,
		magenta_bright = colors.magenta,
		cyan = colors.cyan,
		cyan_bright = colors.cyan,
		white = colors.fg_dark,
		white_bright = colors.fg,
	}

	-- Call user's on_colors callback for further customization
	opts.on_colors(colors)

	return colors, opts
end

return M
