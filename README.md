# jjdiff.nvim

A zero-dependency Neovim `0.12+` plugin for Jujutsu (`jj`) that toggles an in-buffer diff HUD with `<leader>jj`.

## Features

- **Right-Extended Number Ribbon (`statuscolumn`)**: Preserves `set nu` line numbers on the left and extends a color-coded rail between line numbers and buffer text:
  - Green (`┃`) for added lines
  - Amber (`┃`) for modified lines
  - Crimson (`·· ▎`) for deleted virtual ghost lines
- **Virtual Red Deleted Ghost Lines (`virt_lines`)**: Deleted lines appear inline as non-editable red virtual lines without shifting real line numbers.
- **Inline Word-Diff (`--color-words` style)**: Paired modified lines highlight deleted tokens in red strikethrough (`virt_text_pos = "inline"`) and added tokens in green.
- **Off-Screen Radar Bars (`▲` / `▼`)**: Auto-hiding 1-row top and bottom window overlays show styled pills for off-screen hunks with exact **cursor-relative distances** (`▲ 19 ±2`, `▼ 12 +4`, `▼ 26 -3`) — type `26j` or `19k` to jump directly onto a hunk.
- **Saved-State Safety**: Refuses to activate if the buffer has unsaved edits, prompting you to `:w` first; auto-refreshes on `:w`.

## Requirements

- Neovim `>= 0.12`
- Jujutsu (`jj`) available in `PATH`

## Installation (`lazy.nvim`)

Default setup (uses built-in defaults automatically):

```lua
{
  "vgaspary/jjdiff",
}
```

With custom configuration (and optional lazy-loading on key/command):

```lua
{
  "vgaspary/jjdiff",
  cmd = "JJDiff",
  keys = {
    { "<leader>jj", "<Plug>(JJDiffToggle)", desc = "Toggle jj diff HUD" },
  },
  opts = {
    -- keymap = "<leader>jj",
  },
}
```

## Usage

- `<leader>jj` (Normal mode): Toggle the diff HUD for the current window.
- `:JJDiff [toggle|on|off|refresh]`: Control the diff HUD from command mode.
- `<Plug>(JJDiffToggle)`: Plug mapping for custom keybindings (set `vim.g.jjdiff_no_default_maps = true` or `keymap = false` to disable `<leader>jj`).

## Configuration

```lua
require("jjdiff").setup({
  keymap = "<leader>jj", -- set to false to disable default mapping
  signs = {
    add = "┃",
    change = "┃",
    delete = "▎",
    wrap = "┆",
    sep = "│",
    virt_nr = "··",
  },
  arrows = {
    up = "▲",
    down = "▼",
  },
  winblend = 8,
  min_scrolloff = 2,
  inline_similarity_threshold = 0.25,
  highlights = {}, -- optional overrides for any JJDiff* highlight group
})
```

## Highlight Groups

All `JJDiff*` highlight groups adapt automatically to dark and light colorschemes and can be overridden via `highlights` in `setup()` (including `{ link = "..." }` or `{ bg = "NONE" }`):

- **Gutter**: `JJDiffGutterAddNr`, `JJDiffGutterAddBar`, `JJDiffGutterChangeNr`, `JJDiffGutterChangeBar`, `JJDiffGutterDeleteNr`, `JJDiffGutterDeleteBar`, `JJDiffGutterSep`
- **In-buffer diff & inline tokens**: `JJDiffAddLine`, `JJDiffChangeLine`, `JJDiffDeleteVirtLine`, `JJDiffDeletePrefix`, `JJDiffAddInline`, `JJDiffDeleteInline`
- **Radar HUD & pills**: `JJDiffRadarBar`, `JJDiffPillAdd`, `JJDiffPillAddDim`, `JJDiffPillDelete`, `JJDiffPillDeleteDim`, `JJDiffPillChange`, `JJDiffPillChangeDim`, `JJDiffPillChangeAdd`, `JJDiffPillChangeDel`, `JJDiffPillMore`

## Notes

- `<N>j` / `<N>k` radar distances represent buffer line offsets (`hunk.buf_start - cursor_line`) and assume no closed folds lie between the cursor and the target hunk.
- The default `<leader>jj` keymap is only installed when neither `<leader>jj` nor `<Plug>(JJDiffToggle)` is already mapped.
- Unsaved line insertions/deletions while active shift gutter and radar line numbers immediately; inline diffs re-sync with `jj` automatically on `:w`.

## Testing

```bash
nvim --headless -u NONE --cmd "set rtp+=." -l tests/run_tests.lua
```

## License

Licensed under the [GLWT (Good Luck With That) Public License](LICENSE).
