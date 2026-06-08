local M = {}
local uv = vim.uv or vim.loop

local ns = vim.api.nvim_create_namespace("mermaid_live")

M.opts = {
  filetypes = { "mermaid" },
  poll_interval_ms = 350,
  theme = "auto",
  port = 8765,
  open_browser = true,
  open_cmd = nil,
  auto_stop_on_leave = true,
  mermaid_cdn = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs",
  mermaid_elk_cdn = "https://cdn.jsdelivr.net/npm/@mermaid-js/layout-elk@0.1/dist/mermaid-layout-elk.esm.min.mjs",
  svg_pan_zoom_cdn = "https://cdn.jsdelivr.net/npm/svg-pan-zoom@3.6.1/dist/svg-pan-zoom.min.js",
}

local state = {
  server = nil,
  port = nil,
  bufnr = nil,
  code = "",
  version = 0,
  augroup = nil,
  template = nil,
  theme = nil,
  last_poll = 0,
  opened_at = 0,
}

local VALID_THEMES = { auto = true, default = true, dark = true, forest = true, neutral = true, base = true }

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  state.template = nil
end

local function load_template()
  if state.template then
    return state.template
  end
  local matches = vim.api.nvim_get_runtime_file("templates/mermaid-view.html", false)
  local path = matches[1]
  if not path then
    return nil
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local tpl = fd:read("*a")
  fd:close()
  tpl = tpl:gsub("__MERMAID_CDN__", function()
    return M.opts.mermaid_cdn
  end)
  tpl = tpl:gsub("__MERMAID_ELK_CDN__", function()
    return M.opts.mermaid_elk_cdn or ""
  end)
  tpl = tpl:gsub("__SVG_PAN_ZOOM_CDN__", function()
    return M.opts.svg_pan_zoom_cdn
  end)
  tpl = tpl:gsub("__POLL_MS__", function()
    return tostring(M.opts.poll_interval_ms)
  end)
  state.template = tpl
  return tpl
end

local function buffer_code(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function refresh_code()
  local code = buffer_code(state.bufnr)
  if code == nil then
    return
  end
  if code ~= state.code then
    state.code = code
    state.version = state.version + 1
  end
end

local function http_response(status, ctype, body)
  return string.format(
    "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s",
    status,
    ctype,
    #body,
    body
  )
end

local function build_response(path)
  if path == "/" or path == "/index.html" then
    local tpl = load_template()
    if not tpl then
      return http_response("500 Internal Server Error", "text/plain", "no template")
    end
    return http_response("200 OK", "text/html; charset=utf-8", tpl)
  elseif path:match("^/code") then
    state.last_poll = uv.now()
    local body = string.format(
      "%d\n%s\n%s",
      state.version,
      state.theme or M.opts.theme,
      state.code or ""
    )
    return http_response("200 OK", "text/plain; charset=utf-8", body)
  elseif path:match("^/theme/") then
    local name = path:match("^/theme/([%w]+)")
    if name and VALID_THEMES[name] then
      state.theme = name
      state.version = state.version + 1
      return http_response("200 OK", "text/plain", "ok")
    end
    return http_response("400 Bad Request", "text/plain", "invalid theme")
  elseif path == "/__id" then
    return http_response("200 OK", "text/plain", "mermaid-live\n" .. tostring(uv.os_getpid()))
  elseif path == "/__shutdown" then
    vim.schedule(function()
      M.stop()
    end)
    return http_response("200 OK", "text/plain", "shutting down")
  end
  return http_response("404 Not Found", "text/plain", "not found")
end

local function probe_existing(port)
  if vim.fn.executable("curl") ~= 1 then
    return nil
  end
  local out = vim.fn.system({
    "curl",
    "-s",
    "--max-time",
    "1",
    string.format("http://127.0.0.1:%d/__id", port),
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  if not out:match("^mermaid%-live") then
    return nil
  end
  return out
end

local function request_shutdown(port)
  if vim.fn.executable("curl") ~= 1 then
    return
  end
  vim.fn.system({
    "curl",
    "-s",
    "--max-time",
    "1",
    string.format("http://127.0.0.1:%d/__shutdown", port),
  })
end

local function close_existing(port)
  local existing = probe_existing(port)
  if not existing then
    return
  end
  vim.notify("mermaid-live: another server on :" .. port .. ", shutting it down")
  request_shutdown(port)
  vim.wait(1000, function()
    return probe_existing(port) == nil
  end, 50)
end

local function list_local_listen_ports()
  if vim.fn.executable("lsof") ~= 1 then
    return {}
  end
  local out = vim.fn.systemlist({ "lsof", "-iTCP", "-sTCP:LISTEN", "-n", "-P", "-Fn" })
  local set = {}
  for _, line in ipairs(out) do
    local port = line:match("^n.*:(%d+)$")
    if port then
      set[tonumber(port)] = true
    end
  end
  local ports = {}
  for p, _ in pairs(set) do
    table.insert(ports, p)
  end
  table.sort(ports)
  return ports
end

local function start_server()
  if state.server then
    return true
  end
  close_existing(M.opts.port)
  local server = uv.new_tcp()
  local ok, err = pcall(function()
    server:bind("127.0.0.1", M.opts.port or 0)
  end)
  if not ok then
    vim.notify("mermaid-live: bind failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  server:listen(32, function(lerr)
    if lerr then
      return
    end
    local client = uv.new_tcp()
    server:accept(client)
    local acc = ""
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        pcall(function()
          client:close()
        end)
        return
      end
      acc = acc .. chunk
      if not acc:find("\r\n\r\n", 1, true) then
        return
      end
      local _, path = acc:match("^(%S+)%s+(%S+)")
      local resp = build_response(path or "/")
      client:write(resp, function()
        pcall(function()
          client:shutdown(function()
            client:close()
          end)
        end)
      end)
    end)
  end)
  state.server = server
  state.port = server:getsockname().port
  return true
end

local function stop_server()
  if state.server then
    pcall(function()
      state.server:close()
    end)
    state.server = nil
    state.port = nil
  end
end

local function default_open_argv(url)
  if vim.fn.has("mac") == 1 then
    return { "open", url }
  elseif vim.fn.has("unix") == 1 then
    return { "xdg-open", url }
  else
    return { "cmd.exe", "/C", "start", "", url }
  end
end

local function open_browser(url)
  local custom = M.opts.open_cmd
  if custom then
    if type(custom) == "function" then
      custom(url)
    elseif type(custom) == "table" then
      local argv = vim.deepcopy(custom)
      table.insert(argv, url)
      vim.fn.jobstart(argv, { detach = true })
    else
      vim.notify("mermaid-live: open_cmd must be a function or list", vim.log.levels.ERROR)
    end
    return
  end
  vim.fn.jobstart(default_open_argv(url), { detach = true })
end

local function ft_ok(bufnr)
  local ft = vim.bo[bufnr].filetype
  for _, f in ipairs(M.opts.filetypes) do
    if f == ft then
      return true
    end
  end
  return false
end

local function setup_autocmds()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("MermaidLive", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = state.augroup,
    buffer = state.bufnr,
    callback = function()
      refresh_code()
    end,
  })
  local leave_events = { "BufWipeout" }
  if M.opts.auto_stop_on_leave then
    table.insert(leave_events, "BufLeave")
  end
  vim.api.nvim_create_autocmd(leave_events, {
    group = state.augroup,
    buffer = state.bufnr,
    callback = function()
      M.stop()
    end,
  })
end

function M.start(args)
  args = args or {}
  local open
  if args.open_browser ~= nil then
    open = args.open_browser
  else
    open = M.opts.open_browser
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not ft_ok(bufnr) then
    vim.notify(
      string.format(
        "mermaid-live: buffer filetype is %q, expected one of: %s",
        vim.bo[bufnr].filetype,
        table.concat(M.opts.filetypes, ", ")
      ),
      vim.log.levels.WARN
    )
    return
  end
  state.bufnr = bufnr
  state.code = buffer_code(bufnr) or ""
  state.theme = state.theme or M.opts.theme
  state.version = state.version + 1
  if not start_server() then
    return
  end
  setup_autocmds()
  local url = string.format("http://127.0.0.1:%d/", state.port)
  if open then
    local now = uv.now()
    local poll_alive = state.last_poll > 0
      and (now - state.last_poll) < math.max(M.opts.poll_interval_ms * 3, 1500)
    local just_opened = state.opened_at > 0 and (now - state.opened_at) < 3000
    if poll_alive or just_opened then
      vim.notify("mermaid-live: " .. url .. " (tab already open)")
    else
      open_browser(url)
      state.opened_at = now
      vim.notify("mermaid-live: " .. url)
    end
  else
    vim.notify("mermaid-live: serving at " .. url)
  end
end

function M.serve()
  M.start({ open_browser = false })
end

function M.stop()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  stop_server()
  state.bufnr = nil
  state.code = ""
  state.theme = nil
  state.last_poll = 0
  state.opened_at = 0
  vim.schedule(function()
    M.cleanup({ silent = true })
  end)
end

function M.set_theme(name)
  if not VALID_THEMES[name] then
    vim.notify(
      string.format(
        "mermaid-live: invalid theme %q (valid: auto, default, dark, forest, neutral, base)",
        tostring(name)
      ),
      vim.log.levels.WARN
    )
    return
  end
  state.theme = name
  state.version = state.version + 1
end

function M.toggle_theme()
  local current = state.theme or M.opts.theme
  local cycle = { auto = "dark", dark = "default", default = "auto" }
  state.theme = cycle[current] or "auto"
  state.version = state.version + 1
end

function M.get_theme()
  return state.theme or M.opts.theme
end

function M.open()
  if not state.port then
    vim.notify("mermaid-live: not running, call :MermaidView first", vim.log.levels.WARN)
    return
  end
  open_browser(string.format("http://127.0.0.1:%d/", state.port))
end

function M.url()
  if not state.port then
    return nil
  end
  return string.format("http://127.0.0.1:%d/", state.port)
end

function M.is_running()
  return state.server ~= nil
end

function M.scan()
  local found = {}
  for _, port in ipairs(list_local_listen_ports()) do
    if probe_existing(port) then
      table.insert(found, port)
    end
  end
  return found
end

function M.cleanup(args)
  args = args or {}
  local silent = args.silent
  local found = M.scan()
  local closed = {}
  for _, port in ipairs(found) do
    if port ~= state.port then
      request_shutdown(port)
      table.insert(closed, port)
    end
  end
  if #closed > 0 then
    vim.notify(string.format("mermaid-live: shut down %d on ports: %s", #closed, table.concat(closed, ", ")))
  elseif not silent then
    if #found == 0 then
      vim.notify("mermaid-live: no instances found")
    else
      vim.notify(
        string.format("mermaid-live: found %d (only this nvim's :%d, nothing to clean)", #found, state.port or 0)
      )
    end
  end
  return closed
end

return M
