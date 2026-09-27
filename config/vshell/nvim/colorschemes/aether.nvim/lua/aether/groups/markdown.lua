-- Markdown plugin support for Aether colorscheme
local M = {}

---@type aether.HighlightsFn
function M.get(c, opts)
  -- stylua: ignore
  return {
    -- Headings
    ["@markup.heading.1.markdown"] = { fg = c.bright_red, bold = true },
    ["@markup.heading.2.markdown"] = { fg = c.orange, bold = true },
    ["@markup.heading.3.markdown"] = { fg = c.yellow, bold = true },
    ["@markup.heading.4.markdown"] = { fg = c.green, bold = true },
    ["@markup.heading.5.markdown"] = { fg = c.blue, bold = true },
    ["@markup.heading.6.markdown"] = { fg = c.bright_purple, bold = true },

    -- Text styles
    ["@markup.strong"]       = { bold = true },
    ["@markup.italic"]       = { italic = true },
    ["@markup.strikethrough"] = { strikethrough = true },
    ["@markup.underline"]    = { underline = true },

    -- Links and references
    ["@markup.link"]         = { fg = c.blue, underline = true },
    ["@markup.link.url"]     = { fg = c.cyan, underline = true },
    ["@markup.link.label"]   = { fg = c.blue },

    -- Code blocks
    ["@markup.raw"]          = { fg = c.green },
    ["@markup.raw.block"]    = { fg = c.fg },

    -- Lists
    ["@markup.list"]         = { fg = c.cyan },
    ["@markup.list.checked"] = { fg = c.green },
    ["@markup.list.unchecked"] = { fg = c.dark_fg },

    -- Quotes
    ["@markup.quote"]        = { fg = c.muted, italic = true },

    -- Math
    ["@markup.math"]         = { fg = c.orange },
  }
end

return M
