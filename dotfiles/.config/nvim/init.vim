set mouse=

let mapleader=" "

noremap <Leader>y "+y
noremap <Leader>p "+p

set incsearch

call plug#begin()

" List your plugins here
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

call plug#end()

" fzf vim
nnoremap <C-p> :Files<CR>
nnoremap <C-l> :Rg<CR>
