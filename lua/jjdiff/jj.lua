local M = {}

---Escape a filename for a Jujutsu `file:"..."` fileset literal.
---@param name string
---@return string
local function escape_fileset_literal(name)
  local escaped = name
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
  return 'file:"' .. escaped .. '"'
end

---Check whether unified diff output represents a binary file diff.
---@param stdout string
---@return boolean
local function is_binary_diff(stdout)
  if stdout:match("^Binary files ") or stdout:match("\nBinary files ") then
    return true
  end
  if stdout:match("^GIT binary patch\r?\n") or stdout:match("\nGIT binary patch\r?\n") then
    return true
  end
  return false
end

---Validate path and prepare `jj diff --git --context=0` command and working directory.
---@param filepath string
---@return { ok: boolean, cmd?: string[], cwd?: string, err?: string }
local function prepare_diff_cmd(filepath)
  if vim.fn.executable("jj") ~= 1 then
    return { ok = false, err = "jjdiff: 'jj' executable not found in PATH" }
  end

  local abs = vim.fn.fnamemodify(filepath, ":p")
  local clean_abs = abs:gsub("/+$", "")
  if clean_abs == "" then
    clean_abs = abs
  end

  local lstat = vim.uv.fs_lstat(clean_abs)
  if lstat and lstat.type == "directory" then
    return { ok = false, err = "jjdiff: path is a directory: " .. clean_abs }
  end

  local orig_dir = vim.fn.fnamemodify(clean_abs, ":h")
  local base = vim.fn.fnamemodify(clean_abs, ":t")
  if base == "" then
    return { ok = false, err = "jjdiff: path is a directory: " .. clean_abs }
  end

  -- Resolve only the parent directory so symlinked files inside a jj repo are not dereferenced outside it.
  local dir = vim.uv.fs_realpath(orig_dir) or orig_dir
  if vim.fn.isdirectory(dir) ~= 1 then
    return { ok = false, err = "jjdiff: parent directory does not exist: " .. dir }
  end

  return {
    ok = true,
    cwd = dir,
    cmd = {
      "jj",
      "--no-pager",
      "--color=never",
      "diff",
      "--git",
      "--context=0",
      "--",
      escape_fileset_literal(base),
    },
  }
end

---Normalize a completed `jj diff` process result.
---@param res? vim.SystemCompleted
---@return { ok: boolean, diff?: string, binary?: boolean, err?: string }
local function parse_proc_result(res)
  if not res then
    return { ok = false, err = "jjdiff: jj diff did not return a result" }
  end

  if res.code ~= 0 then
    local stderr = (res.stderr or ""):gsub("%s+$", "")
    if stderr == "" then
      stderr = string.format("jj diff exited with code %d", res.code)
    end
    return { ok = false, err = "jjdiff: " .. stderr }
  end

  local stdout = res.stdout or ""
  if is_binary_diff(stdout) then
    return { ok = true, binary = true, diff = "" }
  end

  return { ok = true, binary = false, diff = stdout }
end

---Run `jj diff --git --context=0` synchronously for a single file on disk.
---@param filepath string
---@return { ok: boolean, diff?: string, binary?: boolean, err?: string }
function M.diff_file(filepath)
  local prep = prepare_diff_cmd(filepath)
  if not prep.ok then
    return { ok = false, err = prep.err }
  end

  local ok_call, proc = pcall(vim.system, prep.cmd, { cwd = prep.cwd, text = true })
  if not ok_call or not proc then
    return { ok = false, err = "jjdiff: failed to spawn jj process" }
  end

  return parse_proc_result(proc:wait())
end

---Run `jj diff --git --context=0` asynchronously for a single file on disk.
---@param filepath string
---@param cb fun(res: { ok: boolean, diff?: string, binary?: boolean, err?: string })
function M.diff_file_async(filepath, cb)
  local prep = prepare_diff_cmd(filepath)
  if not prep.ok then
    vim.schedule(function()
      cb({ ok = false, err = prep.err })
    end)
    return
  end

  local ok_call, proc = pcall(
    vim.system,
    prep.cmd,
    { cwd = prep.cwd, text = true },
    vim.schedule_wrap(function(res)
      cb(parse_proc_result(res))
    end)
  )
  if not ok_call or not proc then
    vim.schedule(function()
      cb({ ok = false, err = "jjdiff: failed to spawn jj process" })
    end)
  end
end

return M
