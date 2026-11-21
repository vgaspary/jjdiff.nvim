local config = require("jjdiff.config")
local diff = require("jjdiff.diff")

local M = {}

M.ns = vim.api.nvim_create_namespace("jjdiff_radar")

---Create an unlisted scratch buffer for a radar overlay.
---@return integer
local function create_scratch_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

---Create a 1-row borderless win-relative floating window (initially hidden).
---@param buf integer
---@param parent_win integer
---@param row integer
---@param width integer
---@return integer
local function create_overlay_win(buf, parent_win, row, width)
  local cfg = config.get()
  local fwin = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = parent_win,
    row = row,
    col = 0,
    width = math.max(1, width),
    height = 1,
    style = "minimal",
    focusable = false,
    hide = true,
    noautocmd = true,
    zindex = 45,
  })
  vim.wo[fwin].winhl = "Normal:JJDiffRadarBar,NormalFloat:JJDiffRadarBar"
  vim.wo[fwin].winblend = cfg.winblend or 8
  vim.wo[fwin].wrap = false
  return fwin
end

---Hide a floating window only if it is currently visible.
---@param fwin? integer
local function hide_win(fwin)
  if not (fwin and vim.api.nvim_win_is_valid(fwin)) then
    return
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, fwin)
  if ok and cfg and not cfg.hide then
    pcall(vim.api.nvim_win_set_config, fwin, { hide = true })
  end
end

---Fetch text-area metrics for winid (`height` from getwininfo already excludes winbar).
---@param winid integer
---@return integer win_w, integer text_h, integer textoff
local function get_win_metrics(winid)
  local info = vim.fn.getwininfo(winid)[1]
  local win_w = vim.api.nvim_win_get_width(winid)
  local text_h = (info and info.height) or vim.api.nvim_win_get_height(winid)
  local textoff = (info and info.textoff) or 6
  return win_w, text_h, textoff
end

---Ensure top and bottom radar scratch buffers and floating windows exist for win_state.
---@param win_state JJDiffWinState
function M.ensure_floats(win_state)
  if not vim.api.nvim_win_is_valid(win_state.winid) then
    return
  end
  local width, text_h = get_win_metrics(win_state.winid)

  if not (win_state.top_buf and vim.api.nvim_buf_is_valid(win_state.top_buf)) then
    win_state.top_buf = create_scratch_buf()
    if win_state.top_win and vim.api.nvim_win_is_valid(win_state.top_win) then
      pcall(vim.api.nvim_win_close, win_state.top_win, true)
      win_state.top_win = nil
    end
  end
  if not (win_state.top_win and vim.api.nvim_win_is_valid(win_state.top_win)) then
    win_state.top_win = create_overlay_win(win_state.top_buf, win_state.winid, 0, width)
  end

  if not (win_state.bot_buf and vim.api.nvim_buf_is_valid(win_state.bot_buf)) then
    win_state.bot_buf = create_scratch_buf()
    if win_state.bot_win and vim.api.nvim_win_is_valid(win_state.bot_win) then
      pcall(vim.api.nvim_win_close, win_state.bot_win, true)
      win_state.bot_win = nil
    end
  end
  if not (win_state.bot_win and vim.api.nvim_win_is_valid(win_state.bot_win)) then
    win_state.bot_win = create_overlay_win(win_state.bot_buf, win_state.winid, math.max(0, text_h - 1), width)
  end
end

---Build colored HUD segments for a single radar pill.
---@param item JJDiffRadarItem
---@param arrow string
---@return table[]
local function build_pill_segments(item, arrow)
  local h = item.hunk
  local head = " " .. arrow .. " " .. tostring(item.distance) .. " "

  if h.kind == "add" then
    return {
      { head, "JJDiffPillAdd" },
      { "+" .. tostring(h.new_count) .. " ", "JJDiffPillAddDim" },
    }
  elseif h.kind == "delete" then
    return {
      { head, "JJDiffPillDelete" },
      { "-" .. tostring(h.old_count) .. " ", "JJDiffPillDeleteDim" },
    }
  end

  if h.old_count == h.new_count then
    return {
      { head, "JJDiffPillChange" },
      { "±" .. tostring(h.new_count) .. " ", "JJDiffPillChangeDim" },
    }
  end

  return {
    { head, "JJDiffPillChange" },
    { "+" .. tostring(h.new_count), "JJDiffPillChangeAdd" },
    { "/-" .. tostring(h.old_count) .. " ", "JJDiffPillChangeDel" },
  }
end

---Calculate display width across a list of { text, hl } segments.
---@param segs table[]
---@return integer
local function segments_width(segs)
  local w = 0
  for _, s in ipairs(segs) do
    w = w + vim.fn.strdisplaywidth(s[1])
  end
  return w
end

---Truncate str to fit within max_w display columns.
---@param str string
---@param max_w integer
---@return string
local function truncate_display(str, max_w)
  if max_w <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(str) <= max_w then
    return str
  end
  local chars = vim.fn.strchars(str)
  local out = ""
  local w = 0
  for idx = 0, chars - 1 do
    local ch = vim.fn.strcharpart(str, idx, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > max_w then
      break
    end
    out = out .. ch
    w = w + cw
  end
  return out
end

---Format and render one radar bar overlay, or hide it when list is empty.
---@param parent_win integer
---@param fbuf integer
---@param fwin integer
---@param list JJDiffRadarItem[]
---@param arrow string
---@param row_pos integer
---@param win_w integer
---@param textoff integer
local function render_bar(parent_win, fbuf, fwin, list, arrow, row_pos, win_w, textoff)
  if #list == 0 then
    hide_win(fwin)
    return
  end

  local cfg = config.get()
  local pad_len = math.min(textoff, math.floor(win_w / 3))
  local pad_str = string.rep(" ", math.max(0, pad_len))
  local segments = {
    { pad_str, "JJDiffRadarBar" },
  }
  local used_w = vim.fn.strdisplaywidth(pad_str)
  local shown = 0

  local n = #list
  local pills = {}
  local pill_widths = {}
  for i = 1, n do
    pills[i] = build_pill_segments(list[i], arrow)
    pill_widths[i] = segments_width(pills[i])
  end

  local rem_total = {}
  rem_total[n] = pill_widths[n]
  for i = n - 1, 1, -1 do
    rem_total[i] = pill_widths[i] + 3 + rem_total[i + 1]
  end

  local farthest = tostring(list[n].distance)
  local function emit_pill(idx)
    if shown > 0 then
      segments[#segments + 1] = { "   ", "JJDiffRadarBar" }
      used_w = used_w + 3
    end
    for _, s in ipairs(pills[idx]) do
      segments[#segments + 1] = s
    end
    used_w = used_w + pill_widths[idx]
    shown = shown + 1
  end

  for i = 1, n do
    local sep_w = shown > 0 and 3 or 0
    if (used_w + sep_w + rem_total[i]) <= win_w then
      emit_pill(i)
    else
      local rem_after = n - i
      local next_full_badge = " ⋯ +" .. tostring(rem_after) .. " more (" .. arrow .. " " .. farthest .. ") "
      local reserve = (rem_after > 0) and (3 + vim.fn.strdisplaywidth(next_full_badge)) or 0

      if i < n and (used_w + sep_w + pill_widths[i] + reserve) <= win_w then
        emit_pill(i)
      else
        local remaining = n - i + 1
        local full_badge = " ⋯ +" .. tostring(remaining) .. " more (" .. arrow .. " " .. farthest .. ") "
        local full_sep = shown > 0 and "   " or ""
        local full_w = #full_sep + vim.fn.strdisplaywidth(full_badge)

        local compact_badge = " +" .. tostring(remaining) .. " " .. arrow .. farthest .. " "
        local compact_sep = shown > 0 and " " or ""
        local compact_w = #compact_sep + vim.fn.strdisplaywidth(compact_badge)

        if (used_w + full_w) <= win_w then
          if full_sep ~= "" then
            segments[#segments + 1] = { full_sep, "JJDiffRadarBar" }
          end
          segments[#segments + 1] = { full_badge, "JJDiffPillMore" }
        elseif (used_w + compact_w) <= win_w then
          if compact_sep ~= "" then
            segments[#segments + 1] = { compact_sep, "JJDiffRadarBar" }
          end
          segments[#segments + 1] = { compact_badge, "JJDiffPillMore" }
        elseif shown == 0 then
          segments = {}
          if vim.fn.strdisplaywidth(compact_badge) <= win_w then
            segments[1] = { compact_badge, "JJDiffPillMore" }
          else
            local mini = " " .. arrow .. tostring(list[1].distance) .. " "
            local mini_hl = pills[1][1][2]
            if vim.fn.strdisplaywidth(mini) <= win_w then
              segments[1] = { mini, mini_hl }
            else
              segments[1] = { truncate_display(arrow .. tostring(list[1].distance), win_w), mini_hl }
            end
          end
        else
          local avail = math.max(0, win_w - used_w)
          if avail >= 3 then
            segments[#segments + 1] = { truncate_display(" +" .. tostring(remaining), avail), "JJDiffPillMore" }
          end
        end
        break
      end
    end
  end

  local parts = {}
  for _, s in ipairs(segments) do
    parts[#parts + 1] = s[1]
  end
  local full_line = table.concat(parts)

  vim.bo[fbuf].modifiable = true
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { full_line })
  vim.bo[fbuf].modifiable = false

  vim.api.nvim_buf_clear_namespace(fbuf, M.ns, 0, -1)
  local byte_col = 0
  for _, s in ipairs(segments) do
    local len = #s[1]
    if len > 0 then
      vim.api.nvim_buf_set_extmark(fbuf, M.ns, 0, byte_col, {
        end_row = 0,
        end_col = byte_col + len,
        hl_group = s[2],
      })
      byte_col = byte_col + len
    end
  end

  vim.wo[fwin].winblend = cfg.winblend or 8
  vim.api.nvim_win_set_config(fwin, {
    relative = "win",
    win = parent_win,
    row = row_pos,
    col = 0,
    width = math.max(1, win_w),
    height = 1,
    hide = false,
  })
end

---Recompute off-screen hunks and update top and bottom radar bars for win_state.
---@param win_state JJDiffWinState
function M.update(win_state)
  win_state._radar_scheduled = false

  if not vim.api.nvim_win_is_valid(win_state.winid) then
    return
  end

  local win_w, text_h, textoff = get_win_metrics(win_state.winid)

  local top_line, bot_line, cursor_line
  vim.api.nvim_win_call(win_state.winid, function()
    top_line = vim.fn.line("w0")
    bot_line = vim.fn.line("w$")
    cursor_line = vim.api.nvim_win_get_cursor(win_state.winid)[1]
  end)

  win_state._last_radar_key = string.format("%d:%d:%d:%d:%d:%d", top_line, bot_line, cursor_line, win_w, text_h, textoff)

  if text_h < 3 or win_w < 10 then
    hide_win(win_state.top_win)
    hide_win(win_state.bot_win)
    return
  end

  M.ensure_floats(win_state)

  local above, below = diff.compute_radar(win_state.hunks, top_line, bot_line, cursor_line)
  local arrows = config.get().arrows

  render_bar(win_state.winid, win_state.top_buf, win_state.top_win, above, arrows.up, 0, win_w, textoff)
  render_bar(win_state.winid, win_state.bot_buf, win_state.bot_win, below, arrows.down, text_h - 1, win_w, textoff)
end

---Close radar floating windows and wipe their scratch buffers.
---@param win_state JJDiffWinState
function M.close(win_state)
  if win_state.top_win and vim.api.nvim_win_is_valid(win_state.top_win) then
    pcall(vim.api.nvim_win_close, win_state.top_win, true)
  end
  if win_state.bot_win and vim.api.nvim_win_is_valid(win_state.bot_win) then
    pcall(vim.api.nvim_win_close, win_state.bot_win, true)
  end
  if win_state.top_buf and vim.api.nvim_buf_is_valid(win_state.top_buf) then
    pcall(vim.api.nvim_buf_delete, win_state.top_buf, { force = true })
  end
  if win_state.bot_buf and vim.api.nvim_buf_is_valid(win_state.bot_buf) then
    pcall(vim.api.nvim_buf_delete, win_state.bot_buf, { force = true })
  end
  win_state.top_win = nil
  win_state.bot_win = nil
  win_state.top_buf = nil
  win_state.bot_buf = nil
end

return M
