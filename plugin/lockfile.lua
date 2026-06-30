--- Plugin entry: register user commands. Guarded so it runs only once.

if vim.g.loaded_lockfile then
  return
end
vim.g.loaded_lockfile = true

vim.api.nvim_create_user_command("LockfileDiff", function(args)
  ---@type string?, string?
  local old, new = args.fargs[1], args.fargs[2]
  require("lockfile").diff({ old = old, new = new })
end, {
  nargs = "*",
  desc = "Diff a lockfile: [old-rev] vs [new-rev] (defaults: HEAD vs working tree)",
  complete = function(arglead)
    -- Offer common revisions; git tab-completion proper would require shelling
    -- out, so we keep to a small useful set plus the working-tree sentinel.
    local candidates = { "HEAD", "HEAD~1", "HEAD~2", "main", "master", "origin/main", "origin/HEAD" }
    local out = {}
    for _, c in ipairs(candidates) do
      if c:sub(1, #arglead) == arglead then
        out[#out + 1] = c
      end
    end
    return out
  end,
})
