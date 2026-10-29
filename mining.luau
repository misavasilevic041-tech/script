--[[ Material Farm v5.1 (hub)
	Логика без таймеров респавна:
	  есть ProximityPrompt внутри группы ресурса  -> ресурс жив, можно добывать
	  нет ProximityPrompt                         -> добыт (или не прогружен): заглядываем телепортом
	Дропы сами не подбираются: после добычи телепортируемся на дроп.

	v5:
	  * кэш групп/промптов/дропов на событиях (нет GetChildren/FindFirst... в каждом цикле)
	  * добыча идёт, пока жив промпт (до MineTimeout), а не фиксированные 8 ударов -> BigStone/BigWood
	  * подбор: один телепорт забирает все дропы в зоне досягаемости
	  * меню: ⚙ настройки, ✕ полная выгрузка (loops + connections + GUI)

	v5.1 (запуск из хаба, логика добычи не тронута):
	  * панель, язык (RU/EN), кнопка «лог» и тосты берутся из Core
	  * настройки сохраняются (AutoFarmHub/settings.json), включённость не сохраняется
	  * лог идёт в Core.log (кнопка «скопировать лог»)
	  * защита от зависаний: нет прогресса N минут -> цикл перезапускается
	  * автопауза (общая настройка хаба) и мягкое продолжение после смерти/респавна
]]

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local env = (getgenv and getgenv()) or _G

local Core = env.HubCore
if not Core then
	warn("[MFarm] Core not found: start hub.luau first")
	return
end
local T, ui = Core.t, Core.ui
local C = ui.C
local STATE = rawget(_G, "STATE") or env.STATE
Core.addStrings({
	ru = {
		m_title = "Добыча",
		m_start = "▶ Включить",
		m_stop = "⏹ Выключить",
		m_idle = "выключено",
		m_wait_char = "ждём персонажа...",
		m_probe = "ищем респавн: %s",
		m_none = "нет доступных ресурсов...",
		m_mining = "добыча: %s",
		m_stat = "добыто %d · подобр. %d · %.1f/мин",
		m_paused = "пауза (окно неактивно или открыто меню)",
		m_stones = "Камни",
		m_trees = "Деревья",
		m_weeds = "Сорняки",
		m_hit = "Задержка удара, с",
		m_timeout = "Макс. время на ресурс, с",
		m_radius = "Радиус дропов",
		m_probeskip = "Проверка респавна, с",
		m_tweak = "Ускорение промптов",
		m_debug = "Debug-лог",
		m_on = "Добыча включена",
		m_off = "Добыча выключена",
		m_unload = "Добыча выгружена",
		m_unsupported = "Этот экзекьютор не поддерживает fireproximityprompt",
	},
	en = {
		m_title = "Mining",
		m_start = "▶ Start",
		m_stop = "⏹ Stop",
		m_idle = "off",
		m_wait_char = "waiting for the character...",
		m_probe = "looking for a respawn: %s",
		m_none = "no resources available...",
		m_mining = "mining: %s",
		m_stat = "mined %d · picked %d · %.1f/min",
		m_paused = "paused (window inactive or game menu open)",
		m_stones = "Stones",
		m_trees = "Trees",
		m_weeds = "Weeds",
		m_hit = "Hit delay, s",
		m_timeout = "Max time per resource, s",
		m_radius = "Drop radius",
		m_probeskip = "Respawn check, s",
		m_tweak = "Prompt speed-up",
		m_debug = "Debug log",
		m_on = "Mining on",
		m_off = "Mining off",
		m_unload = "Mining unloaded",
		m_unsupported = "This executor does not support fireproximityprompt",
	},
})

-- повторный запуск: выгружаем прошлую копию
if env.MFarmUnload then pcall(env.MFarmUnload) end

local CFG = {
	Kinds = { Stones = true, Trees = true, Weeds = true },
	HitDelay = 0.1,                        -- пауза между fire
	MineTimeout = 12,                      -- максимум сек на добычу одного ресурса
	TpWait = 0.08,                         -- пауза после телепорта
	StandOffset = Vector3.new(0, 3, 0),    -- где стоять над точкой добычи
	ProbeWait = 1.0,                       -- сколько ждём промпт после "заглядывания"
	ProbeSkip = 4,                         -- не заглядывать в одну группу чаще, чем раз в N сек
	FailSkip = 5,                          -- пропуск группы после неудачной добычи
	DropRadius = 40,                       -- дропы дальше этого от места добычи игнорируем
	CollectTimeout = 6,                    -- максимум сек на подбор дропов одного ресурса
	TweakPrompts = true,                   -- Hold=0 и без line-of-sight у промптов (восстанавливается при выгрузке)
	Debug = true,
}

-- saved settings win over the defaults; "running" is never saved
local SAVED_KEYS = { "HitDelay", "MineTimeout", "DropRadius", "ProbeSkip", "TweakPrompts", "Debug" }
do
	local d = { Kinds = CFG.Kinds }
	for _, k in ipairs(SAVED_KEYS) do d[k] = CFG[k] end
	local r = Core.getFarm("mining", d)
	for _, k in ipairs(SAVED_KEYS) do CFG[k] = r[k] end
	for kk, def in pairs(CFG.Kinds) do
		local v = r.Kinds[kk]
		CFG.Kinds[kk] = (type(v) == "boolean") and v or def
	end
end
local function saveCfg()
	local o = { Kinds = {} }
	for _, k in ipairs(SAVED_KEYS) do o[k] = CFG[k] end
	for kk, v in pairs(CFG.Kinds) do o.Kinds[kk] = v end
	Core.setFarm("mining", o)
end

local function log(...)
	if CFG.Debug then
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		Core.log("MFARM", "%s", table.concat(parts, " "))
	end
end

if not fireproximityprompt then
	warn("[MFarm] fireproximityprompt не поддерживается этим экзекьютором")
	Core.toast(T("m_unsupported"), "err", 6)
	return
end

-- ===== Состояние =====
local running = false
local loopId = 0
local skip = {}        -- [group] = os.clock() до которого группу пропускаем
local tries = {}       -- [drop] = сколько раз пытались подобрать
local mined, picked = 0, 0
local startAt = os.clock()
local setStatus = function() end
local conns = {}       -- глобальные соединения (для unload)
local groups = {}      -- [model] = { kind, prompt, conns }
local orig = {}        -- [prompt] = { HoldDuration, RequiresLineOfSight }
local drops, dropPrompts = {}, {}
local dropSeq = 0
local picked0 = 0

local function track(c)
	conns[#conns + 1] = c
	return c
end

local function tp(hrp, v3)
	hrp.CFrame = CFrame.new(v3)
	hrp.AssemblyLinearVelocity = Vector3.zero
end

local function tweak(p)
	if CFG.TweakPrompts and not orig[p] then
		orig[p] = { p.HoldDuration, p.RequiresLineOfSight }
		p.HoldDuration = 0
		p.RequiresLineOfSight = false
	end
end

-- ===== Группы ресурсов (кэш на событиях) =====
local function hookGroup(g, kind)
	if groups[g] or not g:IsA("Model") then return end
	local rec = { kind = kind, conns = {} }
	groups[g] = rec
	local function setP(p)
		rec.prompt = p
		tweak(p)
	end
	local p0 = g:FindFirstChildWhichIsA("ProximityPrompt", true)
	if p0 then setP(p0) end
	table.insert(rec.conns, g.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then setP(d) end
	end))
	table.insert(rec.conns, g.DescendantRemoving:Connect(function(d)
		if d == rec.prompt then rec.prompt = nil end
	end))
end

local function unhookGroup(g)
	local rec = groups[g]
	if not rec then return end
	for _, c in ipairs(rec.conns) do c:Disconnect() end
	groups[g] = nil
	skip[g] = nil
end

local function hookKind(folder)
	local kind = folder.Name
	if CFG.Kinds[kind] == nil then return end
	for _, g in ipairs(folder:GetChildren()) do hookGroup(g, kind) end
	track(folder.ChildAdded:Connect(function(g) hookGroup(g, kind) end))
	track(folder.ChildRemoved:Connect(unhookGroup))
end

local matRoot = workspace:WaitForChild("MaterialObjects", 10)
if matRoot then
	for _, f in ipairs(matRoot:GetChildren()) do hookKind(f) end
	track(matRoot.ChildAdded:Connect(hookKind))
else
	warn("[MFarm] workspace.MaterialObjects не найден")
end

-- ===== Дропы (кэш на событиях) =====
local dropFolder = workspace:WaitForChild("MaterialFolder", 10)
if dropFolder then
	for _, d in ipairs(dropFolder:GetChildren()) do drops[d] = true end
	track(dropFolder.ChildAdded:Connect(function(d)
		drops[d] = true
		dropSeq += 1
	end))
	track(dropFolder.ChildRemoved:Connect(function(d)
		if (tries[d] or 0) > 0 then picked += 1 end
		drops[d] = nil
		tries[d] = nil
		dropPrompts[d] = nil
	end))
else
	warn("[MFarm] workspace.MaterialFolder не найден")
end

local function getPrompt(g)
	local rec = groups[g]
	return rec and rec.prompt
end

local function promptPos(p, g)
	local par = p.Parent
	if par and par:IsA("BasePart") then return par.Position end
	if par and par:IsA("Attachment") then return par.WorldPosition end
	return g:GetPivot().Position
end

-- возвращает (ближайший живой, ближайший без промпта)
local function chooseGroups(hrp)
	local now = os.clock()
	local hp = hrp.Position
	local readyBest, readyDist, probeBest, probeDist
	for g, rec in pairs(groups) do
		if CFG.Kinds[rec.kind] and (skip[g] or 0) <= now then
			local p = rec.prompt
			local pos = p and promptPos(p, g) or g:GetPivot().Position
			local d = (pos - hp).Magnitude
			if p then
				if p.Enabled and (not readyDist or d < readyDist) then
					readyBest, readyDist = g, d
				end
			elseif not probeDist or d < probeDist then
				probeBest, probeDist = g, d
			end
		end
	end
	return readyBest, probeBest
end

-- ===== Заглянуть в группу без промпта =====
local function probe(g, hrp)
	tp(hrp, g:GetPivot().Position + CFG.StandOffset)
	local t0 = os.clock()
	while running and os.clock() - t0 < CFG.ProbeWait do
		if getPrompt(g) then return true end
		task.wait(0.05)
	end
	skip[g] = os.clock() + CFG.ProbeSkip
	return false
end

-- ===== Диагностика неудачной добычи (один раз на имя) =====
local diagged = {}
local function diagFail(g)
	if not CFG.Debug or diagged[g.Name] then return end
	diagged[g.Name] = true
	local p = getPrompt(g)
	if not p then
		log("диагн.", g:GetFullName(), "промпт пропал, дропа не было")
		return
	end
	local o = orig[p]
	log(string.format("диагн. %s | Action=%s Object=%s Hold=%s Enabled=%s Dist=%s",
		g:GetFullName(), tostring(p.ActionText), tostring(p.ObjectText),
		tostring(o and o[1] or p.HoldDuration), tostring(p.Enabled), tostring(p.MaxActivationDistance)))
end

-- ===== Добыча: бьём, пока жив промпт =====
local function mine(g, hrp)
	local p = getPrompt(g)
	if not p then return false end
	local pos = promptPos(p, g)
	tp(hrp, pos + CFG.StandOffset)
	task.wait(CFG.TpWait)

	local before = dropSeq
	local t0 = os.clock()
	while running and os.clock() - t0 < CFG.MineTimeout do
		p = getPrompt(g)
		if not p then break end -- промпт пропал: ресурс добыт
		if not hrp.Parent then break end -- персонаж умер/пересоздан: выходим, цикл возьмёт нового
		if dropSeq > before then break end -- дроп выпал: сразу стоп
		if (hrp.Position - pos).Magnitude > 8 then
			tp(hrp, pos + CFG.StandOffset)
		end
		fireproximityprompt(p)
		task.wait(CFG.HitDelay)
	end
	local dead = getPrompt(g) == nil
	return dead or dropSeq > before, pos
end

-- ===== Подбор дропов =====
local function dropPos(d)
	if d:IsA("BasePart") then return d.Position end
	return d:GetPivot().Position
end

local function dropPrompt(d)
	local p = dropPrompts[d]
	if p and p.Parent then return p end
	p = d:IsA("ProximityPrompt") and d or d:FindFirstChildWhichIsA("ProximityPrompt", true)
	if p then
		dropPrompts[d] = p
		tweak(p)
	end
	return p
end

local function nearestDrop(pos, hrp)
	local best, bestDist
	for d in pairs(drops) do
		if d.Parent and (tries[d] or 0) < 3 then
			local dp = dropPos(d)
			if (dp - pos).Magnitude < CFG.DropRadius then
				local dist = (dp - hrp.Position).Magnitude
				if not bestDist or dist < bestDist then best, bestDist = d, dist end
			end
		end
	end
	return best
end

local function pickup(d, hrp)
	tries[d] = (tries[d] or 0) + 1
	local p = dropPrompt(d)
	if p then
		fireproximityprompt(p)
	elseif firetouchinterest then
		local part = d:IsA("BasePart") and d or d:FindFirstChildWhichIsA("BasePart", true)
		if part then
			pcall(function()
				firetouchinterest(hrp, part, 0)
				firetouchinterest(hrp, part, 1)
			end)
		end
	end
end

-- забираем всё, что в зоне досягаемости с текущей позиции
local function pickupNear(hrp, except)
	for d in pairs(drops) do
		if d ~= except and d.Parent and (tries[d] or 0) < 3 then
			local p = dropPrompt(d)
			local reach = math.min(p and p.MaxActivationDistance or 6, 14) - 1
			if (dropPos(d) - hrp.Position).Magnitude <= reach then
				pickup(d, hrp)
			end
		end
	end
end

local function collect(pos, hrp)
	if not dropFolder then return end
	-- ждём первый дроп (вместо фиксированных 0.3 сек)
	local t0 = os.clock()
	while running and os.clock() - t0 < 0.4 and not nearestDrop(pos, hrp) do
		task.wait(0.05)
	end
	t0 = os.clock()
	while running and os.clock() - t0 < CFG.CollectTimeout do
		local d = nearestDrop(pos, hrp)
		if not d then return end
		tp(hrp, dropPos(d) + Vector3.new(0, 2, 0))
		task.wait(CFG.TpWait)
		pickup(d, hrp)
		pickupNear(hrp, d)
		task.wait(0.1)
		if d.Parent and (tries[d] or 0) >= 3 then
			warn("[MFarm] дроп не подобрался после 3 попыток:", d:GetFullName())
		end
	end
end

-- ===== Главный цикл =====
local function statText()
	local m = (os.clock() - startAt) / 60
	local rate = m > 0.05 and mined / m or 0
	return T("m_stat", mined, picked, rate)
end

local function farmLoop(myId)
	while running and loopId == myId do
		if Core.paused() then
			setStatus(T("m_paused"))
			task.wait(0.5)
			continue
		end
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then
			setStatus(T("m_wait_char"))
			task.wait(0.5)
		else
			local ready, probeG = chooseGroups(hrp)
			local g = ready
			if not g and probeG then
				setStatus(T("m_probe", probeG.Name))
				if probe(probeG, hrp) then g = probeG end
			end

			if not g then
				setStatus(T("m_none"))
				task.wait(0.2)
			else
				setStatus(T("m_mining", g.Name))
				local ok, pos = mine(g, hrp)
				if ok then
					mined += 1
					if not getPrompt(g) then
						skip[g] = os.clock() + CFG.ProbeSkip -- добит: проверим респавн позже
					end
					collect(pos, hrp)
				else
					if hrp.Parent then -- если персонаж умер посреди добычи, это не сбой ресурса
						skip[g] = os.clock() + CFG.FailSkip
						log("нет дропа после ударов:", g:GetFullName())
						diagFail(g)
					end
				end
				if running and loopId == myId then setStatus(statText()) end
			end
		end
	end
end

-- ===== Твик промптов (вкл/выкл на лету) =====
local function setTweak(on)
	CFG.TweakPrompts = on
	if on then
		for _, rec in pairs(groups) do
			if rec.prompt then tweak(rec.prompt) end
		end
		for d in pairs(drops) do
			local p = dropPrompt(d)
			if p then tweak(p) end
		end
	else
		for p, o in pairs(orig) do
			pcall(function()
				p.HoldDuration = o[1]
				p.RequiresLineOfSight = o[2]
			end)
		end
		table.clear(orig)
	end
end

-- ===== GUI (панель из Core) =====
local langOffs, unloaded = {}, false
local panel = Core.panel({
	titleKey = "m_title",
	size = Vector2.new(240, 96),
	pos = UDim2.new(1, -260, 0.5, -48),
	onClose = function()
		if STATE and STATE.stop then
			STATE.stop() -- запускает unload()
		end
		task.delay(2.5, function() -- общий модуль больше никому не нужен
			if Core.unload then Core.unload() end
		end)
	end,
})
local body = panel.body

local btn = ui.button(body, {
	Position = UDim2.fromOffset(8, 4), Size = UDim2.new(1, -54, 0, 34), TextSize = 14, BackgroundColor3 = C.GREEN,
})
local gear = ui.button(body, {
	Position = UDim2.new(1, -40, 0, 4), Size = UDim2.fromOffset(32, 34), TextSize = 18, Text = "⚙",
})
local label = ui.label(body, {
	Position = UDim2.fromOffset(8, 42), Size = UDim2.new(1, -16, 0, 18), TextSize = 11,
	TextColor3 = C.GRAY, TextXAlignment = Enum.TextXAlignment.Left,
})
setStatus = function(t) label.Text = t end

local function refreshBtn()
	btn.Text = T(running and "m_stop" or "m_start")
	btn.BackgroundColor3 = running and C.RED or C.GREEN
end
refreshBtn()
setStatus(T("m_idle"))
langOffs[#langOffs + 1] = Core.onLang(function()
	refreshBtn()
	if not running then setStatus(T("m_idle")) end
end)

-- ----- настройки (открываются под панелью) -----
local menu = ui.mk("Frame", panel.root, {
	Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.new(0, 0, 1, 6),
	BackgroundColor3 = C.BG, BorderSizePixel = 0, Visible = false,
})
ui.round(menu, 8)
ui.mk("UIListLayout", menu, { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder })
ui.mk("UIPadding", menu, {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
})

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function addToggle(key, get, set)
	local b = ui.button(menu, { Size = UDim2.new(1, 0, 0, 26), TextSize = 12, Font = ui.FONT, LayoutOrder = nextOrder() })
	local function refresh()
		local on = get()
		b.Text = T(key) .. ": " .. T(on and "v_on" or "v_off")
		b.BackgroundColor3 = on and C.GREEN or C.BTN
	end
	refresh()
	langOffs[#langOffs + 1] = Core.onLang(refresh)
	track(b.Activated:Connect(function()
		set(not get())
		refresh()
		saveCfg()
	end))
end

local function addStepper(key, cfgKey, step, lo, hi, fmt)
	local row = ui.mk("Frame", menu, { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = nextOrder() })
	local l = ui.label(row, {
		Size = UDim2.new(1, -94, 1, 0), TextSize = 12, TextColor3 = C.GRAY, TextXAlignment = Enum.TextXAlignment.Left,
	})
	Core.bindText(l, key)
	local minus = ui.button(row, { Size = UDim2.new(0, 24, 1, 0), Position = UDim2.new(1, -90, 0, 0), TextSize = 16, Text = "−" })
	local val = ui.label(row, {
		Size = UDim2.new(0, 36, 1, 0), Position = UDim2.new(1, -64, 0, 0), Font = ui.FONT_BOLD, TextSize = 12,
	})
	local plus = ui.button(row, { Size = UDim2.new(0, 24, 1, 0), Position = UDim2.new(1, -26, 0, 0), TextSize = 16, Text = "+" })
	local function refresh() val.Text = string.format(fmt, CFG[cfgKey]) end
	local function bump(dir)
		local v = math.floor((CFG[cfgKey] + dir * step) / step + 0.5) * step
		CFG[cfgKey] = math.clamp(v, lo, hi)
		refresh()
		saveCfg()
	end
	refresh()
	track(minus.Activated:Connect(function() bump(-1) end))
	track(plus.Activated:Connect(function() bump(1) end))
end

addToggle("m_stones", function() return CFG.Kinds.Stones end, function(v) CFG.Kinds.Stones = v end)
addToggle("m_trees", function() return CFG.Kinds.Trees end, function(v) CFG.Kinds.Trees = v end)
addToggle("m_weeds", function() return CFG.Kinds.Weeds end, function(v) CFG.Kinds.Weeds = v end)
addStepper("m_hit", "HitDelay", 0.05, 0.05, 1, "%.2f")
addStepper("m_timeout", "MineTimeout", 2, 4, 30, "%.0f")
addStepper("m_radius", "DropRadius", 10, 10, 200, "%.0f")
addStepper("m_probeskip", "ProbeSkip", 1, 1, 15, "%.0f")
addToggle("m_tweak", function() return CFG.TweakPrompts end, setTweak)
addToggle("m_debug", function() return CFG.Debug end, function(v) CFG.Debug = v end)

track(gear.Activated:Connect(function()
	menu.Visible = not menu.Visible
	gear.BackgroundColor3 = menu.Visible and C.GREEN or C.BTN
end))

local function setRunning(on)
	if on == running then return end
	running = on
	if running then
		loopId += 1
		mined, picked = 0, 0
		startAt = os.clock()
		task.spawn(farmLoop, loopId)
	else
		loopId += 1
		setStatus(T("m_idle"))
	end
	refreshBtn()
	Core.toast(T(running and "m_on" or "m_off"), running and "ok" or "info", 2)
	log("running =", tostring(running))
end
track(btn.Activated:Connect(function() setRunning(not running) end))

-- ===== v2: защита от зависаний и респавн =====
if STATE then
	Core.watchdog(STATE, {
		name = "mining",
		getProgress = function() return mined + picked end,
		isActive = function() return running end,
		onStall = function() -- новый цикл вместо зависшего, старый выйдет сам по loopId
			loopId += 1
			table.clear(skip)
			table.clear(tries)
			task.spawn(farmLoop, loopId)
		end,
	})
	Core.onRespawn(STATE, function()
		table.clear(skip) -- после смерти ничего не «пропускаем»: цикл сам дождётся нового персонажа
	end)
end

-- ===== Unload: стоп циклов + disconnect + восстановление промптов + destroy GUI =====
local function unload()
	if unloaded then return end
	unloaded = true
	pcall(saveCfg)
	running = false
	loopId += 1
	setStatus = function() end
	for _, off in ipairs(langOffs) do pcall(off) end
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	table.clear(conns)
	for _, rec in pairs(groups) do
		for _, c in ipairs(rec.conns) do pcall(function() c:Disconnect() end) end
	end
	table.clear(groups)
	for p, o in pairs(orig) do
		pcall(function()
			p.HoldDuration = o[1]
			p.RequiresLineOfSight = o[2]
		end)
	end
	table.clear(orig)
	table.clear(drops)
	table.clear(dropPrompts)
	table.clear(tries)
	table.clear(skip)
	pcall(function() panel.root:Destroy() end)
	if env.MFarmUnload == unload then env.MFarmUnload = nil end
	Core.log("MFARM", "unloaded")
	Core.toast(T("m_unload"), "info", 2)
end

env.MFarmUnload = unload
if STATE then STATE.onCleanup(unload) end

log("v5.1 загружен.")
