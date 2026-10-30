-- AutoFarm Hub v2.0
-- Menu: [Autofarm] [Settings]. Autofarm opens a side list of 3 farms; after the choice the hub removes
-- its own menu and loads the chosen farm script. v2: garden, fishing and mining are connected.
-- Settings: language, autopause, restart after death, anti-freeze watchdog, copy log, unload.
--
-- Run this file only:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/YOURNAME/YOURREPO/main/hub.luau"))()
-- BASE is the folder with core.luau and the farm files. For local testing put the files into the
-- executor's workspace folder and set BASE = "AutoFarmHub/files/" (anything not starting with "http"
-- is read with readfile).

local BASE = "https://raw.githubusercontent.com/YOURNAME/YOURREPO/main/"

local FILES = {
	core = "core.luau",
	fishing = "fishing.luau",
	garden = "garden.luau",
	mining = "mining.luau",
}

local function fetch(name)
	if BASE:sub(1, 4) == "http" then
		local ok, res = pcall(function()
			return game:HttpGet(BASE .. name .. "?t=" .. os.time())
		end)
		if ok and type(res) == "string" and #res > 0 then
			if res:sub(1, 3) == "404" then -- raw.githubusercontent answers a missing file with the text "404: Not Found"
				return nil, "404 Not Found: " .. BASE .. name
			end
			return res
		end
		return nil, tostring(res)
	end
	local ok, res = pcall(function()
		return readfile(BASE .. name)
	end)
	if ok and type(res) == "string" and #res > 0 then
		return res
	end
	return nil, tostring(res)
end

-- ===== Core =====
local coreSrc, coreErr = fetch(FILES.core)
if not coreSrc then
	warn("[HUB] cannot download core: " .. tostring(coreErr) .. " (check BASE in hub.luau)")
	return
end
local coreFn, compileErr = loadstring(coreSrc, "=core")
if not coreFn then
	warn("[HUB] core compile error: " .. tostring(compileErr))
	return
end
local Core = coreFn()
local T, ui = Core.t, Core.ui
local C = ui.C

Core.addStrings({
	ru = {
		hub_title = "AutoFarm Hub",
		hub_autofarm = "Автофарм",
		hub_settings = "Настройки",
		hub_choose = "Выбери фарм:",
		farm_garden = "Огород",
		farm_fishing = "Рыбалка",
		farm_mining = "Добыча",
		farm_soon = "скоро, v2",
		hub_soon_toast = "Этот фарм подключим в v2",
		hub_unload = "выгрузить хаб",
		hub_loading = "Загружаю: %s…",
		hub_net_err = "Не удалось скачать %s",
		hub_start_err = "Ошибка запуска: %s",
		hub_ready = "Хаб готов",
	},
	en = {
		hub_title = "AutoFarm Hub",
		hub_autofarm = "Autofarm",
		hub_settings = "Settings",
		hub_choose = "Choose a farm:",
		farm_garden = "Garden",
		farm_fishing = "Fishing",
		farm_mining = "Mining",
		farm_soon = "soon, v2",
		hub_soon_toast = "This farm comes in v2",
		hub_unload = "unload hub",
		hub_loading = "Loading: %s…",
		hub_net_err = "Could not download %s",
		hub_start_err = "Start error: %s",
		hub_ready = "Hub ready",
	},
})

-- ===== Menu =====
local panel
local function closeHub()
	if panel then
		pcall(function()
			panel.root:Destroy()
		end)
		panel = nil
	end
end

local sides = {}
local function showSide(which)
	for name, f in pairs(sides) do
		f.Visible = (name == which) and not f.Visible
	end
end

panel = Core.panel({
	titleKey = "hub_title",
	size = Vector2.new(210, 128),
	onClose = function()
		Core.unload()
	end,
})
local body = panel.body

local function mainButton(y, key, fn)
	local b = ui.button(body, {
		Position = UDim2.fromOffset(8, y), Size = UDim2.new(1, -16, 0, 40), TextSize = 16,
	})
	Core.bindText(b, key)
	b.Activated:Connect(fn)
	return b
end

local function sideFrame(height)
	local f = ui.mk("Frame", panel.root, {
		Position = UDim2.new(1, 6, 0, 0), Size = UDim2.fromOffset(190, height), BackgroundColor3 = C.BG,
		BorderSizePixel = 0, Visible = false,
	})
	ui.round(f, 8)
	return f
end

-- farm choice (side panel)
local farmSide = sideFrame(168)
sides.farms = farmSide
local hdr = ui.label(farmSide, {
	Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 18), TextColor3 = C.GRAY,
	Font = ui.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left,
})
Core.bindText(hdr, "hub_choose")

local function startFarm(key, titleKey)
	local file = FILES[key]
	if not file then
		Core.toast(T("hub_soon_toast"), "warn")
		return
	end
	local name = T(titleKey)
	Core.toast(T("hub_loading", name), "info", 2)
	task.spawn(function()
		local src, err = fetch(file)
		if not src then
			Core.log("HUB", "download failed %s: %s", file, tostring(err))
			Core.toast(T("hub_net_err", file), "err", 5)
			return
		end
		Core.log("HUB", "launching %s", key)
		closeHub() -- the hub removes its own menu; Core stays alive for the farm
		local ok, e = Core.launch(key, src)
		if not ok then
			Core.toast(T("hub_start_err", tostring(e)), "err", 6)
		end
	end)
end

local farmList = {
	{ "garden", "farm_garden" },
	{ "fishing", "farm_fishing" },
	{ "mining", "farm_mining" },
}
for i, f in ipairs(farmList) do
	local key, titleKey = f[1], f[2]
	local available = FILES[key] ~= nil
	local b = ui.button(farmSide, {
		Position = UDim2.fromOffset(8, 28 + (i - 1) * 44), Size = UDim2.new(1, -16, 0, 38), TextSize = 14,
		BackgroundColor3 = available and C.GREEN or C.BTN, TextColor3 = available and C.WHITE or C.GRAY,
		RichText = true,
	})
	if available then
		Core.bindText(b, titleKey)
	else
		-- name + small "soon" note, kept translated
		local function upd()
			b.Text = T(titleKey) .. '\n<font size="11">' .. T("farm_soon") .. "</font>"
		end
		upd()
		Core.onLang(upd)
	end
	b.Activated:Connect(function()
		startFarm(key, titleKey)
	end)
end

-- settings (side panel): language, guard options, copy log, unload hub
local setSide = sideFrame(262)
sides.settings = setSide
local function sideBtn(y, h, props)
	props.Position, props.Size, props.TextSize, props.Font = UDim2.fromOffset(8, y), UDim2.new(1, -16, 0, h), 14, ui.FONT
	return ui.button(setSide, props)
end

local langBtn = sideBtn(8, 32, {})
local function updLang()
	langBtn.Text = T("lang_label") .. ": " .. Core.getLang():upper()
end
updLang()
Core.onLang(updLang)
langBtn.Activated:Connect(Core.nextLang)

local function guardToggle(y, cfgKey, textKey)
	local b = sideBtn(y, 32, {})
	local function upd()
		local on = Core.guard.cfg[cfgKey]
		b.Text = T(textKey) .. ": " .. T(on and "v_on" or "v_off")
		b.BackgroundColor3 = on and C.GREEN or C.BTN
	end
	upd()
	Core.onLang(upd)
	b.Activated:Connect(function()
		Core.guard.cfg[cfgKey] = not Core.guard.cfg[cfgKey]
		Core.guard.save()
		upd()
	end)
end
guardToggle(46, "autopause", "guard_autopause")
guardToggle(84, "restart", "guard_restart_opt")
guardToggle(122, "watchdog", "guard_watchdog")

local copyBtn = sideBtn(168, 32, {})
Core.bindText(copyBtn, "log_copy")
copyBtn.Activated:Connect(Core.copyLog)

local unloadBtn = sideBtn(210, 30, { BackgroundColor3 = C.RED })
Core.bindText(unloadBtn, "hub_unload")
unloadBtn.Activated:Connect(function()
	Core.unload()
end)

mainButton(6, "hub_autofarm", function()
	showSide("farms")
end)
mainButton(52, "hub_settings", function()
	showSide("settings")
end)

Core.log("HUB", "hub v2.0 ready")
Core.toast(T("hub_ready"), "ok", 2)
