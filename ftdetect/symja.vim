augroup symja_filetype
  autocmd!
  autocmd BufRead,BufNewFile *.symja setfiletype symja
  autocmd BufRead,BufNewFile *.mma,*.wl,*.wls setfiletype symja_mma
augroup END
