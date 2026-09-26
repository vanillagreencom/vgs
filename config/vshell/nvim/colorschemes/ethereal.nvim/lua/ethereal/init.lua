-- Ethereal colorscheme for Neovim
-- Maintainer: Bjarne Øverli
-- License: MIT

local config = require("ethereal.config")

local M = {}

---@param opts? ethereal.Config
function M.load(opts)
  opts = require("ethereal.config").extend(opts)
  return require("ethereal.theme").setup(opts)
end

M.setup = config.setup

return M
