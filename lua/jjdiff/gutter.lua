local config = require("jjdiff.config")
local state = require("jjdiff.state")

local M = {}

---Escape '%' for statuscolumn strings.
---@param str string
---@return string
local function escape_stl(str)
  return (str:gsub("%%", "%%%%"))
end

---Right-align str within width display columns.
---@param str string
---@param width integer
---@return string
local function pad_left(str, width)
  local w = vim.fn.strdisplaywidth(str)
  if w >= width then
    return str
  end
  return string.rep(" ", width - w) .. str
end

---Render the right-extended number gutter for the active statusline window.
---@return string
function M.render()
  local winid = vim.g.statusline_winid
  local win_state = state.wins[winid]
  if
    not win_state
    or not vim.api.nvim_buf_is_valid(win_state.bufnr)
    or vim.api.nvim_win_get_buf(winid) ~= win_state.bufnr
  then
    return "%C%s%=%l "
  end

  local lnum = vim.v.lnum
  local relnum = vim.v.relnum
  local virtnum = vim.v.virtnum
  local signs = config.get().signs

  local line_count = vim.api.nvim_buf_line_count(win_state.bufnr)
  local digits_width = math.max(
    (vim.wo[winid].numberwidth or 4) - 1,
    #tostring(line_count),
    vim.fn.strdisplaywidth(signs.virt_nr)
  )

  if virtnum < 0 then
    if win_state.virt_lines_lnums and win_state.virt_lines_lnums[lnum] then
      return string.format(
        "%%C%%s%%#JJDiffGutterDeleteNr#%s %%#JJDiffGutterDeleteBar#%s %%*",
        escape_stl(pad_left(signs.virt_nr, digits_width)),
        escape_stl(signs.delete)
      )
    end
    return string.format(
      "%%C%%s%%#LineNr#%s %%#JJDiffGutterSep#%s %%*",
      string.rep(" ", digits_width),
      escape_stl(signs.sep)
    )
  end

  local status = win_state.line_status and win_state.line_status[lnum]

  if virtnum > 0 then
    local bar_hl = status == "add" and "JJDiffGutterAddBar"
      or (status == "change" and "JJDiffGutterChangeBar" or "JJDiffGutterSep")
    local bar_ch = status and signs.wrap or signs.sep
    return string.format(
      "%%C%%s%%#LineNr#%s %%#%s#%s %%*",
      string.rep(" ", digits_width),
      bar_hl,
      escape_stl(bar_ch)
    )
  end

  local use_rel = vim.wo[winid].relativenumber and relnum ~= 0
  local raw_num = tostring(use_rel and relnum or lnum)
  local num_str = string.rep(" ", math.max(0, digits_width - #raw_num)) .. raw_num

  if status == "add" then
    return string.format(
      "%%C%%s%%#JJDiffGutterAddNr#%s %%#JJDiffGutterAddBar#%s %%*",
      num_str,
      escape_stl(signs.add)
    )
  elseif status == "change" then
    return string.format(
      "%%C%%s%%#JJDiffGutterChangeNr#%s %%#JJDiffGutterChangeBar#%s %%*",
      num_str,
      escape_stl(signs.change)
    )
  end

  local is_cur = (relnum == 0 and vim.wo[winid].cursorline)
  local nr_hl = is_cur and "CursorLineNr" or "LineNr"
  return string.format(
    "%%C%%s%%#%s#%s %%#JJDiffGutterSep#%s %%*",
    nr_hl,
    num_str,
    escape_stl(signs.sep)
  )
end

return M
