-- VGS nvim bridge — lazy.nvim plugin spec for LazyVim setups.
--
-- Activates the current VGS theme in Neovim, preferring fidelity:
--   1. Curated themes install a colorscheme spec at
--      ~/.local/share/vshell/theme.nvim.spec.lua (e.g. tokyonight-night for
--      tokyo-night). If that colorscheme is available, it is activated and
--      lualine uses its own "auto" theme.
--   2. Otherwise (generated themes, or the plugin isn't installed) highlights
--      derive from the VGS role table at ~/.local/share/vshell/theme.nvim.lua
--      via base16, so colors still match the shell.
--   3. Without either file, Neovim keeps terminal ANSI colors.
--
-- Live reload: `vshell theme apply` triggers :VGSReloadTheme over nvim's RPC
-- sockets, and a file watcher covers nvim instances without a socket.
--
-- Usage: copy (or symlink) this file into your lazy.nvim plugins directory,
-- e.g. ~/.config/nvim/lua/plugins/vgs-theme.lua

local fallback = {
  bg = "#1a1b26",
  fg = "#c0caf5",
  black = "#15161e",
  red = "#f7768e",
  green = "#9ece6a",
  yellow = "#e0af68",
  blue = "#7aa2f7",
  magenta = "#bb9af7",
  cyan = "#7dcfff",
  white = "#a9b1d6",
  bright_black = "#414868",
  bright_red = "#ff7a93",
  bright_green = "#b9f27c",
  bright_yellow = "#ff9e64",
  bright_blue = "#7da6ff",
  bright_magenta = "#bb9af7",
  bright_cyan = "#0db9d7",
  bright_white = "#c0caf5",
  accent = "#7aa2f7",
  on_primary = "#1a1b26",
  selection_bg = "#414868",
  selection_fg = "#c0caf5",
}

local function channel(hex, offset)
  return tonumber((hex or ""):sub(offset, offset + 1), 16) or 0
end

local function rel_luminance(hex)
  local function linear(v)
    v = v / 255
    if v <= 0.03928 then
      return v / 12.92
    end
    return ((v + 0.055) / 1.055) ^ 2.4
  end
  local r = linear(channel(hex, 2))
  local g = linear(channel(hex, 4))
  local b = linear(channel(hex, 6))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local function contrast_ratio(a, b)
  local la = rel_luminance(a)
  local lb = rel_luminance(b)
  if la < lb then
    la, lb = lb, la
  end
  return (la + 0.05) / (lb + 0.05)
end

local function readable_on(bg)
  if contrast_ratio(bg, "#ffffff") >= contrast_ratio(bg, "#000000") then
    return "#ffffff"
  end
  return "#000000"
end

local function enrich(colors)
  local c = vim.tbl_extend("force", {}, colors or {})
  for key, value in pairs(fallback) do
    c[key] = c[key] or value
  end
  c.surface = c.surface or c.bg
  c.surface_container_low = c.surface_container_low or c.surface
  c.surface_container = c.surface_container or c.surface_container_low
  c.surface_container_high = c.surface_container_high or c.surface_container
  c.surface_container_highest = c.surface_container_highest or c.surface_container_high
  c.outline = c.outline or c.bright_black
  c.outline_variant = c.outline_variant or c.surface_container_high
  c.muted = c.muted or c.white
  c.dim = c.dim or c.muted
  c.error = c.error or c.red
  c.warning = c.warning or c.yellow
  c.success = c.success or c.green
  c.info = c.info or c.blue
  c.status_bg = c.status_bg or c.surface_container_highest
  c.status_fg = c.status_fg or c.fg
  c.status_muted = c.status_muted or c.muted
  c.status_accent = c.status_accent or c.accent
  c.status_error = c.status_error or c.error
  c.status_warning = c.status_warning or c.warning
  c.status_success = c.status_success or c.success
  c.status_info = c.status_info or c.info
  c.on_primary = c.on_primary or readable_on(c.accent)
  return c
end

local vgs_state_dir = vim.fs.joinpath(vim.env.HOME, ".local/share/vshell")
local vgs_theme_path = vim.fs.joinpath(vgs_state_dir, "theme.nvim.lua")
local vgs_spec_path = vim.fs.joinpath(vgs_state_dir, "theme.nvim.spec.lua")

-- Directory this bridge file lives in, so colorschemes vendored beside it
-- (colorschemes/<name>) resolve regardless of where VGS is installed. Themes
-- reference a vendored colorscheme by `vgs_vendored = "<dir-name>"` in their
-- spec instead of an "owner/repo" GitHub plugin, so nvim has no external plugin
-- dependency.
local vgs_bridge_dir = (debug.getinfo(1, "S").source:sub(2):match("(.*/)")) or "./"
local vgs_colorschemes_dir = vgs_bridge_dir .. "colorschemes/"

local function read_vgs_colors()
  local ok, colors = pcall(dofile, vgs_theme_path)
  if ok and type(colors) == "table" then
    return enrich(colors)
  end
  return enrich({})
end

local function spec_colorscheme_name()
  local ok, spec = pcall(dofile, vgs_spec_path)
  if not ok or type(spec) ~= "table" then
    return nil
  end
  -- Curated specs are lazy fragments; the LazyVim entry names
  -- the colorscheme. Fall back to any entry carrying opts.colorscheme.
  for _, entry in ipairs(spec) do
    if type(entry) == "table" and type(entry.opts) == "table" and type(entry.opts.colorscheme) == "string" then
      return entry.opts.colorscheme
    end
  end
  return nil
end

-- Some curated themes have no published colorscheme plugin; their upstream
-- package bundles the colorscheme inline, so the spec's LazyVim entry carries a
-- FUNCTION colorscheme that sets highlights directly (e.g. akane, ember-n-ash).
-- Return it so reload can invoke it instead of falling back to base16 roles.
local function spec_colorscheme_fn()
  local ok, spec = pcall(dofile, vgs_spec_path)
  if not ok or type(spec) ~= "table" then
    return nil
  end
  for _, entry in ipairs(spec) do
    if type(entry) == "table" and type(entry.opts) == "table" and type(entry.opts.colorscheme) == "function" then
      return entry.opts.colorscheme
    end
  end
  return nil
end

-- Some colorschemes are shared across many curated themes and take the theme's
-- palette via opts.colors; they must be re-configured when the VGS theme
-- changes. lazy only runs setup() once at load, so on a live theme switch we
-- re-invoke the plugin's setup with the new spec's opts before applying the
-- colorscheme, else the previous theme's palette sticks.
local function spec_plugin_setup()
  local ok, spec = pcall(dofile, vgs_spec_path)
  if not ok or type(spec) ~= "table" then
    return nil
  end
  for _, entry in ipairs(spec) do
    if type(entry) == "table" and type(entry.opts) == "table" then
      local repo = entry[1]
      local vendored = entry.vgs_vendored
      local mod = entry.name
      if (type(vendored) == "string" and vendored ~= "")
        or (type(repo) == "string" and repo:find("/", 1, true) and repo ~= "LazyVim/LazyVim") then
        if type(mod) ~= "string" or mod == "" then
          local base = vendored or repo
          mod = base:match("([^/]+)$")
          if mod then
            mod = mod:gsub("%.nvim$", "")
          end
        end
        if mod and mod ~= "" then
          return { module = mod, opts = entry.opts }
        end
      end
    end
  end
  return nil
end

-- Pull the curated colorscheme plugin(s) out of the spec so lazy.nvim actually
-- installs them. Without this the spec only tells us the colorscheme *name*;
-- the plugin providing it is never added to lazy, so `colorscheme <name>` fails
-- and Neovim silently falls back to base16 roles. We force lazy=false +
-- priority so the colorscheme is loaded and available when the theme applies.
-- (Switching to a colorscheme not yet installed installs it on the next nvim
-- launch; already-installed ones switch live via the file watcher.)
local function spec_plugins()
  local ok, spec = pcall(dofile, vgs_spec_path)
  if not ok or type(spec) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(spec) do
    if type(entry) == "table" then
      -- Preferred form: a colorscheme vendored into VGS. `vgs_vendored` names a
      -- directory under colorschemes/; resolve it to a local `dir` plugin so
      -- lazy loads it with no GitHub dependency. Preserve opts (palette) etc.
      local vendored = entry.vgs_vendored
      if type(vendored) == "string" and vendored ~= "" then
        local plugin = {}
        for k, v in pairs(entry) do
          if k ~= 1 and k ~= "vgs_vendored" then
            plugin[k] = v
          end
        end
        plugin.dir = vgs_colorschemes_dir .. vendored
        plugin.lazy = false
        plugin.priority = plugin.priority or 1000
        out[#out + 1] = plugin
      else
        local repo = entry[1]
        -- Copy the full external-plugin specification to retain palette options
        -- and version pins.
        if type(repo) == "string" and repo:find("/", 1, true) and repo ~= "LazyVim/LazyVim" then
          local plugin = {}
          for k, v in pairs(entry) do
            plugin[k] = v
          end
          plugin.lazy = false
          plugin.priority = 1000
          out[#out + 1] = plugin
        end
      end
    end
  end
  return out
end

local function set_hl(name, spec)
  vim.api.nvim_set_hl(0, name, spec)
end

local function apply_vgs_colors()
  local c = read_vgs_colors()
  require("base16-colorscheme").setup({
    base00 = c.bg,
    base01 = c.surface_container_low,
    base02 = c.surface_container_high,
    base03 = c.muted,
    base04 = c.dim,
    base05 = c.fg,
    base06 = c.fg,
    base07 = c.bright_white,
    base08 = c.error,
    base09 = c.warning,
    base0A = c.warning,
    base0B = c.success,
    base0C = c.info,
    base0D = c.accent,
    base0E = c.magenta,
    base0F = c.muted,
  })

  set_hl("Normal", { fg = c.fg, bg = "NONE" })
  set_hl("NormalNC", { fg = c.fg, bg = "NONE" })
  set_hl("NormalFloat", { fg = c.fg, bg = c.surface_container })
  set_hl("FloatBorder", { fg = c.outline, bg = c.surface_container })
  set_hl("SignColumn", { fg = c.muted, bg = "NONE" })
  set_hl("LineNr", { fg = c.muted, bg = "NONE" })
  set_hl("CursorLine", { bg = c.surface_container_low })
  set_hl("CursorLineNr", { fg = c.accent, bg = c.surface_container_low, bold = true })
  set_hl("Visual", { bg = c.selection_bg, fg = c.selection_fg })
  set_hl("Search", { bg = c.warning, fg = c.bg })
  set_hl("IncSearch", { bg = c.accent, fg = c.on_primary })
  set_hl("Pmenu", { fg = c.fg, bg = c.surface_container })
  set_hl("PmenuSel", { fg = c.selection_fg, bg = c.selection_bg })
  set_hl("WinSeparator", { fg = c.outline_variant, bg = "NONE" })
  set_hl("EndOfBuffer", { fg = c.surface_container_high, bg = "NONE" })
  set_hl("StatusLine", { bg = c.status_bg, fg = c.status_fg })
  set_hl("StatusLineNC", { bg = c.status_bg, fg = c.status_muted })
end

local function lualine_theme()
  local c = read_vgs_colors()
  local active = {
    a = { bg = c.accent, fg = c.on_primary, gui = "bold" },
    b = { bg = c.status_bg, fg = c.status_fg },
    c = { bg = c.status_bg, fg = c.status_fg },
  }
  return {
    normal = active,
    insert = active,
    visual = active,
    replace = active,
    command = active,
    terminal = active,
    inactive = {
      a = { bg = c.status_bg, fg = c.status_muted },
      b = { bg = c.status_bg, fg = c.status_muted },
      c = { bg = c.status_bg, fg = c.status_muted },
    },
  }
end

local vgs_spec_active = false

local function current_lualine_theme()
  -- A real colorscheme brings its own lualine palette; VGS roles otherwise.
  if vgs_spec_active then
    return "auto"
  end
  return lualine_theme()
end

local function refresh_lualine_theme()
  -- Never require() here: during LazyVim's colorscheme phase that force-loads
  -- lualine before the Snacks/LazyVim globals its opts need exist. If lualine
  -- is not loaded yet, its own spec below applies current_lualine_theme() on load.
  local lualine = package.loaded["lualine"]
  if not lualine then
    return
  end
  local config = {}
  if type(lualine.get_config) == "function" then
    config = lualine.get_config() or {}
  end
  config.options = config.options or {}
  config.options.theme = current_lualine_theme()
  config.options.globalstatus = true
  lualine.setup(config)
end

local vgs_theme_watcher
local vgs_theme_timer

local function reload_vgs_theme()
  vgs_spec_active = false
  local name = spec_colorscheme_name()
  if name then
    -- Re-configure an opts-driven shared colorscheme with the
    -- current theme's palette before applying it, so live switches take effect.
    local ps = spec_plugin_setup()
    if ps then
      pcall(function()
        require(ps.module).setup(ps.opts)
      end)
    end
    vgs_spec_active = pcall(vim.cmd.colorscheme, name)
  end
  if not vgs_spec_active then
    -- No named colorscheme (or its plugin isn't installed yet): try an inline
    -- function colorscheme bundled by the theme before giving up to roles.
    local fn = spec_colorscheme_fn()
    if fn then
      vgs_spec_active = pcall(fn)
    end
  end
  if not vgs_spec_active then
    apply_vgs_colors()
  end
  refresh_lualine_theme()
  if type(_G.VGSApplyTransparency) == "function" then
    pcall(_G.VGSApplyTransparency)
  end
end

local function setup_vgs_theme_reload()
  if vim.g.vgs_theme_reload_setup then
    return
  end
  vim.g.vgs_theme_reload_setup = true

  vim.api.nvim_create_user_command("VGSReloadTheme", reload_vgs_theme, {})

  local uv = vim.uv or vim.loop
  if not (uv and uv.new_fs_event) then
    return
  end

  vgs_theme_watcher = uv.new_fs_event()
  vgs_theme_timer = uv.new_timer()
  vgs_theme_watcher:start(vgs_state_dir, {}, vim.schedule_wrap(function(err, filename)
    if err or (filename ~= "theme.nvim.lua" and filename ~= "theme.nvim.spec.lua") then
      return
    end
    vgs_theme_timer:stop()
    vgs_theme_timer:start(80, 0, vim.schedule_wrap(reload_vgs_theme))
  end))
end

local function setup_vgs_theme()
  reload_vgs_theme()
  setup_vgs_theme_reload()
end

local plugins = {
  {
    "RRethy/base16-nvim",
    priority = 1000,
    config = setup_vgs_theme,
  },
  { "LazyVim/LazyVim", opts = { colorscheme = setup_vgs_theme } },
  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.theme = current_lualine_theme()
      opts.options.globalstatus = true
    end,
  },
}

-- Include curated plugins so lazy can load the named colorscheme.
-- Absent specifications retain the role-based fallback.
for _, plugin in ipairs(spec_plugins()) do
  plugins[#plugins + 1] = plugin
end

return plugins
