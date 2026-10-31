-- Copy this file to lua/plugins/symja.lua in your Neovim config.
return {
  {
    "Nazar0360/symja.nvim",
    name = "symja.nvim",
    -- Load at startup so :Symja* commands are available immediately.
    lazy = false,
    -- Uses Maven Central by default. Set SYMJA_HOME before launching Neovim
    -- to build against an extracted Symja apps bundle instead.
    build = "./backend/build.sh",
    -- No hard Neovim-plugin dependencies. Optional integrations are detected
    -- independently (nvim-cmp, Comment.nvim, vim-closer, image.nvim).
    config = function()
      local symja = require("symja")
      symja.setup({
        symja_version = vim.env.SYMJA_VERSION or "3.1.1",
        symja_home = vim.env.SYMJA_HOME,
        symja_lib_dir = vim.env.SYMJA_LIB_DIR,
      })

      if pcall(require, "cmp") then
        symja.register_cmp()
      end
    end,
  },
}
