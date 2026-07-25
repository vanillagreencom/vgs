-- LazyVim plugin spec: load the Nagai Twilight colorscheme plugin
-- Place this file under LazyVim's plugin specs (Omarchy will copy/link when applying the theme)
return {
  {
    vgs_vendored = "nagai-twilight.nvim",
    name = "nagai_twilight",
    lazy = false,
    priority = 1000,
    config = function()
      require("nagai_twilight").setup({ transparent = false })
      vim.cmd.colorscheme("nagai-twilight")
    end,
  },
}
