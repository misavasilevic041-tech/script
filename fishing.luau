-- Autofish bot for Avatar Simulator
-- Drives the game's own handlers: CAST -> charge -> THROW -> TUG (lure) -> HOOK -> bite -> fight (REEL)
-- Optional auto-sell through the game's own FISHDEX panel. Control: the GUI panel or getgenv().AF.
--
--   AF.enabled   true/false                     pause / resume
--   AF.speed     "slow"|"medium"|"fast"         tempo of all delays
--   AF.human     "off"|"low"|"normal"|"high"    strength of the randomizer
--   AF.mouse     true/false                     real mouse clicks at random points of a button
--   AF.pauses    true/false                     random pauses between casts (+ rare long pause)
--   AF.policy    "smart"|"always"|"probe"       fight policy
--   AF.hardCast  true/false                     cast at exactly 34.0 m (MAX DEPTH)
--   AF.sell / sellKeep / sellEvery / sellMax    auto-sell
--   AF.stop()    unload: stop everything, destroy the menu, clear getgenv() entries
--
-- v1 (hub): runs under the hub. STATE comes from Core.launch, the log goes to Core.log (copy-log button),
-- settings are saved through Core.getFarm / Core.setFarm, all GUI texts are translated. Fishing logic untouched.
--   AF.stats, AF.trace (last 900 log lines), AF.state, AF.ready, AF.status

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local P = Players.LocalPlayer

local Core = getgenv().HubCore
if not Core then
	warn("[AF] Core not found: start hub.luau first")
	return
end
local T = Core.t
Core.addStrings({
	ru = {
		af_enabled = "ВКЛЮЧЕНО",
		af_disabled = "ВЫКЛЮЧЕНО",
		af_waiting = "ОЖИДАНИЕ",
		af_speed = "скорость:",
		af_settings = "настройки",
		af_policy = "стратегия боя",
		af_hardcast = "заброс 34 м",
		af_humanize = "человечность",
		af_mouse = "клики мышью",
		af_pauses = "паузы между забросами",
		af_sell = "автопродажа",
		af_sellevery = "продавать каждые",
		af_sellmax = "макс. за раз",
		af_keep = "оставлять %s",
		af_unload_title = "ВЫГРУЗКА СКРИПТА",
		af_unload_text = "Остановит работу и уберёт меню",
		af_cancel = "Отмена",
		af_toast_on = "Рыбалка включена",
		af_toast_off = "Рыбалка выключена",
		af_toast_unload = "Рыбалка выгружена",
	},
	en = {
		af_enabled = "ENABLED",
		af_disabled = "DISABLED",
		af_waiting = "WAITING",
		af_speed = "speed:",
		af_settings = "settings",
		af_policy = "fight policy",
		af_hardcast = "hard cast 34m",
		af_humanize = "humanize",
		af_mouse = "mouse clicks",
		af_pauses = "cast pauses",
		af_sell = "auto-sell",
		af_sellevery = "sell every",
		af_sellmax = "sell max",
		af_keep = "keep %s",
		af_unload_title = "UNLOAD SCRIPT",
		af_unload_text = "Stops all work and destroys the menu",
		af_cancel = "Cancel",
		af_toast_on = "Fishing enabled",
		af_toast_off = "Fishing disabled",
		af_toast_unload = "Fishing unloaded",
	},
})

local VIM
pcall(function()
	VIM = game:GetService("VirtualInputManager")
end)

-- STATE (connect / onCleanup / alive) normally comes from the loader; fall back to a tiny built-in one
local STATE = rawget(_G, "STATE") or getgenv().STATE
if not (type(STATE) == "table" and STATE.connect and STATE.onCleanup and STATE.alive) then
	pcall(function()
		getgenv().AFShim.stop()
	end)
	local s = { conns = {}, fns = {}, dead = false }
	function s.connect(sig, fn)
		local c = sig:Connect(fn)
		s.conns[#s.conns + 1] = c
		return c
	end
	function s.onCleanup(fn)
		s.fns[#s.fns + 1] = fn
	end
	function s.alive()
		return not s.dead
	end
	function s.stop()
		s.dead = true
		for _, c in ipairs(s.conns) do
			pcall(c.Disconnect, c)
		end
		for _, f in ipairs(s.fns) do
			pcall(f)
		end
	end
	getgenv().AFShim, STATE = s, s
end

local AF = getgenv().AF
if type(AF) ~= "table" then
	AF = {}
end
getgenv().AF = AF
AF.t0, AF.trace, AF.enabled, AF.ready, AF.status = os.clock(), {}, false, false, nil
AF.stats = { casts = 0, catches = 0, escapes = 0, errors = 0, sold = 0, bestDist = 0, bestProg = 0 }
-- saved settings (AutoFarmHub/settings.json) win over the built-in defaults; enabled is never saved
local DEFAULTS = {
	policy = "smart",
	hardCast = true,
	sell = false,
	sellKeep = { Epic = true, Legendary = true },
	sellEvery = 5,
	sellMax = 25,
	speed = "medium",
	human = "normal",
	mouse = false,
	pauses = true,
}
for k, v in pairs(Core.getFarm("fishing", DEFAULTS)) do
	if AF[k] == nil then
		AF[k] = v
	end
end
local function saveSettings()
	local o = {}
	for k in pairs(DEFAULTS) do
		o[k] = AF[k]
	end
	Core.setFarm("fishing", o)
end

local function log(fmt, ...)
	local s = string.format(fmt, ...)
	local t = AF.trace
	t[#t + 1] = string.format("[%6.2f] %s", os.clock() - AF.t0, s)
	if #t > 900 then
		table.remove(t, 1)
	end
	Core.log("AF", "%s", s)
end
AF.log = log

-- Current FishingGui "session". The game re-creates its GUI when the rod is lost and picked up again,
-- so everything below is (re)resolved by attach() and dropped by detach().
local gui, castBtn, lureBtn, hookBtn, catchPopup, catchPanel, continueBtn, reelBtn, meter, track
local castH, beginCast, finishCast, lureH, hookH, setReeling, continueH
local attached = false

-- ============================================================
-- Humanizer: randomized delays, click points and hold times
-- ============================================================
local rng = Random.new()
local function rand(a, b)
	return a + rng:NextNumber() * (b - a)
end
local SPEED = { slow = 1.8, medium = 1, fast = 0.55 }
local HUMAN = { off = 0, low = 0.5, normal = 1, high = 1.6 }
local function humanK()
	return HUMAN[AF.human] or 1
end

-- delay: lo is the base, (hi-lo) the random spread (scaled by humanize), all scaled by speed.
-- crit = time-critical action, the slow-down is capped so bites are not missed.
local function D(lo, hi, crit)
	local m = SPEED[AF.speed] or 1
	if crit then
		m = math.min(m, 1.2)
	end
	return (lo + (hi - lo) * rng:NextNumber() * humanK()) * m
end

-- one-shot timer: true once the randomized delay for `name` has elapsed
local due = {}
local function gate(name, lo, hi, crit)
	local now = os.clock()
	due[name] = due[name] or now + D(lo, hi, crit)
	if now >= due[name] then
		due[name] = nil
		return true
	end
	return false
end

-- real mouse click at a random (centre-biased) spot inside a button; false if clicks are unavailable
local function clickAt(btn, fallback)
	if not (VIM and btn and btn.AbsoluteSize.X > 0) then
		return false
	end
	local function r()
		return 0.5 + ((rng:NextNumber() + rng:NextNumber()) / 2 - 0.5) * 0.75
	end
	local pos, sz = btn.AbsolutePosition, btn.AbsoluteSize
	local x = pos.X + sz.X * r()
	local y = pos.Y + sz.Y * r() + (gui.IgnoreGuiInset and 0 or GuiService:GetGuiInset().Y)
	task.spawn(function()
		local ok = pcall(function()
			VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
			task.wait(D(0.03, 0.12))
			VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
		end)
		if not ok and fallback then
			fallback()
		end
	end)
	return true
end

-- press a button via the game's handler, or (AF.mouse) with a real click at a random spot inside it
local lastAct = {}
local function act(name, btn, fn, cooldown)
	local now = os.clock()
	if now - (lastAct[name] or 0) < cooldown then
		return
	end
	lastAct[name] = now
	if not (AF.mouse and clickAt(btn, fn)) then
		fn()
	end
end

-- ============================================================
-- Game handlers
-- ============================================================
-- the connection with the most upvalues (>= minUps) is the game's own handler
local function find(sig, minUps)
	local best, bestUps = nil, (minUps or 0) - 1
	for _, c in ipairs(getconnections(sig)) do
		local f = c.Function
		if type(f) == "function" then
			local ok, info = pcall(debug.getinfo, f)
			if ok and info and info.nups > bestUps then
				best, bestUps = f, info.nups
			end
		end
	end
	return best
end

-- recursive lookup, waits a little in case the game builds its GUI late
local function child(parent, name, wait)
	if not parent then
		return nil
	end
	return parent:FindFirstChild(name, true) or (wait and parent:WaitForChild(name, wait)) or nil
end

local staleGui, staleSince, dumped = nil, 0, nil

-- Bind to the current FishingGui. Everything is resolved into temporaries first, so a half-built GUI
-- (the game's scripts connect their handlers a moment after creating it) never leaves a half session.
-- Returns true, or false + the reason.
local function attach(now)
	local g = P.PlayerGui:FindFirstChild("FishingGui")
	if not g then
		return false, "waiting for FishingGui"
	end
	if g == staleGui and now - staleSince < 5 then
		return false, "waiting for new FishingGui" -- the old one belongs to the lost rod
	end
	local c, l, h = child(g, "CastButton"), child(g, "LureButton"), child(g, "HookButton")
	if not (c and l and h) then
		if dumped ~= g then
			dumped = g
			for _, d in ipairs(g:GetChildren()) do
				log("FishingGui child: %s (%s)", d.Name, d.ClassName) -- shows the real names
			end
		end
		return false, "buttons not found"
	end
	local popup = child(g, "CatchPopup")
	local cont = child(popup, "ContinueButton")
	local reel = child(child(g, "FightHUD"), "ReelButton")
	local ch = find(c.Activated, 6)
	local lh, hh = find(l.Activated, 6), find(h.Activated, 3)
	local rh = reel and find(reel.InputBegan, 2)
	-- TextButton:Activate() does not exist here: the OK button is driven through the game's handler.
	-- It only accepts the press in state "Catch"/"CaughtHold" and then resets the state to None.
	local ct = cont and find(cont.Activated)
	local begin = ch and debug.getupvalue(ch, 7)
	local finish = ch and debug.getupvalue(ch, 8)
	local sr = rh and debug.getupvalue(rh, 2)
	local miss = {}
	for _, e in ipairs({ { "cast", begin and finish }, { "lure", lh }, { "hook", hh }, { "reel", sr }, { "continue", ct } }) do
		if not e[2] then
			miss[#miss + 1] = e[1]
		end
	end
	if #miss > 0 then
		return false, "handlers not ready: " .. table.concat(miss, ",")
	end
	gui, castBtn, lureBtn, hookBtn = g, c, l, h
	catchPopup, catchPanel, continueBtn, reelBtn = popup, child(g, "CatchPanel"), cont, reel
	meter = child(g, "CastMeter")
	track = child(meter, "Track")
	castH, beginCast, finishCast, lureH, hookH, setReeling, continueH = ch, begin, finish, lh, hh, sr, ct
	attached = true
	return true, "ready"
end

-- the current state string lives in an upvalue of the cast handler: read it live
local function getState()
	return castH and debug.getupvalue(castH, 4) or "None"
end

-- ============================================================
-- Runtime state
-- ============================================================
local reeling, fight = false, {}
local fightStart, maxProg, pendingCast = 0, 0, 0
local lastState, lastPopupName = nil, nil
local catchSince = 0
local okSince, okDelay, okStage, lastOkScan = 0, 0, 0, 0
local sinceSell = 0 -- catches since the last sell pass
local chargeAt = 0.97
local selling, sellPending = false, false
local lastBind, lastAttach, lastEquip, lastRodScan = 0, 0, 0, 0
local rodTool -- the rod Tool (in the character or the backpack), nil when the player has none

local function setReel(v)
	if reeling ~= v then
		reeling = v
		setReeling(v)
	end
end

-- humanized REEL: reaction latency, minimum hold/release time, rare attention lapses
local reelDue, reelHold, reelChanged = nil, 0.1, 0
local function humanReel(want)
	if humanK() == 0 then
		setReel(want)
		return
	end
	local now = os.clock()
	if want == reeling then
		reelDue = nil
		return
	end
	if not reelDue then
		local d = D(0.03, 0.17, true)
		if rng:NextNumber() < 0.03 * humanK() then
			d = d + rand(0.25, 0.6)
		end
		reelDue = now + d
	end
	if now >= reelDue and now - reelChanged >= reelHold then
		setReel(want)
		reelChanged, reelDue = now, nil
		reelHold = rand(0.05, 0.2) * math.max(humanK(), 0.5)
	end
end

-- ============================================================
-- Rod / GUI lifecycle
-- ============================================================
-- the rod: a Tool called "Fishing Rod" / "...fisher...", or any Tool that owns a FishingRemote
local function isRod(t)
	return t:IsA("Tool")
		and (t.Name == "Fishing Rod" or t.Name:lower():find("fisher", 1, true) ~= nil or t:FindFirstChild("FishingRemote") ~= nil)
end

local function findRodIn(holder)
	if holder then
		for _, t in ipairs(holder:GetChildren()) do
			if isRod(t) then
				return t
			end
		end
	end
	return nil
end

local function findRod() -- equipped first, then the backpack
	return findRodIn(P.Character) or findRodIn(P:FindFirstChildOfClass("Backpack"))
end

-- keep the rod in hand, otherwise the game refuses to cast
local function equipRod(now)
	if now - lastEquip < 0.5 or not rodTool or rodTool.Parent == P.Character then
		return
	end
	lastEquip = now
	local char = P.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		hum:EquipTool(rodTool)
		log("equipped rod")
	end
end

-- drop the session (the rod was lost or the game rebuilt its GUI); the old GUI is remembered so that
-- we wait for the new one instead of binding to the dead one
local function detach(reason)
	if attached then
		log("detached: %s", reason)
		staleGui, staleSince = gui, os.clock()
		if reeling then
			pcall(setReeling, false)
		end
	end
	attached = false
	reeling, fight = false, {}
	lastState, lastPopupName = nil, nil
	catchSince, okSince, okStage, pendingCast = 0, 0, 0, 0
	sellPending = false
	due, reelDue = {}, nil
end

local function setStatus(ready, text) -- AF.ready / AF.status drive the GUI; changes are logged
	AF.ready = ready
	if AF.status ~= text then
		AF.status = text
		log("status: %s", text)
	end
end

-- ============================================================
-- Server events (the remote is re-bound automatically when the rod changes)
-- ============================================================
local function getRemote()
	local rod = rodTool or findRod()
	return rod and rod:FindFirstChild("FishingRemote")
end

local function onEvent(a1, a2)
	if a1 ~= "FishingState" or type(a2) ~= "table" then
		return
	end
	local ev, d = a2.event, a2.data or {}
	if ev == "FightUpdate" then
		fight = d
		maxProg = math.max(maxProg, d.progress or 0)
		return
	end
	log("EV %s %s", tostring(ev), ev == "Throw" and tostring(d.castDistance) or "")
	local s = AF.stats
	if ev == "Throw" then
		s.bestDist = math.max(s.bestDist, tonumber(d.castDistance) or 0)
	elseif ev == "FightStart" then
		fightStart, maxProg, fight = os.clock(), 0, {}
	elseif ev == "CatchSuccess" then
		s.catches = s.catches + 1
		s.bestProg = math.max(s.bestProg, maxProg)
		log("CATCH prog=%.3f", maxProg)
		sinceSell = sinceSell + 1
		if AF.sell and sinceSell >= AF.sellEvery then
			sellPending = true
		end
	elseif ev == "FishEscape" then
		s.escapes = s.escapes + 1
		log("ESCAPE prog=%.3f reason=%s", maxProg, tostring(d.reason))
	elseif ev == "Error" then
		s.errors = s.errors + 1
		log("ERROR %s", tostring(d.message))
	end
end

local boundRem
local function bindRemote()
	local r = getRemote()
	if r == boundRem then
		return
	end
	pcall(function()
		getgenv().AFListener:Disconnect()
	end)
	getgenv().AFListener, boundRem = nil, r
	if r then
		getgenv().AFListener = r.OnClientEvent:Connect(onEvent)
		log("remote bound")
	end
end

-- ============================================================
-- Actions
-- ============================================================
local CYCLE = 1.35 -- FishingConfig.CastChargeCycleSeconds

-- Fire the Cast remote with exactly 1.0 so the server computes distance == 34.0 (MAX DEPTH).
-- finishCastCharge() only samples the meter, so it can never reach exactly 1.0.
local function hardCast()
	local conn = debug.getupvalue(finishCast, 4)
	if type(conn) == "RBXScriptConnection" then
		conn:Disconnect()
	end
	debug.setupvalue(finishCast, 4, nil)
	if track then
		track.Visible = false
	end
	if meter then
		meter.Visible = false
	end
	castBtn.Visible = false
	castBtn.Text = "CAST"
	castBtn.BackgroundColor3 = Color3.fromRGB(34, 174, 214)
	debug.setupvalue(castH, 4, "CastPending")
	local r = getRemote()
	if r then
		r:FireServer("Cast", 1.0)
	end
	pendingCast = os.clock()
end

local function fightDecision(d)
	if AF.policy == "always" then
		return true
	elseif AF.policy == "probe" then
		return math.floor((os.clock() - fightStart) / 1.2) % 2 == 0
	end
	if (d.tension or 0) > 0.55 or d.isResisting == true then
		return false
	end
	return d.inZone or (d.fishPosition or 0.5) > (d.zonePosition or 0.5)
end

-- popup shows "Caught <Name>!" and "<Rarity> ... XP" below
local function reportCatch()
	local nameLbl, infoLbl
	for _, d in ipairs(catchPopup:GetChildren()) do
		if d:IsA("TextLabel") then
			if d.Text:match("^Caught ") then
				nameLbl = d
			elseif d.Text:match("^%a+%s") and d.Text:find("XP") then
				infoLbl = d
			end
		end
	end
	if nameLbl then
		lastPopupName = nameLbl.Text
		log("CAUGHT %s [%s]", nameLbl.Text, infoLbl and infoLbl.Text:match("^(%a+)") or "?")
	end
end

-- ============================================================
-- Auto-sell through the game's own FISHDEX panel
-- ============================================================
local function rows() -- key, rarity and basket count of every fishdex row
	local out, list = {}, catchPanel and catchPanel:FindFirstChild("CatchList")
	for _, row in ipairs(list and list:GetChildren() or {}) do
		if row:IsA("Frame") then
			local rarity, count
			for _, d in ipairs(row:GetDescendants()) do
				if d:IsA("TextLabel") then
					local r, n = d.Text:match("^(%a+)%s+.-%s+Basket x(%d+)")
					if r then
						rarity, count = r, tonumber(n)
					end
				end
			end
			if rarity then
				out[#out + 1] = { row = row, key = row.Name, rarity = rarity, count = count }
			end
		end
	end
	return out
end

local function rowByKey(key)
	for _, r in ipairs(rows()) do
		if r.key == key then
			return r
		end
	end
	return nil
end

local function sellHandler(row) -- resolved lazily, only for the row being sold
	for _, b in ipairs(row:GetDescendants()) do
		if b:IsA("TextButton") then
			for _, l in ipairs(b:GetDescendants()) do
				if l:IsA("TextLabel") and l.Text:match("^SELL") then
					return find(b.Activated)
				end
			end
		end
	end
	return nil
end

local function runSell()
	if selling or not catchPanel then
		return
	end
	selling = true
	local sold = 0
	local ok, err = pcall(function()
		if not catchPanel.Visible then
			RS.BindableEvents.FishingPanelRequestEvent:Fire("Catch")
		end
		-- the server answers with CatchState and the client rebuilds the rows
		local plan, deadline = {}, os.clock() + 5
		while STATE.alive() and os.clock() < deadline and not next(plan) do
			for _, r in ipairs(rows()) do
				if not AF.sellKeep[r.rarity] and r.count > 0 then
					plan[r.key] = r.count
				end
			end
			if not next(plan) then
				task.wait(0.15)
			end
		end
		if not next(plan) then
			log("SELL: nothing to sell")
			return
		end
		for key, amount in pairs(plan) do
			for _ = 1, amount do
				if not STATE.alive() then
					return
				end
				if sold >= AF.sellMax then
					log("SELL: reached sellMax (%d)", AF.sellMax)
					return
				end
				local row = rowByKey(key)
				local fn = row and row.count > 0 and sellHandler(row.row)
				if not fn then
					break
				end
				task.wait(D(0.1, 0.45))
				fn()
				sold = sold + 1
				AF.stats.sold = AF.stats.sold + 1
				log("SELL %s (%s) left=%d", key, row.rarity, row.count - 1)
				-- wait until the server rebuilt the row and the counter dropped
				local t0 = os.clock()
				repeat
					task.wait(0.15)
					local fresh = rowByKey(key)
				until not fresh or fresh.count < row.count or os.clock() - t0 > 2
			end
		end
	end)
	if not ok then
		log("sell error: %s", tostring(err))
	end
	pcall(function() -- close the panel again
		local close = catchPanel:FindFirstChild("Close")
		local fn = catchPanel.Visible and close and close:IsA("TextButton") and find(close.Activated)
		if fn then
			fn()
		end
	end)
	selling, sellPending, sinceSell = false, false, 0
	log("SELL done: %d fish sold", sold)
end

-- ============================================================
-- OK button after a catch: fishing is blocked until it is pressed
-- ============================================================
local function shown(o) -- visible all the way up to the FishingGui
	while o and o ~= gui do
		if o:IsA("GuiObject") and not o.Visible then
			return false
		end
		o = o.Parent
	end
	return o == gui
end

-- the known ContinueButton, or any visible TextButton labelled "OK"
local function findOk()
	if continueBtn and shown(continueBtn) then
		return continueBtn
	end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextButton") and d.Text:upper() == "OK" and shown(d) then
			return d
		end
	end
	return nil
end

-- Escalating dismissal, works whatever state name the game is in:
--   stage 0: the game's own handler (it only accepts Catch/CaughtHold, so that state is forced if needed)
--   stage 1: +1.5 s still visible -> a real mouse click at a random point of the button
--   stage 2: +4 s still visible -> start over
local function dismissOk(now, st)
	if now - lastOkScan < 0.3 then
		return
	end
	lastOkScan = now
	local btn = findOk()
	if not btn then
		okSince, okStage = 0, 0
		return
	end
	if okSince == 0 then
		okSince, okStage, okDelay = now, 0, D(0.5, 1.6)
		log("OK button visible (%s) state=%s", btn.Name, tostring(st))
	end
	local waited = now - okSince
	if okStage == 0 and waited >= okDelay and (st ~= "Catch" or now - catchSince > 2.5) then
		okStage = 1
		local fn = (btn == continueBtn and continueH) or find(btn.Activated)
		if st ~= "Catch" and st ~= "CaughtHold" then
			debug.setupvalue(castH, 4, "CaughtHold")
			log("OK: forced state CaughtHold")
		end
		if fn then
			act("ok", btn, fn, 0)
		end
		log("OK pressed")
	elseif okStage == 1 and waited >= okDelay + 1.5 then
		okStage = 2
		clickAt(btn)
		log("OK: real click")
	elseif okStage == 2 and waited >= okDelay + 4 then
		okSince = 0
	end
end

-- settings are read live everywhere; this only drops timers scheduled with the old tempo / randomness
local function applySettings()
	due, reelDue = {}, nil
	saveSettings()
end

-- ============================================================
-- Main loop
-- ============================================================
local function onStateChange(st, now)
	local prev = lastState
	log("STATE %s -> %s", tostring(prev), tostring(st))
	lastState, due, reelDue = st, {}, nil
	if st ~= "Fight" then
		setReel(false)
	end
	if st == "Catch" or st == "CaughtHold" then
		catchSince = catchSince == 0 and now or catchSince
	else
		catchSince, lastPopupName = 0, nil -- also logs the same fish twice in a row
	end
	if st == "Charging" then
		chargeAt = math.min(0.995, 0.97 + (rng:NextNumber() - 0.5) * 0.04 * humanK()) -- release point varies
	elseif st == "None" and prev and AF.pauses and rng:NextNumber() < 0.04 * humanK() then
		due.cast = now + rand(4, 12) -- rare long pause before the next cast
		log("long pause")
	end
end

local function tick()
	local now = os.clock()
	AF.refreshUI()
	if now - lastRodScan > 0.3 then
		lastRodScan = now
		rodTool = findRod()
	end
	if now - lastBind > 1 then
		lastBind = now
		bindRemote()
	end

	-- rod / GUI lifecycle: pause without a rod, re-attach when the game rebuilt its GUI
	if not rodTool then
		if attached then
			detach("rod lost")
		end
		AF.state = "NoRod"
		setStatus(false, "no rod in inventory")
		return
	end
	if attached and not gui.Parent then
		detach("FishingGui was replaced")
	end
	if not attached then
		AF.state = "Detached"
		if AF.enabled then
			equipRod(now)
		end
		if now - lastAttach < 0.5 then
			return
		end
		lastAttach = now
		local ok, res, why = pcall(attach, now)
		if not (ok and res) then
			setStatus(false, ok and why or tostring(res))
			return
		end
		log("attached to FishingGui")
	end
	setStatus(true, "ready")

	local st = getState()
	AF.state = st
	if not AF.enabled then
		setReel(false)
		return
	end
	if st ~= lastState then
		onStateChange(st, now)
	end

	if st == "None" then
		equipRod(now)
		if sellPending and not selling then
			task.spawn(runSell)
		elseif not selling and not castBtn.Visible then
			dismissOk(now, st) -- cannot cast: most likely the OK button is still up
		elseif not selling and castBtn.Visible and castBtn.Text == "CAST" then
			local lo, hi = 0, 0
			if AF.pauses then
				lo, hi = 0.3, 1.5
			end
			if gate("cast", lo, hi) then
				log("CAST start")
				act("cast", castBtn, beginCast, 1)
			end
		end
	elseif st == "Charging" then
		local v = (now - debug.getupvalue(finishCast, 3)) / CYCLE % 2
		if v > 1 then
			v = 2 - v
		end
		if v >= chargeAt then
			if AF.hardCast then
				hardCast()
			else
				debug.setupvalue(finishCast, 3, now - CYCLE)
				finishCast()
			end
			AF.stats.casts = AF.stats.casts + 1
			log("THROW")
		end
	elseif st == "CastPending" then
		-- watchdog: if the server never answered, unlock the button and try again
		if pendingCast > 0 and now - pendingCast > 3 then
			pendingCast = 0
			log("cast timeout - unlock")
			debug.setupvalue(castH, 4, "None")
			castBtn.Visible, castBtn.Text = true, "CAST"
			castBtn.BackgroundColor3 = Color3.fromRGB(34, 174, 214)
		end
	elseif st == "Idle" then
		if lureBtn.Visible and gate("lure", 0.15, 0.4) then
			act("lure", lureBtn, lureH, 0.05)
		end
	elseif st == "Bite" then
		if hookBtn.Visible and gate("hook", 0.12, 0.4, true) then
			act("hook", hookBtn, hookH, 0.4)
		end
	elseif st == "Fight" then
		humanReel(fightDecision(fight))
	elseif st == "Catch" or st == "CaughtHold" then
		if not lastPopupName and catchPopup and catchPopup.Visible then
			reportCatch()
		end
		dismissOk(now, st)
	else
		setReel(false)
		dismissOk(now, st)
	end
end

local lastErr = 0
local function safeTick()
	local ok, err = pcall(tick)
	if not ok and os.clock() - lastErr > 2 then
		lastErr = os.clock()
		log("tick error: %s", tostring(err))
	end
end

-- ============================================================
-- GUI: one rectangle split in halves
--   top    : big ENABLED / DISABLED switch
--   bottom : [ speed ] [ settings ]   (speed cycles slow -> medium -> fast)
-- Settings menu (opens under the rectangle) has an X: it shows an "unload" warning
-- inside the GUI, then unloads everything automatically unless Cancel is pressed.
-- ============================================================
local function buildGui()
	pcall(function()
		getgenv().AFGui:Destroy()
	end)
	local sg = Instance.new("ScreenGui")
	sg.Name, sg.ResetOnSpawn, sg.DisplayOrder = "AFPanel", false, 999
	if not pcall(function()
		sg.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end) or not sg.Parent then
		sg.Parent = P:WaitForChild("PlayerGui")
	end
	getgenv().AFGui = sg

	local function mk(class, parent, props)
		local o = Instance.new(class)
		for k, v in pairs(props) do
			o[k] = v
		end
		o.Parent = parent
		return o
	end
	local function round(o, r)
		mk("UICorner", o, { CornerRadius = UDim.new(0, r or 6) })
	end
	local WHITE, GRAY, BTN = Color3.fromRGB(235, 235, 240), Color3.fromRGB(150, 150, 160), Color3.fromRGB(44, 44, 54)
	local BG = Color3.fromRGB(24, 24, 30)
	local function button(parent, props)
		props.BorderSizePixel, props.Text = 0, props.Text or ""
		props.Font, props.TextColor3 = props.Font or Enum.Font.GothamBold, WHITE
		local b = mk("TextButton", parent, props)
		round(b)
		return b
	end
	local function label(parent, y, h, size, color, font)
		return mk("TextLabel", parent, {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, h),
			TextSize = size, TextColor3 = color, Font = font,
		})
	end

	local root = mk("Frame", sg, {
		Size = UDim2.fromOffset(190, 112), Position = UDim2.new(0, 20, 0.5, -56),
		BackgroundColor3 = BG, BorderSizePixel = 0, Active = true, Draggable = true,
	})
	round(root, 8)
	local toggle = button(root, {
		Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 46), TextSize = 18, AutoButtonColor = false, RichText = true,
	})
	local speedBtn = button(root, {
		Position = UDim2.fromOffset(6, 58), Size = UDim2.new(0.5, -9, 0, 48), BackgroundColor3 = BTN,
	})
	Core.bindText(label(speedBtn, 5, 12, 11, GRAY, Enum.Font.Gotham), "af_speed")
	local speedVal = label(speedBtn, 18, 26, 17, WHITE, Enum.Font.GothamBold)
	local setBtn = button(root, {
		Position = UDim2.new(0.5, 3, 0, 58), Size = UDim2.new(0.5, -9, 0, 48), BackgroundColor3 = BTN,
		TextSize = 15,
	})
	Core.bindText(setBtn, "af_settings")

	-- settings menu: header with X + scrolling list of groups
	local menu = mk("Frame", root, {
		Position = UDim2.new(0, 0, 1, 6), Size = UDim2.new(1, 0, 0, 262), BackgroundColor3 = BG,
		BorderSizePixel = 0, Visible = false,
	})
	round(menu, 8)
	mk("TextLabel", menu, {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -44, 0, 20),
		Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = GRAY, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "settings",
	})
	local closeBtn = button(menu, {
		Position = UDim2.new(1, -28, 0, 4), Size = UDim2.fromOffset(22, 20),
		BackgroundColor3 = Color3.fromRGB(170, 50, 50), TextSize = 13, Text = "X",
	})
	local list = mk("ScrollingFrame", menu, {
		Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 1, -28), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 3, AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	})
	mk("UIListLayout", list, { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder })
	mk("UIPadding", list, {
		PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 5),
		PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5),
	})

	local updaters, order = {}, 0
	local function addGap()
		order = order + 1
		mk("Frame", list, { Size = UDim2.new(1, -8, 0, 8), BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = order })
	end
	-- every row cycles through its values on click; changes apply immediately (no restart needed)
	local function addRow(key, get, set, opts, arg)
		order = order + 1
		local b = button(list, {
			Size = UDim2.new(1, -8, 0, 24), LayoutOrder = order, BackgroundColor3 = BTN,
			TextSize = 13, Font = Enum.Font.Gotham,
		})
		local function upd()
			local v = get()
			b.Text = T(key, arg) .. ": " .. (v == true and T("v_on") or v == false and T("v_off") or tostring(v))
		end
		b.Activated:Connect(function()
			set(opts[(table.find(opts, get()) or 0) % #opts + 1])
			upd()
			applySettings()
		end)
		upd()
		updaters[#updaters + 1] = upd
	end

	-- language row + copy-log button (shared Core features)
	addRow("lang_label", Core.getLang, function(v)
		Core.setLang(v)
	end, Core.LANGS)
	order = order + 1
	local copyBtn = button(list, {
		Size = UDim2.new(1, -8, 0, 24), LayoutOrder = order, BackgroundColor3 = BTN,
		TextSize = 13, Font = Enum.Font.Gotham,
	})
	Core.bindText(copyBtn, "log_copy")
	copyBtn.Activated:Connect(Core.copyLog)
	addGap()
	for _, s in ipairs({
		{ "af_policy", "policy", { "smart", "always", "probe" } },
		{ "af_hardcast", "hardCast", { true, false } },
		"gap",
		{ "af_humanize", "human", { "off", "low", "normal", "high" } },
		{ "af_mouse", "mouse", { false, true } },
		{ "af_pauses", "pauses", { true, false } },
		"gap",
		{ "af_sell", "sell", { false, true } },
		{ "af_sellevery", "sellEvery", { 1, 3, 5, 10, 20 } },
		{ "af_sellmax", "sellMax", { 5, 10, 25, 50 } },
	}) do
		if s == "gap" then
			addGap()
		else
			addRow(s[1], function()
				return AF[s[2]]
			end, function(v)
				AF[s[2]] = v
			end, s[3])
		end
	end
	addGap()
	for _, rarity in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary" }) do
		addRow("af_keep", function()
			return AF.sellKeep[rarity] == true
		end, function(v)
			AF.sellKeep[rarity] = v or nil
		end, { true, false }, rarity)
	end

	-- unload warning (covers the main rectangle)
	local warn = mk("Frame", root, {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(70, 26, 26), BorderSizePixel = 0,
		Visible = false, Active = true, ZIndex = 10,
	})
	round(warn, 8)
	local w1 = label(warn, 8, 18, 14, WHITE, Enum.Font.GothamBold)
	Core.bindText(w1, "af_unload_title")
	w1.ZIndex = 11
	local w2 = label(warn, 28, 32, 11, Color3.fromRGB(215, 200, 200), Enum.Font.Gotham)
	Core.bindText(w2, "af_unload_text")
	w2.TextWrapped, w2.ZIndex = true, 11
	local cancel = button(warn, {
		Position = UDim2.fromOffset(10, 66), Size = UDim2.new(1, -20, 0, 36), BackgroundColor3 = BTN,
		TextSize = 14, Text = T("af_cancel"), ZIndex = 11,
	})

	local unloadId = 0
	closeBtn.Activated:Connect(function()
		if warn.Visible then
			return
		end
		unloadId = unloadId + 1
		local my = unloadId
		menu.Visible, warn.Visible = false, true
		task.spawn(function()
			for i = 3, 1, -1 do
				if unloadId ~= my then
					return
				end
				cancel.Text = T("af_cancel") .. " (" .. i .. ")"
				task.wait(1)
			end
			if unloadId == my then
				AF.stop()
			end
		end)
	end)
	cancel.Activated:Connect(function()
		unloadId = unloadId + 1
		warn.Visible = false
	end)

	local uiEnabled, uiReady, uiStatus
	local function refresh()
		uiEnabled, uiReady, uiStatus = AF.enabled, AF.ready, AF.status
		if not AF.enabled then
			toggle.Text, toggle.BackgroundColor3 = T("af_disabled"), Color3.fromRGB(170, 50, 50)
		elseif AF.ready then
			toggle.Text, toggle.BackgroundColor3 = T("af_enabled"), Color3.fromRGB(46, 160, 67)
		else -- enabled, but no rod / GUI not attached yet
			toggle.Text = T("af_waiting") .. '\n<font size="11">' .. tostring(AF.status) .. "</font>"
			toggle.BackgroundColor3 = Color3.fromRGB(196, 130, 30)
		end
		speedVal.Text = AF.speed
		for _, f in ipairs(updaters) do
			f()
		end
	end
	AF.refreshUI = function() -- also picks up AF.enabled changes made from the console
		if uiEnabled ~= AF.enabled or uiReady ~= AF.ready or uiStatus ~= AF.status then
			refresh()
		end
	end

	toggle.Activated:Connect(function()
		AF.enabled = not AF.enabled
		log("enabled = %s", tostring(AF.enabled))
		Core.toast(T(AF.enabled and "af_toast_on" or "af_toast_off"), AF.enabled and "ok" or "info", 2)
		refresh()
	end)
	local SPEEDS = { "slow", "medium", "fast" }
	speedBtn.Activated:Connect(function()
		AF.speed = SPEEDS[(table.find(SPEEDS, AF.speed) or 0) % #SPEEDS + 1]
		applySettings()
		refresh()
	end)
	setBtn.Activated:Connect(function()
		menu.Visible = not menu.Visible
	end)
	AF.langOff = Core.onLang(refresh)
	refresh()
	return sg
end

local sg = buildGui()
local tickConn = STATE.connect(RunService.Heartbeat, safeTick)

-- unload: stop all work, release inputs, restore the game's cast button, destroy the menu, clear globals
local stopped = false
local function cleanup()
	if stopped then
		return
	end
	stopped = true
	AF.enabled = false
	pcall(setReel, false)
	pcall(function()
		tickConn:Disconnect()
	end)
	pcall(function()
		getgenv().AFListener:Disconnect()
	end)
	pcall(function()
		if attached and getState() == "CastPending" then
			debug.setupvalue(castH, 4, "None")
			castBtn.Visible, castBtn.Text = true, "CAST"
		end
	end)
	pcall(sg.Destroy, sg)
	pcall(function()
		AF.langOff()
	end)
	saveSettings()
	getgenv().AFListener, getgenv().AFGui, getgenv().AFShim = nil, nil, nil
	log("unloaded")
	Core.toast(T("af_toast_unload"), "info", 2)
	getgenv().AF = nil
	task.delay(2.5, function() -- nothing else needs the shared module once the only farm is gone
		if Core.unload then
			Core.unload()
		end
	end)
end
STATE.onCleanup(cleanup)
AF.stop = function()
	if STATE.stop then
		STATE.stop() -- runs cleanup() as well
	end
	cleanup()
end