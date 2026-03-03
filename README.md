# dirsv.nvim

Neovim plugin for previewing files in the browser using [dirsv][dirsv]. Opens
the current file's URL, auto-detects the git root as the serve directory, and
finds a free port starting from 8080.

## Requirements

- Neovim >= 0.10
- [dirsv][dirsv] in `$PATH`

## Install

With [lazy.nvim][lazy]:

```lua
{ 'taishib/dirsv.nvim' }
```

No `setup()` call needed. Commands are registered globally on load.

## Commands

| Command      | Description                               |
| ------------ | ----------------------------------------- |
| `:Dirsv`     | Start dirsv and open the file in a browser |
| `:DirsvStop` | Stop the running dirsv server             |

Calling `:Dirsv` while the server is already running opens the current file
without restarting.

## Development

```sh
mise install   # install lua 5.1.5
mise setup     # install nlua + busted
mise test      # run tests
```

[dirsv]: https://github.com/taishib/dirsv
[lazy]: https://github.com/folke/lazy.nvim
