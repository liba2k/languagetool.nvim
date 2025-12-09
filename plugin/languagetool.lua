-- Prevent loading the plugin twice
if vim.g.loaded_languagetool then
  return
end
vim.g.loaded_languagetool = true

-- The plugin requires Neovim 0.9+ for vim.system
if vim.fn.has("nvim-0.9") == 0 then
  vim.api.nvim_err_writeln("languagetool.nvim requires Neovim 0.9+")
  return
end
