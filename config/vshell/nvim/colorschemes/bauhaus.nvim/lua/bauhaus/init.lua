local H = require("bauhaus.highlights")
local C = require("bauhaus.palette")

local M = {}

M.opts = {
  transparent = false,
  -- user_overrides = function() end,
}

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function set_terminal()
  local n, b = C.ansi.normal, C.ansi.bright
  vim.g.terminal_color_0 = n[1]
  vim.g.terminal_color_1 = n[2]
  vim.g.terminal_color_2 = n[3]
  vim.g.terminal_color_3 = n[4]
  vim.g.terminal_color_4 = n[5]
  vim.g.terminal_color_5 = n[6]
  vim.g.terminal_color_6 = n[7]
  vim.g.terminal_color_7 = n[8]
  vim.g.terminal_color_8 = b[1]
  vim.g.terminal_color_9 = b[2]
  vim.g.terminal_color_10 = b[3]
  vim.g.terminal_color_11 = b[4]
  vim.g.terminal_color_12 = b[5]
  vim.g.terminal_color_13 = b[6]
  vim.g.terminal_color_14 = b[7]
  vim.g.terminal_color_15 = b[8]
end

function M.load()
  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end

  vim.o.termguicolors = true
  vim.o.background = "dark"
  vim.g.colors_name = "bauhaus"

  H.apply(M.opts)
  set_terminal()

  if M.opts.user_overrides then
    pcall(M.opts.user_overrides)
  end
end

return M
