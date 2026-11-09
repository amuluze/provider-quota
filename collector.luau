-- One collector per host VM. Dependencies are injected so the lifecycle
-- logic stays deterministic and testable; host.luau wires tern.process /
-- tern.kv / tern.timer in.

local M = {}
local INTERVAL = 60_000 -- poll omp every minute
local TIMEOUT = 30_000 -- each omp call must answer within 30s
local LEASE = TIMEOUT * 3 + 15_000 -- in-flight guard covering all three legs
local INVALIDATE_TIMEOUT = 8_000 -- `omp usage invalidate` clears a local cache

function M.new(deps, priorLease)
	local self = {
		snapshot = nil,
		error = nil,
		lastSuccess = nil,
		refreshing = false,
		leaseUntil = math.min(tonumber(priorLease) or 0, deps.now() + LEASE),
		nextFetch = 0,
	}

	local function record()
		return {
			snapshot = self.snapshot,
			error = self.error,
			lastSuccess = self.lastSuccess,
			heartbeat = deps.now(),
			refreshing = self.refreshing,
		}
	end

	function self:publish()
		local rec = record()
		local summary = deps.summary(rec.snapshot, deps.now(), {
			error = self.error,
			lastSuccess = self.lastSuccess,
			refreshing = self.refreshing,
		})
		rec.text = summary.text
		rec.tone = summary.tone
		rec.segments = summary.segments
		deps.publish(rec)
		deps.changed()
	end

	local function finish(snapshot, message)
		self.refreshing = false
		self.leaseUntil = 0
		-- nextFetch was armed at refresh start, so failures keep the same
		-- period as successes.
		if snapshot then
			self.snapshot = snapshot
			self.lastSuccess = deps.now()
			self.error = nil
		else
			-- Keep the last good snapshot; show why it is stale.
			self.error = message
		end
		self:publish()
	end

	local function finishWith(usageOut, modelsOut)
		local parsed, snapshot = pcall(function()
			return deps.normalize(usageOut, modelsOut)
		end)
		if parsed then
			finish(snapshot, nil)
		else
			finish(nil, "omp 返回了无法解析的用量报告。检查 omp usage --json 后按 r 重试。")
		end
	end

	-- refresh(force): one full sampling pass. Auto ticks pass no argument;
	-- the manual path (r / 刷新按钮) passes true, which first clears omp's
	-- cached usage reports so the numbers come from the providers live —
	-- omp otherwise keeps serving a report that can be minutes old.
	function self:refresh(force: boolean?)
		local now = deps.now()
		if self.refreshing or now < self.leaseUntil then
			return false
		end
		self.refreshing = true
		self.leaseUntil = now + LEASE
		-- The period counts from the START of a refresh, not its completion,
		-- so a slow omp never stretches the cycle between fresh snapshots.
		self.nextFetch = now + INTERVAL
		self:publish()

		local function startFetch()
			local ok = pcall(deps.fetch, TIMEOUT, function(result)
				if result.timed_out then
					finish(nil, "omp usage 超时（30s）。检查 omp 后按 r 重试。")
				elseif result.status ~= 0 then
					finish(nil, "omp usage 退出码 " .. tostring(result.status) .. "。检查 omp 后按 r 重试。")
				else
					-- Second leg: the model catalog. Its failure degrades to a
					-- usage-only snapshot instead of losing good quota data.
					local ok2 = pcall(deps.fetchModels, TIMEOUT, function(mresult)
						if mresult.timed_out or mresult.status ~= 0 then
							finishWith(result.stdout, nil)
						else
							-- Third leg (host-side): direct provider balance adapters.
							-- enrich must call back exactly once with a snapshot;
							-- a sync raise degrades to the plain merge below.
							local enriched = pcall(deps.enrich, result.stdout, mresult.stdout, function(snapshot)
								if snapshot == nil then
									finish(nil, "omp 返回了无法解析的用量报告。检查 omp usage --json 后按 r 重试。")
								else
									finish(snapshot, nil)
								end
							end)
							if not enriched then
								finishWith(result.stdout, mresult.stdout)
							end
						end
					end)
					if not ok2 then
						finishWith(result.stdout, nil)
					end
				end
			end)
			if not ok then
				self.refreshing = false
				self.leaseUntil = 0
				self.error = "无法启动 omp。确认它在 daemon 的 PATH 上，或设置 TERN_QUOTA_BIN 后重载插件。"
				self:publish()
			end
		end

		if force then
			-- Best-effort: an invalidate that cannot start (or raises) falls
			-- through to the plain fetch — a cached snapshot beats no data.
			-- pcall's first return only means "did not raise"; the dep's own
			-- boolean carries whether it actually spawned.
			local invoked, ok = pcall(deps.invalidate, INVALIDATE_TIMEOUT, function()
				startFetch()
			end)
			if not invoked or ok == false then
				startFetch()
			end
		else
			startFetch()
		end
		return true
	end

	function self:tick()
		local now = deps.now()
		if now >= self.nextFetch and not self.refreshing and now >= self.leaseUntil then
			self:refresh()
		else
			self:publish()
		end
	end

	return self
end

M.INTERVAL = INTERVAL
M.LEASE = LEASE

return M
