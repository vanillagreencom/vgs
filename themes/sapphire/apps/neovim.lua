return {
	{
		vgs_vendored = "nightfall.nvim",
		name = "nightfall",
		lazy = false,
		priority = 1000,
		opts = {},
		config = function(_, opts)
			require("nightfall").setup(opts)
			vim.cmd("colorscheme deeper-night") -- nightfall, deeper-night, maron, nord
		end,
	},
	{
		"LazyVim/LazyVim",
		opts = {
			colorscheme = "deeper-night",
		},
	},
}
