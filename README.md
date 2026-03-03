# dirsv.nvim

Neovim plugin for previewing markdown files in the browser using [dirsv][dirsv].
Opens the current file's URL, auto-detects the git root as the serve directory,
and finds a free port starting from 8080.

## Requirements

- Neovim >= 0.10
- [dirsv][dirsv] in `$PATH`

## Install

With [lazy.nvim][lazy]:

```lua
{ 'taishib/dirsv.nvim' }
```

No `setup()` call needed. The plugin registers buffer-local commands on
`FileType markdown` automatically.

## Commands

| Command              | Description                               |
| -------------------- | ----------------------------------------- |
| `:MarkdownPreview`     | Start dirsv and open the file in a browser |
| `:MarkdownPreviewStop` | Stop the running dirsv server             |

Calling `:MarkdownPreview` while the server is already running opens the current
file without restarting.

## Development

```sh
mise install   # install lua 5.1.5
mise setup     # install nlua + busted
mise test      # run tests
```

[dirsv]: https://github.com/taishib/dirsv
[lazy]: https://github.com/folke/lazy.nvim
