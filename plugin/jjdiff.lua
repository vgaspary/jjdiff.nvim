if vim.g.loaded_jjdiff then
  return
end
vim.g.loaded_jjdiff = 1

vim.keymap.set("n", "<Plug>(JJDiffToggle)", function()
  require("jjdiff").toggle()
end, { silent = true, desc = "Toggle jj diff HUD" })

if
  not vim.g.jjdiff_no_default_maps
  and not vim.g._jjdiff_setup_called
  and vim.fn.hasmapto("<Plug>(JJDiffToggle)", "n") == 0
  and vim.fn.maparg("<leader>jj", "n") == ""
then
  vim.keymap.set("n", "<leader>jj", "<Plug>(JJDiffToggle)", {
    silent = true,
    desc = "Toggle jj diff HUD",
  })
  vim.g._jjdiff_default_mapped_lhs = "<leader>jj"
end

vim.api.nvim_create_user_command("JJDiff", function(opts)
  local raw_arg = vim.trim(opts.args or "")
  local action = (raw_arg ~= "" and raw_arg or "toggle"):lower()
  local jjdiff = require("jjdiff")
  if action == "toggle" then
    jjdiff.toggle()
  elseif action == "on" then
    jjdiff.enable()
  elseif action == "off" then
    jjdiff.disable()
  elseif action == "refresh" then
    jjdiff.refresh()
  else
    vim.notify("jjdiff: unknown subcommand '" .. action .. "' (expected toggle|on|off|refresh)", vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  complete = function(arglead)
    local prefix = (arglead or ""):lower()
    local items = { "toggle", "on", "off", "refresh" }
    if prefix == "" then
      return items
    end
    return vim.tbl_filter(function(item)
      return vim.startswith(item, prefix)
    end, items)
  end,
  desc = "Toggle or control the jjdiff HUD",
})
