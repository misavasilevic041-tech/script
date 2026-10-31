--[[ ============================================================
 AutoFarm Hub · hub.luau · v4.2   (@version 4.2)
 The ONLY file the user runs. It downloads core.luau, preloads the farm files, shows the menu and starts a farm.
 Files of the project: hub.luau, core.luau (shared module), garden.luau, fishing.luau, mining.luau (farms),
 versions.json (version list for the update check), lang.luau (optional: extra languages). See README.md.

 Run:
   loadstring(game:HttpGet("https://raw.githubusercontent.com/misavasilevic041-tech/script/refs/heads/main/hub.luau"))()
 BASE is the folder with the files. For local testing put the files into the executor's workspace folder and set
 BASE = "AutoFarmHub/files/" (anything not starting with "http" is read with readfile).
============================================================ ]]
-- v4.2: warnings cover the whole menu (unload: countdown, then it unloads by itself; switch farm: Yes / No).
-- v4.1: loading screen without CanvasGroup (buttons inside it did not react).
-- v4.0 (cosmetics): loading screen, preloading of all files with a clear error when GitHub is unreachable (retry / continue),
--   version check against versions.json, themes (dark / light + accent), hotkey + floating button, anti-AFK switch,
--   last used farm highlighted, "About" page, optional lang.luau with extra languages, scrolling settings list.
-- v3.3: English is the default language on the first run; console log is OFF by default.
-- v3.2: the module system is gone. Buff (cooking) and languages live in the core and work for all farms.
--   Every started farm gets the dock window with a [Hub] button: it opens this menu again WITHOUT stopping the farm.
--   Picking a farm while another one runs asks first. Running the hub again asks "reload?".

local HUB_VERSION = "4.2"
local BASE = "https://raw.githubusercontent.com/misavasilevic041-tech/script/refs/heads/main/"

local FILES = {
	core = "core.luau",
	fishing = "fishing.luau",
	garden = "garden.luau",
	mining = "mining.luau",
	manifest = "versions.json",
	lang = "lang.luau",
}
local FARM_KEYS = { "garden", "fishing", "mining" }

local env = (getgenv and getgenv()) or _G
local HttpService = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

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

-- "4.0" vs "4.1": 1 if a is newer, -1 if older, 0 if equal
local function vcmp(a, b)
	local pa, pb = {}, {}
	for n in tostring(a):gmatch("%d+") do
		pa[#pa + 1] = tonumber(n)
	end
	for n in tostring(b):gmatch("%d+") do
		pb[#pb + 1] = tonumber(n)
	end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x > y and 1 or -1
		end
	end
	return 0
end

-- ===== Error screen without the core (the core itself could not be downloaded) =====
local function bootError(detail, retry)
	pcall(function()
		local parent = (gethui and gethui()) or game:GetService("CoreGui")
		local old = parent:FindFirstChild("HubBootError")
		if old then
			old:Destroy()
		end
		local g = Instance.new("ScreenGui")
		g.Name, g.ResetOnSpawn, g.DisplayOrder = "HubBootError", false, 1000
		g.Parent = parent
		local f = Instance.new("Frame")
		f.Size, f.Position = UDim2.fromOffset(330, 170), UDim2.new(0.5, -165, 0.5, -85)
		f.BackgroundColor3, f.BorderSizePixel = Color3.fromRGB(24, 24, 30), 0
		f.Parent = g
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
		local st = Instance.new("UIStroke", f)
		st.Color, st.Thickness = Color3.fromRGB(170, 50, 50), 1.5
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency, t.Position, t.Size = 1, UDim2.fromOffset(12, 10), UDim2.new(1, -24, 0, 100)
		t.Font, t.TextSize, t.TextWrapped = Enum.Font.Gotham, 13, true
		t.TextColor3, t.TextXAlignment, t.TextYAlignment = Color3.fromRGB(235, 235, 240), Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
		t.Text = "AutoFarm Hub: cannot download the core file. Check the internet / GitHub and BASE in hub.luau.\n"
			.. "Не удалось скачать файл ядра. Проверь интернет / GitHub и BASE в hub.luau.\n\n" .. tostring(detail):sub(1, 120)
		t.Parent = f
		local function btn(text, x, fn)
			local b = Instance.new("TextButton")
			b.Size, b.Position = UDim2.new(0.5, -18, 0, 34), UDim2.new(x, x == 0 and 12 or 6, 1, -46)
			b.BackgroundColor3, b.BorderSizePixel = Color3.fromRGB(44, 44, 54), 0
			b.Font, b.TextSize, b.TextColor3, b.Text = Enum.Font.GothamBold, 14, Color3.fromRGB(235, 235, 240), text
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
			b.Parent = f
			b.Activated:Connect(function()
				g:Destroy()
				if fn then
					task.spawn(fn)
				end
			end)
		end
		btn("Retry / Повторить", 0, retry)
		btn("Close / Закрыть", 0.5, nil)
	end)
	warn("[HUB] cannot download core: " .. tostring(detail))
end

local main

function main()
	-- ===== Core =====
	local coreSrc, coreErr
	for attempt = 1, 2 do
		coreSrc, coreErr = fetch(FILES.core)
		if coreSrc then
			break
		end
		task.wait(1)
	end
	if not coreSrc then
		bootError(coreErr, main)
		return
	end
	local coreFn, compileErr = loadstring(coreSrc, "=core")
	if not coreFn then
		bootError("core compile error: " .. tostring(compileErr), main)
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
			hub_unload = "выгрузить всё",
			hub_loading = "Загружаю: %s…",
			hub_net_err = "Не удалось скачать %s",
			hub_net_hint = "GitHub недоступен или файла нет в репозитории. Проверь интернет и попробуй ещё раз.",
			hub_start_err = "Ошибка запуска: %s",
			hub_ready = "Хаб готов",
			hub_already = "Этот фарм уже запущен",
			switch_title = "СМЕНА ФАРМА",
			switch_text = "Сейчас работает «%s». При запуске «%s» он остановится.",
			switch_yes = "Сменить",
			splash_loading = "Загрузка файлов…",
			splash_files = "Загружено файлов: %d из %d",
			splash_fail = "Не скачались: %s. Проверь интернет / GitHub.",
			splash_retry = "Повторить",
			splash_continue = "Продолжить",
			files_ok = "файлы загружены: %d из %d",
			files_bad = "не загружено: %s",
			hub_ver = "хаб %s · ядро %s",
			upd_avail = "доступно обновление: %s",
			upd_none = "Обновлений нет",
			upd_fail = "Не удалось проверить обновления (GitHub недоступен)",
			upd_toast = "Доступно обновление: %s. Запусти загрузчик заново.",
			about_title = "О проекте",
			about_text = "<b>AutoFarm Hub</b> — меню автоматизации для трёх занятий: огород, рыбалка, добыча.\n\n<b>Как пользоваться</b>\n1. Нажми «Автофарм» и выбери занятие.\n2. На панели фарма включи его кнопкой ВКЛ/ВЫКЛ.\n3. Скорость и настройки доступны на той же панели.\n4. «☰ Хаб» открывает это меню, не останавливая фарм.\n5. Баф: за заданное время до конца эффекта скрипт готовит блюдо и просит съесть его. Съедаешь ты.\n\n<b>Полезно знать</b>\n• Скрыть / показать интерфейс: клавиша %s (на телефоне — плавающая кнопка).\n• Журнал: кнопка «журнал» на панели; «скопировать лог» — для поиска ошибок.\n• Настройки, язык, тема и положение окон сохраняются сами.\n• Автопауза, защита от зависаний и антиафк включаются в настройках.\n• «выгрузить всё» убирает интерфейс, соединения и переменные.",
			about_versions = "Версии (у тебя / в репозитории)",
			acc_green = "зелёный", acc_blue = "синий", acc_purple = "фиолетовый", acc_pink = "розовый", acc_teal = "бирюзовый",
		},
		en = {
			hub_title = "AutoFarm Hub",
			hub_autofarm = "Autofarm",
			hub_settings = "Settings",
			hub_choose = "Choose a farm:",
			farm_garden = "Garden",
			farm_fishing = "Fishing",
			farm_mining = "Mining",
			hub_unload = "unload everything",
			hub_loading = "Loading: %s…",
			hub_net_err = "Could not download %s",
			hub_net_hint = "GitHub is unreachable or the file is missing in the repository. Check the internet and try again.",
			hub_start_err = "Start error: %s",
			hub_ready = "Hub ready",
			hub_already = "This farm is already running",
			switch_title = "SWITCH FARM",
			switch_text = "\"%s\" is running now. Starting \"%s\" will stop it.",
			switch_yes = "Switch",
			splash_loading = "Loading files…",
			splash_files = "Files loaded: %d of %d",
			splash_fail = "Not downloaded: %s. Check the internet / GitHub.",
			splash_retry = "Retry",
			splash_continue = "Continue",
			files_ok = "files loaded: %d of %d",
			files_bad = "not loaded: %s",
			hub_ver = "hub %s · core %s",
			upd_avail = "update available: %s",
			upd_none = "No updates",
			upd_fail = "Could not check for updates (GitHub unreachable)",
			upd_toast = "Update available: %s. Run the loader again.",
			about_title = "About",
			about_text = "<b>AutoFarm Hub</b> is an automation menu for three activities: garden, fishing, mining.\n\n<b>How to use</b>\n1. Press \"Autofarm\" and pick an activity.\n2. Switch it on with the ON/OFF button of the farm panel.\n3. Speed and settings are on the same panel.\n4. \"☰ Hub\" opens this menu without stopping the farm.\n5. Buff: shortly before the effect ends the script cooks the dish and asks you to eat it. You do the eating.\n\n<b>Good to know</b>\n• Hide / show the interface: key %s (on a phone: the floating button).\n• Log: the \"log\" button on the panel; \"copy log\" is for bug reports.\n• Settings, language, theme and window positions are saved automatically.\n• Autopause, stall protection and anti-AFK are switched in the settings.\n• \"unload everything\" removes the interface, connections and variables.",
			about_versions = "Versions (yours / repository)",
			acc_green = "green", acc_blue = "blue", acc_purple = "purple", acc_pink = "pink", acc_teal = "teal",
		},
	})

	-- optional extra languages: lang.luau returns { es = { key = "text", ... }, pt = { ... } } (see README)
	pcall(function()
		local src = fetch(FILES.lang)
		if src then
			local fn = loadstring(src, "=lang")
			local pack = fn and fn()
			if type(pack) == "table" then
				Core.addStrings(pack)
			end
		end
	end)

	local farmList = {
		{ "garden", "farm_garden" },
		{ "fishing", "farm_fishing" },
		{ "mining", "farm_mining" },
	}
	local titleOf = {}
	for _, f in ipairs(farmList) do
		titleOf[f[1]] = f[2]
	end

	-- ===== Preload: every farm file is downloaded before the menu opens =====
	local cache, manifest = {}, nil
	local function verOf(src)
		return src and src:sub(1, 4000):match("@version%s+([%w%.%-]+)") or nil
	end

	local function preload(progress)
		local todo = {}
		for _, key in ipairs(FARM_KEYS) do
			if not cache[key] then
				todo[#todo + 1] = key
			end
		end
		local total, pending, failed, done = #todo, #todo + 1, {}, 0
		task.spawn(function() -- the version list; a failure here is silent (no update info)
			local txt = fetch(FILES.manifest)
			if txt then
				local ok, dec = pcall(function()
					return HttpService:JSONDecode(txt)
				end)
				if ok and type(dec) == "table" then
					manifest = dec
				end
			end
			pending = pending - 1
		end)
		for _, key in ipairs(todo) do
			task.spawn(function()
				local src, err = fetch(FILES[key])
				if src then
					cache[key] = src
				else
					failed[#failed + 1] = key
					Core.log("HUB", "download failed %s: %s", FILES[key], tostring(err))
				end
				pending = pending - 1
				done = done + 1
				if progress then
					progress(done, total)
				end
			end)
		end
		while pending > 0 do
			task.wait(0.05)
		end
		return failed
	end

	-- ===== Loading screen =====
	local function showSplash()
		local g = Core.gui()
		local box = ui.mk("Frame", g, {
			Name = "HubSplash", Size = UDim2.fromOffset(290, 150), Position = UDim2.new(0.5, -145, 0.5, -75),
			BackgroundColor3 = C.BG, BorderSizePixel = 0, Active = true, ZIndex = 70,
		})
		ui.round(box, 12)
		ui.mk("UIStroke", box, { Color = C.GREEN, Thickness = 1.5 })
		local title = ui.label(box, {
			Position = UDim2.fromOffset(10, 12), Size = UDim2.new(1, -20, 0, 26), TextSize = 21, Font = ui.FONT_BOLD,
			Text = "AutoFarm Hub",
		})
		ui.label(box, {
			Position = UDim2.fromOffset(10, 40), Size = UDim2.new(1, -20, 0, 16), TextSize = 12, TextColor3 = C.GRAY,
			Text = "v" .. HUB_VERSION,
		})
		local barBg = ui.mk("Frame", box, {
			Position = UDim2.fromOffset(20, 70), Size = UDim2.new(1, -40, 0, 8), BackgroundColor3 = C.BTN, BorderSizePixel = 0,
		})
		ui.round(barBg, 4)
		local fill = ui.mk("Frame", barBg, { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.GREEN, BorderSizePixel = 0 })
		ui.round(fill, 4)
		local status = ui.label(box, {
			Position = UDim2.fromOffset(12, 86), Size = UDim2.new(1, -24, 0, 26), TextSize = 12, TextColor3 = C.GRAY,
			TextWrapped = true, Text = T("splash_loading"),
		})
		local sp = {}
		function sp.progress(frac)
			pcall(function()
				TweenService:Create(fill, TweenInfo.new(0.15), { Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0) }):Play()
			end)
		end
		function sp.status(text, bad)
			status.Text = text
			status.TextColor3 = bad and C.ORANGE or C.GRAY
		end
		function sp.ask(retryKey, contKey) -- two buttons; returns "retry" or "continue"
			local choice
			local a = ui.button(box, {
				Position = UDim2.fromOffset(12, 114), Size = UDim2.new(0.5, -18, 0, 28), TextSize = 13, BackgroundColor3 = C.GREEN,
				Text = T(retryKey),
			})
			local b = ui.button(box, {
				Position = UDim2.new(0.5, 6, 0, 114), Size = UDim2.new(0.5, -18, 0, 28), TextSize = 13, Text = T(contKey),
			})
			a.Activated:Connect(function()
				choice = "retry"
			end)
			b.Activated:Connect(function()
				choice = "continue"
			end)
			while not choice and box.Parent do
				task.wait(0.1)
			end
			pcall(a.Destroy, a)
			pcall(b.Destroy, b)
			return choice or "continue"
		end
		function sp.close()
			pcall(box.Destroy, box)
		end
		return sp
	end

	-- ===== Versions / updates =====
	local function updatesList()
		local out = {}
		if type(manifest) ~= "table" then
			return out
		end
		local function chk(name, cur)
			local new = manifest[name]
			if cur and type(new) == "string" and vcmp(new, cur) > 0 then
				out[#out + 1] = string.format("%s %s → %s", name, cur, new)
			end
		end
		chk("hub", HUB_VERSION)
		chk("core", Core.VERSION)
		for _, k in ipairs(FARM_KEYS) do
			chk(k, verOf(cache[k]))
		end
		return out
	end

	-- ===== Starting a farm =====
	local panel, versionLbl
	local function closeHub()
		if panel then
			pcall(function()
				panel.root:Destroy()
			end)
			panel = nil
		end
	end

	local function doStart(key, titleKey)
		local name = T(titleKey)
		Core.toast(T("hub_loading", name), "info", 2)
		task.spawn(function()
			local src, err = cache[key], nil
			if not src then
				src, err = fetch(FILES[key])
				if src then
					cache[key] = src
				end
			end
			if not src then
				Core.log("HUB", "download failed %s: %s", FILES[key], tostring(err))
				Core.toast(T("hub_net_err", FILES[key]), "err", 5)
				Core.toast(T("hub_net_hint"), "warn", 7)
				return
			end
			closeHub() -- the hub removes its own menu; Core stays alive for the farm
			Core.setGlobal("lastFarm", key)
			local ok, e = Core.launch(key, src, verOf(src))
			if not ok then
				Core.toast(T("hub_start_err", tostring(e)), "err", 6)
			end
		end)
	end

	local function startFarm(key, titleKey)
		local cur = Core.farmScope
		if cur and not cur.dead then
			if Core.farmName == key then
				Core.toast(T("hub_already"), "info", 2)
				return
			end
			Core.confirm({
				parent = panel and panel.root,
				titleKey = "switch_title",
				text = T("switch_text", T(titleOf[Core.farmName] or tostring(Core.farmName)), T(titleKey)),
				yesKey = "switch_yes", noKey = "confirm_no",
				onYes = function()
					doStart(key, titleKey)
				end,
			})
			return
		end
		doStart(key, titleKey)
	end

	local function showAbout()
		local lines = { T("about_text", Core.getGlobal("hotkey", "RightShift")), "", "<b>" .. T("about_versions") .. "</b>" }
		local function add(name, cur)
			local new = type(manifest) == "table" and manifest[name] or nil
			local mark = (new and cur and vcmp(new, cur) > 0) and "  ⚠" or ""
			lines[#lines + 1] = string.format("• %s: %s / %s%s", name, tostring(cur or "—"), tostring(new or "—"), mark)
		end
		add("hub", HUB_VERSION)
		add("core", Core.VERSION)
		for _, k in ipairs(FARM_KEYS) do
			add(k, verOf(cache[k]))
		end
		Core.info({ titleKey = "about_title", text = table.concat(lines, "\n") })
	end

	local function checkUpdates()
		task.spawn(function()
			local txt = fetch(FILES.manifest)
			local ok, dec = false, nil
			if txt then
				ok, dec = pcall(function()
					return HttpService:JSONDecode(txt)
				end)
			end
			if not (ok and type(dec) == "table") then
				Core.toast(T("upd_fail"), "err", 4)
				return
			end
			manifest = dec
			local list = updatesList()
			if #list == 0 then
				Core.toast(T("upd_none"), "ok", 3)
			else
				Core.toast(T("upd_avail", table.concat(list, ", ")), "warn", 6)
			end
			if versionLbl then
				versionLbl.Refresh()
			end
		end)
	end

	-- ===== Menu =====
	local function buildHub()
		local sides = {}
		local function showSide(which)
			for name, f in pairs(sides) do
				f.Visible = (name == which) and not f.Visible
			end
		end

		panel = Core.panel({
			titleKey = "hub_title",
			posKey = "hub",
			size = Vector2.new(210, 160),
			pos = UDim2.new(0.5, -105, 0.5, -80),
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

		local function sideFrame(height, scrolling)
			local f = ui.mk(scrolling and "ScrollingFrame" or "Frame", panel.root, {
				Position = UDim2.new(1, 6, 0, 0), Size = UDim2.fromOffset(210, height), BackgroundColor3 = C.BG,
				BorderSizePixel = 0, Visible = false,
			})
			if scrolling then
				f.ScrollBarThickness, f.AutomaticCanvasSize, f.CanvasSize = 3, Enum.AutomaticSize.Y, UDim2.new()
			end
			ui.round(f, 8)
			return f
		end

		-- farm choice (side panel)
		local farmSide = sideFrame(222)
		sides.farms = farmSide
		local hdr = ui.label(farmSide, {
			Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 18), TextColor3 = C.GRAY,
			Font = ui.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left,
		})
		Core.bindText(hdr, "hub_choose")
		local last = Core.getGlobal("lastFarm", "")
		for i, f in ipairs(farmList) do
			local key, titleKey = f[1], f[2]
			local b = ui.button(farmSide, {
				Position = UDim2.fromOffset(8, 28 + (i - 1) * 44), Size = UDim2.new(1, -16, 0, 38), TextSize = 14,
				BackgroundColor3 = C.GREEN,
			})
			Core.bindText(b, titleKey)
			if key == last then -- the farm used last time: a star
				ui.label(b, {
					Position = UDim2.new(1, -26, 0, 0), Size = UDim2.fromOffset(20, 38), TextSize = 16, Text = "★",
					TextColor3 = C.WHITE,
				})
			end
			b.Activated:Connect(function()
				startFarm(key, titleKey)
			end)
		end
		local filesLbl = ui.label(farmSide, {
			Position = UDim2.fromOffset(10, 28 + 3 * 44), Size = UDim2.new(1, -20, 0, 32), TextSize = 11, TextColor3 = C.GRAY,
			TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		})
		local function updFiles()
			local ok, bad = 0, {}
			for _, k in ipairs(FARM_KEYS) do
				if cache[k] then
					ok = ok + 1
				else
					bad[#bad + 1] = FILES[k]
				end
			end
			if #bad == 0 then
				filesLbl.Text = T("files_ok", ok, #FARM_KEYS)
				filesLbl.TextColor3 = C.GRAY
			else
				filesLbl.Text = T("files_bad", table.concat(bad, ", "))
				filesLbl.TextColor3 = C.ORANGE
			end
		end
		updFiles()
		Core.onLang(updFiles)

		-- settings (side panel, scrolls): language, theme, accent, hotkey, floating button, switches, log, updates, about, unload
		local setSide = sideFrame(300, true)
		sides.settings = setSide
		ui.mk("UIListLayout", setSide, { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder })
		ui.mk("UIPadding", setSide, {
			PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		})
		local rows, order = {}, 0
		local function updAll()
			for _, f in ipairs(rows) do
				f()
			end
		end
		local function row(textFn, onClick, role)
			order = order + 1
			local b = ui.button(setSide, { Size = UDim2.new(1, 0, 0, 30), TextSize = 13, Font = ui.FONT, LayoutOrder = order })
			local function upd()
				local text, bg = textFn()
				b.Text = text
				if bg then
					b.BackgroundColor3 = bg
				end
			end
			upd()
			rows[#rows + 1] = upd
			b.Activated:Connect(function()
				onClick()
				updAll()
			end)
			if role then
				b.BackgroundColor3 = role
			end
			return b
		end
		local function cycle(list, cur)
			local i = table.find(list, cur) or 0
			return list[i % #list + 1]
		end

		row(function()
			return T("lang_label") .. ": " .. Core.getLang():upper()
		end, Core.nextLang)
		row(function()
			local th = Core.getGlobal("theme", "dark")
			return T("theme_label") .. ": " .. T(th == "light" and "theme_light" or "theme_dark")
		end, function()
			Core.setTheme(Core.getGlobal("theme", "dark") == "dark" and "light" or "dark")
		end)
		row(function()
			local ac = Core.getGlobal("accent", "green")
			return T("accent_label") .. ": " .. T("acc_" .. ac), C.GREEN
		end, function()
			Core.setAccent(cycle(Core.ACCENT_LIST, Core.getGlobal("accent", "green")))
		end)
		row(function()
			return T("hotkey_label") .. ": " .. Core.getGlobal("hotkey", "RightShift")
		end, function()
			Core.setGlobal("hotkey", cycle(Core.HOTKEYS, Core.getGlobal("hotkey", "RightShift")))
		end)
		local fabDefault = UIS.TouchEnabled and not UIS.KeyboardEnabled
		local function toggleRow(labelKey, key, default, after)
			row(function()
				local on = Core.getGlobal(key, default)
				return T(labelKey) .. ": " .. T(on and "v_on" or "v_off"), on and C.GREEN or C.BTN
			end, function()
				Core.setGlobal(key, not Core.getGlobal(key, default))
				if after then
					after()
				end
			end)
		end
		toggleRow("fab_label", "fab", fabDefault, Core.updateFab)
		toggleRow("afk_label", "antiafk", true)
		toggleRow("g_autopause", "autopause", false)
		toggleRow("g_watchdog", "watchdog", true)
		toggleRow("g_console", "console_log", false)
		row(function()
			return T("log_copy")
		end, Core.copyLog)
		row(function()
			return T("upd_btn")
		end, checkUpdates)
		row(function()
			return T("about_btn")
		end, showAbout)
		row(function()
			return T("hub_unload"), C.RED
		end, function()
			Core.confirm({
				parent = panel and panel.root, countdown = 3, titleKey = "unload_title", textKey = "unload_text",
				noKey = "confirm_no", onYes = Core.unload,
			})
		end)
		Core.onLang(updAll)

		mainButton(6, "hub_autofarm", function()
			showSide("farms")
		end)
		mainButton(52, "hub_settings", function()
			showSide("settings")
		end)

		-- version line + update hint
		local vl = ui.label(body, {
			Position = UDim2.fromOffset(8, 96), Size = UDim2.new(1, -16, 0, 14), TextSize = 11, TextColor3 = C.GRAY,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local ul = ui.label(body, {
			Position = UDim2.fromOffset(8, 110), Size = UDim2.new(1, -16, 0, 14), TextSize = 11, TextColor3 = C.ORANGE,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		})
		versionLbl = {}
		function versionLbl.Refresh()
			vl.Text = T("hub_ver", HUB_VERSION, Core.VERSION)
			local list = updatesList()
			ul.Text = #list > 0 and T("upd_avail", table.concat(list, ", ")) or ""
		end
		versionLbl.Refresh()
		Core.onLang(versionLbl.Refresh)
	end

	-- the [Hub] button of the dock window: open / close the menu, the running farm is not touched
	Core.toggleHub = function()
		if panel and panel.root.Parent then
			closeHub()
		else
			buildHub()
		end
	end

	-- ===== Start: loading screen -> preload -> menu =====
	local sp = showSplash()
	while true do
		local failed = preload(function(done, total)
			sp.progress(total > 0 and done / total or 1)
			sp.status(T("splash_files", done, total))
		end)
		sp.progress(1)
		if #failed == 0 then
			break
		end
		local names = {}
		for _, k in ipairs(failed) do
			names[#names + 1] = FILES[k]
		end
		sp.status(T("splash_fail", table.concat(names, ", ")), true)
		Core.toast(T("hub_net_hint"), "warn", 6)
		if sp.ask("splash_retry", "splash_continue") ~= "retry" then
			break
		end
		sp.status(T("splash_loading"))
		sp.progress(0)
	end
	task.wait(0.3)
	sp.close()

	buildHub()
	Core.logLoad("hub " .. HUB_VERSION)
	Core.toast(T("hub_ready"), "ok", 2)
	local list = updatesList()
	if #list > 0 then
		Core.toast(T("upd_toast", table.concat(list, ", ")), "warn", 6)
	end
end

-- running the hub again: ask first instead of silently resetting the running one
local old = env.HubCore
if old and not old.dead and old.confirm then
	old.confirm({
		titleKey = "reload_title", textKey = "reload_text", yesKey = "reload_yes", noKey = "confirm_no",
		onYes = function()
			pcall(old.unload)
			task.wait(0.3)
			main()
		end,
	})
else
	main()
end
