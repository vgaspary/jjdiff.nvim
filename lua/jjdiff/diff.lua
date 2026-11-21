local M = {}

local MAX_WORD_DIFF_LEN = 1000
local MAX_WORD_DIFF_TOKENS = 400

---@class JJDiffHunk
---@field kind "add"|"delete"|"change"
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field buf_start integer 1-based anchor start line in buffer
---@field buf_end integer 1-based anchor end line in buffer
---@field is_eof boolean true for pure deletion at end of file
---@field old_lines string[]
---@field new_lines string[]

---@class JJDiffToken
---@field text string
---@field start_col integer 0-based inclusive byte offset
---@field end_col integer 0-based exclusive byte offset

---@class JJDiffWordOp
---@field kind "del"|"add"
---@field col? integer 0-based byte offset in new_line (when kind == "del")
---@field text? string deleted text (when kind == "del")
---@field start_col? integer 0-based inclusive byte offset (when kind == "add")
---@field end_col? integer 0-based exclusive byte offset (when kind == "add")

---Tokenize a single line into identifier runs, whitespace runs, and UTF-8 codepoints.
---@param str string
---@return JJDiffToken[]
local function tokenize(str)
  local tokens = {}
  local len = #str
  local i = 1
  while i <= len do
    local s, e = str:find("^[%w_]+", i)
    if not s then
      s, e = str:find("^%s+", i)
    end
    if not s then
      s, e = str:find("^[\1-\127\194-\244][\128-\191]*", i)
      if not s then
        s, e = i, i
      end
    end
    tokens[#tokens + 1] = {
      text = str:sub(s, e),
      start_col = s - 1,
      end_col = e,
    }
    i = e + 1
  end
  return tokens
end

---Sum non-whitespace byte length across tokens[from_idx..to_idx].
---@param tokens JJDiffToken[]
---@param from_idx? integer
---@param to_idx? integer
---@return integer
local function non_ws_bytes(tokens, from_idx, to_idx)
  local total = 0
  local start_i = from_idx or 1
  local end_i = to_idx or #tokens
  for i = start_i, end_i do
    local txt = tokens[i].text
    if not txt:match("^%s+$") then
      total = total + #txt
    end
  end
  return total
end

---Build a single concatenated token text slice for tokens[from_idx..to_idx].
---@param tokens JJDiffToken[]
---@param from_idx integer
---@param to_idx integer
---@return string
local function concat_tokens(tokens, from_idx, to_idx)
  local parts = {}
  for i = from_idx, to_idx do
    parts[#parts + 1] = tokens[i].text
  end
  return table.concat(parts)
end

---Parse `jj diff --git --context=0` output into structured hunks.
---@param diff_text string
---@param buf_line_count integer
---@return JJDiffHunk[]
function M.parse_git_diff(diff_text, buf_line_count)
  local line_count = math.max(1, buf_line_count or 1)
  if not diff_text or diff_text == "" then
    return {}
  end

  local hunks = {}
  local lines = vim.split(diff_text, "\n", { plain = true })
  local current = nil
  local rem_old = 0
  local rem_new = 0

  local function finalize_current()
    if not current then
      return
    end
    local old_c = #current.old_lines
    local new_c = #current.new_lines
    current.old_count = old_c
    current.new_count = new_c

    if old_c == 0 and new_c > 0 then
      current.kind = "add"
      current.buf_start = math.max(1, math.min(current.new_start, line_count))
      current.buf_end = math.max(current.buf_start, math.min(current.new_start + new_c - 1, line_count))
      current.is_eof = false
      hunks[#hunks + 1] = current
    elseif old_c > 0 and new_c == 0 then
      current.kind = "delete"
      local is_eof = current.new_start >= line_count
      local anchor = is_eof and line_count or math.max(1, current.new_start + 1)
      current.is_eof = is_eof
      current.buf_start = anchor
      current.buf_end = anchor
      hunks[#hunks + 1] = current
    elseif old_c > 0 and new_c > 0 then
      current.kind = "change"
      current.is_eof = false
      current.buf_start = math.max(1, math.min(current.new_start, line_count))
      current.buf_end = math.max(current.buf_start, math.min(current.new_start + new_c - 1, line_count))
      hunks[#hunks + 1] = current
    end

    current = nil
    rem_old = 0
    rem_new = 0
  end

  for _, raw in ipairs(lines) do
    if current and (rem_old > 0 or rem_new > 0) then
      local prefix = raw:sub(1, 1)
      if prefix == "-" and rem_old > 0 then
        current.old_lines[#current.old_lines + 1] = raw:sub(2)
        rem_old = rem_old - 1
      elseif prefix == "+" and rem_new > 0 then
        current.new_lines[#current.new_lines + 1] = raw:sub(2)
        rem_new = rem_new - 1
      elseif prefix == " " and rem_old > 0 and rem_new > 0 then
        rem_old = rem_old - 1
        rem_new = rem_new - 1
      elseif prefix == "\\" then
        -- "\ No newline at end of file" — skip without decrementing counts
      else
        finalize_current()
      end
    end

    if not current or (rem_old == 0 and rem_new == 0) then
      local old_s, old_c_str, new_s, new_c_str = raw:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if old_s then
        finalize_current()
        local oc = old_c_str ~= "" and tonumber(old_c_str) or 1
        local nc = new_c_str ~= "" and tonumber(new_c_str) or 1
        current = {
          old_start = tonumber(old_s) --[[@as integer]],
          old_count = oc,
          new_start = tonumber(new_s) --[[@as integer]],
          new_count = nc,
          old_lines = {},
          new_lines = {},
        }
        rem_old = oc
        rem_new = nc
        if rem_old == 0 and rem_new == 0 then
          finalize_current()
        end
      elseif raw:sub(1, 1) ~= "\\" and current and rem_old == 0 and rem_new == 0 then
        finalize_current()
      end
    end
  end

  finalize_current()
  return hunks
end

---Compute token-level word diff between two single lines.
---@param old_line string
---@param new_line string
---@param threshold? number
---@return { similar: boolean, ops: JJDiffWordOp[] }
function M.compute_word_diff(old_line, new_line, threshold)
  local thresh = threshold or 0.25
  if old_line == new_line then
    return { similar = true, ops = {} }
  end
  if #old_line > MAX_WORD_DIFF_LEN or #new_line > MAX_WORD_DIFF_LEN then
    return { similar = false, ops = {} }
  end

  local old_tokens = tokenize(old_line)
  local new_tokens = tokenize(new_line)
  if #old_tokens > MAX_WORD_DIFF_TOKENS or #new_tokens > MAX_WORD_DIFF_TOKENS then
    return { similar = false, ops = {} }
  end
  local old_nws = non_ws_bytes(old_tokens)
  local new_nws = non_ws_bytes(new_tokens)

  if #old_tokens == 0 or #new_tokens == 0 or old_nws == 0 or new_nws == 0 then
    return { similar = false, ops = {} }
  end

  local old_texts = {}
  for i, tok in ipairs(old_tokens) do
    old_texts[i] = tok.text
  end
  local new_texts = {}
  for i, tok in ipairs(new_tokens) do
    new_texts[i] = tok.text
  end

  local a_str = table.concat(old_texts, "\n") .. "\n"
  local b_str = table.concat(new_texts, "\n") .. "\n"
  local diff_hunks = vim.diff(a_str, b_str, {
    result_type = "indices",
    algorithm = "histogram",
  })

  local changed_old_nws = 0
  local ops = {}

  for _, h in ipairs(diff_hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then
      changed_old_nws = changed_old_nws + non_ws_bytes(old_tokens, sa, sa + ca - 1)
    end

    if ca > 0 and cb == 0 then
      local col = sb == 0 and 0 or new_tokens[sb].end_col
      ops[#ops + 1] = {
        kind = "del",
        col = col,
        text = concat_tokens(old_tokens, sa, sa + ca - 1),
      }
    elseif ca == 0 and cb > 0 then
      ops[#ops + 1] = {
        kind = "add",
        start_col = new_tokens[sb].start_col,
        end_col = new_tokens[sb + cb - 1].end_col,
      }
    elseif ca > 0 and cb > 0 then
      local col = new_tokens[sb].start_col
      ops[#ops + 1] = {
        kind = "del",
        col = col,
        text = concat_tokens(old_tokens, sa, sa + ca - 1),
      }
      ops[#ops + 1] = {
        kind = "add",
        start_col = col,
        end_col = new_tokens[sb + cb - 1].end_col,
      }
    end
  end

  local unchanged_nws = math.max(0, old_nws - changed_old_nws)
  local ratio = unchanged_nws / math.max(old_nws, new_nws, 1)
  return {
    similar = ratio >= thresh,
    ops = ops,
  }
end

---@class JJDiffPairedLine
---@field lnum integer 1-based buffer line number
---@field status "add"|"change"
---@field ops JJDiffWordOp[]

---@class JJDiffVirtBlock
---@field lnum integer 1-based anchor line number
---@field above boolean
---@field lines string[]

---Pair lines inside a "change" hunk into inline-diffed lines, added lines, and virtual deleted blocks.
---@param hunk JJDiffHunk
---@param threshold number
---@param buf_line_count integer
---@return { line_ops: JJDiffPairedLine[], virt_blocks: JJDiffVirtBlock[] }
function M.pair_change_hunk(hunk, threshold, buf_line_count)
  local old_lines = hunk.old_lines
  local new_lines = hunk.new_lines
  local m = #old_lines
  local n = #new_lines
  local pairs_count = math.min(m, n)

  local line_ops = {}
  local virt_blocks = {}

  -- Flush accumulated unpaired old lines onto the anchor line of that block
  local pending_old = {}
  local pending_anchor_lnum = nil

  local function flush_pending(above)
    if #pending_old == 0 then
      return
    end
    virt_blocks[#virt_blocks + 1] = {
      lnum = pending_anchor_lnum,
      above = above,
      lines = pending_old,
    }
    pending_old = {}
    pending_anchor_lnum = nil
  end

  for k = 1, pairs_count do
    local lnum = math.min(hunk.new_start + k - 1, buf_line_count)
    local wd = M.compute_word_diff(old_lines[k], new_lines[k], threshold)
    if wd.similar then
      flush_pending(true)
      line_ops[#line_ops + 1] = {
        lnum = lnum,
        status = "change",
        ops = wd.ops,
      }
    else
      if not pending_anchor_lnum then
        pending_anchor_lnum = lnum
      end
      pending_old[#pending_old + 1] = old_lines[k]
      line_ops[#line_ops + 1] = {
        lnum = lnum,
        status = "add",
        ops = {},
      }
    end
  end

  if n > m then
    -- Any pending unpaired old lines belong above the block's first added line
    flush_pending(true)
    for k = pairs_count + 1, n do
      local lnum = math.min(hunk.new_start + k - 1, buf_line_count)
      line_ops[#line_ops + 1] = {
        lnum = lnum,
        status = "add",
        ops = {},
      }
    end
  elseif m > n then
    if #pending_old > 0 then
      -- Trailing lines belong to the same contiguous unpaired replacement block above pending_anchor_lnum
      for k = pairs_count + 1, m do
        pending_old[#pending_old + 1] = old_lines[k]
      end
      flush_pending(true)
    else
      -- Last line was paired; attach remaining deleted lines immediately after the last new line
      local trailing = {}
      for k = pairs_count + 1, m do
        trailing[#trailing + 1] = old_lines[k]
      end
      local after_lnum = hunk.new_start + n
      if after_lnum <= buf_line_count then
        virt_blocks[#virt_blocks + 1] = {
          lnum = after_lnum,
          above = true,
          lines = trailing,
        }
      else
        virt_blocks[#virt_blocks + 1] = {
          lnum = buf_line_count,
          above = false,
          lines = trailing,
        }
      end
    end
  else
    flush_pending(true)
  end

  return {
    line_ops = line_ops,
    virt_blocks = virt_blocks,
  }
end

---@class JJDiffRadarItem
---@field hunk JJDiffHunk
---@field distance integer
---@field target_line integer

---Partition off-screen hunks into above-viewport and below-viewport lists sorted nearest-to-cursor first.
---@param hunks JJDiffHunk[]
---@param top_line integer
---@param bot_line integer
---@param cursor_line integer
---@return JJDiffRadarItem[] above, JJDiffRadarItem[] below
function M.compute_radar(hunks, top_line, bot_line, cursor_line)
  local above = {}
  local below = {}

  for _, hunk in ipairs(hunks) do
    if hunk.buf_end < top_line then
      above[#above + 1] = {
        hunk = hunk,
        distance = math.max(1, cursor_line - hunk.buf_start),
        target_line = hunk.buf_start,
      }
    elseif hunk.buf_start > bot_line then
      below[#below + 1] = {
        hunk = hunk,
        distance = math.max(1, hunk.buf_start - cursor_line),
        target_line = hunk.buf_start,
      }
    end
  end

  -- When a radar bar is already visible, include hunks on the covered edge row.
  if #above > 0 then
    for _, hunk in ipairs(hunks) do
      if hunk.buf_end == top_line and hunk.buf_start < cursor_line then
        above[#above + 1] = {
          hunk = hunk,
          distance = math.max(1, cursor_line - hunk.buf_start),
          target_line = hunk.buf_start,
        }
      end
    end
  end

  if #below > 0 then
    for _, hunk in ipairs(hunks) do
      if hunk.buf_start == bot_line and hunk.buf_start > cursor_line then
        below[#below + 1] = {
          hunk = hunk,
          distance = math.max(1, hunk.buf_start - cursor_line),
          target_line = hunk.buf_start,
        }
      end
    end
  end

  table.sort(above, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.target_line < b.target_line
  end)

  table.sort(below, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.target_line < b.target_line
  end)

  return above, below
end

return M
