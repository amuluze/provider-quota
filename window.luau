-- Window half: a palette command that opens the dashboard, and a status-line
-- segment fed by the host's kv record. Runs on each window's UI thread; only
-- reads the small published record, never runs omp itself.

local current = { { text = "额度 · 启动中", tone = "muted" } }
local currentKey = ""
local BLOCK = "provider-quota.dashboard"
local CMD = "plugin.provider-quota.open"

local function open(cx)
	-- Reuse the panel in this session without moving any existing panes.
	local tabs = {}
	for _, session in cx.session:sessions() do
		if session.current then
			for _, tab in session.tabs do
				tabs[tab] = true
			end
		end
	end
	for _, pane in cx.session:panes() do
		if pane.block == BLOCK and tabs[pane.tab] and not pane.error then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if not cx:new_block(BLOCK, {}, "beside") then
		cx:toast("error", "无法打开额度面板", "当前 Tern host 上没有这个插件。")
	end
end

tern.command({
	id = "open",
	title = "打开额度面板",
	icon = "gauge",
	keys = { "ctrl+alt+q" },
	run = open,
})

tern.chrome.status(function()
	local out = {}
	for i, seg in current do
		out[i] = {
			text = seg.text,
			tone = seg.tone,
			icon = if i == 1 then "gauge" else nil,
			command = CMD,
		}
	end
	return out
end)

local function pollOnce()
	local ok, record = pcall(tern.kv.get, "record")
	local nextValue
	if not ok then
		nextValue = { { text = "额度 · 缓存错误", tone = "warning" } }
	elseif type(record) ~= "table" or type(record.heartbeat) ~= "number"
		or os.time() * 1000 - record.heartbeat > 15_000 then
		nextValue = { { text = "额度 · 采集器离线", tone = "warning" } }
	elseif type(record.segments) == "table" and #record.segments > 0 then
		nextValue = {}
		for i, seg in record.segments do
			nextValue[i] = { text = tostring(seg.text), tone = seg.tone }
		end
	else
		nextValue = { { text = record.text or "额度 · 读取中", tone = record.tone or "muted" } }
	end
	local parts = {}
	for i, seg in nextValue do
		parts[i] = seg.text .. "\0" .. (seg.tone or "")
	end
	local key = table.concat(parts, "\1")
	if key ~= currentKey then
		current, currentKey = nextValue, key
		tern.chrome.refresh()
	end
end

local function poll()
	-- Re-arm before work so one slow or failed read cannot freeze the segment.
	tern.timer(2000, poll)
	pcall(pollOnce)
end

tern.timer(100, poll)
