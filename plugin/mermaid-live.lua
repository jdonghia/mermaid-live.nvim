if vim.g.loaded_mermaid_live then
  return
end
vim.g.loaded_mermaid_live = 1

vim.filetype.add({
  extension = {
    mermaid = "mermaid",
    mmd = "mermaid",
  },
})

vim.api.nvim_create_user_command("MermaidView", function()
  require("mermaid-live").start()
end, { desc = "Mermaid: start live preview for current buffer" })

vim.api.nvim_create_user_command("MermaidServe", function()
  require("mermaid-live").serve()
end, { desc = "Mermaid: start server for current buffer without opening browser" })

vim.api.nvim_create_user_command("MermaidStop", function()
  require("mermaid-live").stop()
end, { desc = "Mermaid: stop live preview" })

vim.api.nvim_create_user_command("MermaidOpen", function()
  require("mermaid-live").open()
end, { desc = "Mermaid: reopen browser at preview URL" })

vim.api.nvim_create_user_command("MermaidTheme", function(args)
  require("mermaid-live").set_theme(args.args)
end, {
  nargs = 1,
  complete = function()
    return { "default", "dark", "forest", "neutral", "base" }
  end,
  desc = "Mermaid: set preview theme",
})

vim.api.nvim_create_user_command("MermaidThemeToggle", function()
  require("mermaid-live").toggle_theme()
end, { desc = "Mermaid: toggle dark/light preview theme" })

vim.api.nvim_create_user_command("MermaidCleanup", function()
  require("mermaid-live").cleanup()
end, { desc = "Mermaid: scan localhost and shut down stray mermaid-live servers" })
