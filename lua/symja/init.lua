-- Symja integration for Neovim.
-- A long-lived Java process evaluates requests, so definitions survive between runs.
local M = {
  job = nil,
  next_id = 0,
  pending = {},
  output_buf = nil,
  last_source_buf = nil,
  repl_buf = nil,
  repl_count = 0,
  stdout_tail = "",
  stderr_head = {},
  stderr_tail = {},
  stderr_total = 0,
  last_bridge_error = nil,
  last_latex_error = nil,
  options = { keymaps = true, lsp = true, output_height = 8, latex = true, latex_dpi = 240, latex_cell_width_px = 10, symja_version = "3.1.1" },
  _setup = false,
  _cmp_registered = false,
  _docs_cache = {},
  _docs_pending = {},
  _jar_error_notified = false,
  _lsp_error_notified = false,
  _comment_pre_hook_wrapper = nil,
  _rendered_image = nil,
  _rendered_image_path = nil,
  _check_generation = {},
  _manual_check = {},
  _diagnostic_namespace = vim.api.nvim_create_namespace("symja-syntax"),
}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return source:gsub("[/\\]lua[/\\]symja[/\\]init%.lua$", "")
end

local function bridge_jar()
  if type(M.options.bridge_jar) == "string" and M.options.bridge_jar ~= "" then
    return vim.fn.expand(M.options.bridge_jar)
  end

  local candidates = {
    plugin_root() .. "/backend/target/symja-nvim.jar",
    vim.fn.stdpath("data") .. "/symja-nvim/backend/target/symja-nvim.jar",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return candidates[1]
end

local function local_symja_lib_dir()
  local configured = M.options.symja_lib_dir
  if type(configured) == "string" and configured ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(configured), ":p")
  end

  local home = M.options.symja_home
  if type(home) == "string" and home ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(home) .. "/lib", ":p")
  end

  configured = vim.env.SYMJA_LIB_DIR
  if type(configured) == "string" and configured ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(configured), ":p")
  end

  home = vim.env.SYMJA_HOME
  if type(home) == "string" and home ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(home) .. "/lib", ":p")
  end

  -- backend/build.sh writes this marker in local-bundle mode. It means users
  -- only need to set SYMJA_HOME for the build; the runtime path is remembered.
  local markers = {
    plugin_root() .. "/backend/target/symja-local-lib-dir",
    vim.fn.stdpath("data") .. "/symja-nvim/backend/target/symja-local-lib-dir",
  }
  for _, marker in ipairs(markers) do
    if vim.fn.filereadable(marker) == 1 then
      local lines = vim.fn.readfile(marker)
      if lines[1] and lines[1] ~= "" then
        return vim.fn.fnamemodify(vim.fn.expand(lines[1]), ":p")
      end
    end
  end
  return nil
end

local function java_classpath(jar, bridge_lib_dir)
  local path_sep = package.config:sub(1, 1) == "\\" and ";" or ":"
  local parts = { jar, bridge_lib_dir .. "/*" }
  local symja_dir = local_symja_lib_dir()
  if symja_dir and vim.fn.fnamemodify(symja_dir, ":p") ~= vim.fn.fnamemodify(bridge_lib_dir, ":p") then
    table.insert(parts, symja_dir .. "/*")
  end
  return table.concat(parts, path_sep)
end

local function validate_local_symja_lib_dir()
  local dir = local_symja_lib_dir()
  if not dir then return true end
  if vim.fn.isdirectory(dir) ~= 1 then
    return false, "Local Symja library directory not found: " .. dir
  end
  local jars = vim.fn.globpath(dir, "*.jar", false, true)
  if #jars == 0 then
    return false, "No JAR files found in local Symja library directory: " .. dir
  end
  return true
end

local function notice(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "Symja" })
  end)
end

-- Comment.nvim has its own filetype commentstring table. Register Symja there
-- so gcc/gc do not depend on a Tree-sitter parser for this custom language.
local function register_comment_nvim_filetypes()
  local ok, comment_ft = pcall(require, "Comment.ft")
  if not ok or type(comment_ft) ~= "table" or type(comment_ft.set) ~= "function" then
    return false
  end

  for _, filetype in ipairs({ "symja", "symja_mma" }) do
    local set_ok, err = pcall(comment_ft.set, filetype, { "(*%s*)", "(*%s*)" })
    if not set_ok and vim.g.symja_debug then
      notice("Could not register Comment.nvim filetype " .. filetype .. ": " .. tostring(err),
        vim.log.levels.WARN)
    end
  end

  -- A common Comment.nvim setup uses ts-context-commentstring as pre_hook.
  -- pre_hook has priority over Comment.nvim's filetype table, so bypass it
  -- for Symja buffers while preserving the user's hook for every other filetype.
  local config_ok, comment_config = pcall(require, "Comment.config")
  if config_ok and type(comment_config.get) == "function" then
    local get_ok, config = pcall(comment_config.get, comment_config)
    if get_ok and type(config) == "table" and config.pre_hook ~= M._comment_pre_hook_wrapper then
      local previous_pre_hook = config.pre_hook
      local wrapper = function(ctx)
        local filetype = vim.bo[vim.api.nvim_get_current_buf()].filetype
        if filetype == "symja" or filetype == "symja_mma" then
          return "(*%s*)"
        end
        if type(previous_pre_hook) == "function" then
          return previous_pre_hook(ctx)
        end
      end
      config.pre_hook = wrapper
      M._comment_pre_hook_wrapper = wrapper
    end
  end
  return true
end

-- Attach a real LSP client to Symja buffers. This makes the user's existing
-- vim.lsp.buf.hover() mapping work without installing or changing any keymaps.
local function start_symja_lsp(buf)
  if M.options.lsp == false then return end
  if vim.lsp and type(vim.lsp.get_clients) == "function" then
    local attached = vim.lsp.get_clients({ bufnr = buf, name = "symja" })
    if #attached > 0 then return attached[1].id end
  end
  if not vim.lsp or type(vim.lsp.start) ~= "function" then
    if not M._lsp_error_notified then
      M._lsp_error_notified = true
      notice("Symja hover requires Neovim 0.10 or newer (vim.lsp.start is unavailable)", vim.log.levels.WARN)
    end
    return
  end

  local jar = bridge_jar()
  if vim.fn.filereadable(jar) ~= 1 then
    if not M._lsp_error_notified then
      M._lsp_error_notified = true
      notice("Symja LSP JAR not found. Build it with `./backend/build.sh`.", vim.log.levels.ERROR)
    end
    return
  end
  local lib_dir = M.options.bridge_lib_dir or (vim.fn.fnamemodify(jar, ":h") .. "/lib")
  if vim.fn.isdirectory(lib_dir) ~= 1 then
    if not M._lsp_error_notified then
      M._lsp_error_notified = true
      notice("Symja LSP runtime dependencies not found: " .. lib_dir .. ". Rebuild the backend with ./backend/build.sh.",
        vim.log.levels.ERROR)
    end
    return
  end
  local local_ok, local_error = validate_local_symja_lib_dir()
  if not local_ok then
    if not M._lsp_error_notified then
      M._lsp_error_notified = true
      notice(local_error .. ". Check symja_home/symja_lib_dir or SYMJA_HOME/SYMJA_LIB_DIR.", vim.log.levels.ERROR)
    end
    return
  end

  local java = M.options.java or "java"
  if vim.fn.executable(java) ~= 1 then
    if not M._lsp_error_notified then
      M._lsp_error_notified = true
      notice("Java executable not found: " .. java, vim.log.levels.ERROR)
    end
    return
  end

  java = vim.fn.exepath(java) ~= "" and vim.fn.exepath(java) or java
  local classpath = java_classpath(jar, lib_dir)
  local docs_dir = ""
  if type(M.options.docs_dir) == "string" and M.options.docs_dir ~= "" then
    docs_dir = vim.fn.fnamemodify(vim.fn.expand(M.options.docs_dir), ":p")
  end
  local raw_base = M.options.docs_raw_base_url
    or ("https://raw.githubusercontent.com/axkr/symja_android_library/v%s/symja_android_library/doc/functions/"):format(M.options.symja_version or "3.1.1")
  local root_dir
  if vim.fs and type(vim.fs.root) == "function" then
    local ok, root = pcall(vim.fs.root, buf, { ".git" })
    if ok then root_dir = root end
  end
  root_dir = root_dir or vim.fn.getcwd()

  local config = {
    name = "symja",
    cmd = {
      java, "-cp", classpath, "org.symjanvim.SymjaLspServer",
      plugin_root(), docs_dir, raw_base, M.options.symja_version or "3.1.1",
    },
    root_dir = root_dir,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    on_attach = function(client, attached_buf)
      vim.b[attached_buf].symja_lsp_attached = true
      if vim.g.symja_debug then
        notice(string.format("Symja LSP attached (client %d, buffer %d)", client.id, attached_buf),
          vim.log.levels.DEBUG)
      end
    end,
    on_exit = function(code, signal, client_id)
      if code ~= 0 and vim.g.symja_debug then
        notice(string.format("Symja LSP exited (client %s, status %s, signal %s)",
          tostring(client_id), tostring(code), tostring(signal)), vim.log.levels.ERROR)
      end
    end,
  }
  local ok, client_id = pcall(vim.lsp.start, config, { bufnr = buf })
  if not ok or not client_id then
    if not M._lsp_error_notified then
      M._lsp_error_notified = true
      notice("Could not start the Symja LSP client: " .. tostring(client_id), vim.log.levels.ERROR)
    end
  end
end

local function split_lines(value)
  return vim.split(tostring(value or ""), "\n", { plain = true, trimempty = false })
end

local function handle_response(line)
  if line == "" then return end
  local ok, response = pcall(vim.json.decode, line)
  if not ok or type(response) ~= "table" then
    if vim.g.symja_debug then
      notice("Could not parse bridge response: " .. line, vim.log.levels.ERROR)
    end
    return
  end
  local callback = M.pending[response.id]
  M.pending[response.id] = nil
  if callback then
    vim.schedule(function() callback(response) end)
  end
end

local function remember_bridge_stderr(data)
  for _, line in ipairs(data or {}) do
    if line ~= nil and line ~= "" then
      line = tostring(line)
      M.stderr_total = M.stderr_total + 1
      if #M.stderr_head < 32 then
        table.insert(M.stderr_head, line)
      end
      table.insert(M.stderr_tail, line)
    end
  end
  -- Preserve the exception header and recent stack frames, even when a
  -- StackOverflowError produces a very large traceback.
  while #M.stderr_tail > 4000 do
    table.remove(M.stderr_tail, 1)
  end
end

local function bridge_exception_class()
  local function parse(lines)
    for _, line in ipairs(lines or {}) do
      local class = line:match('Exception in thread%s+"[^"]+"%s+([%w_.$]+)')
        or line:match('Caused by:%s*([%w_.$]+)')
        or line:match('^%s*([%w_.$]+Exception)')
        or line:match('^%s*([%w_.$]+Error)')
      if class and (class:match("Exception$") or class:match("Error$")) then
        return class
      end
    end
  end
  return parse(M.stderr_head) or parse(M.stderr_tail)
end

local function bridge_error_summary(code)
  local class = bridge_exception_class()
  if class then return class end

  local detail = tostring(M.last_bridge_error or "")
  if detail:find("JAR not found", 1, true) then return "Symja bridge JAR not found" end
  if detail:find("dependencies directory not found", 1, true) then
    return "Symja bridge runtime libraries not found"
  end
  if detail:find("Could not start Java bridge", 1, true) then
    return "Could not start Symja bridge"
  end
  if code ~= nil then return "Symja bridge exited (status " .. tostring(code) .. ")" end
  if detail ~= "" then return detail:match("^[^\n]+") end
  return "Symja bridge failed"
end

local function bridge_stderr_report()
  if M.stderr_total == 0 then
    return { "Java produced no stderr output." }
  end
  if M.stderr_total <= 4000 then
    return vim.deepcopy(M.stderr_tail)
  end

  -- Join the preserved beginning and end without duplicating their overlap.
  local overlap = 0
  local max_overlap = math.min(#M.stderr_head, #M.stderr_tail)
  for count = max_overlap, 1, -1 do
    local matches = true
    for i = 1, count do
      if M.stderr_head[#M.stderr_head - count + i] ~= M.stderr_tail[i] then
        matches = false
        break
      end
    end
    if matches then
      overlap = count
      break
    end
  end

  local lines = vim.deepcopy(M.stderr_head)
  local omitted = M.stderr_total - #M.stderr_head - #M.stderr_tail + overlap
  if omitted > 0 then
    table.insert(lines, string.format("... %d stderr lines omitted ...", omitted))
  end
  for i = overlap + 1, #M.stderr_tail do
    table.insert(lines, M.stderr_tail[i])
  end
  return lines
end

local function bridge_exit_message(code)
  local jar = bridge_jar()
  local lib_dir = M.options.bridge_lib_dir or (vim.fn.fnamemodify(jar, ":h") .. "/lib")
  local java = M.options.java or "java"
  local resolved_java = vim.fn.exepath(java)
  if resolved_java ~= "" then java = resolved_java end

  local lines = {
    string.format("Symja bridge process exited unexpectedly (status %s).", tostring(code)),
    "Java: " .. tostring(java),
    "JAR: " .. tostring(jar),
    "Runtime libraries: " .. tostring(lib_dir),
    "Local Symja libraries: " .. tostring(local_symja_lib_dir() or "not configured (Maven dependency)"),
  }
  table.insert(lines, "Java stderr:")
  for _, line in ipairs(bridge_stderr_report()) do
    table.insert(lines, "  " .. line)
  end
  if M.stdout_tail ~= "" then
    table.insert(lines, "Unterminated stdout fragment:")
    table.insert(lines, "  " .. M.stdout_tail)
  end
  return table.concat(lines, "\n")
end

local function start_backend()
  if M.job and vim.fn.jobwait({ M.job }, 0)[1] == -1 then
    return M.job
  end
  M.job = nil
  M.stdout_tail = ""
  M.stderr_head = {}
  M.stderr_tail = {}
  M.stderr_total = 0
  M.last_bridge_error = nil

  local jar = bridge_jar()
  if vim.fn.filereadable(jar) ~= 1 then
    M.last_bridge_error = "Symja bridge JAR not found: " .. tostring(jar)
      .. "\nBuild it with: ./backend/build.sh"
    if not M._jar_error_notified then
      M._jar_error_notified = true
      notice(bridge_error_summary(), vim.log.levels.ERROR)
    end
    return nil
  end

  local lib_dir = M.options.bridge_lib_dir or (vim.fn.fnamemodify(jar, ":h") .. "/lib")
  if vim.fn.isdirectory(lib_dir) ~= 1 then
    M.last_bridge_error = "Symja runtime dependencies directory not found: " .. tostring(lib_dir)
      .. "\nRebuild the backend with: ./backend/build.sh"
    notice(bridge_error_summary(), vim.log.levels.ERROR)
    return nil
  end
  local local_ok, local_error = validate_local_symja_lib_dir()
  if not local_ok then
    M.last_bridge_error = local_error .. "\nCheck symja_home/symja_lib_dir or SYMJA_HOME/SYMJA_LIB_DIR."
    notice(bridge_error_summary(), vim.log.levels.ERROR)
    return nil
  end

  -- Keep dependencies as separate JARs. In particular, Log4j API is a
  -- multi-release JAR and must not be flattened into an uber-JAR by Shade.
  local classpath = java_classpath(jar, lib_dir)
  local java = M.options.java or "java"
  local java_exepath = vim.fn.exepath(java)
  if java_exepath ~= "" then java = java_exepath end
  local command = { java, "-cp", classpath, "org.symjanvim.SymjaBridge" }
  local start_ok, job_id = pcall(vim.fn.jobstart, command, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for i, chunk in ipairs(data) do
        if i == 1 then chunk = M.stdout_tail .. chunk end
        if i < #data then
          if chunk ~= "" then handle_response(chunk) end
        else
          M.stdout_tail = chunk
        end
      end
    end,
    on_stderr = function(_, data)
      remember_bridge_stderr(data)
      if vim.g.symja_debug and data then
        for _, line in ipairs(data) do
          if line ~= "" then notice("bridge: " .. line, vim.log.levels.DEBUG) end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        M.job = nil
        local message = bridge_exit_message(code)
        M.last_bridge_error = message
        local pending = M.pending
        M.pending = {}
        local summary = bridge_error_summary(code)
        for _, callback in pairs(pending) do
          callback({ ok = false, error = summary })
        end
        if code ~= 0 then
          notice(summary, vim.log.levels.ERROR)
        end
      end)
    end,
  })

  if not start_ok then
    M.job = nil
    M.last_bridge_error = "Could not start Java bridge: " .. tostring(job_id)
    notice(bridge_error_summary(), vim.log.levels.ERROR)
    return nil
  end
  M.job = job_id
  if type(M.job) ~= "number" or M.job <= 0 then
    local code = M.job
    M.job = nil
    M.last_bridge_error = string.format(
      "Could not start Java bridge (jobstart returned %s). Java: %s; JAR: %s; runtime libraries: %s",
      tostring(code), tostring(java), tostring(jar), tostring(lib_dir))
    notice(bridge_error_summary(), vim.log.levels.ERROR)
    return nil
  end
  return M.job
end

local function send(method, code, mode, callback, request_options)
  local job = start_backend()
  if not job then
    if callback then
      vim.schedule(function()
        callback({ ok = false, error = bridge_error_summary() })
      end)
    end
    return false
  end

  M.next_id = M.next_id + 1
  local id = M.next_id
  M.pending[id] = callback
  local payload = {
    id = id,
    method = method,
    code = code or "",
    mode = mode or "native",
  }
  if type(request_options) == "table" then
    for key, value in pairs(request_options) do
      payload[key] = value
    end
  end
  local request = vim.json.encode(payload) .. "\n"
  local ok, result = pcall(vim.fn.chansend, job, request)
  if not ok or result == 0 then
    M.pending[id] = nil
    local detail = not ok and tostring(result) or "job channel is closed (chansend returned 0)"
    local message = "Could not send request to the Symja bridge: " .. detail
    notice(message, vim.log.levels.ERROR)
    if callback then
      vim.schedule(function()
        callback({ ok = false, error = message })
      end)
    end
    return false
  end
  return true
end

local function is_symja_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local ft = vim.bo[buf].filetype
  return ft == "symja" or ft == "symja_mma"
end

-- Showing results opens/focuses the output split. Keep its source association
-- separate from the output text so commands invoked there never evaluate the
-- generated result as if it were Symja source.
local function evaluation_buffer()
  local current = vim.api.nvim_get_current_buf()
  -- The output buffer is not executable source. Prefer the exact source buffer
  -- associated with the displayed result, then fall back to the most recently
  -- used Symja source buffer.
  if current == M.output_buf or vim.bo[current].filetype == "symja_output" then
    local associated = vim.b[current].symja_source_buf
    if is_symja_buffer(associated) then
      return associated
    end
    if is_symja_buffer(M.last_source_buf) then
      return M.last_source_buf
    end
    return nil
  end
  return current
end

local function remember_source_buffer(buf)
  if is_symja_buffer(buf) then M.last_source_buf = buf end
end

local function mode_for_buffer(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local explicit = vim.b[buf].symja_mode
  if explicit == "mma" or explicit == "native" then return explicit end
  if vim.bo[buf].filetype == "symja_mma" then return "mma" end
  return "native"
end

local function is_kitty()
  return vim.env.KITTY_WINDOW_ID ~= nil or vim.env.TERM == "xterm-kitty"
end

local function clear_rendered_image()
  if M._rendered_image then
    pcall(function() M._rendered_image:clear() end)
    M._rendered_image = nil
  end
  if M._rendered_image_path then
    pcall(vim.fn.delete, M._rendered_image_path)
    M._rendered_image_path = nil
  end
end

local function render_latex(latex, callback)
  if M.options.latex == false then
    callback(nil, "LaTeX image rendering is disabled (latex = false)")
    return
  end
  if not is_kitty() then
    callback(nil, "LaTeX image rendering requires running Neovim inside Kitty")
    return
  end

  -- image.nvim owns Kitty image placement, scrolling, clipping, and cleanup.
  -- Keep it optional: evaluation itself must continue to work without it.
  local image_ok = pcall(require, "image")
  if not image_ok then
    callback(nil, "Install the optional plugin 3rd/image.nvim to display formulas as images")
    return
  end

  local renderer
  if type(M.options.latex_renderer) == "string" and M.options.latex_renderer ~= "" then
    renderer = vim.fn.expand(M.options.latex_renderer)
  else
    local candidates = {
      plugin_root() .. "/scripts/render-latex.sh",
      vim.fn.stdpath("data") .. "/symja-nvim/scripts/render-latex.sh",
    }
    for _, candidate in ipairs(candidates) do
      if vim.fn.executable(candidate) == 1 then
        renderer = candidate
        break
      end
    end
    renderer = renderer or candidates[1]
  end
  if vim.fn.executable(renderer) ~= 1 then
    callback(nil, "LaTeX renderer is missing or not executable: " .. renderer)
    return
  end

  M.last_latex_error = nil
  M._latex_render_counter = (M._latex_render_counter or 0) + 1
  local token = string.format("%d-%d", vim.fn.getpid(), M._latex_render_counter)
  local tex_path = vim.fn.tempname() .. ".tex"
  local png_path = (vim.env.TMPDIR or "/tmp") .. "/symja-latex-" .. token .. ".png"
  local highlight_ok, normal_hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  local foreground = highlight_ok and normal_hl.fg or nil
  local tex_color = foreground and string.format("%06X", foreground)
    or (vim.o.background == "dark" and "FFFFFF" or "000000")

  local dpi = math.floor(tonumber(M.options.latex_dpi) or 240)
  dpi = math.max(96, math.min(600, dpi))

  -- breqn needs a real display-math environment (standalone's preview wrapper
  -- groups the content in a way that conflicts with dmath). Limit the TeX
  -- line width to this Neovim window so long results wrap before image.nvim
  -- has a reason to scale them down. Kitty cell width varies with font/DPI,
  -- so expose the pixel estimate as an option.
  local window_width = vim.api.nvim_win_get_width(0)
  local available_cells = math.max(10, window_width - 2)
  local cell_width_px = math.max(4, tonumber(M.options.latex_cell_width_px) or 10)
  local width_pt = math.max(24, math.floor(available_cells * cell_width_px * 72 / dpi))
  local tex = table.concat({
    "\\documentclass{article}",
    string.format("\\usepackage[paperwidth=%dpt,paperheight=1200pt,margin=0pt]{geometry}", width_pt),
    "\\usepackage{xcolor,amsmath,amssymb}",
    "\\usepackage{breqn}",
    "\\pagestyle{empty}",
    "\\setlength{\\parindent}{0pt}",
    string.format("\\setlength{\\textwidth}{%dpt}", width_pt),
    string.format("\\setlength{\\hsize}{%dpt}", width_pt),
    "\\begin{document}",
    "{\\color[HTML]{" .. tex_color .. "}\\begin{dmath*}" .. tostring(latex) .. "\\end{dmath*}}",
    "\\end{document}",
  }, "\n")
  local write_ok = vim.fn.writefile(split_lines(tex), tex_path)
  if write_ok ~= 0 then
    callback(nil, "Could not write temporary LaTeX source")
    return
  end

  local stderr = {}
  local render_job = vim.fn.jobstart({ renderer, tex_path, png_path, tostring(dpi) }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            stderr[#stderr + 1] = line
            if vim.g.symja_debug then notice("LaTeX: " .. line, vim.log.levels.DEBUG) end
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        pcall(vim.fn.delete, tex_path)
        if code ~= 0 or vim.fn.filereadable(png_path) ~= 1 then
          pcall(vim.fn.delete, png_path)
          local detail = #stderr > 0 and table.concat(stderr, "\n")
            or ("renderer exited with code " .. tostring(code))
          M.last_latex_error = "LaTeX rendering failed (exit code " .. tostring(code) .. ")\n\n" .. detail
          callback(nil, "LaTeX rendering failed. Run :SymjaLatexError for the full diagnostic.")
          return
        end
        callback({ path = png_path }, nil)
      end)
    end,
  })
  if render_job <= 0 then
    pcall(vim.fn.delete, tex_path)
    pcall(vim.fn.delete, png_path)
    M.last_latex_error = "Could not start the LaTeX renderer process (job id " .. tostring(render_job) .. ")"
    callback(nil, "Could not start the LaTeX renderer process. Run :SymjaLatexError for details.")
  end
end

local function open_output(lines, source_buf)
  local buf = M.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.cmd("botright " .. tostring(math.max(3, tonumber(M.options.output_height) or 8)) .. "new")
    buf = vim.api.nvim_get_current_buf()
    M.output_buf = buf
    pcall(vim.api.nvim_buf_set_name, buf, "Symja Output")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "symja_output"
  else
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
      vim.cmd("botright " .. tostring(math.max(3, tonumber(M.options.output_height) or 8)) .. "split")
      vim.api.nvim_win_set_buf(0, buf)
    else
      vim.api.nvim_set_current_win(win)
    end
  end
  if M.options.keymaps ~= false then
    local leader = vim.g.mapleader or "\\"
    local lhs = "<leader>rr"
    if vim.fn.maparg(lhs:gsub("<leader>", leader), "n") == "" then
      vim.keymap.set("n", lhs, "<cmd>SymjaRun<cr>", {
        buffer = buf,
        silent = true,
        desc = "Run Symja source buffer (text)",
      })
    end
    local latex_lhs = "<leader>rl"
    if vim.fn.maparg(latex_lhs:gsub("<leader>", leader), "n") == "" then
      vim.keymap.set("n", latex_lhs, "<cmd>SymjaRunLatex<cr>", {
        buffer = buf,
        silent = true,
        desc = "Run Symja source buffer (LaTeX)",
      })
    end
  end
  if is_symja_buffer(source_buf) then
    vim.b[buf].symja_source_buf = source_buf
    remember_source_buffer(source_buf)
  elseif not is_symja_buffer(vim.b[buf].symja_source_buf) and is_symja_buffer(M.last_source_buf) then
    vim.b[buf].symja_source_buf = M.last_source_buf
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.cmd("normal! G")
  return buf
end

local function show_eval_result(label, response, as_latex, source_buf)
  local header = { label, string.rep("─", math.max(12, #label)) }

  local function show_text(reason)
    clear_rendered_image()
    local lines = vim.deepcopy(header)
    local result = response.ok and response.result or ("ERROR: " .. tostring(response.error or "unknown error"))
    vim.list_extend(lines, split_lines(result))
    open_output(lines, source_buf)
    if reason then
      notice(reason .. "; showing the evaluated result as text", vim.log.levels.WARN)
    end
  end

  if not response.ok then
    show_text(nil)
    return
  end
  if not as_latex then
    show_text(nil)
    return
  end
  if type(response.latex) ~= "string" or response.latex == "" then
    show_text("Symja did not provide a LaTeX representation")
    return
  end

  render_latex(response.latex, function(rendered, render_error)
    if not rendered then
      show_text(render_error or "LaTeX rendering failed")
      return
    end

    clear_rendered_image()
    local lines = vim.deepcopy(header)
    local image_row = #lines -- zero-based row: place the image below the header
    lines[#lines + 1] = "" -- image anchor line
    -- image.nvim adds virtual lines below the anchor to reserve the image's
    -- height. Keep a real buffer line after those virtual lines so the cursor
    -- can move past the image and scroll its bottom into view.
    lines[#lines + 1] = ""
    local buf = open_output(lines, source_buf)
    local win = vim.api.nvim_get_current_win()

    local ok, image_api = pcall(require, "image")
    if not ok then
      pcall(vim.fn.delete, rendered.path)
      show_text("Install the optional plugin 3rd/image.nvim to display formulas as images")
      return
    end

    -- Do not force a fixed width: that stretches short formulas and shrinks
    -- long ones, making the apparent font size depend on expression length.
    -- With no width/height override, image.nvim uses the PNG's native pixel
    -- dimensions and maps them to the terminal's cell geometry. The source
    -- is rasterized at a fixed DPI, so the TeX font size stays consistent.
    local image_ok, image = pcall(image_api.from_file, rendered.path, {
      buffer = buf,
      window = win,
      x = 0,
      y = image_row,
      inline = true,
      with_virtual_padding = true,
      -- image.nvim defaults this to 50%, which shrinks tall formulas even
      -- when their width fits. Let multiline results keep their native size.
      max_height_window_percentage = 1000,
    })
    if not image_ok or not image then
      pcall(vim.fn.delete, rendered.path)
      show_text("image.nvim could not load the rendered formula: " .. tostring(image))
      return
    end

    local display_ok, display_error = pcall(function() image:render() end)
    if not display_ok then
      pcall(function() image:clear() end)
      pcall(vim.fn.delete, rendered.path)
      show_text("image.nvim could not display the rendered formula: " .. tostring(display_error))
      return
    end

    M._rendered_image = image
    M._rendered_image_path = rendered.path
    -- Reposition after image.nvim has inserted its virtual padding. This puts
    -- the cursor on the real blank line after the image, making the bottom of
    -- a tall image reachable with normal scrolling.
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end)
end

local function buffer_text(buf, first, last)
  return table.concat(vim.api.nvim_buf_get_lines(buf, first, last, true), "\n")
end

local function set_mode(buf, mode)
  if mode ~= "native" and mode ~= "mma" then
    notice("Syntax mode must be 'native' or 'mma'", vim.log.levels.ERROR)
    return false
  end
  local ft = mode == "mma" and "symja_mma" or "symja"
  vim.b[buf].symja_mode = mode
  vim.api.nvim_buf_call(buf, function()
    -- Clear the previous syntax's guard variable so changing mode in-place
    -- actually loads the new syntax file instead of stopping at b:current_syntax.
    vim.cmd("syntax clear")
    vim.b.current_syntax = nil
    vim.bo.filetype = ft
    vim.bo.syntax = ft
    vim.bo.commentstring = "(* %s *)"
    vim.bo.comments = "s1:(*,mb:*,ex:*)"
  end)
  return true
end

function M.complete(prefix, callback)
  prefix = tostring(prefix or "")
  return send("complete", prefix, "native", function(response)
    if response.ok and type(response.symbols) == "table" then
      callback(response.symbols)
    else
      callback({})
    end
  end)
end

function M.register_cmp()
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    notice("nvim-cmp is not installed; Symja completion source was not registered", vim.log.levels.WARN)
    return false
  end
  if M._cmp_registered then return true end
  local source_ok, source = pcall(require, "cmp_symja")
  if not source_ok then
    notice("Could not load cmp_symja: " .. tostring(source), vim.log.levels.ERROR)
    return false
  end
  cmp.register_source("symja", source.new())

  -- Add the source to the existing global source list rather than replacing
  -- the user's filetype configuration or requiring cmp-buffer/luasnip/etc.
  -- The source's is_available() method limits it to Symja buffers.
  if type(cmp.get_config) == "function" and type(cmp.setup) == "function" then
    local config = cmp.get_config()
    config.sources = config.sources or {}
    local present = false
    for _, entry in ipairs(config.sources) do
      if entry.name == "symja" then
        present = true
        break
      end
    end
    if not present then
      table.insert(config.sources, { name = "symja" })
      cmp.setup(config)
    end
  end

  M._cmp_registered = true
  return true
end

local function show_documentation(symbol, lines)
  if type(lines) ~= "table" or #lines == 0 then
    notice("The Symja documentation page for " .. symbol .. " is empty", vim.log.levels.WARN)
    return
  end

  local buf_name = "SymjaDoc://" .. symbol
  local buf = vim.fn.bufnr(buf_name)
  if buf < 0 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, buf_name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  local height = math.max(8, math.min(#lines, tonumber(M.options.docs_height) or 20))
  vim.cmd("botright " .. height .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.keymap.set("n", "q", "<cmd>close<cr>", {
    buffer = buf,
    silent = true,
    desc = "Close Symja documentation",
  })
end

local function local_documentation_path(symbol)
  local dirs, seen = {}, {}
  local function add_dir(path)
    if type(path) ~= "string" or path == "" then return end
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
    if not seen[path] then
      seen[path] = true
      dirs[#dirs + 1] = path
    end
  end

  -- `docs_dir` may be the functions directory itself, the `doc` directory,
  -- or the root of the extracted Symja bundle. Keep it first, but do not let
  -- a missing page there prevent checking the other local Symja copies.
  if type(M.options.docs_dir) == "string" and M.options.docs_dir ~= "" then
    local configured = vim.fn.expand(M.options.docs_dir)
    add_dir(configured)
    add_dir(configured .. "/functions")
    add_dir(configured .. "/doc/functions")
    add_dir(configured .. "/symja_android_library/doc/functions")
  end

  local root = plugin_root()
  local home = M.options.symja_home
  if type(home) ~= "string" or home == "" then home = vim.env.SYMJA_HOME end
  if type(home) == "string" and home ~= "" then
    add_dir(home .. "/symja_android_library/doc/functions")
    add_dir(home .. "/doc/functions")
  end
  -- Also support the Symja 3.1.1 application/source bundle when a user keeps
  -- it beside this plugin; neither the bundle nor local docs are required.
  local version = M.options.symja_version or "3.1.1"
  add_dir(root .. "/../symja-" .. version .. "/symja_android_library/doc/functions")
  add_dir(root .. "/../symja-" .. version .. "/doc/functions")
  add_dir(root .. "/../symja_android_library/doc/functions")
  -- Also support a source tree or docs copy placed inside the plugin itself.
  add_dir(root .. "/symja_android_library/doc/functions")
  add_dir(root .. "/doc/functions")

  for _, dir in ipairs(dirs) do
    local path = dir .. "/" .. symbol .. ".md"
    if vim.fn.filereadable(path) == 1 then return path end
  end
  return nil
end

local function normalize_documentation_symbol(symbol)
  symbol = tostring(symbol or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- A symbol may be context-qualified (System`Integrate); docs use the bare name.
  symbol = symbol:gsub("^.*`", "")
  if not symbol:match("^[%a_$][%w_$]*$") then return nil end
  return symbol
end

-- Load the original Symja Markdown once per symbol. The same loader is used by
-- :SymjaDoc and nvim-cmp's resolve() callback, so suggestions show the exact
-- upstream reference text rather than locally-authored summaries.
function M.get_documentation(symbol, callback)
  symbol = normalize_documentation_symbol(symbol)
  if not symbol then
    callback(nil, "Not a valid Symja symbol name")
    return
  end

  if M._docs_cache[symbol] then
    callback(vim.deepcopy(M._docs_cache[symbol]))
    return
  end

  M._docs_pending[symbol] = M._docs_pending[symbol] or {}
  table.insert(M._docs_pending[symbol], callback)
  if #M._docs_pending[symbol] > 1 then return end

  local function finish(lines, err)
    if lines and #lines > 0 then
      M._docs_cache[symbol] = vim.deepcopy(lines)
    end
    local callbacks = M._docs_pending[symbol] or {}
    M._docs_pending[symbol] = nil
    for _, cb in ipairs(callbacks) do
      cb(lines and vim.deepcopy(lines) or nil, err)
    end
  end

  local local_path = local_documentation_path(symbol)
  if local_path then
    finish(vim.fn.readfile(local_path))
    return
  end

  local curl = M.options.curl or "curl"
  if vim.fn.executable(curl) ~= 1 then
    finish(nil, "No local Symja docs found and curl is unavailable. Set docs_dir or install curl.")
    return
  end

  -- Fetch the original Markdown from the exact Symja version used by the bridge.
  local base = M.options.docs_raw_base_url
    or ("https://raw.githubusercontent.com/axkr/symja_android_library/v%s/symja_android_library/doc/functions/"):format(M.options.symja_version or "3.1.1")
  local stdout, stderr = {}, {}
  local job = vim.fn.jobstart({ curl, "--fail", "--silent", "--show-error", "--location", base .. symbol .. ".md" }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) stdout = data or {} end,
    on_stderr = function(_, data) stderr = data or {} end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 and #stdout > 0 and not (#stdout == 1 and stdout[1] == "") then
          if stdout[#stdout] == "" then table.remove(stdout) end
          finish(stdout)
          return
        end

        local detail = table.concat(stderr, " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if detail:find("404", 1, true) then
          finish(nil, "Symja has no published function-reference page for " .. symbol)
        else
          finish(nil, "Could not load Symja documentation for " .. symbol
            .. (detail ~= "" and (": " .. detail) or ""))
        end
      end)
    end,
  })
  if job <= 0 then
    finish(nil, "Could not start curl to retrieve Symja documentation")
  end
end

local function open_documentation(symbol)
  symbol = symbol == "" and vim.fn.expand("<cword>") or symbol
  local normalized = normalize_documentation_symbol(symbol)
  if not normalized then
    notice("Usage: :SymjaDoc SymbolName (use a built-in symbol name)", vim.log.levels.WARN)
    return
  end

  M.get_documentation(normalized, function(lines, err)
    if lines then
      show_documentation(normalized, lines)
    else
      notice(err or ("No documentation available for " .. normalized), vim.log.levels.WARN)
    end
  end)
end

local function apply_syntax_check(buf, changedtick)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return end
  if vim.api.nvim_buf_get_changedtick(buf) ~= changedtick then return end
  local ft = vim.bo[buf].filetype
  if ft ~= "symja" and ft ~= "symja_mma" then return end

  local code = buffer_text(buf, 0, -1)
  send("check", code, mode_for_buffer(buf), function(response)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.api.nvim_buf_get_changedtick(buf) ~= changedtick then return end
    if not response.ok then
      if vim.g.symja_debug then
        notice("Syntax check failed: " .. tostring(response.error), vim.log.levels.WARN)
      end
      return
    end

    local diagnostics = {}
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
    for _, item in ipairs(response.diagnostics or {}) do
      local line = math.max(0, tonumber(item.line) or 0)
      local col = math.max(0, tonumber(item.column) or 0)
      local line_text = lines[line + 1] or ""
      col = math.min(col, #line_text)
      local end_col = math.min(#line_text, col + math.max(1, tonumber(item.length) or 1))
      diagnostics[#diagnostics + 1] = {
        lnum = line,
        col = col,
        end_lnum = line,
        end_col = math.max(col, end_col),
        severity = item.severity == "warning" and vim.diagnostic.severity.WARN
          or vim.diagnostic.severity.ERROR,
        source = "symja",
        message = tostring(item.message or "Syntax error"),
      }
    end
    vim.diagnostic.set(M._diagnostic_namespace, buf, diagnostics)
    if M._manual_check[buf] then
      M._manual_check[buf] = nil
      if #diagnostics == 0 then
        notice("No Symja syntax errors", vim.log.levels.INFO)
      else
        notice(string.format("Found %d Symja syntax error(s)", #diagnostics), vim.log.levels.WARN)
      end
    end
  end)
end

local function schedule_syntax_check(buf)
  if M.options.syntax_check == false then
    vim.diagnostic.reset(M._diagnostic_namespace, buf)
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local ft = vim.bo[buf].filetype
  if ft ~= "symja" and ft ~= "symja_mma" then return end

  local generation = (M._check_generation[buf] or 0) + 1
  M._check_generation[buf] = generation
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  vim.defer_fn(function()
    if M._check_generation[buf] ~= generation then return end
    apply_syntax_check(buf, changedtick)
  end, math.max(100, tonumber(M.options.syntax_check_debounce_ms) or 500))
end

function M.check(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local ft = vim.bo[buf].filetype
  if ft ~= "symja" and ft ~= "symja_mma" then
    notice(":SymjaCheck requires a .symja, .mma, .wl, or .wls buffer", vim.log.levels.WARN)
    return
  end
  local generation = (M._check_generation[buf] or 0) + 1
  M._check_generation[buf] = generation
  M._manual_check[buf] = true
  apply_syntax_check(buf, vim.api.nvim_buf_get_changedtick(buf))
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
  if M._setup then return M end
  M._setup = true

  local cleanup_group = vim.api.nvim_create_augroup("SymjaImageCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = cleanup_group,
    callback = clear_rendered_image,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = cleanup_group,
    callback = function(event)
      if event.buf == M.output_buf and M._rendered_image then
        vim.schedule(function()
          if M._rendered_image then
            pcall(function() M._rendered_image:render() end)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = cleanup_group,
    callback = function(event)
      if event.buf == M.output_buf then
        clear_rendered_image()
        M.output_buf = nil
      end
    end,
  })

  vim.filetype.add({ extension = {
    symja = "symja",
    mma = "symja_mma",
    wl = "symja_mma",
    wls = "symja_mma",
  } })

  local function evaluate_buffer(as_latex)
    local buf = evaluation_buffer()
    if not buf then
      notice("No Symja source buffer is associated with this output. Open a .symja or .mma buffer first.",
        vim.log.levels.WARN)
      return
    end
    remember_source_buffer(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local label = "Symja (" .. mode_for_buffer(buf) .. "): " .. (name ~= "" and name or "current buffer")
    send("eval", buffer_text(buf, 0, -1), mode_for_buffer(buf), function(response)
      show_eval_result(label, response, as_latex, buf)
    end, as_latex and { renderLatex = true } or nil)
  end

  local function evaluate_range(opts, as_latex)
    local buf = evaluation_buffer()
    if not buf then
      notice("No Symja source buffer is associated with this output. Open a .symja or .mma buffer first.",
        vim.log.levels.WARN)
      return
    end
    remember_source_buffer(buf)

    local code
    local label
    if opts.args ~= "" then
      code = opts.args
      label = string.format("Symja (%s): expression", mode_for_buffer(buf))
    else
      code = buffer_text(buf, opts.line1 - 1, opts.line2)
      label = string.format("Symja (%s): lines %d-%d", mode_for_buffer(buf), opts.line1, opts.line2)
    end
    send("eval", code, mode_for_buffer(buf), function(response)
      show_eval_result(label, response, as_latex, buf)
    end, as_latex and { renderLatex = true } or nil)
  end

  vim.api.nvim_create_user_command("SymjaRun", function()
    evaluate_buffer(false)
  end, { desc = "Evaluate the current Symja buffer and show text output" })

  vim.api.nvim_create_user_command("SymjaRunLatex", function()
    evaluate_buffer(true)
  end, { desc = "Evaluate the current Symja buffer and render its result as LaTeX" })

  vim.api.nvim_create_user_command("SymjaEval", function(opts)
    evaluate_range(opts, false)
  end, {
    nargs = "*",
    range = true,
    desc = "Evaluate an expression, current line, or selection and show text output",
  })

  vim.api.nvim_create_user_command("SymjaEvalLatex", function(opts)
    evaluate_range(opts, true)
  end, {
    nargs = "*",
    range = true,
    desc = "Evaluate an expression, current line, or selection and render its result as LaTeX",
  })

  vim.api.nvim_create_user_command("SymjaReset", function()
    send("reset", "", "native", function(response)
      notice(response.ok and response.result or response.error,
        response.ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end, { desc = "Reset the shared Symja evaluator and definitions" })

  vim.api.nvim_create_user_command("SymjaPing", function()
    send("ping", "", "native", function(response)
      notice(response.ok and response.result or response.error,
        response.ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end, { desc = "Check whether the Symja bridge responds" })

  vim.api.nvim_create_user_command("SymjaBridgeInfo", function()
    local jar = bridge_jar()
    local lib_dir = M.options.bridge_lib_dir or (vim.fn.fnamemodify(jar, ":h") .. "/lib")
    local java = M.options.java or "java"
    local resolved_java = vim.fn.exepath(java)
    if resolved_java ~= "" then java = resolved_java end
    local lines = {
      "Symja bridge job: " .. tostring(M.job or "not running"),
      "Java: " .. tostring(java),
      "JAR: " .. tostring(jar) .. (vim.fn.filereadable(jar) == 1 and " [found]" or " [missing]"),
      "Runtime libraries: " .. tostring(lib_dir)
        .. (vim.fn.isdirectory(lib_dir) == 1 and " [found]" or " [missing]"),
    }
    local local_dir = local_symja_lib_dir()
    table.insert(lines, "Local Symja libraries: " .. tostring(local_dir or "not configured (Maven dependency)"))
    if local_dir then
      local valid_local = validate_local_symja_lib_dir()
      table.insert(lines, "Local Symja status: " .. (valid_local and "[found]" or "[missing/invalid]"))
    end
    if M.last_bridge_error then
      table.insert(lines, "Last bridge error: " .. bridge_error_summary())
      table.insert(lines, "Run :SymjaBridgeError to inspect the full stack trace and stderr.")
    elseif M.stderr_total > 0 then
      table.insert(lines, "Java stderr has been captured. Run :SymjaBridgeError to inspect it.")
    else
      table.insert(lines, "No bridge error or stderr output recorded.")
    end
    notice(table.concat(lines, "\n"), M.last_bridge_error and vim.log.levels.ERROR or vim.log.levels.INFO)
  end, { desc = "Show Symja bridge paths and recent startup/runtime errors" })

  vim.api.nvim_create_user_command("SymjaLatexError", function()
    local detail = M.last_latex_error or "No LaTeX rendering error has been recorded."
    vim.cmd("botright 16new")
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_name, buf, "Symja LaTeX Error")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "text"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(detail, "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, desc = "Close Symja LaTeX error" })
  end, { desc = "Open the full LaTeX rendering error and compiler log" })

  vim.api.nvim_create_user_command("SymjaBridgeError", function()
    local detail = M.last_bridge_error
    if not detail then
      if M.stderr_total > 0 then
        detail = "Recent Symja bridge stderr:\n" .. table.concat(bridge_stderr_report(), "\n")
      else
        detail = "No Symja bridge error has been recorded."
      end
    end

    vim.cmd("botright 12new")
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_name, buf, "Symja Bridge Error")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "text"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(detail, "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, desc = "Close Symja bridge error" })
  end, { desc = "Open the full Symja bridge error and captured Java stack trace" })

  vim.api.nvim_create_user_command("SymjaCheck", function()
    M.check(vim.api.nvim_get_current_buf())
  end, { desc = "Check the current Symja buffer for syntax errors" })

  vim.api.nvim_create_user_command("SymjaCheckToggle", function()
    M.options.syntax_check = M.options.syntax_check == false
    if M.options.syntax_check then
      notice("Automatic Symja syntax checking enabled")
      M.check(vim.api.nvim_get_current_buf())
    else
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        vim.diagnostic.reset(M._diagnostic_namespace, buf)
      end
      notice("Automatic Symja syntax checking disabled")
    end
  end, { desc = "Toggle automatic Symja syntax checking" })

  vim.api.nvim_create_user_command("SymjaDoc", function(opts)
    open_documentation(opts.args)
  end, {
    nargs = "?",
    desc = "Open the Symja built-in function reference for a symbol",
  })

  vim.api.nvim_create_user_command("SymjaLspInfo", function()
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    local clients = {}
    if vim.lsp and type(vim.lsp.get_clients) == "function" then
      clients = vim.lsp.get_clients({ bufnr = buf })
    end

    if #clients == 0 then
      notice(string.format(
        "No LSP client is attached to this buffer (filetype=%s). Check :messages and :LspLog; expected Java class org.symjanvim.SymjaLspServer.",
        ft), vim.log.levels.WARN)
      return
    end

    for _, client in ipairs(clients) do
      local supports_hover = client:supports_method("textDocument/hover")
      notice(string.format("LSP %s (id=%d): hover=%s, root=%s, cmd=%s",
        client.name, client.id, tostring(supports_hover), tostring(client.config.root_dir),
        vim.inspect(client.config.cmd)), supports_hover and vim.log.levels.INFO or vim.log.levels.WARN)
    end
  end, { desc = "Show Symja/LSP attachment status for the current buffer" })

  vim.api.nvim_create_user_command("SymjaMode", function(opts)
    local buf = vim.api.nvim_get_current_buf()
    if opts.args == "" then
      notice("Current Symja syntax mode: " .. mode_for_buffer(buf))
      return
    end
    local requested = opts.args:lower()
    if requested == "wolfram" or requested == "mathematica" then requested = "mma" end
    if set_mode(buf, requested) then
      notice("Symja syntax mode set to " .. requested)
    end
  end, {
    nargs = "?",
    complete = function() return { "native", "mma" } end,
    desc = "Show or set this buffer's Symja syntax mode (native/mma)",
  })

  local function submit_repl()
    local buf = vim.api.nvim_get_current_buf()
    if buf ~= M.repl_buf or not vim.api.nvim_buf_is_valid(buf) then
      notice("Open the Symja REPL with :SymjaRepl first", vim.log.levels.WARN)
      return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local count = vim.api.nvim_buf_line_count(buf)
    if row ~= count then
      notice("Submit only the last line in the REPL", vim.log.levels.WARN)
      return
    end

    local code = vim.api.nvim_get_current_line():gsub("^%s+", ""):gsub("%s+$", "")
    if code == "" then return end

    M.repl_count = M.repl_count + 1
    local n = M.repl_count
    vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { "In[" .. n .. "]:=" .. " " .. code })
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "… evaluating …" })
    vim.bo[buf].modified = false
    -- Avoid a second input racing with the previous request's asynchronous output.
    vim.bo[buf].modifiable = false

    send("eval", code, mode_for_buffer(buf), function(response)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.bo[buf].modifiable = true
      local last = vim.api.nvim_buf_line_count(buf)
      local output = response.ok and split_lines(response.result)
        or split_lines("ERROR: " .. tostring(response.error or "unknown error"))
      if #output == 0 then output = { "" } end
      output[1] = "Out[" .. n .. "]:=" .. " " .. output[1]
      vim.api.nvim_buf_set_lines(buf, last - 1, last, false, output)
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
      vim.bo[buf].modified = false
      if vim.api.nvim_get_current_buf() == buf then
        vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
        vim.cmd("startinsert")
      end
    end)
  end

  vim.api.nvim_create_user_command("SymjaReplSubmit", submit_repl, {
    desc = "Submit the current Symja REPL input",
  })

  local function exit_repl()
    local buf = M.repl_buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      M.repl_buf = nil
      notice("The Symja REPL is not open", vim.log.levels.WARN)
      return
    end
    if vim.api.nvim_get_current_buf() ~= buf then
      notice("Run :SymjaReplExit from the Symja REPL buffer", vim.log.levels.WARN)
      return
    end

    -- The evaluator is shared with normal buffer evaluation, so closing the
    -- REPL must not stop the Java bridge or discard its definitions.
    vim.api.nvim_buf_delete(buf, { force = true })
    M.repl_buf = nil
  end

  vim.api.nvim_create_user_command("SymjaReplExit", exit_repl, {
    desc = "Close the Symja REPL (keep the shared evaluator running)",
  })

  vim.api.nvim_create_user_command("SymjaRepl", function(opts)
    local requested = opts.args:lower()
    if requested == "wolfram" or requested == "mathematica" then requested = "mma" end
    if requested ~= "" and requested ~= "native" and requested ~= "mma" then
      notice("Usage: :SymjaRepl [native|mma]", vim.log.levels.ERROR)
      return
    end

    if M.repl_buf and vim.api.nvim_buf_is_valid(M.repl_buf) then
      vim.api.nvim_set_current_buf(M.repl_buf)
      if requested ~= "" then set_mode(M.repl_buf, requested) end
    else
      local buf = vim.api.nvim_create_buf(false, true)
      M.repl_buf = buf
      vim.api.nvim_buf_set_name(buf, "Symja REPL")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "(* Persistent Symja REPL. Enter evaluates the last line. *)",
        "",
      })
      vim.bo[buf].buftype = "nofile"
      -- :q should really close the scratch REPL, not leave a hidden buffer.
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].swapfile = false
      vim.api.nvim_set_current_buf(buf)
      set_mode(buf, requested ~= "" and requested or "native")

      vim.keymap.set("i", "<CR>", function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local count = vim.api.nvim_buf_line_count(buf)
        if row == count and vim.api.nvim_get_current_line():match("%S") then
          return "<Esc><Cmd>SymjaReplSubmit<CR>"
        end
        return "<CR>"
      end, { buffer = buf, expr = true, replace_keycodes = true, desc = "Evaluate Symja REPL input" })

      vim.keymap.set("n", "<CR>", function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local count = vim.api.nvim_buf_line_count(buf)
        if row == count and vim.api.nvim_get_current_line():match("%S") then
          submit_repl()
          return ""
        end
        return "\r"
      end, { buffer = buf, expr = true, desc = "Evaluate Symja REPL input" })

      -- Ctrl-D exits in Normal mode. In Insert mode it exits only at an empty
      -- prompt; on a non-empty line, preserve Neovim's normal Ctrl-D behavior.
      vim.keymap.set("n", "<C-D>", "<Cmd>SymjaReplExit<CR>", {
        buffer = buf, desc = "Exit Symja REPL",
      })
      vim.keymap.set("i", "<C-D>", function()
        if vim.api.nvim_get_current_line():match("^%s*$") then
          return "<Esc><Cmd>SymjaReplExit<CR>"
        end
        return "<C-D>"
      end, {
        buffer = buf, expr = true, replace_keycodes = true,
        desc = "Exit Symja REPL on an empty prompt",
      })

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
          if M.repl_buf == buf then M.repl_buf = nil end
        end,
      })
    end

    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(M.repl_buf), 0 })
    send("ping", "", mode_for_buffer(M.repl_buf), function(response)
      if not response.ok then notice(response.error, vim.log.levels.ERROR) end
    end)
    vim.cmd("startinsert")
  end, {
    nargs = "?",
    complete = function() return { "native", "mma" } end,
    desc = "Open a persistent Symja REPL (optionally choose native or MMA syntax)",
  })

  local function configure_symja_buffer(buf)
    local ft = vim.bo[buf].filetype
    if ft ~= "symja" and ft ~= "symja_mma" then return end

    -- Keep the native option for Vim/Neovim, and register the same syntax in
    -- Comment.nvim's own filetype table. The latter avoids relying on a
    -- Tree-sitter parser for these custom filetypes.
    register_comment_nvim_filetypes()
    vim.bo[buf].commentstring = "(* %s *)"
    vim.bo[buf].comments = "s1:(*,mb:*,ex:*)"
    vim.bo[buf].iskeyword = "@,48-57,_,192-255,$,`"

    if M.options.keymaps ~= false then
      local function map_if_free(mode, lhs, rhs, desc)
        local leader = vim.g.mapleader or "\\"
        local lookup_lhs = lhs:gsub("<leader>", leader)
        if vim.fn.maparg(lookup_lhs, mode) == "" then
          vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
        end
      end
      map_if_free("n", "<leader>rr", "<cmd>SymjaRun<cr>", "Run Symja buffer (text)")
      map_if_free("n", "<leader>rl", "<cmd>SymjaRunLatex<cr>", "Run Symja buffer (LaTeX)")
      -- Keep the visual range: do not prefix these mappings with <C-U>.
      map_if_free("x", "<leader>r", ":SymjaEval<cr>", "Evaluate Symja selection (text)")
      map_if_free("x", "<leader>rl", ":SymjaEvalLatex<cr>", "Evaluate Symja selection (LaTeX)")
      map_if_free("n", "<leader>ri", "<cmd>SymjaRepl<cr>", "Open Symja REPL")
      map_if_free("n", "<leader>rd", "<cmd>SymjaDoc<cr>", "Open Symja symbol documentation")
      map_if_free("n", "<leader>rc", "<cmd>SymjaCheck<cr>", "Check Symja syntax")
    end

    -- Deliberately do not define, replace, or wrap K here. The LSP attachment
    -- gives an existing vim.lsp.buf.hover() mapping a Symja hover provider.
    start_symja_lsp(buf)
  end

  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "symja", "symja_mma" },
    callback = function(event) configure_symja_buffer(event.buf) end,
  })

  -- Comment.nvim may itself be lazy-loaded after Symja's FileType event.
  -- Re-register its custom filetypes once lazy.nvim finishes loading plugins.
  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyLoad",
    callback = function()
      register_comment_nvim_filetypes()
      -- nvim-cmp may be lazy-loaded after Symja; register its source once it
      -- becomes available without making it a hard dependency.
      if not M._cmp_registered and pcall(require, "cmp") then
        M.register_cmp()
      end
    end,
  })

  -- FileType may have fired before a lazy-loaded plugin finished setup. Retry
  -- on entry as well, so an already-open Symja buffer still gets its LSP.
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(event)
      if vim.api.nvim_buf_is_valid(event.buf) then configure_symja_buffer(event.buf) end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    pattern = "*",
    callback = function(event) schedule_syntax_check(event.buf) end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "symja", "symja_mma" },
    callback = function(event)
      schedule_syntax_check(event.buf)
    end,
  })

  -- A lazy-loaded plugin can be loaded *because* a buffer acquired this
  -- filetype. Configure such an already-open buffer too (even if its original
  -- FileType event is not replayed by the plugin manager).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then configure_symja_buffer(buf) end
  end

  return M
end

return M
