-- Self-contained VGS colorscheme (Arc Blueberry), no external plugin. The
-- highlights live inside the LazyVim colorscheme function so the VGS bridge
-- activates them (a bare setup call + `return {}` is skipped by the bridge).
return {
	{
		"LazyVim/LazyVim",
		opts = {
			colorscheme = function()
				vim.cmd("hi clear")
				if vim.fn.exists("syntax_on") == 1 then
					vim.cmd("syntax reset")
				end
				vim.g.colors_name = "vgs-arc-blueberry"
				vim.opt.termguicolors = true

				local colors = {
					bg = "#111422",
					fg = "#bcc1dc",
					blue = "#69C3FF",
					green = "#3CEC85",
					yellow = "#EACD61",
					red = "#E35535",
					purple = "#F38CEC",
					cyan = "#22ECDB",
					subtle = "#1a1e33",
				}
				local set = vim.api.nvim_set_hl
				set(0, "Normal", { fg = colors.fg, bg = colors.bg })
				set(0, "Comment", { fg = colors.subtle, italic = true })
				set(0, "Constant", { fg = colors.red })
				set(0, "String", { fg = colors.green })
				set(0, "Identifier", { fg = colors.purple })
				set(0, "Function", { fg = colors.blue })
				set(0, "Statement", { fg = colors.yellow })
				set(0, "Type", { fg = colors.cyan })
				set(0, "Visual", { bg = colors.subtle })
				-- Treesitter links so modern highlighting follows the base groups.
				set(0, "@comment", { link = "Comment" })
				set(0, "@string", { link = "String" })
				set(0, "@constant", { link = "Constant" })
				set(0, "@function", { link = "Function" })
				set(0, "@keyword", { link = "Statement" })
				set(0, "@type", { link = "Type" })
				set(0, "@variable", { fg = colors.fg })
			end,
		},
	},
}
