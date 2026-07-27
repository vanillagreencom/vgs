local H = require("nagai_twilight.highlights")
local C = require("nagai_twilight.palette")

local M = {}

M.opts = {
  transparent = false,
  -- user_overrides = function() end,
}

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function set_terminal()
  local normal = C.ansi.normal
  local bright = C.ansi.bright

  vim.g.terminal_color_0  = normal[1]
  vim.g.terminal_color_1  = normal[2]
  vim.g.terminal_color_2  = normal[3]
  vim.g.terminal_color_3  = normal[4]
  vim.g.terminal_color_4  = normal[5]
  vim.g.terminal_color_5  = normal[6]
  vim.g.terminal_color_6  = normal[7]
  vim.g.terminal_color_7  = normal[8]

  if bright then
    vim.g.terminal_color_8  = bright[1]
    vim.g.terminal_color_9  = bright[2]
    vim.g.terminal_color_10 = bright[3]
    vim.g.terminal_color_11 = bright[4]
    vim.g.terminal_color_12 = bright[5]
    vim.g.terminal_color_13 = bright[6]
    vim.g.terminal_color_14 = bright[7]
    vim.g.terminal_color_15 = bright[8]
  end
end

function M.load()
  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end

  vim.o.termguicolors = true
  vim.o.background = "dark"
  vim.g.colors_name = "nagai-twilight"

  H.apply(M.opts)
  set_terminal()

  if M.opts.user_overrides then
    pcall(M.opts.user_overrides)
  end
end

return M
