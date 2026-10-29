-- AutoFarm Hub: shared module (Core) v1.0
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

local env = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local P = Players.LocalPlayer

-- a second run replaces the first one completely
if env.HubCore and env.HubCore.unload then
	pcall(env.HubCore.unload)
end

local Core = { VERSION = "1.0", dead = false }
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

-- ============================================================
-- Settings (saved to AutoFarmHub/settings.json)
-- ============================================================
local FOLDER, FILE = "AutoFarmHub", "AutoFarmHub/settings.json"
local fsOk = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local data = { lang = "ru", farms = {} }

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
		closeBtn.Activated:Connect(opts.onClose)
	end
	local body = mk("Frame", root, {
		Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 1, -30), BackgroundTransparency = 1,
	})
	return { root = root, body = body, title = title, close = closeBtn }
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
	env.STATE = scope
	pcall(function()
		_G.STATE = scope
	end)
	local fn, err = loadstring(src, "=" .. name)
	if not fn then
		Core.log("CORE", "compile error in %s: %s", name, tostring(err))
		return false, tostring(err)
	end
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
	pcall(function()
		if sg then
			sg:Destroy()
		end
	end)
	if env.HubCore == Core then
		env.HubCore = nil
	end
end

Core.log("CORE", "core v%s loaded, language=%s, settings file %s", Core.VERSION, data.lang, fsOk and "available" or "unavailable")
return Core
