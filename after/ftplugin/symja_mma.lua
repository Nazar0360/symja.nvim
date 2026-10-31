-- Keep Neovim's native gc mapping and Comment.nvim on the Mathematica comment syntax.
vim.bo.commentstring = "(* %s *)"
vim.bo.comments = "s1:(*,mb:*,ex:*)"

-- vim-closer enables bracket expansion only for its built-in filetypes.
-- Advertise the delimiters used by Symja and Mathematica so pressing Enter
-- after an unmatched opener inserts its matching closer. This is independent
-- of Tree-sitter; vim-closer scans the current line itself.
vim.b.closer_flags = "([{"
