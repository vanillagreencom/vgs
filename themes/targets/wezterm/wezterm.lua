-- The vgs theme for WezTerm, run by the line vgsh theme apply keeps first in
-- wezterm.lua. WezTerm has no include directive, so the theme wraps
-- wezterm.config_builder: a config it builds starts on the vgs colour
-- scheme, and every setting wezterm.lua makes on it afterwards overrides it.
local wezterm = require 'wezterm'
local build = wezterm.config_builder
if build then
  function wezterm.config_builder()
    local config = build()
    config.color_schemes = {
      vgs = {
        foreground = '#@{palette.foreground}',
        background = '#@{palette.background}',
        cursor_bg = '#@{palette.foreground}',
        cursor_fg = '#@{palette.background}',
        cursor_border = '#@{palette.foreground}',
        selection_fg = '#@{palette.foreground}',
        selection_bg = '#@{color.borderStrong}',
        ansi = { '#@{terminal.color0}', '#@{terminal.color1}', '#@{terminal.color2}', '#@{terminal.color3}', '#@{terminal.color4}', '#@{terminal.color5}', '#@{terminal.color6}', '#@{terminal.color7}' },
        brights = { '#@{terminal.color8}', '#@{terminal.color9}', '#@{terminal.color10}', '#@{terminal.color11}', '#@{terminal.color12}', '#@{terminal.color13}', '#@{terminal.color14}', '#@{terminal.color15}' },
      },
    }
    config.color_scheme = 'vgs'
    return config
  end
end
