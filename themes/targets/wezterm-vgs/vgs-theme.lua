-- VGS generated wezterm colors.
-- Merge into your config: config.colors = dofile(wezterm.home_dir .. "/.config/wezterm/vgs-theme.lua").colors
return {
  colors = {
    foreground = "{foreground}",
    background = "{background}",
    cursor_bg = "{cursor}",
    cursor_fg = "{background}",
    cursor_border = "{cursor}",
    selection_fg = "{selection_foreground}",
    selection_bg = "{selection_background}",
    scrollbar_thumb = "{outline}",
    split = "{outlineVariant}",
    ansi = { "{terminal_color0}", "{terminal_color1}", "{terminal_color2}", "{terminal_color3}", "{terminal_color4}", "{terminal_color5}", "{terminal_color6}", "{terminal_color7}" },
    brights = { "{terminal_color8}", "{terminal_color9}", "{terminal_color10}", "{terminal_color11}", "{terminal_color12}", "{terminal_color13}", "{terminal_color14}", "{terminal_color15}" },
    tab_bar = {
      background = "{statusBg}",
      active_tab = { bg_color = "{accent}", fg_color = "{onPrimary}" },
      inactive_tab = { bg_color = "{surfaceContainer}", fg_color = "{muted}" },
      new_tab = { bg_color = "{statusBg}", fg_color = "{statusFg}" },
    },
  },
}
