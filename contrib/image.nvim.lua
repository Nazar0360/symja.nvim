-- Optional image display for Symja's LaTeX results.
-- Copy this as lua/plugins/image.lua, or merge the opts into an existing
-- 3rd/image.nvim spec. It is deliberately not a dependency of symja.nvim.
return {
  {
    "3rd/image.nvim",
    build = false,
    opts = {
      backend = "kitty",
      processor = "magick_cli",
      integrations = {
        markdown = { enabled = false },
        asciidoc = { enabled = false },
        typst = { enabled = false },
        neorg = { enabled = false },
        syslang = { enabled = false },
        html = { enabled = false },
        css = { enabled = false },
        org = { enabled = false },
      },
    },
  },
}
