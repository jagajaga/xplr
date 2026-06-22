version = "2.0.0"

local home = os.getenv("HOME")
package.path = home
  .. "/.config/xplr/plugins/?/init.lua;"
  .. home
  .. "/.config/xplr/plugins/?.lua;"
  .. package.path

require("dual-pane").setup()
require("map").setup()

-- ===========================================================================
-- Dual-pane, function-key file-manager layer for xplr
-- ===========================================================================

-- --- Helpers ---------------------------------------------------------------

-- Files to act on: the selection if any, else the focused node.
local function targets_of(app)
  local t = {}
  if app.selection and #app.selection > 0 then
    for _, n in ipairs(app.selection) do
      table.insert(t, n.absolute_path)
    end
  elseif app.focused_node then
    table.insert(t, app.focused_node.absolute_path)
  end
  return t
end

local function shell_quote_all(paths)
  local q = {}
  for _, p in ipairs(paths) do
    table.insert(q, xplr.util.shell_quote(p))
  end
  return q
end

-- State file the background copy worker writes progress to ("pct|count|name"),
-- read by the bottom-bar panel. Shared verbatim with the shell side.
local PROGRESS_FILE = "/tmp/xplr_copy_progress"

-- --- Tab: toggle between the two dual-panes --------------------------------
-- (first press also enters dual-pane mode). Overrides default tab.
xplr.config.modes.builtin.default.key_bindings.on_key.tab = {
  help = "toggle pane",
  messages = {
    { CallLuaSilently = "custom.dual_pane.toggle_pane" },
  },
}

-- --- Enter: descend into the focused directory (default was quit-with-result)
xplr.config.modes.builtin.default.key_bindings.on_key.enter = {
  help = "enter directory",
  messages = { "Enter" },
}

-- --- `/` : zsh-style multilevel completion, IN-PANE (cross-folder), ASYNC ----
-- Press `/`, then type a path. Every `/`-separated segment is a case-insensitive
-- prefix; the pane shows EVERY match across folders at once — e.g. p/w lists
-- projects∕web-app, projects∕worker, public∕wiki together (a flat menu, like zsh
-- completion). It does this by filling a temp folder with shortcuts. The globbing
-- runs in a DETACHED background worker so typing never blocks (even on `*`); the
-- pane is refreshed when the worker finishes via the fork's control FIFO, and
-- only the latest keystroke's result is applied. up/down pick; Enter follows the
-- highlighted shortcut; Esc returns to start. `ctrl-f` is xplr's plain search.
local jump_start_pwd = nil
local JUMP_RESULTS = "/tmp/xplr-jump-results"
local JUMP_WANTED = "/tmp/xplr-jump-wanted" -- latest keystroke's input (backstop)
local JUMP_PID = "/tmp/xplr-jump-pid"       -- PID of the live worker (to cancel)
local JUMP_WORKER = "/tmp/xplr-jump-worker.sh"
local JUMP_SENTINEL = "\1" -- written to WANTED on exit so in-flight workers skip

local function write_file(path, content)
  local f = io.open(path, "w")
  if f then
    f:write(content)
    f:close()
  end
end

-- Cancel the live worker (and its glob children). Each keystroke does this
-- before launching a new one, so a slow glob never blocks the next search.
local function kill_worker()
  xplr.util.shell_execute("bash", {
    "-c",
    "p=$(cat '" .. JUMP_PID .. "' 2>/dev/null); [ -n \"$p\" ] && { pkill -P \"$p\" 2>/dev/null; kill -9 \"$p\" 2>/dev/null; }; :",
  })
end

-- Detached background worker. After a short debounce it builds the results
-- folder of shortcuts, then pokes xplr's control FIFO to refresh the pane. No
-- lock is needed: the launcher KILLS the previous worker before starting this
-- one, so only a single worker is ever alive. Directory matches are cross-folder
-- at any depth; file matches are limited to files directly in the start dir.
local JUMP_WORKER_BODY = [==[
myinput="$1"; base="$2"; results="$3"; ctrl="$4"
wanted="/tmp/xplr-jump-wanted"
mine() { [ "$(cat "$wanted" 2>/dev/null)" = "$myinput" ]; }

# A newer keystroke kills this process (see launcher), so a burst of typing
# terminates us here, before we ever touch the disk.
sleep 0.05

expr="$myinput"
case "$expr" in
  "~/"*) cur="$HOME"; rest="${expr#\~/}" ;;
  "~")   cur="$HOME"; rest="" ;;
  /*)    cur="/"; rest="${expr#/}" ;;
  *)     cur="$base"; rest="$expr" ;;
esac
while [ "${rest%/}" != "$rest" ]; do rest="${rest%/}"; done
shopt -s nocaseglob nullglob
pat=""; first=""; IFS='/' read -ra segs <<< "$rest"
for seg in "${segs[@]}"; do
  [ -z "$seg" ] && continue
  [ -z "$first" ] && first="$seg" # first segment = the start-dir (current) level
  pat="${pat}${seg}*/" # trailing / => directories only (it's a folder jump)
done

target="$results"
if [ -z "$pat" ]; then
  target="$cur"                  # empty input -> just show the start dir
else
  # Keep the results dir itself (xplr may be standing in it) — only clear its
  # contents, so xplr's cwd inode never disappears mid-keystroke.
  mkdir -p "$results"; find "$results" -mindepth 1 -delete 2>/dev/null
  count=0
  for m in "$cur"/$pat; do
    m="${m%/}"
    rel="${m#"$cur"/}"
    name="${rel//\//∕}"
    ln -s "$m" "$results/$name" 2>/dev/null
    count=$((count+1)); [ "$count" -ge 2000 ] && break
  done
  # Also surface FILES directly in the start dir matching the first segment.
  for m in "$cur"/${first}*; do
    [ -f "$m" ] || continue
    name="${m##*/}"; [ -e "$results/$name" ] && continue
    ln -s "$m" "$results/$name" 2>/dev/null
    count=$((count+1)); [ "$count" -ge 2000 ] && break
  done
fi

mine || exit 0                   # superseded during the glob -> don't touch view
[ -n "$ctrl" ] && [ -p "$ctrl" ] || exit 0
esc=$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g')
{
  printf 'ChangeDirectory: "%s"\n' "$esc"
  printf 'ExplorePwd\n'
  printf 'FocusFirst\n'
} > "$ctrl"
]==]

-- Instant launcher (synchronous, but it only CANCELS the previous worker and
-- backgrounds a new one, then returns). Args: $1=worker $2=input $3=base
-- $4=results $5=ctrl $6=pidfile.
local JUMP_LAUNCH = [==[
worker="$1"; input="$2"; base="$3"; results="$4"; ctrl="$5"; pidf="$6"
prev=$(cat "$pidf" 2>/dev/null)
if [ -n "$prev" ]; then pkill -P "$prev" 2>/dev/null; kill -9 "$prev" 2>/dev/null; fi
nohup bash "$worker" "$input" "$base" "$results" "$ctrl" </dev/null >/dev/null 2>&1 &
echo $! > "$pidf"
]==]

xplr.fn.custom.jump_start = function(app)
  jump_start_pwd = app.pwd
  write_file(JUMP_WORKER, JUMP_WORKER_BODY) -- (re)materialize the worker script
  write_file(JUMP_WANTED, JUMP_SENTINEL)    -- invalidate any leftover worker
  kill_worker()                             -- cancel a worker left over from before
  xplr.util.shell_execute("bash", { "-c", "mkdir -p '" .. JUMP_RESULTS .. "'" })
  return {}
end

-- Each keystroke: record the input, KILL the previous worker, and fire a new one
-- DETACHED, then return immediately. No globbing happens on the xplr thread, so
-- typing never blocks (even on `*`) and the now-stale search is aborted at once;
-- the pane is refreshed later by the worker via the control FIFO.
xplr.fn.custom.jump_live = function(app)
  local input = app.input_buffer or ""
  local base = jump_start_pwd or app.pwd
  local ctrl = os.getenv("XPLR_PIPE_CTRL_IN") or ""
  write_file(JUMP_WANTED, input) -- latest keystroke wins (poke backstop)
  xplr.util.shell_execute(
    "bash",
    { "-c", JUMP_LAUNCH, "_", JUMP_WORKER, input, base, JUMP_RESULTS, ctrl, JUMP_PID }
  )
  return {}
end

-- Enter: resolve the highlighted shortcut to its REAL path (realpath follows
-- the whole chain, e.g. a cloud-synced symlink) and go there, so pwd is the
-- real folder rather than the temp shortcut.
xplr.fn.custom.jump_commit = function(app)
  write_file(JUMP_WANTED, JUMP_SENTINEL) -- backstop: stop any in-flight worker poking
  kill_worker() -- and actually cancel it
  local node = app.focused_node
  if not node then
    if jump_start_pwd then
      return { { ChangeDirectory = jump_start_pwd } }
    end
    return {}
  end
  local out = xplr.util.shell_execute("bash", {
    "-c",
    'p="$(realpath "$1" 2>/dev/null)"; [ -z "$p" ] && exit 0; [ -d "$p" ] && printf "d\t%s" "$p" || printf "f\t%s" "$p"',
    "_",
    node.absolute_path,
  })
  local kind, real = (out and out.stdout or ""):match("^(%a)\t(.*)$")
  if not real or real == "" then
    return {}
  end
  if kind == "d" then
    return { { ChangeDirectory = real } }
  end
  return { { FocusPath = real } }
end

xplr.fn.custom.jump_cancel = function(app)
  write_file(JUMP_WANTED, JUMP_SENTINEL) -- backstop: stop any in-flight worker poking
  kill_worker() -- and actually cancel it
  if jump_start_pwd then
    return { { ChangeDirectory = jump_start_pwd } }
  end
  return {}
end

xplr.config.modes.custom.jump = {
  name = "jump",
  prompt = "jump ❯ ",
  key_bindings = {
    on_key = {
      enter = { help = "go", messages = { { CallLuaSilently = "custom.jump_commit" }, "PopMode" } },
      esc = { help = "cancel", messages = { { CallLuaSilently = "custom.jump_cancel" }, "PopMode" } },
      ["ctrl-c"] = { messages = { { CallLuaSilently = "custom.jump_cancel" }, "PopMode" } },
      up = { help = "pick", messages = { "FocusPrevious" } },
      down = { help = "pick", messages = { "FocusNext" } },
      ["ctrl-p"] = { messages = { "FocusPrevious" } },
      ["ctrl-n"] = { messages = { "FocusNext" } },
    },
    default = { messages = { "UpdateInputBufferFromKey", { CallLuaSilently = "custom.jump_live" } } },
  },
}

xplr.config.modes.builtin.default.key_bindings.on_key["/"] = {
  help = "jump",
  messages = {
    { SwitchModeCustom = "jump" },
    { SetInputBuffer = "" },
    { CallLuaSilently = "custom.jump_start" },
  },
}

-- --- Track the OTHER pane's directory --------------------------------------
-- dual-pane keeps it in private state, so we record it here: every real pane
-- switch leaves the current dir behind as the "other" pane.
local other_pwd = nil
do
  local dp = xplr.fn.custom.dual_pane
  local function track(orig)
    return function(app)
      local leaving = app.pwd
      local msgs = orig(app)
      if msgs ~= nil then -- nil = no actual switch happened
        other_pwd = leaving
      end
      return msgs
    end
  end
  dp.activate_left_pane = track(dp.activate_left_pane)
  dp.activate_right_pane = track(dp.activate_right_pane)

  -- Forget the other pane when dual-pane is closed, so F5/F6 won't fire blindly.
  local orig_quit = dp.quit_active_pane
  dp.quit_active_pane = function(app)
    local msgs = orig_quit(app)
    other_pwd = nil
    return msgs
  end
end

-- After a copy/move, dual-pane only re-reads a pane when it becomes active, so
-- flip to the other pane and back. Two toggles return focus here with both
-- panes' snapshots refreshed.
local refresh_panes = {
  { CallLuaSilently = "custom.dual_pane.toggle_pane" },
  { CallLuaSilently = "custom.dual_pane.toggle_pane" },
}

-- --- F3 View / F4 Edit -----------------------------------------------------
xplr.fn.custom.view_file = function(app)
  if not app.focused_node then
    return {}
  end
  return {
    { BashExec = "${PAGER:-less} -- " .. xplr.util.shell_quote(app.focused_node.absolute_path) },
  }
end

xplr.fn.custom.edit_file = function(app)
  if not app.focused_node then
    return {}
  end
  return {
    { BashExec = "${EDITOR:-vi} -- " .. xplr.util.shell_quote(app.focused_node.absolute_path) },
  }
end

-- --- F5 Copy to the other pane, with a live in-layout progress bar ---------
-- The patched xplr drains its message pipe on a 100ms idle tick, so a detached
-- background copy can drive the UI: the worker streams through `pv -n`, writes
-- "pct|count|name" to the progress file, and pings the pipe (Refresh) so the
-- bottom-bar panel redraws live. On finish it refreshes both panes.
xplr.fn.custom.copy_to_other_pane = function(app)
  if not other_pwd then
    return { { LogError = "Other pane unknown - switch panes once (Tab) first." } }
  end
  local srcs = targets_of(app)
  if #srcs == 0 then
    return { { LogWarning = "Nothing to copy." } }
  end

  -- Worker body (written verbatim to a temp script; no launcher-time expansion).
  -- $1 = progress file, $2 = dest, $3.. = sources.
  local worker = [[
PROGRESS_FILE="$1"; dest="$2"; shift 2
trap 'rm -f "$PROGRESS_FILE"' EXIT
# $XPLR_PIPE_CTRL_IN is the persistent control FIFO (patched xplr); writes wake
# the UI instantly. Fall back to the per-command msg_in pipe if unset.
CTRL="${XPLR_PIPE_CTRL_IN:-$XPLR_PIPE_MSG_IN}"
poke() { printf 'Refresh\n' >> "$CTRL" 2>/dev/null; }
n=$#; i=0
for p in "$@"; do
  i=$((i+1)); name=${p##*/}; parent=${p%/*}; [ "$parent" = "$p" ] && parent=/
  kb=$(du -sk "$p" 2>/dev/null | cut -f1); bytes=$(( ${kb:-0} * 1024 ))
  ratio="$i/$n"
  tar -C "$parent" -cf - "./$name" \
    | pv -n -i 0.2 -s "$bytes" 2> >(while IFS= read -r pct; do
          printf '%s|%s|%s\n' "$pct" "$ratio" "$name" > "$PROGRESS_FILE"
          poke
        done) \
    | tar -C "$dest" -xf -
done
rm -f "$PROGRESS_FILE"
{ printf 'CallLuaSilently: custom.dual_pane.toggle_pane\n'
  printf 'CallLuaSilently: custom.dual_pane.toggle_pane\n'
  printf 'Refresh\n'; } >> "$CTRL" 2>/dev/null
rm -f "$0"
]]

  local launcher = "WORKER=$(mktemp \"${TMPDIR:-/tmp}/xplr_copy.XXXXXX\")\n"
    .. "cat > \"$WORKER\" <<'XPLRWORKER'\n"
    .. worker
    .. "XPLRWORKER\n"
    .. "nohup bash \"$WORKER\" "
    .. xplr.util.shell_quote(PROGRESS_FILE) .. " "
    .. xplr.util.shell_quote(other_pwd) .. " "
    .. table.concat(shell_quote_all(srcs), " ")
    .. " >/dev/null 2>&1 &\n"

  return {
    { BashExecSilently = launcher },
    { LogInfo = "Copying " .. #srcs .. " item(s) to " .. other_pwd .. " ..." },
  }
end

-- --- F6 Move to the other pane ---------------------------------------------
xplr.fn.custom.move_to_other_pane = function(app)
  if not other_pwd then
    return { { LogError = "Other pane unknown - switch panes once (Tab) first." } }
  end
  local srcs = targets_of(app)
  if #srcs == 0 then
    return { { LogWarning = "Nothing to move." } }
  end
  local cmd = "mv -- "
    .. table.concat(shell_quote_all(srcs), " ")
    .. " "
    .. xplr.util.shell_quote(other_pwd)
    .. "/"

  local msgs = { { BashExecSilently = cmd }, "ClearSelection" }
  for _, m in ipairs(refresh_panes) do
    table.insert(msgs, m)
  end
  table.insert(msgs, { LogSuccess = #srcs .. " item(s) moved to " .. other_pwd })
  return msgs
end

-- --- F7 Mkdir (prompts for a name) -----------------------------------------
xplr.config.modes.custom.mc_mkdir = {
  name = "mkdir",
  prompt = "mkdir ❯ ",
  key_bindings = {
    on_key = {
      enter = {
        help = "create",
        messages = {
          { CallLuaSilently = "custom.mc_mkdir" },
          "PopMode",
        },
      },
      esc = { help = "cancel", messages = { "PopMode" } },
      ["ctrl-c"] = { messages = { "PopMode" } },
    },
    default = {
      messages = { "UpdateInputBufferFromKey" },
    },
  },
}

xplr.fn.custom.mc_mkdir = function(app)
  local name = app.input_buffer
  if not name or name == "" then
    return {}
  end
  return {
    { BashExecSilently = "mkdir -p -- " .. xplr.util.shell_quote(app.pwd .. "/" .. name) },
    "ExplorePwdAsync",
    { LogSuccess = "Created " .. name },
  }
end

-- --- F8 Delete (confirm first, permanent) ----------------------------------
xplr.config.modes.custom.mc_delete = {
  name = "delete?",
  key_bindings = {
    on_key = {
      y = {
        help = "yes, delete",
        messages = {
          { CallLuaSilently = "custom.mc_delete" },
          "PopMode",
        },
      },
      n = { help = "no", messages = { "PopMode" } },
      esc = { messages = { "PopMode" } },
      ["ctrl-c"] = { messages = { "PopMode" } },
    },
    default = { messages = {} }, -- ignore other keys; only y / n / esc act
  },
}

xplr.fn.custom.mc_delete = function(app)
  local targets = targets_of(app)
  if #targets == 0 then
    return { { LogWarning = "Nothing to delete." } }
  end
  return {
    { BashExecSilently = "rm -rf -- " .. table.concat(shell_quote_all(targets), " ") },
    "ClearSelection",
    "ExplorePwdAsync",
    { LogSuccess = #targets .. " item(s) deleted." },
  }
end

-- --- Function-key bindings (default mode) -----------------------------------
do
  local k = xplr.config.modes.builtin.default.key_bindings.on_key
  k.f3 = { help = "view", messages = { { CallLuaSilently = "custom.view_file" } } }
  k.f4 = { help = "edit", messages = { { CallLuaSilently = "custom.edit_file" } } }
  k.f5 = { help = "copy to other pane", messages = { { CallLuaSilently = "custom.copy_to_other_pane" } } }
  k.f6 = { help = "move to other pane", messages = { { CallLuaSilently = "custom.move_to_other_pane" } } }
  k.f7 = { help = "mkdir", messages = { { SwitchModeCustom = "mc_mkdir" }, { SetInputBuffer = "" } } }
  k.f8 = { help = "delete", messages = { { SwitchModeCustom = "mc_delete" } } }
  k.f10 = { help = "quit", messages = { "Quit" } }
end

-- --- Blue theme    ---------------------------------------------------------
do
  local g = xplr.config.general

  g.default_ui.style = { fg = "White", bg = "Blue" }
  g.focus_ui.style = { fg = "Black", bg = "Cyan", add_modifiers = { "Bold" } }
  g.selection_ui.prefix = " {"
  g.selection_ui.suffix = "}"
  g.selection_ui.style = { fg = "Yellow", bg = "Blue", add_modifiers = { "Bold" } }
  g.focus_selection_ui.style = { fg = "Yellow", bg = "Cyan", add_modifiers = { "Bold" } }

  -- Keep directories/symlinks readable on the blue background.
  if xplr.config.node_types.directory then
    xplr.config.node_types.directory.style = { fg = "White", add_modifiers = { "Bold" } }
  end
  if xplr.config.node_types.symlink then
    xplr.config.node_types.symlink.style = { fg = "Cyan" }
  end

  -- Blue panels, cyan borders, yellow titles.
  for _, name in ipairs({ "default", "table", "sort_and_filter", "selection", "help_menu", "input_and_logs" }) do
    local p = g.panel_ui[name]
    if p then
      p.style = p.style or {}
      p.style.bg = "Blue"
      p.border_style = { fg = "Cyan" }
      p.title = p.title or {}
      p.title.style = { fg = "Yellow", add_modifiers = { "Bold" } }
    end
  end

  -- Give every table column a blue base so cell padding stays blue instead of
  -- falling back to the terminal default (black). Columns: index, path, perm,
  -- size, modified.
  local col_fg = { "Cyan", "White", "Green", "Cyan", "White" }
  for i, col in ipairs(g.table.row.cols) do
    col.style = { fg = col_fg[i], bg = "Blue" }
  end

  -- Index column: rename header to "int" and cap its width at 4 chars.
  g.table.header.cols[1].format = " int"
  g.table.col_widths[1] = { Max = 4 }

  -- The default `perm` renderer paints each r/w/x bit with an ANSI reset that
  -- drops the background to black. Render it as plain text; color comes from the
  -- column style set above.
  xplr.fn.builtin.fmt_general_table_row_cols_2 = function(m)
    return xplr.util.permissions_rwx(m.permissions)
  end

  -- The default `path` renderer appends an unpainted trailing space after the
  -- colored node name, which inherits the name paint's reset (black). Re-render
  -- the name, trailing space, and any symlink target painted with the row style.
  xplr.fn.builtin.fmt_general_table_row_cols_1 = function(m)
    local ms = m.style or {}
    local r = m.tree .. m.prefix
    local style = xplr.util.style_mix({ xplr.util.lscolor(m.absolute_path), ms })
    if m.meta.icon ~= nil then
      r = r .. m.meta.icon .. " "
    end
    local rel = m.relative_path
    if m.is_dir then
      rel = rel .. "/"
    end
    r = r .. xplr.util.paint(xplr.util.shell_escape(rel), style)
    r = r .. xplr.util.paint(m.suffix .. " ", ms)
    if m.is_symlink then
      local s = "-> "
      if m.is_broken then
        s = s .. "×"
      else
        local p = xplr.util.shorten(m.symlink.absolute_path, { base = m.parent })
        if m.symlink.is_dir then
          p = p .. "/"
        end
        s = s .. p
      end
      r = r .. xplr.util.paint(s, ms)
    end
    return r
  end

  -- Index column: show only the absolute index, dropping the default's
  -- relative-to-focus number (the "-1│", "0│", … prefix).
  xplr.fn.builtin.fmt_general_table_row_cols_0 = function(m)
    return " " .. m.index
  end
end

-- --- File preview panel (top-right) ----------------------------------------
-- Shows the head of the focused file; image files are rendered with viu.
local IMG_EXT = {
  png = true, jpg = true, jpeg = true, gif = true, bmp = true,
  webp = true, ico = true, tiff = true, tif = true,
}
local img_cache = { key = nil, body = nil }
-- On iTerm2 the patched xplr renders real images; elsewhere we fall back to
-- viu's 256-color blocks.
local IS_ITERM = (os.getenv("TERM_PROGRAM") or ""):find("iTerm") ~= nil

-- Strip ANSI/terminal escapes so previews of color-coded files (e.g. *.log with
-- embedded SGR codes) render on the panel's blue background instead of leaving
-- ragged black boxes — an ANSI "default background" cell draws as the terminal's
-- black, not the panel color, so we remove the codes entirely.
local function strip_ansi(s)
  s = s:gsub("\27%[[0-?]*[ -/]*[@-~]", "") -- CSI (colors, cursor moves, erases)
  s = s:gsub("\27%].-\7", "")              -- OSC ... BEL
  s = s:gsub("\27[PX^_].-\27\\", "")       -- DCS/SOS/PM/APC ... ST
  s = s:gsub("\27.", "")                   -- any leftover 2-byte escape
  return s
end

xplr.fn.custom.preview = function(ctx)
  local node = ctx.app.focused_node
  local ui = { title = { format = " preview " } }
  if not node then
    return { CustomParagraph = { ui = ui, body = "" } }
  end
  if node.is_dir then
    return { CustomParagraph = { ui = ui, body = "📁 " .. (node.relative_path or "") .. "/" } }
  end

  local w = (ctx.layout_size and ctx.layout_size.width or 30) - 2
  local h = (ctx.layout_size and ctx.layout_size.height or 20) - 2
  if w < 1 then w = 1 end
  if h < 1 then h = 1 end

  -- Image: render with viu. Forced blocks (-b) so it works in any terminal and
  -- can be captured. Cached by path+size so we don't re-run viu every frame.
  local ext = (node.absolute_path:match("%.([%a%d]+)$") or ""):lower()
  if IMG_EXT[ext] then
    -- iTerm2: hand off to the fork, which overlays the real image (sentinel
    -- body; the panel renders empty and the runner draws the image over it).
    if IS_ITERM then
      return { CustomParagraph = { ui = ui, body = "\1xplr-image\1" .. node.absolute_path } }
    end
    local key = node.absolute_path .. ":" .. w .. "x" .. h
    if img_cache.key ~= key then
      local out = xplr.util.shell_execute(
        "viu",
        { "-b", "-s", "-w", tostring(w), "-h", tostring(h), node.absolute_path }
      )
      local body = (out and out.stdout) or ""
      if body == "" then
        body = "(viu could not render this image)"
      end
      img_cache.key = key
      img_cache.body = body
    end
    return { CustomParagraph = { ui = ui, body = img_cache.body } }
  end

  -- Otherwise show the head of the file as text.
  local f = io.open(node.absolute_path, "r")
  if not f then
    return { CustomParagraph = { ui = ui, body = "(cannot read)" } }
  end
  local data = f:read(8192) or ""
  f:close()
  if data == "" then
    return { CustomParagraph = { ui = ui, body = "(empty file)" } }
  end
  if data:find("\0") then
    return { CustomParagraph = { ui = ui, body = "(binary file)" } }
  end
  local lines, n = {}, 0
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    table.insert(lines, (strip_ansi(line):gsub("\t", "    ")))
    if n >= h then
      break
    end
  end
  return { CustomParagraph = { ui = ui, body = table.concat(lines, "\n") } }
end

-- --- Right column: preview (top, big) / selection (mid) / help (bottom) -----
do
  local right_column = {
    Vertical = {
      config = {
        constraints = {
          { Percentage = 55 }, -- preview, biggest
          { Percentage = 25 }, -- selection, smaller
          { Percentage = 20 }, -- help, smallest
        },
      },
      splits = {
        { Dynamic = "custom.preview" },
        "Selection",
        "HelpMenu",
      },
    },
  }

  -- All three base layouts are Horizontal{ left, right }; swap in our right col.
  for _, layout in ipairs({
    xplr.config.layouts.builtin.default,
    xplr.config.layouts.custom.left_pane_active,
    xplr.config.layouts.custom.right_pane_active,
  }) do
    if layout.Horizontal and layout.Horizontal.splits then
      layout.Horizontal.splits[2] = right_column
    end
  end
end

-- --- Bottom bar: live copy progress while copying, else function-key hints --
xplr.fn.custom.bottom_bar = function(_ctx)
  local f = io.open(PROGRESS_FILE, "r")
  if f then
    local line = f:read("*l")
    f:close()
    if line and line ~= "" then
      local pct, ratio, name = line:match("^(%d+)|([^|]*)|(.*)$")
      pct = tonumber(pct) or 0
      if pct > 100 then
        pct = 100
      end
      local width = 28
      local filled = math.floor(width * pct / 100)
      local barstr = string.rep("█", filled) .. string.rep("░", width - filled)
      return {
        CustomParagraph = {
          ui = { title = { format = " copying " } },
          body = string.format(" %s  %s %3d%%   %s", ratio or "", barstr, pct, name or ""),
        },
      }
    end
  end
  return {
    CustomParagraph = {
      ui = { title = { format = " keys " } },
      body = " F3 View   F4 Edit   F5 Copy   F6 Move   F7 Mkdir   F8 Delete   F10 Quit   Tab Switch ",
    },
  }
end

do
  local bar = { Dynamic = "custom.bottom_bar" }

  local function with_bar(layout)
    return {
      Vertical = {
        config = { constraints = { { Min = 1 }, { Length = 3 } } },
        splits = { layout, bar },
      },
    }
  end

  xplr.config.layouts.builtin.default = with_bar(xplr.config.layouts.builtin.default)
  xplr.config.layouts.custom.left_pane_active = with_bar(xplr.config.layouts.custom.left_pane_active)
  xplr.config.layouts.custom.right_pane_active = with_bar(xplr.config.layouts.custom.right_pane_active)
end
