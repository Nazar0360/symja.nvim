-- Standard Neovim install bootstrap. Lazy.nvim users can load the local plugin too.
if vim.g.loaded_symja_nvim then return end
vim.g.loaded_symja_nvim = true
require("symja").setup()
