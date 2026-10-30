-- AutoFarm Hub: shared module (Core) v1.3
-- Provides: languages, settings saving, log, toasts, panel, copy-log button, farm scopes.
-- Loaded by hub.luau, stored in getgenv().HubCore. Farm scripts take everything from there.
--
--   Core.t(key, ...)              translated string (fallback: en, then the key itself)
--   Core.addStrings({ru={}, en={}})   a farm registers its own strings
--   Core.getLang() / Core.setLang("ru"|"en") / Core.onLang(fn) -> disconnect fn
--   Core.bindText(guiObj, key, ...)   keeps obj.Text translated when the language changes
--   Core.getFarm(name, defaults) / Core.setFarm(name, tbl)   saved settings per farm
--   Core.log(tag, fmt, ...) / Core.logText() / Core.copyLog()
--   Core.toast(text, kind, seconds)   kind: "info" | "ok" | "warn" | "err"
--   Core.panel{titleKey=, size=, pos=, onClose=}   draggable panel with lang / log / X buttons
--   Core.newScope() / Core.launch(name, source)   scope = {connect, onCleanup, alive, stop}
--   Core.unload()                 stops the running farm, saves, destroys the GUI
--   v1.1:
--   Core.getGlobal(key, default) / Core.setGlobal(key, value)   hub-wide saved settings (autopause, watchdog)
--   Core.paused()                 true while autopause is on and the window is unfocused or the Roblox menu is open
--   Core.watchdog(scope, {name=, getProgress=fn->number, isActive=fn->bool, onStall=fn, minutes=})
--                                 no progress for N minutes -> log + toast + onStall() (usually restarts the loop)
--   Core.onRespawn(scope, fn)     fn(character) after every respawn (death, teleport)
--   v1.2:
--   Core.logLoad(name) / Core.logUnload(name)   the only start/stop lines in the log: "[LOAD] x" / "[UNLOAD] x"
--   Core.confirm{titleKey=|title=, textKey=|text=, yesKey=|yes=, noKey=|no=, onYes=fn, onNo=fn}   modal window, fades in/out
--   Core.panel: the X button now asks for confirmation before calling onClose
--   v1.3 (modules: add-ons of a farm, live in a nested scope inside the farm scope):
--   Core.launchModule(name, src)  runs a module script; it receives (scope, farmScope) as varargs: local scope, farm = ...
--                                 stops together with the farm, or alone; own [LOAD] / [UNLOAD] lines
--   Core.unloadModule(name)       stops one module, the farm keeps working
--   Core.modules                  name -> scope of the running modules

local env = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local P = Players.LocalPlayer

-- a second run replaces the first one completely
if env.HubCore and env.HubCore.unload then
	pcall(env.HubCore.unload)
end

local Core = { VERSION = "1.3", dead = false }
env.HubCore = Core

local function copy(v)
	if type(v) ~= "table" then
		return v
	end
	local o = {}
	for k, x in pairs(v) do
		o[k] = copy(x)
	end
	return o
end

-- ============================================================
-- Log
-- ============================================================
local logBuf, LOGMAX, t0 = {}, 1500, os.clock()

function Core.log(tag, fmt, ...)
	local s = fmt
	if select("#", ...) > 0 then
		local ok, r = pcall(string.format, fmt, ...)
		s = ok and r or (tostring(fmt) .. " (format error)")
	end
	s = tostring(s)
	logBuf[#logBuf + 1] = string.format("[%7.2f] [%s] %s", os.clock() - t0, tag, s)
	if #logBuf > LOGMAX then
		table.remove(logBuf, 1)
	end
	print("[" .. tag .. "] " .. s)
end

function Core.logText()
	return table.concat(logBuf, "\n")
end

-- the only start / stop lines: something was loaded or unloaded
function Core.logLoad(name)
	Core.log("LOAD", "%s", tostring(name))
end

function Core.logUnload(name)
	Core.log("UNLOAD", "%s", tostring(name))
end

-- ============================================================
-- Settings (saved to AutoFarmHub/settings.json)
-- ============================================================
local FOLDER, FILE = "AutoFarmHub", "AutoFarmHub/settings.json"
local fsOk = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local data = { lang = "ru", farms = {}, global = {} }

if fsOk then
	local ok, raw = pcall(function()
		if isfile(FILE) then
			return readfile(FILE)
		end
	end)
	if ok and type(raw) == "string" and raw ~= "" then
		local ok2, dec = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok2 and type(dec) == "table" then
			if type(dec.lang) == "string" then
				data.lang = dec.lang
			end
			if type(dec.farms) == "table" then
				data.farms = dec.farms
			end
			if type(dec.global) == "table" then
				data.global = dec.global
			end
		else
			Core.log("CORE", "settings file is broken, using defaults")
		end
	end
end

local function writeFile(path, text)
	if not fsOk then
		return false
	end
	return (pcall(function()
		if makefolder and isfolder and not isfolder(FOLDER) then
			makefolder(FOLDER)
		end
		writefile(path, text)
	end))
end

local saveQueued = false
function Core.save(now)
	if not fsOk then
		return
	end
	local function doSave()
		saveQueued = false
		local ok, json = pcall(function()
			return HttpService:JSONEncode(data)
		end)
		if ok then
			writeFile(FILE, json)
		end
	end
	if now then
		doSave()
		return
	end
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(0.5, doSave)
end

-- saved values win over the defaults; a value of the wrong type is ignored
function Core.getFarm(name, defaults)
	local saved = data.farms[name]
	local out = {}
	for k, v in pairs(defaults) do
		local s
		if type(saved) == "table" then
			s = saved[k]
		end
		if s ~= nil and type(s) == type(v) then
			out[k] = copy(s)
		else
			out[k] = copy(v)
		end
	end
	return out
end

function Core.setFarm(name, tbl)
	data.farms[name] = copy(tbl)
	Core.save()
end

-- hub-wide settings (autopause, watchdog); same file, own table
function Core.getGlobal(key, default)
	local v = data.global[key]
	if v ~= nil and type(v) == type(default) then
		return v
	end
	return default
end

function Core.setGlobal(key, value)
	data.global[key] = value
	Core.save()
end

-- ============================================================
-- Languages
-- ============================================================
Core.LANGS = { "ru", "en" }
local DICT = {
	ru = {
		v_on = "вкл",
		v_off = "выкл",
		log_copy = "скопировать лог",
		log_btn = "лог",
		log_copied = "Лог скопирован (%d строк)",
		log_empty = "Лог пока пуст",
		log_file = "Буфер обмена недоступен, лог сохранён в файл: %s",
		log_fail = "Не удалось скопировать лог",
		lang_label = "язык",
		g_autopause = "автопауза",
		g_watchdog = "защита от зависаний",
		wd_stall = "%s: нет прогресса %d мин, перезапускаю цикл",
		wd_warn = "%s: нет прогресса %d мин",
		paused = "пауза (окно неактивно или открыто меню)",
		confirm_title = "ВЫГРУЗКА",
		confirm_text = "Будут выгружены хаб, ядро и все подключённые файлы (огород, рыбалка, добыча). Настройки сохранятся.",
		confirm_yes = "Выгрузить",
		confirm_no = "Отмена",
		reload_title = "ПЕРЕЗАГРУЗКА",
		reload_text = "Скрипт уже запущен. Перезагрузить? Текущая работа остановится, настройки сохранятся.",
		reload_yes = "Перезагрузить",
	},
	en = {
		v_on = "on",
		v_off = "off",
		log_copy = "copy log",
		log_btn = "log",
		log_copied = "Log copied (%d lines)",
		log_empty = "The log is empty",
		log_file = "Clipboard unavailable, log saved to file: %s",
		log_fail = "Could not copy the log",
		lang_label = "language",
		g_autopause = "autopause",
		g_watchdog = "stall protection",
		wd_stall = "%s: no progress for %d min, restarting the loop",
		wd_warn = "%s: no progress for %d min",
		paused = "paused (window inactive or game menu open)",
		confirm_title = "UNLOAD",
		confirm_text = "The hub, the core and all connected files (garden, fishing, mining) will be unloaded. Settings are kept.",
		confirm_yes = "Unload",
		confirm_no = "Cancel",
		reload_title = "RELOAD",
		reload_text = "The script is already running. Reload it? Current work will stop, settings are kept.",
		reload_yes = "Reload",
	},
}

function Core.addStrings(tbl)
	for lang, strings in pairs(tbl) do
		DICT[lang] = DICT[lang] or {}
		for k, v in pairs(strings) do
			DICT[lang][k] = v
		end
	end
end

function Core.t(key, ...)
	local d = DICT[data.lang] or DICT.en
	local s = d[key] or DICT.en[key] or key
	if select("#", ...) > 0 then
		local ok, r = pcall(string.format, s, ...)
		if ok then
			return r
		end
	end
	return s
end

function Core.getLang()
	return data.lang
end

local langListeners, binds = {}, {}

function Core.onLang(fn)
	langListeners[#langListeners + 1] = fn
	return function()
		local i = table.find(langListeners, fn)
		if i then
			table.remove(langListeners, i)
		end
	end
end

function Core.bindText(obj, key, ...)
	local args = table.pack(...)
	local function apply()
		obj.Text = Core.t(key, table.unpack(args, 1, args.n))
	end
	binds[#binds + 1] = { obj = obj, apply = apply }
	apply()
end

function Core.setLang(lang)
	if not DICT[lang] or lang == data.lang then
		return
	end
	data.lang = lang
	Core.save()
	for i = #binds, 1, -1 do
		local b = binds[i]
		if b.obj.Parent == nil then
			table.remove(binds, i)
		else
			pcall(b.apply)
		end
	end
	for _, fn in ipairs({ table.unpack(langListeners) }) do
		pcall(fn, lang)
	end
end

function Core.nextLang()
	local i = table.find(Core.LANGS, data.lang) or 0
	Core.setLang(Core.LANGS[i % #Core.LANGS + 1])
end

-- ============================================================
-- GUI helpers
-- ============================================================
local ui = {}
Core.ui = ui
ui.FONT, ui.FONT_BOLD = Enum.Font.Gotham, Enum.Font.GothamBold
ui.C = {
	BG = Color3.fromRGB(24, 24, 30),
	BTN = Color3.fromRGB(44, 44, 54),
	WHITE = Color3.fromRGB(235, 235, 240),
	GRAY = Color3.fromRGB(150, 150, 160),
	RED = Color3.fromRGB(170, 50, 50),
	GREEN = Color3.fromRGB(46, 160, 67),
	ORANGE = Color3.fromRGB(196, 130, 30),
	BLUE = Color3.fromRGB(60, 110, 200),
}
local C = ui.C

function ui.mk(class, parent, props)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = parent
	return o
end
local mk = ui.mk

function ui.round(o, r)
	mk("UICorner", o, { CornerRadius = UDim.new(0, r or 6) })
end

function ui.button(parent, props)
	props.BorderSizePixel, props.Text = 0, props.Text or ""
	props.Font = props.Font or ui.FONT_BOLD
	props.TextColor3 = props.TextColor3 or C.WHITE
	props.BackgroundColor3 = props.BackgroundColor3 or C.BTN
	local b = mk("TextButton", parent, props)
	ui.round(b)
	return b
end

function ui.label(parent, props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or ui.FONT
	props.TextColor3 = props.TextColor3 or C.WHITE
	props.TextSize = props.TextSize or 13
	return mk("TextLabel", parent, props)
end

local sg
function Core.gui()
	if Core.dead then
		return nil
	end
	if sg and sg.Parent then
		return sg
	end
	sg = Instance.new("ScreenGui")
	sg.Name, sg.ResetOnSpawn, sg.DisplayOrder = "HubCoreGui", false, 1000
	if not pcall(function()
		sg.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end) or not sg.Parent then
		sg.Parent = P:WaitForChild("PlayerGui")
	end
	return sg
end

-- ============================================================
-- Toasts
-- ============================================================
local toastHolder, toasts, toastN = nil, {}, 0
local KIND = { info = C.BLUE, ok = C.GREEN, warn = C.ORANGE, err = C.RED }

function Core.toast(text, kind, seconds)
	pcall(function()
		local g = Core.gui()
		if not g then
			return
		end
		if not (toastHolder and toastHolder.Parent) then
			toastHolder = mk("Frame", g, {
				Name = "Toasts", BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 0),
				AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.new(0.5, -150, 0, 10),
			})
			mk("UIListLayout", toastHolder, {
				Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
			})
		end
		toastN = toastN + 1
		local accent = KIND[kind or "info"] or C.BLUE
		local f = mk("Frame", toastHolder, {
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.BG,
			BackgroundTransparency = 0.05, BorderSizePixel = 0, LayoutOrder = toastN,
		})
		ui.round(f, 8)
		local stroke = mk("UIStroke", f, { Color = accent, Thickness = 1.5, Transparency = 0.2 })
		mk("UIPadding", f, {
			PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7),
			PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
		})
		local l = ui.label(f, {
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left, Text = tostring(text),
		})
		toasts[#toasts + 1] = f
		while #toasts > 4 do
			local old = table.remove(toasts, 1)
			pcall(old.Destroy, old)
		end
		task.delay(seconds or 3, function()
			pcall(function()
				local ti = TweenInfo.new(0.3)
				TweenService:Create(f, ti, { BackgroundTransparency = 1 }):Play()
				TweenService:Create(l, ti, { TextTransparency = 1 }):Play()
				TweenService:Create(stroke, ti, { Transparency = 1 }):Play()
				task.wait(0.35)
				local i = table.find(toasts, f)
				if i then
					table.remove(toasts, i)
				end
				f:Destroy()
			end)
		end)
	end)
end

-- ============================================================
-- Confirm window (v1.2): modal in the middle of the screen, fades in and out
--   Core.confirm{ titleKey=|title=, textKey=|text=, yesKey=|yes=, noKey=|no=, onYes=fn, onNo=fn }
-- ============================================================
local modal
local function pickText(o, name)
	if o[name .. "Key"] then
		return Core.t(o[name .. "Key"])
	end
	return tostring(o[name] or "")
end

function Core.confirm(o)
	local g = Core.gui()
	if not g then -- no GUI (core already unloaded): nothing to ask, just do it
		if o.onYes then
			task.spawn(o.onYes)
		end
		return
	end
	if modal and modal.Parent then
		pcall(modal.Destroy, modal)
	end
	local dim = mk("TextButton", g, {
		Name = "Confirm", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", AutoButtonColor = false, ZIndex = 50,
	})
	modal = dim -- the dim layer also swallows clicks, so nothing below can be pressed meanwhile
	local box = mk("CanvasGroup", dim, {
		Size = UDim2.fromOffset(300, 156), Position = UDim2.new(0.5, -150, 0.5, -78), BackgroundColor3 = C.BG,
		BorderSizePixel = 0, GroupTransparency = 1,
	})
	ui.round(box, 10)
	mk("UIStroke", box, { Color = C.ORANGE, Thickness = 1.5 })
	ui.label(box, {
		Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -24, 0, 20), TextSize = 15,
		Font = ui.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = pickText(o, "title"),
	})
	ui.label(box, {
		Position = UDim2.fromOffset(12, 36), Size = UDim2.new(1, -24, 0, 66), TextSize = 13, TextWrapped = true,
		TextColor3 = C.GRAY, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		Text = pickText(o, "text"),
	})
	local yes = ui.button(box, {
		Position = UDim2.fromOffset(12, 110), Size = UDim2.new(0.5, -18, 0, 34), TextSize = 14,
		BackgroundColor3 = C.RED, Text = pickText(o, "yes"),
	})
	local no = ui.button(box, {
		Position = UDim2.new(0.5, 6, 0, 110), Size = UDim2.new(0.5, -18, 0, 34), TextSize = 14,
		Text = pickText(o, "no"),
	})
	local closed = false
	local function close(cb)
		if closed then
			return
		end
		closed = true
		pcall(function()
			local ti = TweenInfo.new(0.12)
			TweenService:Create(box, ti, { GroupTransparency = 1 }):Play()
			TweenService:Create(dim, ti, { BackgroundTransparency = 1 }):Play()
		end)
		task.delay(0.15, function()
			pcall(dim.Destroy, dim)
		end)
		if cb then
			task.spawn(cb)
		end
	end
	yes.Activated:Connect(function()
		close(o.onYes)
	end)
	no.Activated:Connect(function()
		close(o.onNo)
	end)
	pcall(function()
		local ti = TweenInfo.new(0.15)
		TweenService:Create(box, ti, { GroupTransparency = 0 }):Play()
		TweenService:Create(dim, ti, { BackgroundTransparency = 0.5 }):Play()
	end)
end

-- ============================================================
-- Copy log
-- ============================================================
function Core.copyLog()
	local txt = Core.logText()
	if txt == "" then
		Core.toast(Core.t("log_empty"), "warn")
		return
	end
	local clip = setclipboard or toclipboard
	if type(clip) == "function" and pcall(clip, txt) then
		Core.toast(Core.t("log_copied", #logBuf), "ok")
		return
	end
	local path = FOLDER .. "/last_log.txt"
	if writeFile(path, txt) then
		Core.toast(Core.t("log_file", path), "warn", 5)
	else
		Core.toast(Core.t("log_fail"), "err")
	end
end

-- ============================================================
-- Panel: draggable window, header = title + [log] [lang] [X]
-- ============================================================
function Core.panel(opts)
	local g = Core.gui()
	local size = opts.size or Vector2.new(200, 150)
	local root = mk("Frame", g, {
		Size = UDim2.fromOffset(size.X, size.Y), Position = opts.pos or UDim2.new(0, 20, 0.5, -size.Y / 2),
		BackgroundColor3 = C.BG, BorderSizePixel = 0, Active = true, Draggable = true,
	})
	ui.round(root, 8)
	local title = ui.label(root, {
		Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -120, 0, 20), TextSize = 13,
		Font = ui.FONT_BOLD, TextColor3 = C.GRAY, TextXAlignment = Enum.TextXAlignment.Left,
	})
	if opts.titleKey then
		Core.bindText(title, opts.titleKey)
	end
	local closeBtn = ui.button(root, {
		Position = UDim2.new(1, -28, 0, 5), Size = UDim2.fromOffset(22, 20), BackgroundColor3 = C.RED,
		TextSize = 13, Text = "X",
	})
	local langBtn = ui.button(root, {
		Position = UDim2.new(1, -66, 0, 5), Size = UDim2.fromOffset(32, 20), TextSize = 11,
	})
	local logBtn = ui.button(root, {
		Position = UDim2.new(1, -108, 0, 5), Size = UDim2.fromOffset(38, 20), TextSize = 11,
	})
	Core.bindText(logBtn, "log_btn")
	langBtn.Text = Core.getLang():upper()
	Core.onLang(function(l)
		if langBtn.Parent then
			langBtn.Text = l:upper()
		end
	end)
	langBtn.Activated:Connect(Core.nextLang)
	logBtn.Activated:Connect(Core.copyLog)
	if opts.onClose then
		closeBtn.Activated:Connect(function()
			Core.confirm({
				titleKey = "confirm_title", textKey = "confirm_text", yesKey = "confirm_yes", noKey = "confirm_no",
				onYes = opts.onClose,
			})
		end)
	end
	local body = mk("Frame", root, {
		Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 1, -30), BackgroundTransparency = 1,
	})
	return { root = root, body = body, title = title, close = closeBtn }
end

-- ============================================================
-- Autopause, watchdog, respawn (v1.1)
-- ============================================================
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local focused = true
UIS.WindowFocused:Connect(function()
	focused = true
end)
UIS.WindowFocusReleased:Connect(function()
	focused = false
end)

function Core.paused()
	if not Core.getGlobal("autopause", false) then
		return false
	end
	local menu = false
	pcall(function()
		menu = GuiService.MenuIsOpen
	end)
	return (not focused) or menu
end

function Core.watchdog(scope, o)
	local name = o.name or "farm"
	local lastProg, lastT, warned = nil, os.clock(), false
	local alive = true
	scope.onCleanup(function()
		alive = false
	end)
	task.spawn(function()
		while alive and scope.alive() and not Core.dead do
			task.wait(5)
			local now = os.clock()
			local mins = o.minutes or Core.getGlobal("stallMin", 5)
			local prog = o.getProgress and o.getProgress() or 0
			local active = (not o.isActive) or o.isActive()
			if not active or Core.paused() or not Core.getGlobal("watchdog", true) or prog ~= lastProg then
				lastProg, lastT, warned = prog, now, false
			elseif now - lastT >= mins * 60 then
				Core.log("WD", "%s: no progress for %d min", name, mins)
				if o.onStall then
					Core.toast(Core.t("wd_stall", name, mins), "warn", 5)
					pcall(o.onStall)
				else
					Core.toast(Core.t("wd_warn", name, mins), "warn", 5)
				end
				lastT = now
			end
		end
	end)
end

function Core.onRespawn(scope, fn)
	return scope.connect(P.CharacterAdded, function(ch)
		Core.log("CORE", "respawn detected")
		task.spawn(fn, ch)
	end)
end

-- ============================================================
-- Scopes: the unload mechanism of a farm (connections + cleanup callbacks)
-- ============================================================
function Core.newScope()
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
		if s.dead then
			return
		end
		s.dead = true
		for _, c in ipairs(s.conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		for _, f in ipairs(s.fns) do
			pcall(f)
		end
		if s.after then
			pcall(s.after) -- Core.launch hangs the UNLOAD line here
		end
	end
	return s
end

-- runs a farm script (source text) with a fresh scope in STATE
function Core.launch(name, src)
	if Core.farmScope then
		pcall(Core.farmScope.stop)
	end
	local scope = Core.newScope()
	Core.farmScope, Core.farmName = scope, name
	scope.after = function()
		Core.logUnload(name)
	end
	env.STATE = scope
	pcall(function()
		_G.STATE = scope
	end)
	local fn, err = loadstring(src, "=" .. name)
	if not fn then
		Core.log("CORE", "compile error in %s: %s", name, tostring(err))
		return false, tostring(err)
	end
	Core.logLoad(name)
	task.spawn(function()
		local ok, e = pcall(fn)
		if not ok then
			Core.log("CORE", "runtime error in %s: %s", name, tostring(e))
			Core.toast(name .. ": " .. tostring(e), "err", 6)
		end
	end)
	return true
end

-- ============================================================
-- Modules (v1.3): add-on of the running farm, nested scope inside the farm scope
-- ============================================================
Core.modules = {}

function Core.launchModule(name, src)
	local farm = Core.farmScope
	if not farm or farm.dead then
		return false, "no running farm"
	end
	local fn, err = loadstring(src, "=" .. name)
	if not fn then
		Core.log("CORE", "compile error in %s: %s", name, tostring(err))
		return false, tostring(err)
	end
	if Core.modules[name] then
		pcall(Core.modules[name].stop)
	end
	local scope = Core.newScope()
	Core.modules[name] = scope
	scope.after = function()
		Core.logUnload(name)
		if Core.modules[name] == scope then
			Core.modules[name] = nil
		end
	end
	farm.onCleanup(scope.stop) -- farm stops -> module stops first
	Core.logLoad(name)
	task.spawn(function()
		local ok, e = pcall(fn, scope, farm)
		if not ok then
			Core.log("CORE", "runtime error in %s: %s", name, tostring(e))
			Core.toast(name .. ": " .. tostring(e), "err", 6)
		end
	end)
	return true
end

function Core.unloadModule(name)
	local s = Core.modules[name]
	if s then
		pcall(s.stop)
	end
end

-- ============================================================
-- Unload
-- ============================================================
function Core.unload()
	if Core.dead then
		return
	end
	Core.dead = true
	if Core.farmScope then
		pcall(Core.farmScope.stop)
	end
	Core.save(true)
	Core.logUnload("hub")
	pcall(function()
		if sg then
			sg:Destroy()
		end
	end)
	if env.HubCore == Core then
		env.HubCore = nil
	end
end

Core.logLoad("core " .. Core.VERSION)
return Core
-- AutoFarm Hub v3.0
-- v3: no start-up log lines (only "[LOAD] x" / "[UNLOAD] x"), a confirm window before every unload, and running the hub
-- again asks "reload?" instead of silently resetting. Rod / bait / food features of fishing come after the game scan.
-- Menu: [Autofarm] [Settings]. Autofarm opens a side list of 3 farms; after the choice the hub removes
-- its own menu and loads the chosen farm script. v2: garden, fishing and mining are all connected.
--
-- Run this file only:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/YOURNAME/YOURREPO/main/hub.luau"))()
-- BASE is the folder with core.luau and the farm files. For local testing put the files into the
-- executor's workspace folder and set BASE = "AutoFarmHub/files/" (anything not starting with "http"
-- is read with readfile).

local BASE = "https://raw.githubusercontent.com/misavasilevic041-tech/script/refs/heads/main/"

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

local env = (getgenv and getgenv()) or _G

local function main()
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
			hub_global = "Общие настройки",
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
			hub_global = "Global settings",
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

	-- settings (side panel): language, copy log, unload hub
	local setSide = sideFrame(214)
	sides.settings = setSide
	local langBtn = ui.button(setSide, {
		Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 34), TextSize = 14, Font = ui.FONT,
	})
	local function updLang()
		langBtn.Text = T("lang_label") .. ": " .. Core.getLang():upper()
	end
	updLang()
	Core.onLang(updLang)
	langBtn.Activated:Connect(Core.nextLang)

	local copyBtn = ui.button(setSide, {
		Position = UDim2.fromOffset(8, 48), Size = UDim2.new(1, -16, 0, 34), TextSize = 14, Font = ui.FONT,
	})
	Core.bindText(copyBtn, "log_copy")
	copyBtn.Activated:Connect(Core.copyLog)

	-- global toggles (saved in the settings file, read by the farms through Core)
	local function globalToggle(y, key, default, labelKey)
		local b = ui.button(setSide, {
			Position = UDim2.fromOffset(8, y), Size = UDim2.new(1, -16, 0, 34), TextSize = 13, Font = ui.FONT,
		})
		local function upd()
			local on = Core.getGlobal(key, default)
			b.Text = T(labelKey) .. ": " .. T(on and "v_on" or "v_off")
			b.BackgroundColor3 = on and C.GREEN or C.BTN
		end
		upd()
		Core.onLang(upd)
		b.Activated:Connect(function()
			Core.setGlobal(key, not Core.getGlobal(key, default))
			upd()
		end)
	end
	globalToggle(88, "autopause", false, "g_autopause")
	globalToggle(128, "watchdog", true, "g_watchdog")

	local unloadBtn = ui.button(setSide, {
		Position = UDim2.fromOffset(8, 172), Size = UDim2.new(1, -16, 0, 30), TextSize = 13, Font = ui.FONT,
		BackgroundColor3 = C.RED,
	})
	Core.bindText(unloadBtn, "hub_unload")
	unloadBtn.Activated:Connect(function()
		Core.confirm({
			titleKey = "confirm_title", textKey = "confirm_text", yesKey = "confirm_yes", noKey = "confirm_no",
			onYes = Core.unload,
		})
	end)

	mainButton(6, "hub_autofarm", function()
		showSide("farms")
	end)
	mainButton(52, "hub_settings", function()
		showSide("settings")
	end)

	Core.logLoad("hub 3.0")
	Core.toast(T("hub_ready"), "ok", 2)
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
