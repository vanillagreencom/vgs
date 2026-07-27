local colors = require("aether.colorscheme")

return {
  normal = {
    a = { bg = colors.yellow, fg = colors.darker_bg, gui = "bold" },
    b = { bg = colors.dark_bg, fg = colors.yellow },
    c = { bg = colors.bg, fg = colors.fg },
    x = { bg = colors.bg, fg = colors.fg },
  },
  insert = {
    a = { bg = colors.green, fg = colors.darker_bg, gui = "bold" },
    b = { bg = colors.dark_bg, fg = colors.green },
  },
  command = {
    a = { bg = colors.orange, fg = colors.darker_bg, gui = "bold" },
    b = { bg = colors.dark_bg, fg = colors.orange },
  },
  visual = {
    a = { bg = colors.bright_purple, fg = colors.darker_bg, gui = "bold" },
    b = { bg = colors.dark_bg, fg = colors.bright_purple },
  },
  replace = {
    a = { bg = colors.bright_red, fg = colors.darker_bg, gui = "bold" },
    b = { bg = colors.dark_bg, fg = colors.bright_red },
  },
  inactive = {
    a = { bg = colors.dark_bg, fg = colors.muted },
    b = { bg = colors.bg, fg = colors.muted },
  },
}
