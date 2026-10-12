" ============================================================================
"  通用 Vim 配置（系统级）—— 安装位置：/etc/vim/vimrc.local
"  由 setup_vimrc.sh 自动部署；被各发行版的 system vimrc 在启动时 source，
"  因此对系统上所有用户生效。用户可在 ~/.vimrc 中覆盖任意设置。
"
"  适用：Vim 7.4+ / Vim 8 / Vim 9 / Neovim
"  发行版：Debian/Ubuntu/Kali/Deepin/UOS、RHEL/CentOS/Fedora/Rocky/Alma/
"          openEuler/麒麟/Anolis、Arch/Manjaro、openSUSE/SLES、Alpine
" ============================================================================

" ---------------------------------------------------------------------------
" 0. 前置保护
" ---------------------------------------------------------------------------
" vim-tiny / 精简版（无 +eval 或 +syntax）功能太弱，降级为最基本设置后退出，
" 避免 :if / has() 之类不可用时刷屏报错。请安装完整版 vim 以启用全部功能。
if exists('*has') && (!has('eval') || !has('syntax'))
  set nocompatible
  set number
  set backspace=indent,eol,start
  finish
endif

if &compatible
  set nocompatible
endif

" ---------------------------------------------------------------------------
" 1. 行号 / 光标 / 滚动
" ---------------------------------------------------------------------------
set number                  " 显示绝对行号
set relativenumber          " 显示相对行号（5j / 12k 跳转更直观）
set cursorline              " 高亮当前行
set nocursorcolumn          " 不整列高亮光标所在列（终端下是一道贯穿竖带，太抢眼）
                            " 想开启可改为 set cursorcolumn
set scrolloff=5             " 光标上下各保留 5 行上下文
set sidescrolloff=8
set wrap                    " 超长行自动折行
set linebreak               " 折行按单词边界，不切断单词
set listchars=tab:>\ ,trail:.,extends:>,precedes:<,nbsp:+
set nolist                  " 默认不显示不可见字符（:set list 手动开）

" ---------------------------------------------------------------------------
" 2. 高亮配色（按终端明暗自动切换，兼容 256 色）
" ---------------------------------------------------------------------------
if &background ==# 'dark'
  highlight CursorLine    cterm=NONE ctermbg=236 guibg=#2d2d2d
  highlight CursorLineNr  cterm=bold ctermfg=214 gui=bold guifg=#ffaf00
  highlight LineNr        ctermfg=243 guifg=#6c6c6c
  highlight NonText       ctermfg=238 guifg=#4a4a4a
  highlight VertSplit     cterm=NONE ctermfg=240 guifg=#4e4e4e
else
  highlight CursorLine    cterm=NONE ctermbg=253 guibg=#e8e8e8
  highlight CursorLineNr  cterm=bold ctermfg=130 gui=bold guifg=#af5f00
  highlight LineNr        ctermfg=246 guifg=#8a8a8a
  highlight NonText       ctermfg=250 guifg=#bcbcbc
  highlight VertSplit     cterm=NONE ctermfg=250 guifg=#c6c6c6
endif
" CursorColumn 已停用（见 §1）；此处清掉底色，避免残留访客主题留下竖带
highlight CursorColumn  cterm=NONE ctermbg=NONE guibg=NONE
highlight Search        cterm=reverse ctermfg=16 ctermbg=214 gui=reverse
highlight IncSearch     cterm=reverse ctermfg=16 ctermbg=199 gui=reverse
highlight Visual        cterm=NONE ctermbg=237 guibg=#3a3a3a
highlight MatchParen    cterm=bold ctermfg=16 ctermbg=51 gui=bold
highlight ColorColumn   cterm=NONE ctermbg=236 guibg=#2d2d2d
set colorcolumn=100         " 100 列参考线（不需要可 set colorcolumn=）

" ---------------------------------------------------------------------------
" 3. 缩进与制表符（通用默认 4 空格；各语言在 §7 覆盖）
" ---------------------------------------------------------------------------
set expandtab               " Tab 展开为空格
set shiftwidth=4
set tabstop=4
set softtabstop=4
set shiftround
set autoindent              " 新行继承上一行缩进
set smartindent
set copyindent
set preserveindent
set backspace=indent,eol,start

" ---------------------------------------------------------------------------
" 4. 搜索
" ---------------------------------------------------------------------------
set incsearch               " 边输入边高亮
set hlsearch                " 高亮全部匹配
set ignorecase              " 忽略大小写……
set smartcase               " ……但含大写时区分大小写
set wrapscan
set gdefault                " :s 默认替换行内全部匹配
if has('nvim')
  set inccommand=nosplit    " Neovim：实时预览替换结果
endif

" ---------------------------------------------------------------------------
" 5. 界面 / 状态栏
" ---------------------------------------------------------------------------
set showcmd
set showmode
set ruler
set laststatus=2            " 总是显示状态栏
set statusline=%<%f\ %h%m%r%=\ [%{&fileformat}][%{&fileencoding}][%{&filetype}]\ %l/%L:%c\ %P
set wildmenu
set wildmode=longest:full,full
set wildignore=*.o,*.obj,*.pyc,*.class,*.swp,*.bak,*.zip,*.tar,*.gz,*/node_modules/*,*/__pycache__/*,*/.git/*
set completeopt=menuone,noinsert,noselect
set noerrorbells
if !has('nvim')
  set visualbell
  set t_vb=
endif
set timeoutlen=500
set ttimeoutlen=50          " 终端下 Esc 更跟手
set updatetime=300
set history=1000
set confirm
set hidden
set autoread                " 外部修改后自动重载
let g:netrw_banner = 0

" ---------------------------------------------------------------------------
" 6. 编码 / 换行符（中文环境防乱码）
" ---------------------------------------------------------------------------
set encoding=utf-8
if !has('nvim')
  set termencoding=utf-8
endif
set fileencodings=ucs-bom,utf-8,gb18030,gbk,big5,latin1
set fileformats=unix,dos,mac
set ambiwidth=double        " 全角字符按双宽显示，避免错位

" ---------------------------------------------------------------------------
" 7. 按文件类型（后缀）差异化配置 —— 语法高亮 / 缩进 / 换行
" ---------------------------------------------------------------------------
filetype plugin indent on
syntax enable

augroup WorkBuddyFileType
  autocmd!
  " ---- 空格缩进 ----
  autocmd FileType python,cython,pyrex  setlocal expandtab shiftwidth=4 tabstop=4 softtabstop=4 textwidth=0
  autocmd FileType ruby,eruby           setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType sh,bash,zsh,ksh      setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType dockerfile           setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType yaml,yml,json,jsonc  setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType html,xhtml,xml,css,scss,less,vue,svelte
        \ setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType javascript,typescript,javascriptreact,typescriptreact
        \ setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType lua,vim,perl,tcl,sql setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  " ---- 必须用 Tab 的 ----
  autocmd FileType go                   setlocal noexpandtab shiftwidth=4 tabstop=4 softtabstop=4
  autocmd FileType make,makefile        setlocal noexpandtab tabstop=8 shiftwidth=8 softtabstop=0
  " ---- C 系 ----
  autocmd FileType c,cpp,objc,objcpp,cs,java,rust
        \ setlocal expandtab shiftwidth=4 tabstop=4 softtabstop=4 cindent
  " ---- 文本类 ----
  autocmd FileType markdown,text,gitcommit
        \ setlocal wrap linebreak spell spelllang=en_us nolist
  autocmd FileType tex                  setlocal wrap linebreak expandtab shiftwidth=2
  " ---- 特殊缓冲 ----
  autocmd FileType help,qf,man          setlocal nonumber norelativenumber nocursorline
augroup END

" 补充后缀映射：部分发行版自带 filetype.vim 较旧，按后缀/文件名兜底识别
augroup WorkBuddyFileExt
  autocmd!
  autocmd BufNewFile,BufRead *.conf,*.cfg,*.ini,*.toml,*.properties,*.env,*.service,*.repo setfiletype conf
  autocmd BufNewFile,BufRead *.md,*.markdown                                             setfiletype markdown
  autocmd BufNewFile,BufRead *.tpl,*.j2,*.jinja2,*.yaml.j2                               setfiletype yaml
  autocmd BufNewFile,BufRead *.ts,*.tsx                                                  setfiletype typescript
  autocmd BufNewFile,BufRead *.vue                                                       setfiletype vue
  autocmd BufNewFile,BufRead Dockerfile*,*.dockerfile,Containerfile*                     setfiletype dockerfile
  autocmd BufNewFile,BufRead Jenkinsfile,Vagrantfile,Berksfile                           setfiletype groovy
  autocmd BufNewFile,BufRead *.rasi,*.sls                                                setfiletype yaml
  autocmd BufNewFile,BufRead .bashrc,.bash_profile,.bash_aliases,.profile,.zshrc  setfiletype sh
  autocmd BufNewFile,BufRead .gitconfig,.gitignore                                       setfiletype gitconfig
augroup END

" ---------------------------------------------------------------------------
" 8. 撤销历史 / 备份 / 交换文件（统一收纳到 ~/.vim，首次自动创建）
" ---------------------------------------------------------------------------
silent! call mkdir(expand('~/.vim/undo'),   'p', 0700)
silent! call mkdir(expand('~/.vim/backup'), 'p', 0700)
silent! call mkdir(expand('~/.vim/swap'),   'p', 0700)

set backup
set writebackup
set backupext=.bak
let &backupdir = expand('~/.vim/backup') . '//'
let &directory = expand('~/.vim/swap')   . '//'
if has('persistent_undo')
  set undofile               " 关闭文件后仍可撤销
  let &undodir = expand('~/.vim/undo') . '//'
  set undolevels=1000
endif

" ---------------------------------------------------------------------------
" 9. 自动命令：记忆光标位置 / 外部改动检测
" ---------------------------------------------------------------------------
augroup WorkBuddyAutoCmd
  autocmd!
  " 恢复上次编辑位置
  autocmd BufReadPost *
        \ if line("'\"") > 0 && line("'\"") <= line("$") |
        \   execute 'normal! g`"' |
        \ endif
  " 切回终端时检查文件是否被外部修改
  autocmd FocusGained,BufEnter,CursorHold,CursorHoldI *
        \ if mode() =~# '^[nV]' | silent! checktime | endif
  " 新建文件不自动插入注释头
  autocmd BufNewFile * setlocal noformatoptions
augroup END

" ---------------------------------------------------------------------------
" 10. 快捷键（leader = 逗号）
" ---------------------------------------------------------------------------
let mapleader = ','
let maplocalleader = '\\'

nnoremap <silent> <leader>w :update<CR>
nnoremap <silent> <leader>q :q<CR>
nnoremap <silent> <leader>Q :qa!<CR>
cnoremap w!! w !sudo tee % >/dev/null<CR>      " 以 sudo 权限保存只读文件

nnoremap <silent> <leader>h :nohlsearch<CR>                            " 清搜索高亮
nnoremap <silent> <leader>n :setlocal number! relativenumber!<CR>      " 切行号
nnoremap <silent> <leader>z :setlocal wrap!<CR>                        " 切折行

nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l
nnoremap <silent> <C-Up>    :resize +2<CR>
nnoremap <silent> <C-Down>  :resize -2<CR>
nnoremap <silent> <C-Left>  :vertical resize -2<CR>
nnoremap <silent> <C-Right> :vertical resize +2<CR>

vnoremap < <gv                                 " 缩进后保持选中
vnoremap > >gv
nnoremap Y y$
nnoremap n nzzzv                               " n/N 结果居中
nnoremap N Nzzzv
nnoremap <A-j> :m .+1<CR>==                    " 上下移动当前行
nnoremap <A-k> :m .-2<CR>==
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" ---------------------------------------------------------------------------
" 11. 鼠标 / 剪贴板 / 真彩色（能力检测，缺失时自动跳过）
" ---------------------------------------------------------------------------
if has('mouse')
  set mouse=a                " 需要选择复制时按住 Shift 拖选
endif
if has('nvim')
  set clipboard=unnamedplus
elseif has('clipboard')
  set clipboard=unnamed      " ssh 下可能略慢，可注释掉
endif
if has('termguicolors')
  set termguicolors
endif

" ---------------------------------------------------------------------------
" 12. 配色主题（存在则启用，否则静默跳过）
" ---------------------------------------------------------------------------
" silent! colorscheme torte
silent! colorscheme desert
" 想要更暗： silent! colorscheme torte
" 想要浅色： silent! colorscheme morning
