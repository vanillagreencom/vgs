-- white colorscheme for Neovim
-- Maintainer: Bjarne Øverli
-- License: MIT

local config = require("white.config")

local M = {}

---@param opts? white.Config
function M.load(opts)
  opts = require("white.config").extend(opts)
  return require("white.theme").setup(opts)
end

M.setup = config.setup

return M
