# dirsv.nvim

Neovim plugin for previewing files in the browser using [dirsv][dirsv]. Opens
the current file's URL, auto-detects the git root as the serve directory, and
finds a free port starting from 8080. Files outside the root get a dedicated
single-file server tied to the buffer.

## Requirements

- Neovim >= 0.10
- [dirsv][dirsv] in `$PATH`
- `git` in `$PATH` (optional — without it, root = Neovim's starting directory)

## Install

With [lazy.nvim][lazy]:

```lua
{ 'letientai299/dirsv.nvim' }
```

With [vim-plug][plug]:

```vim
Plug 'letientai299/dirsv.nvim'
```

No `setup()` call needed. Commands are registered globally on load.

## Commands

| Command         | Description                              |
| --------------- | ---------------------------------------- |
| `:Dirsv [path]` | Start dirsv and open a file or directory |
| `:DirsvStop`    | Stop all running dirsv servers           |

`:Dirsv` accepts an optional file or directory path (with tab completion). When
omitted, it uses the current buffer. Calling `:Dirsv` while the server is
already running opens the target without restarting.

The root is determined once at startup: git toplevel from Neovim's starting
directory, or the starting directory itself if not in a git repo. Files under
the root share a global server; files outside (temp files, scratch buffers) get
a per-buffer server cleaned up on `:bdelete`. See `:help dirsv-single-file`.

## Development

```sh
mise install   # install lua 5.1.5
mise setup     # install nlua + busted
mise test      # run tests
```

[dirsv]: https://github.com/letientai299/dirsv
[lazy]: https://github.com/folke/lazy.nvim
[plug]: https://github.com/junegunn/vim-plug
