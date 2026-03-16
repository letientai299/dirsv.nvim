# dirsv.nvim

Neovim plugin for previewing files in the browser using [dirsv][dirsv]. Syncs
cursor position, selection, and scroll to the browser in real-time via
WebSocket.

dirsv serves any file type — markdown, diagrams (Mermaid, PlantUML, Graphviz),
code (100+ languages), JSON/YAML, images, videos, and more. See the [dirsv
README][dirsv] for the full list.

## Comparison

| Feature             | dirsv.nvim                            | [markdown-preview.nvim][mp] | [live-preview.nvim][lp] |
| ------------------- | ------------------------------------- | --------------------------- | ----------------------- |
| File types          | 100+ via dirsv                        | Markdown only               | MD, HTML, AsciiDoc, SVG |
| Cursor sync         | Yes                                   | No                          | No                      |
| Selection sync      | Yes (v, V, CTRL-V)                    | No                          | No                      |
| Scroll sync         | Yes                                   | Yes                         | Yes                     |
| Live reload on save | Yes (dirsv built-in)                  | Yes                         | Yes                     |
| Diagram support     | Mermaid, PlantUML, Graphviz, D2, DBML | Mermaid (via plugin)        | Mermaid                 |
| Math (KaTeX)        | Yes                                   | Yes (MathJax)               | Yes                     |
| External runtime    | `dirsv` binary                        | Node.js                     | None                    |
| Setup call needed   | No                                    | Yes                         | Yes                     |

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

No `setup()` call needed. Commands register globally on load.

## Commands

| Command         | Description                              |
| --------------- | ---------------------------------------- |
| `:Dirsv [path]` | Start dirsv and open a file or directory |
| `:DirsvStop`    | Stop all running dirsv servers           |
| `:DirsvLog`     | Open realtime communication log          |

`:Dirsv` accepts an optional file or directory path (tab-completed). When
omitted, it uses the current buffer. Calling `:Dirsv` while the server is
already running opens the target without restarting.

## Plugin buffer support

`:Dirsv` works from buffers owned by other plugins that use custom URI schemes.
The plugin resolves the real filesystem path automatically:

| Plugin                    | Buffer name                              | Resolved path         |
| ------------------------- | ---------------------------------------- | --------------------- |
| [oil.nvim][oil]           | `oil:///home/user/project/`              | `/home/user/project/` |
| [diffview.nvim][diffview] | `diffview:///repo/.git/:0:/src/main.lua` | `/repo/src/main.lua`  |
| [copilot.lua][copilot]    | `copilot:///home/user/file.lua`          | `/home/user/file.lua` |
| [gitsigns.nvim][gitsigns] | `gitsigns:///repo/.git//:0:src/main.lua` | `/repo/src/main.lua`  |
| [fugitive.vim][fugitive]  | `fugitive:///repo/.git//0/src/main.lua`  | `/repo/src/main.lua`  |

## Editor sync

The plugin tracks cursor movement, visual selection, and scroll position via
autocmds, then sends them to the browser over WebSocket at ~60fps (16ms
debounce). The browser highlights the current line, selection range, or viewport
accordingly.

Duplicate browser tabs are closed automatically before opening new ones for the
same file.

## Two server modes

The session root is determined once at startup: git toplevel from Neovim's
starting directory, or the starting directory itself if not in a git repo.

- **Root mode** — files under the root share a single global server. Efficient
  for navigating within a project.
- **Single-file mode** — files outside the root (temp files, scratch buffers)
  get a per-buffer server, cleaned up on `:bdelete`.

See `:help dirsv.nvim` for details.

## Development

```sh
mise install # install lua 5.1.5
mise setup   # install nlua + busted
mise test    # run tests
```

[dirsv]: https://github.com/letientai299/dirsv
[lazy]: https://github.com/folke/lazy.nvim
[plug]: https://github.com/junegunn/vim-plug
[mp]: https://github.com/iamcco/markdown-preview.nvim
[lp]: https://github.com/brianhuster/live-preview.nvim
[oil]: https://github.com/stevearc/oil.nvim
[diffview]: https://github.com/sindrets/diffview.nvim
[copilot]: https://github.com/zbirenbaum/copilot.lua
[gitsigns]: https://github.com/lewis6991/gitsigns.nvim
[fugitive]: https://github.com/tpope/vim-fugitive
