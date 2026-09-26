" Ethereal colorscheme for Vim/Neovim
" Maintainer: Bjarne Øverli
" License: MIT

" Neovim-only Lua colorscheme
if !has('nvim')
  echohl ErrorMsg
  echom "ethereal.nvim requires Neovim"
  echohl None
  finish
endif

lua require('ethereal').load()