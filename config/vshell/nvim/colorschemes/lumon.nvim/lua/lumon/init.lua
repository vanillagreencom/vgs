-- Lumon colorscheme for Neovim
-- Maintainer: Bjarne Øverli
-- License: MIT

local config = require("lumon.config")

local M = {}

---@param opts? lumon.Config
function M.load(opts)
  opts = require("lumon.config").extend(opts)
  return require("lumon.theme").setup(opts)
end

M.setup = config.setup

return M
