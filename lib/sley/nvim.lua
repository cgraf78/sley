-- Optional Neovim protocol adapters for Sley.
--
-- This module intentionally does not resolve shdeps paths, choose filetypes,
-- create keymaps, or decide when linting should be disabled. Those choices are
-- editor policy owned by the caller. Sley owns only the public hook command
-- contracts and the JSON diagnostic shape emitted by `sley hook lint-file
-- --json`, so the helpers below translate those contracts into common Neovim
-- plugin shapes.

local M = {}

local function copy_list(items)
  local result = {}
  for i, item in ipairs(items or {}) do
    result[i] = item
  end
  return result
end

local function severity_map()
  -- Resolve through `vim.diagnostic` at call time so tests can run with a
  -- minimal headless Neovim and callers can load the module before diagnostics
  -- are otherwise configured.
  return {
    error = vim.diagnostic.severity.ERROR,
    warning = vim.diagnostic.severity.WARN,
    info = vim.diagnostic.severity.INFO,
    hint = vim.diagnostic.severity.HINT,
  }
end

--- Parse `sley hook lint-file --json` output into Neovim diagnostics.
---
--- @param output string JSON-lines output from Sley's lint hook.
--- @param opts table|nil Optional parser settings.
--- @return table[] diagnostics Neovim `vim.diagnostic` records.
function M.parse_diagnostics(output, opts)
  opts = opts or {}

  local levels = severity_map()
  local default_severity = opts.default_severity or vim.diagnostic.severity.WARN
  local default_source = opts.source or "sley"
  local diags = {}

  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local ok, d = pcall(vim.json.decode, line)
    if ok and type(d) == "table" and type(d.line) == "number" then
      -- Sley's unified diagnostic schema is 1-based because it is also used by
      -- shell tools and human-facing JSON. Neovim diagnostics are 0-based.
      diags[#diags + 1] = {
        lnum = math.max(0, d.line - 1),
        col = math.max(0, (d.col or 1) - 1),
        end_lnum = type(d.end_line) == "number" and (d.end_line - 1) or nil,
        end_col = type(d.end_col) == "number" and (d.end_col - 1) or nil,
        severity = levels[d.severity] or default_severity,
        code = d.code,
        message = d.message,
        source = d.source or default_source,
      }
    end
  end

  return diags
end

--- Build a Conform formatter spec for `sley hook format-file`.
---
--- @param opts table|nil Options: `command`, `args`, and any Conform fields to
---   overlay onto the returned formatter spec.
--- @return table formatter Conform-compatible formatter spec.
function M.conform_formatter(opts)
  opts = opts or {}

  local formatter = {
    command = opts.command or "sley",
    args = copy_list(opts.args or { "hook", "format-file", "$FILENAME" }),
    stdin = false,
  }

  for key, value in pairs(opts) do
    if key ~= "command" and key ~= "args" then
      formatter[key] = value
    end
  end

  return formatter
end

--- Build an nvim-lint linter spec for `sley hook lint-file --json`.
---
--- @param opts table|nil Options: `command`, `args`, `condition`, parser
---   defaults, and any nvim-lint fields to overlay onto the returned spec.
--- @return table linter nvim-lint-compatible linter spec.
function M.nvim_lint_linter(opts)
  opts = opts or {}

  local parser_opts = opts.parser_opts
    or {
      default_severity = opts.default_severity,
      source = opts.source,
    }
  local linter = {
    cmd = opts.command or "sley",
    args = copy_list(opts.args or { "hook", "lint-file", "--json" }),
    stdin = false,
    append_fname = true,
    stream = "stdout",
    ignore_exitcode = true,
    condition = opts.condition,
    parser = function(output, bufnr)
      -- Keep the parser signature nvim-lint-compatible even though Sley's JSON
      -- output is file-local and does not need the buffer number today.
      return M.parse_diagnostics(output, vim.tbl_extend("keep", { bufnr = bufnr }, parser_opts))
    end,
  }

  for key, value in pairs(opts) do
    if
      key ~= "command"
      and key ~= "args"
      and key ~= "condition"
      and key ~= "parser_opts"
      and key ~= "default_severity"
      and key ~= "source"
    then
      linter[key] = value
    end
  end

  return linter
end

return M
