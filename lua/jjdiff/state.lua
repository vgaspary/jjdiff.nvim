---@class JJDiffWinState
---@field winid integer
---@field bufnr integer
---@field filepath string
---@field hunks JJDiffHunk[]
---@field line_status table<integer, "add"|"change">
---@field virt_lines_lnums table<integer, boolean>
---@field orig_opts { statuscolumn: string, number: boolean, scrolloff: integer }
---@field top_buf? integer
---@field top_win? integer
---@field bot_buf? integer
---@field bot_win? integer
---@field _last_radar_key? string
---@field _radar_scheduled? boolean

local M = {
  ---@type table<integer, JJDiffWinState>
  wins = {},
  ---@type table<integer, integer>
  buf_refs = {},
  ---@type table<integer, boolean>
  buf_attached = {},
  ---@type table<integer, integer>
  buf_refresh_seq = {},
}

return M
