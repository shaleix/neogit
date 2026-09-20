-- headless 最小配置:只加载 worktree 中的 neogit
local wt = "/tmp/opencode/research-baseline-profile"
vim.opt.runtimepath:prepend(wt)
vim.opt.swapfile = false
vim.opt.termguicolors = true
