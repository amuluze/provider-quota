-- Host half: owns the collector and every dashboard block. Runs on the
-- session daemon's worker thread for this plugin, one call at a time, 2s
-- budget per call. Polls `omp usage --json` every 60s, keeps the last good
-- snapshot, publishes a small record to tern.kv for the window halves.

local usage = require("./usage")
local view = require("./view")
local Collector = require("./collector")
local balances = require("./balances")

local blocks = {}
local function now() return os.time() * 1000 end

local function renderLive()
	local live = {}
	for _, pane in tern.pane.list() do
		live[pane.pane] = true
	end
	for pane, cx in blocks do
		if live[pane] then
			cx:render() -- countdowns tick, busy state flips
		else
			blocks[pane] = nil
		end
	end
end

-- Resolve the omp binary: env override, conventional user paths, then PATH.
local home = tern.getenv("HOME") or tern.getenv("USERPROFILE") or ""
local binary = tern.getenv("TERN_QUOTA_BIN")
if not binary or binary == "" then
	binary = nil
	local candidates = {
		home .. "/.local/bin/omp",
		home .. "/Library/Application Support/Tern/omp/bin/omp",
	}
	for _, path in candidates do
		if home ~= "" and tern.fs.exists(path) then
			binary = path
			break
		end
	end
	if binary == nil then
		binary = "omp"
	end
end

-- GUI-launched daemons can miss the user's PATH additions; extend it with the
-- conventional user executable directories. Never invoke a login shell.
local search = {}
local binDir = binary:match("^(.*)[/\\]")
if binDir and binDir ~= "" then
	table.insert(search, binDir)
end
if home ~= "" then
	table.insert(search, home .. "/.local/bin")
	table.insert(search, home .. "/.bun/bin")
end
table.insert(search, tern.getenv("PATH") or "/usr/bin:/bin")
local processEnv = { PATH = table.concat(search, ":") }

-- Provider API keys often live in shell rc files (e.g. ~/.zshenv), which the
-- GUI-launched daemon never sees. Run omp through the user's login shell so
-- omp reads the same credentials it reads in a terminal. POSIX shells only;
-- Windows runs the binary directly.
local shell = tern.getenv("SHELL")
if shell == nil or shell == "" then
	shell = "/bin/zsh"
end
local function shQuote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end
local useShell = tern.runtime.os ~= "windows"
local function ompRun(args, timeout, done)
	if useShell then
		-- exec keeps the omp process in place of the shell, so stdout is
		-- exactly omp's output and no extra process lingers.
		local cmd = "exec " .. shQuote(binary) .. " " .. table.concat(args, " ")
		return tern.process.run({ shell, "-l", "-c", cmd }, { timeout_ms = timeout, env = processEnv }, done)
	end
	return tern.process.run({ binary, table.unpack(args) }, { timeout_ms = timeout, env = processEnv }, done)
end

-- Balance adapters: token lookup + provider-API fetch. Keys stay in this VM's
-- memory and in request headers only.
local tokenCache: { [string]: string } = {}

-- Balance endpoints that failed back off for a while: later lookups skip
-- them so a dead mirror (Kimi falls back across three URLs) stops costing
-- its 10s timeout on every refresh cycle.
local urlBadUntil: { [string]: number } = {}

local function getToken(pid: string, done: (string?) -> ())
	local cached = tokenCache[pid]
	if cached ~= nil then
		done(cached)
		return
	end
	ompRun({ "token", pid }, 8000, function(r)
		local key = if r.status == 0 and type(r.stdout) == "string" and r.stdout ~= ""
			then (r.stdout:gsub("%s+$", ""))
			else nil
		if key ~= nil and #key > 0 then
			tokenCache[pid] = key
			done(key)
		else
			done(nil)
		end
	end)
end

local function fetchBalance(pid: string, key: string, done: ({ any }?, string?) -> ())
	local adapter = balances.adapters[pid]
	if adapter == nil then
		done(nil, nil)
		return
	end
	-- Skip URLs that failed recently; when every URL is marked, the plan
	-- still probes the canonical first URL so the error note stays visible
	-- and the endpoint can recover.
	local plan = balances.planAttempts(adapter.urls, urlBadUntil, now())
	local idx = 0
	local lastNote: string? = nil
	local function noteFrom(body: string): string?
		if body == "" then
			return nil
		end
		local ok, data = pcall(function()
			return tern.json.decode(body)
		end)
		if not ok or type(data) ~= "table" then
			return nil
		end
		local err = (data :: any).error
		if type(err) ~= "table" then
			return nil
		end
		local code = if type(err.code) == "string" then err.code elseif type(err.type) == "string" then err.type else nil
		if code ~= nil then
			return code
		end
		return nil
	end
	local function attempt()
		idx += 1
		local url = plan[idx]
		if url == nil then
			done(nil, lastNote)
			return
		end
		tern.fetch(url, { headers = { Authorization = "Bearer " .. key }, timeout_ms = 10000 }, function(r)
			if r.error ~= nil or r.status ~= 200 or r.body == "" then
				urlBadUntil[url] = now() + balances.URL_BACKOFF_MS
				lastNote = noteFrom(r.body) or lastNote
				attempt()
				return
			end
			local ok, rows = pcall(adapter.parse, r.body, tern.json.decode)
			if ok and type(rows) == "table" and #rows > 0 then
				done(rows, nil)
			else
				urlBadUntil[url] = now() + balances.URL_BACKOFF_MS
				lastNote = noteFrom(r.body) or lastNote
				attempt()
			end
		end)
	end
	attempt()
end

-- Compose the final snapshot: usage + catalog + direct balances. Calls done
-- exactly once; never raises past the collector's pcall.
local function enrich(usageOut: string, modelsOut: string, done: (any) -> ())
	local okS, snap = pcall(function()
		local s = usage.normalize(tern.json.decode(usageOut))
		local okC, catalog = pcall(function()
			return usage.normalizeModels(tern.json.decode(modelsOut))
		end)
		if okC then
			s = usage.merge(s, catalog)
		end
		return s
	end)
	if not okS then
		done(nil)
		return
	end

	local targets: { any } = {}
	for _, p in (snap :: any).providers do
		if balances.adapters[p.key] ~= nil and #p.limits == 0 then
			table.insert(targets, p)
		end
	end
	if #targets == 0 then
		usage.recount(snap :: any)
		done(snap)
		return
	end

	local pending = #targets
	local function settle()
		pending -= 1
		if pending <= 0 then
			usage.recount(snap :: any)
			done(snap)
		end
	end
	for _, p in targets do
		local provider = p
		getToken(provider.key, function(key)
			if key == nil then
				settle()
				return
			end
			fetchBalance(provider.key, key, function(rows, note)
				if rows ~= nil then
					for _, l in rows do
						table.insert(provider.limits, l)
					end
					provider.state = "reported"
					provider.note = nil
				elseif note ~= nil then
					provider.note = note
				end
				settle()
			end)
		end)
	end
end

-- Seed the last published record so a daemon restart shows data at once
-- instead of "读取中" until the first refresh lands.
local prior = tern.kv.get("record")

local collector = Collector.new({
	now = now,
	normalize = function(usageOut, modelsOut)
		local snap = usage.normalize(tern.json.decode(usageOut))
		if modelsOut ~= nil then
			local ok, catalog = pcall(function()
				return usage.normalizeModels(tern.json.decode(modelsOut))
			end)
			if ok then
				snap = usage.merge(snap, catalog)
			end
			-- 目录失败只降级为纯用量快照，绝不丢配额数据。
		end
		return snap
	end,
	summary = usage.summary,
	decode = tern.json.decode,
	fetch = function(timeout, done)
		return ompRun({ "usage", "--json" }, timeout, done)
	end,
	fetchModels = function(timeout, done)
		return ompRun({ "models", "--json" }, timeout, done)
	end,
	invalidate = function(timeout, done)
		return ompRun({ "usage", "invalidate" }, timeout, done)
	end,
	enrich = enrich,
	publish = function(rec)
		tern.kv.set("record", rec)
	end,
	changed = renderLive,
}, if type(prior) == "table" then prior.leaseUntil else nil)

if type(prior) == "table" and type(prior.snapshot) == "table" then
	collector.snapshot = prior.snapshot
	collector.lastSuccess = prior.lastSuccess
end

tern.block.define("dashboard", {
	init = function(cx, _args, _saved)
		blocks[cx.pane] = cx
		return {}
	end,
	title = function()
		return "Provider Quota"
	end,
	view = function(_state, _cx)
		return view.render({
			snapshot = collector.snapshot,
			error = collector.error,
			lastSuccess = collector.lastSuccess,
			heartbeat = now(),
			refreshing = collector.refreshing,
		}, now(), tern.ui)
	end,
	key = function(_state, key, _cx)
		if key.name == "r" and not key.ctrl and not key.alt and not key.meta then
			collector:refresh(true)
			return true
		end
		return false
	end,
	event = function(_state, ev, _cx)
		if ev.ev == "action" and ev.act == "refresh" then
			collector:refresh(true)
		end
	end,
})

local function tick()
	-- Re-arm before work: a failed publish must not end the loop for good.
	tern.timer(5000, tick)
	pcall(collector.tick, collector)
end
-- Defer IO until the entries and restored blocks have loaded.
tern.timer(100, tick)
