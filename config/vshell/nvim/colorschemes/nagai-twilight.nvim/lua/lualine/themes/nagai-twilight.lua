-- Lualine theme for Nagai Twilight
local C = require("nagai_twilight.palette")

local M = {}

local bg = C.bg
local fg = C.fg
local surface = C.surface0
local dim = C.comment

M.normal = {
  a = { bg = C.blue, fg = C.bg_dark, gui = "bold" },
  b = { bg = surface, fg = fg },
  c = { bg = surface, fg = fg },
}

M.insert = {
  a = { bg = C.bright_cyan, fg = C.bg_dark, gui = "bold" },
  b = { bg = surface, fg = fg },
  c = { bg = surface, fg = fg },
}

M.visual = {
  a = { bg = C.pink, fg = C.bg_dark, gui = "bold" },
  b = { bg = surface, fg = fg },
  c = { bg = surface, fg = fg },
}

M.replace = {
  a = { bg = C.red, fg = C.bg_dark, gui = "bold" },
  b = { bg = surface, fg = fg },
  c = { bg = surface, fg = fg },
}

M.command = {
  a = { bg = C.yellow, fg = C.bg_dark, gui = "bold" },
  b = { bg = surface, fg = fg },
  c = { bg = surface, fg = fg },
}

M.inactive = {
  a = { bg = bg, fg = dim },
  b = { bg = bg, fg = dim },
  c = { bg = bg, fg = dim },
}

return M
