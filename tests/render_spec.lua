-- Smoke tests for the renderer: structure, fold expressions, highlights.

return function(T)
  local model = require("lockfile.model")
  local diff = require("lockfile.diff")
  local analyze = require("lockfile.analyze")
  local render = require("lockfile.render")
  local config = require("lockfile.config")

  config.setup({})

  local function build(packages, roots)
    local lf = model.new("cargo")
    for _, p in ipairs(packages) do
      lf:add(p)
    end
    for _, r in ipairs(roots or {}) do
      lf:add_root(r)
    end
    return lf
  end

  local old = build({
    { name = "app", version = "1.0.0", deps = { { name = "dep" } } },
    { name = "dep", version = "1.0.0", source = "registry+https://x", checksum = "a" },
  }, { "app@1.0.0" })
  local new = build({
    { name = "app", version = "1.0.0", deps = { { name = "dep" } } },
    { name = "dep", version = "2.0.0", source = "registry+https://x", checksum = "b" },
  }, { "app@1.0.0" })

  local report = diff.diff(old, new)
  analyze.annotate(report, config.options)

  local lines = render.render(report, { old_label = "HEAD", new_label = "working tree" })

  T.ok(#lines > 3, "renders multiple lines")
  T.ok(lines[1].text:find("Cargo.lock", 1, true) ~= nil, "title shows format label")
  T.ok(lines[1].text:find("HEAD", 1, true) ~= nil, "title shows old label")

  -- Every line carries a valid fold expression.
  local valid = { ["0"] = true, [">1"] = true, [">2"] = true, ["3"] = true }
  for _, l in ipairs(lines) do
    T.ok(valid[l.fold] == true, "valid fold expr: " .. tostring(l.fold))
  end

  -- There is at least one section header and one highlighted segment.
  local has_section, has_hl = false, false
  for _, l in ipairs(lines) do
    if l.fold == ">1" then
      has_section = true
    end
    if #l.hls > 0 then
      has_hl = true
    end
  end
  T.ok(has_section, "has a section header")
  T.ok(has_hl, "has highlight segments")

  -- Empty diff renders a "No changes." line.
  local same = diff.diff(old, old)
  analyze.annotate(same, config.options)
  local empty = render.render(same, { old_label = "HEAD", new_label = "working tree" })
  local found_none = false
  for _, l in ipairs(empty) do
    if l.text:find("No changes", 1, true) then
      found_none = true
    end
  end
  T.ok(found_none, "empty diff shows 'No changes.'")
end
