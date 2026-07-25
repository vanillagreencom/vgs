-- Lualine theme for white colorscheme
--
-- Each mode uses a distinct luminance tier for the "a" pill so they
-- are immediately distinguishable in a monochrome palette:
--   NORMAL  #000000 (T7)  — darkest, grounded
--   COMMAND #1a1a1a (T6)  — near-black, authoritative
--   REPLACE #2e2e2e (T5)  — dark, heavy feel
--   INSERT  #4a4a4a (T3)  — medium gray, lighter/open
--   VISUAL  #6e6e6e (T2)  — softest active mode
--
-- Sections gradient: a (dark pill) → b (light gray) → c (near-white)

local colors = require("white.colorscheme")

local M = {}

M.normal = {
	a = { bg = colors.fg, fg = colors.bg, gui = "bold" },
	b = { bg = colors.bg_highlight, fg = colors.fg_dark },
	c = { bg = colors.bg_dark, fg = colors.blue5 },
}

M.insert = {
	a = { bg = colors.blue5, fg = colors.bg, gui = "bold" },
	b = { bg = colors.bg_highlight, fg = colors.blue5 },
	c = { bg = colors.bg_dark, fg = colors.blue5 },
}

M.command = {
	a = { bg = colors.fg_dark, fg = colors.bg, gui = "bold" },
	b = { bg = colors.bg_highlight, fg = colors.fg_dark },
	c = { bg = colors.bg_dark, fg = colors.blue5 },
}

M.visual = {
	a = { bg = colors.comment, fg = colors.bg, gui = "bold" },
	b = { bg = colors.bg_highlight, fg = colors.comment },
	c = { bg = colors.bg_dark, fg = colors.blue5 },
}

M.replace = {
	a = { bg = colors.magenta, fg = colors.bg, gui = "bold" },
	b = { bg = colors.bg_highlight, fg = colors.magenta },
	c = { bg = colors.bg_dark, fg = colors.blue5 },
}

M.terminal = {
	a = { bg = colors.green, fg = colors.bg, gui = "bold" },
	b = { bg = colors.bg_highlight, fg = colors.green },
	c = { bg = colors.bg_dark, fg = colors.blue5 },
}

M.inactive = {
	a = { bg = colors.bg_highlight, fg = colors.dark3 },
	b = { bg = colors.bg_dark, fg = colors.dark3 },
	c = { bg = colors.bg_dark, fg = colors.fg_gutter },
}

return M
