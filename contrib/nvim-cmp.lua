-- Optional nvim-cmp integration. Safe to load even when nvim-cmp is absent.
-- Symja registers its source and appends it to the existing global source list;
-- the source itself is available only in .symja/.mma/.wl/.wls buffers.
if not pcall(require, "cmp") then return end
require("symja").register_cmp()
