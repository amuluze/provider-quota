--!strict
-- provider-quota view: pure render of a snapshot record into native nodes.
-- render(record, nowMs, ui) -> { main = col, dock = row }.
-- `ui` is tern.ui, injected so this module never touches the tern global.

local usage = require("./usage")

type Ui = any
type UiNode = any

type Limit = usage.Limit
type Provider = usage.Provider
type Snapshot = usage.Snapshot

-- What view.render actually reads; the full kv record carries more.
export type RenderRecord = {
	snapshot: Snapshot?,
	error: string?,
	lastSuccess: number?,
	refreshing: boolean?,
}

export type Status = { refreshing: boolean, error: string?, lastSuccess: number? }

type Ctx = {
	ui: Ui,
	now: number,
	snap: Snapshot?,
	status: Status,
}

local STALE_MS = usage.STALE_MS

local SEV_TONE: { [string]: string } = {
	exhausted = "error",
	low = "warning",
	ok = "success",
}

local function with(node: UiNode, props: { [string]: any }): UiNode
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function span(ctx: Ctx, t: string, s: string?): any
	return ctx.ui.span(t, s)
end

-- Newer Tern builds hand a card its props as a third argument; older ones take
-- the head and the body only. Probe once: a build that accepts the props
-- argument keeps them in p, so the meta line can stay in the card head.
local cardPropsFlag: boolean? = nil

local function cardTakesProps(ctx: Ctx): boolean
	if cardPropsFlag == nil then
		local ok, probe = pcall(ctx.ui.card, "probe", {}, { meta = "probe" })
		cardPropsFlag = ok
			and type(probe) == "table"
			and type(probe.p) == "table"
			and probe.p.meta ~= nil
	end
	return cardPropsFlag
end

local function cardNode(ctx: Ctx, head: any, children: { any }, props: { [string]: any }): UiNode
	if cardTakesProps(ctx) then
		return ctx.ui.card(head, children, props)
	end
	local node = ctx.ui.card(head, children)
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- The stats strip only exists on newer Tern builds; older ones get a badge
-- row with the same numbers.
local function statsNode(ctx: Ctx, items: { any }): UiNode
	local ui = ctx.ui
	if ui.stats ~= nil then
		return ui.stats(items)
	end
	local row: { any } = {}
	for _, item in items do
		table.insert(row, ui.badge(tostring(item.label) .. " " .. tostring(item.value), item.tone or "muted"))
	end
	return ui.row(row)
end

-- "推荐" goes to the provider whose best remaining fraction is the highest;
-- that is where the user should send work next.
local function recommendedKey(snap: Snapshot): string?
	local bestProv: string? = nil
	local bestFrac: number? = nil
	for _, prov in snap.providers do
		local f = usage.providerBest(prov)
		if f ~= nil and (bestFrac == nil or f > (bestFrac :: number)) then
			bestFrac = f
			bestProv = prov.key
		end
	end
	return bestProv
end

local function limitRow(ctx: Ctx, l: Limit): { any }
	local sev = usage.severity(l)
	local tone = SEV_TONE[sev]
	local fill = usage.remainingFill(l)

	local label: { any } = { span(ctx, l.label, if sev == "exhausted" then "error strong" elseif sev == "low" then "warning" else nil) }
	if l.windowLabel ~= nil and l.windowLabel ~= "" then
		table.insert(label, span(ctx, " · " .. l.windowLabel, "muted"))
	end
	if sev == "unknown" then
		table.insert(label, span(ctx, " · 未上报", "muted"))
	end

	local bar: any
	local left: any
	local reset: any
	if l.isBalance then
		-- Money rows: no meter, no reset — just the amount.
		table.insert(label, span(ctx, " · 直查", "muted"))
		bar = span(ctx, "—", "muted")
		left = { span(ctx, l.amountText or "—", "num strong") }
		reset = span(ctx, "", "")
	elseif fill ~= nil then
		bar = { meter = { value = fill, tone = tone } }
		local parts: { any } = { span(ctx, usage.percent(fill), if sev == "exhausted" then "error strong" elseif sev == "low" then "warning strong" else "num") }
		if l.remaining ~= nil and l.unit ~= nil and l.unit ~= "" then
			table.insert(parts, span(ctx, " " .. tostring(math.floor(l.remaining + 0.5)) .. " " .. l.unit, "muted"))
		end
		left = parts
		if l.resetsAt ~= nil then
			local ms = (l.resetsAt :: number) - ctx.now
			if ms <= 0 then
				reset = { span(ctx, "已到期", "warning") }
			else
				reset = { span(ctx, usage.duration(ms), "num"), span(ctx, " 后", "muted") }
			end
		else
			reset = { span(ctx, "未上报", "muted") }
		end
	else
		bar = span(ctx, "—", "muted")
		left = span(ctx, "未上报", "muted")
		reset = span(ctx, "未上报", "muted")
	end

	-- A row is a plain cell list; the row-id form only exists on newer builds.
	return { label, bar, left, reset }
end

local LIMIT_COLS = {
	{ id = "quota", head = "额度", grow = 2, truncate = "end", priority = 3 },
	{ id = "bar", head = "余量", grow = 3, priority = 1 },
	{ id = "left", head = "剩余", align = "end", priority = 2 },
	{ id = "reset", head = "重置", align = "end", priority = 4 },
}

-- Limits within a provider sorted by remaining, unknown last.
local function sortedLimits(prov: Provider): { Limit }
	local out: { Limit } = {}
	for _, l in prov.limits do
		table.insert(out, l)
	end
	table.sort(out, function(a, b)
		local fa = usage.remainingFill(a)
		local fb = usage.remainingFill(b)
		if fa ~= nil and fb ~= nil then
			if fa ~= fb then
				return fa < fb
			end
		elseif (fa == nil) ~= (fb == nil) then
			return fb == nil -- known first
		end
		return a.key < b.key
	end)
	return out
end

local function providerCard(ctx: Ctx, prov: Provider, recommended: boolean): UiNode
	local ui = ctx.ui
	local head: { any } = { span(ctx, prov.name, "strong") }
	if prov.plan ~= nil then
		table.insert(head, span(ctx, " · " .. (prov.plan :: string), "muted"))
	end
	if recommended then
		table.insert(head, span(ctx, " · 推荐", "success strong"))
	end
	local rows: { any } = {}
	for _, l in sortedLimits(prov) do
		table.insert(rows, limitRow(ctx, l))
	end
	-- Older builds have no table options, so the empty case is a text line.
	local body: { any } = {}
	if #rows > 0 then
		table.insert(body, ui.table(LIMIT_COLS, rows))
	else
		table.insert(body, ui.text({ span(ctx, "此供应商未上报额度。", "muted") }))
	end
	local meta: { any } = {}
	if prov.models ~= nil then
		table.insert(meta, span(ctx, tostring(prov.models) .. " 个模型", "muted"))
	end
	if prov.fetchedAt ~= nil then
		local age = ctx.now - (prov.fetchedAt :: number)
		table.insert(meta, span(ctx, " · 更新于 " .. usage.ago(ctx.now, prov.fetchedAt :: number), if age > STALE_MS then "warning" else "muted"))
	end
	-- The card head has no meta slot on older builds, so the line rides in the
	-- body instead of the head.
	local props: { [string]: any } = {
		key = "p:" .. prov.key,
		icon = "gauge",
	}
	if cardTakesProps(ctx) then
		if #meta > 0 then
			props.meta = meta
		end
	elseif #meta > 0 then
		table.insert(body, 1, ui.text(meta))
	end
	return with(cardNode(ctx, head, body, props), { role = "provider-quota.provider" })
end

-- Providers without any reported quota, one compact row each.
-- Upstream error codes -> readable hints (display layer only).
local NOTE_TEXT: { [string]: string } = {
	api_key_expired = "key 已过期：续订 Go 或在 Console 重建 key",
	invalid_authentication_error = "认证失败：key 与此端点不匹配",
}

local function noteText(prov: Provider): string?
	local note = prov.note
	if note == nil then
		return nil
	end
	return NOTE_TEXT[note] or note
end

local function noQuotaCard(ctx: Ctx, providers: { Provider }): UiNode?
	if #providers == 0 then
		return nil
	end
	local ui = ctx.ui
	local rows: { any } = {}
	for _, prov in providers do
		local note = noteText(prov)
		local parts: { any } = { span(ctx, prov.name, "strong") }
		if note ~= nil then
			table.insert(parts, span(ctx, " · " .. note, "warning"))
		elseif prov.state == "no-usage" then
			table.insert(parts, span(ctx, " · API key，无用量端点", "muted"))
		else
			table.insert(parts, span(ctx, " · 已配置", "muted"))
		end
		if prov.models ~= nil then
			table.insert(parts, span(ctx, " · " .. tostring(prov.models) .. " 个模型", "muted"))
		end
		table.insert(rows, with(ui.text(parts), { key = "nq:" .. prov.key }))
	end
	local props: { [string]: any } = {
		key = "noquota",
		icon = "puzzle",
	}
	local head: any = "未上报额度"
	if cardTakesProps(ctx) then
		props.meta = span(ctx, tostring(#providers) .. " 家", "muted")
	else
		head = "未上报额度 · " .. tostring(#providers) .. " 家"
	end
	return with(cardNode(ctx, head, rows, props), { role = "provider-quota.no-quota" })
end

local function disabledCard(ctx: Ctx): UiNode?
	local snap = ctx.snap :: Snapshot
	if #snap.disabled == 0 then
		return nil
	end
	local ui = ctx.ui
	local rows: { any } = {}
	for _, d in snap.disabled do
		local parts: { any } = { span(ctx, d.provider, "strong") }
		table.insert(parts, span(ctx, " · " .. d.cause, "muted"))
		if d.models ~= nil then
			table.insert(parts, span(ctx, " · " .. tostring(d.models) .. " 个模型", "muted"))
		end
		if d.at ~= nil then
			table.insert(parts, span(ctx, " · " .. usage.ago(ctx.now, d.at :: number), "muted"))
		end
		table.insert(rows, with(ui.text(parts), { key = "d:" .. d.key }))
	end
	table.insert(rows, with(ui.text({ span(ctx, "在终端重新登录该供应商后按 r 刷新。", "muted") }), { key = "d:hint" }))
	return with(cardNode(ctx, "需要重新登录", rows, { key = "disabled", icon = "alert", tone = "warning" }), {
		role = "provider-quota.disabled",
	})
end

local M = {}

function M.render(record: RenderRecord, nowMs: number, ui: Ui): { main: UiNode, dock: UiNode? }
	local snap = record.snapshot
	local status: Status = {
		refreshing = record.refreshing == true,
		error = record.error,
		lastSuccess = record.lastSuccess,
	}
	local ctx: Ctx = { ui = ui, now = nowMs, snap = snap, status = status }

	if snap == nil then
		local sub = if status.error ~= nil
			then "读取失败：" .. (status.error :: string)
			else "正在读取 omp usage / omp models（首次需要几秒）…"
		return {
			main = ui.col({
				with(ui.text({ span(ctx, "额度面板", "strong") }), { key = "empty-head" }),
				with(ui.text({ span(ctx, sub, if status.error then "warning" else "muted") }), { key = "empty-sub" }),
			}),
		}
	end

	local s = snap :: Snapshot
	local c = s.counts
	local main: { any } = {}

	local stats: { any } = {
		{ label = "已配置", value = tostring(c.providers) },
		{ label = "正常", value = tostring(c.ok), tone = "success" },
		{ label = "偏低", value = tostring(c.low), tone = if c.low > 0 then "warning" else nil },
		{ label = "耗尽", value = tostring(c.exhausted), tone = if c.exhausted > 0 then "error" else nil },
		{ label = "需登录", value = tostring(c.disabled), tone = if c.disabled > 0 then "warning" else nil },
	}
	table.insert(main, with(statsNode(ctx, stats), { key = "stats" }))

	if status.error ~= nil then
		local age = if status.lastSuccess ~= nil
			then "，数据是 " .. usage.ago(nowMs, status.lastSuccess :: number)
			else ""
		table.insert(main, with(cardNode(ctx, "上次刷新失败", {
			with(ui.text({
				span(ctx, status.error :: string, "warning"),
				span(ctx, age .. "。按 r 重试。", "muted"),
			}), { key = "err-text" }),
		}, { key = "error", icon = "alert", tone = "warning" }), { key = "error-card" }))
	end

	-- Reported-quota providers first, worst severity on top; the best-stocked
	-- provider carries the 推荐 badge so picking where to work is one glance.
	local recKey = recommendedKey(s)
	local withLimits: { Provider } = {}
	local withoutLimits: { Provider } = {}
	for _, p in s.providers do
		if #p.limits > 0 then
			table.insert(withLimits, p)
		else
			table.insert(withoutLimits, p)
		end
	end
	table.sort(withLimits, function(a, b)
		local ra = usage.SEVERITY_RANK[usage.providerWorst(a)]
		local rb = usage.SEVERITY_RANK[usage.providerWorst(b)]
		if ra ~= rb then
			return ra < rb
		end
		return a.name < b.name
	end)
	table.sort(withoutLimits, function(a, b)
		return a.name < b.name
	end)

	for _, prov in withLimits do
		table.insert(main, providerCard(ctx, prov, prov.key == recKey))
	end

	local noQuota = noQuotaCard(ctx, withoutLimits)
	if noQuota ~= nil then
		table.insert(main, noQuota :: UiNode)
	end

	local disabled = disabledCard(ctx)
	if disabled ~= nil then
		table.insert(main, disabled :: UiNode)
	end

	if c.providers == 0 and c.disabled == 0 then
		table.insert(main, with(ui.text({ span(ctx, "omp 未配置任何模型供应商；先在终端里登录一家。", "muted") }), { key = "empty" }))
	end

	-- The button builder only exists on newer builds; older ones keep the
	-- refresh on the "r" key.
	local refresh: any
	if ui.button ~= nil then
		refresh = ui.button("刷新", {
			key = "refresh",
			icon = "repeat",
			size = "sm",
			keys = { "r" },
			actions = { click = "refresh" },
			busy = status.refreshing,
		})
	else
		refresh = ui.text({ span(ctx, if status.refreshing then "刷新中…" else "按 r 刷新", "muted") })
	end

	local dock: { any } = {
		with(ui.text({ span(ctx, "omp usage + models · 每 60s 自动刷新", "muted") }), { key = "dock-note" }),
		with(ui.row({}), { key = "dock-fill", grow = 1 }),
		with(refresh, { key = "dock-refresh" }),
	}

	return {
		main = with(ui.col(main), { role = "provider-quota.main" }),
		dock = ui.row(dock),
	}
end

return M
