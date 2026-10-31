--[[ ============================================================
 AutoFarm Hub · core.luau · v3.2   (@version 3.2)
 Part of the AutoFarm Hub project: hub.luau (the only file the user runs), core.luau (this file, shared module),
 garden.luau, fishing.luau, mining.luau (farms), versions.json (version list), lang.luau (optional extra languages).
 Needs an executor with: loadstring, game:HttpGet, writefile/readfile/isfile (for saved settings), gethui (optional).
 See README.md for the file layout and how to add a language.
============================================================ ]]
-- AutoFarm Hub: shared module (Core) v3.0
-- v3.2: the unload warning covers the whole panel (like the fishing one): [Cancel (3)] counts down, then everything unloads by itself.
--   Core.confirm{ parent = panelFrame, countdown = 3, ... }; without parent: a small window in the middle of the screen (Yes / No).
--   Every element has an explicit ZIndex (the children of the dialog were hidden behind it).
-- v3.0 (hub v4.0, cosmetics): themes (dark / light + accent colour), remembered panel positions, hotkey + floating button
--   to show / hide the whole interface, anti-AFK, unified farm panel (dock: ON/OFF, speed, settings, stats, buff timer,
--   last 20 log lines), generic respawn handling, new languages through Core.addStrings (the language list grows by itself),
--   Core.info window (About), full clean-up of getgenv on unload.
--   Farm hooks (all optional, set by a farm script):  Core.farmHooks = {
--       isOn = fn -> bool, toggle = fn, settings = fn (opens / closes the farm's own menu),
--       speed = { label = fn -> string, next = fn }, stats = fn -> { count = n, coins = n|nil, unitKey = "u_mined" },
--       onRespawn = fn(character) }
--   Core.registerGui(screenGui)   a farm with its own ScreenGui joins the theme + the hide / show hotkey
--   Core.rememberPos(frame, key)  saves / restores the position of a draggable frame
--   Core.setTheme("dark"|"light") / Core.setAccent(name) / Core.ACCENT_LIST
--   Core.setVisible(bool) / Core.toggleVisible()   Core.info{title|titleKey, text|textKey}
-- v2.1: English default on first run, console log off by default, confirm dialog has no full-screen dim layer.
-- Provides: languages, settings saving, log, toasts, panel, copy-log button, farm scopes, buff (cooking) system,
-- the small dock window of a running farm (back to the hub + buff controls).
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
--   v2.0 (the module system of v1.3 is removed; buff and languages live here, one system for all farms):
--   Core.buffBusy()               true while the buff wants the player's hands (waiting for a safe moment, cooking, dish in hand);
--                                 a farm that swaps tools itself (fishing: the rod) must not do it while this is true
--   Core.buffSafe                 optional hook a farm sets: fn -> bool, "tools can be swapped right now" (default: always)
--   Core.farmActive               optional hook a farm sets: fn -> bool, "the farm is switched on" (the buff cooks only then)
--   Core.toggleHub                set by the hub: opens / closes the hub menu without touching the running farm
--   Buff settings per farm (saved as "buff_<farm>"): on / dish / lead (cook when the buff has <= lead seconds left)
--   Dock window: [Hub] button, buff on/off, status line, dish choice, lead time. Created with every farm, destroyed with it.

local env = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local P = Players.LocalPlayer

-- a second run replaces the first one completely
if env.HubCore and env.HubCore.unload then
	pcall(env.HubCore.unload)
end

local Core = { VERSION = "3.2", dead = false }
env.HubCore = Core

local UIS = game:GetService("UserInputService")
local coreConns, guis, extraThemed = {}, {}, {} -- core-wide connections (disconnected on unload) and every registered ScreenGui
local function addConn(c)
	coreConns[#coreConns + 1] = c
	return c
end

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
	-- console output is OFF by default (hub settings: console log); the buffer for [copy log] always fills
	local gg = Core.getGlobal
	if gg and gg("console_log", false) then
		print("[" .. tag .. "] " .. s)
	end
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
local data = { lang = "en", farms = {}, global = {} } -- first run (no settings file): English

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
Core.LANGS = { "en", "ru" }
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
		g_console = "лог в консоль",
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
		dock_hub = "☰ Хаб",
		buff_label = "Бафф",
		buff_off = "бафф выключен",
		buff_none = "бафф: нет",
		buff_left = "бафф: %s",
		buff_wait = "жду паузу в работе…",
		buff_cooking = "готовлю: %s",
		buff_dish = "блюдо: %s",
		buff_lead = "готовить за %d с",
		buff_eat = "Съешь блюдо сейчас!",
		buff_cooked = "Блюдо готово и в руке",
		buff_no_fish = "Нет рыбы для блюда «%s»",
		buff_fail = "Готовка не удалась: %s",
		buff_multi = "В инвентаре несколько блюд: съешь лишнее или сделай ресет",
		buff_other = "В инвентаре другое блюдо (%s), готовка пропущена",
		buff_stuck = "Не дождался паузы в работе, повторю позже",
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
		g_console = "console log",
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
		dock_hub = "☰ Hub",
		buff_label = "Buff",
		buff_off = "buff is off",
		buff_none = "buff: none",
		buff_left = "buff: %s",
		buff_wait = "waiting for a pause…",
		buff_cooking = "cooking: %s",
		buff_dish = "dish: %s",
		buff_lead = "cook at %d s left",
		buff_eat = "Eat the dish now!",
		buff_cooked = "Dish is ready and in your hand",
		buff_no_fish = "No fish for the dish \"%s\"",
		buff_fail = "Cooking failed: %s",
		buff_multi = "Several dishes in the inventory: eat the extra one or reset",
		buff_other = "Another dish is in the inventory (%s), cooking skipped",
		buff_stuck = "No pause in the work came, will try again later",
	},
}

function Core.addStrings(tbl)
	for lang, strings in pairs(tbl) do
		if not table.find(Core.LANGS, lang) then
			Core.LANGS[#Core.LANGS + 1] = lang -- a new language pack (lang.luau): it appears in the language button at once
		end
		DICT[lang] = DICT[lang] or {}
		for k, v in pairs(strings) do
			DICT[lang][k] = v
		end
	end
end


-- v3.0 strings (core): panel, themes, hotkey, stats, about
Core.addStrings({
	ru = {
		unload_title = "ВЫГРУЗКА СКРИПТА", unload_text = "Всё будет остановлено и выгружено.",
		u_items = "предметов", u_mined = "добыто", u_harvest = "собрано", u_caught = "поймано",
		st_line1 = "%s · %s: %s", st_rate = "%s/ч", st_coins = "%s монет/ч", st_wait = "фарм выключен",
		dock_speed = "скорость: %s", dock_log = "журнал", dock_log_hide = "журнал ▴", dock_copy = "копировать лог",
		dock_log_empty = "журнал пуст",
		respawn_cont = "Персонаж возродился, фарм продолжает работу",
		theme_label = "тема", theme_dark = "тёмная", theme_light = "светлая", accent_label = "акцент",
		hotkey_label = "кнопка меню", fab_label = "плавающая кнопка", afk_label = "антиафк",
		about_btn = "о проекте", upd_btn = "проверить обновления", info_close = "Закрыть",
		ui_hidden = "Интерфейс скрыт, вернуть: %s",
	},
	en = {
		unload_title = "UNLOAD SCRIPT", unload_text = "Everything will be stopped and unloaded.",
		u_items = "items", u_mined = "mined", u_harvest = "harvested", u_caught = "caught",
		st_line1 = "%s · %s: %s", st_rate = "%s/h", st_coins = "%s coins/h", st_wait = "farm is off",
		dock_speed = "speed: %s", dock_log = "log", dock_log_hide = "log ▴", dock_copy = "copy log",
		dock_log_empty = "the log is empty",
		respawn_cont = "Character respawned, the farm keeps working",
		theme_label = "theme", theme_dark = "dark", theme_light = "light", accent_label = "accent",
		hotkey_label = "menu key", fab_label = "floating button", afk_label = "anti-AFK",
		about_btn = "about", upd_btn = "check for updates", info_close = "Close",
		ui_hidden = "Interface hidden, show again: %s",
	},
})

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
local function parentGui(g)
	if not pcall(function()
		g.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end) or not g.Parent then
		g.Parent = P:WaitForChild("PlayerGui")
	end
end

local hidden = false
function Core.gui()
	if Core.dead then
		return nil
	end
	if sg and sg.Parent then
		return sg
	end
	sg = Instance.new("ScreenGui")
	sg.Name, sg.ResetOnSpawn, sg.DisplayOrder = "HubCoreGui", false, 1000
	sg.Enabled = not hidden
	parentGui(sg)
	guis[#guis + 1] = sg
	return sg
end


-- ============================================================
-- Themes (v3.0): ui.C is changed IN PLACE, so every script that holds `local C = ui.C` follows the theme.
-- Existing GUI objects are recoloured by colour: an object that has a role colour gets the new role colour.
-- ============================================================
local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end
local THEMES = {
	dark = { BG = rgb(24, 24, 30), BTN = rgb(44, 44, 54), WHITE = rgb(235, 235, 240), GRAY = rgb(150, 150, 160),
		RED = rgb(170, 50, 50), ORANGE = rgb(196, 130, 30), BLUE = rgb(60, 110, 200) },
	light = { BG = rgb(238, 238, 244), BTN = rgb(206, 206, 220), WHITE = rgb(26, 26, 32), GRAY = rgb(92, 92, 106),
		RED = rgb(224, 108, 108), ORANGE = rgb(232, 172, 72), BLUE = rgb(108, 148, 224) },
}
local ACCENTS = {
	green = { dark = rgb(46, 160, 67), light = rgb(98, 196, 118) },
	blue = { dark = rgb(34, 138, 222), light = rgb(96, 176, 240) },
	purple = { dark = rgb(138, 84, 214), light = rgb(184, 148, 240) },
	pink = { dark = rgb(206, 72, 138), light = rgb(240, 148, 190) },
	teal = { dark = rgb(30, 160, 160), light = rgb(104, 206, 206) },
}
Core.ACCENT_LIST = { "green", "blue", "purple", "pink", "teal" }
Core.THEME_LIST = { "dark", "light" }
local ROLES = { "BG", "BTN", "WHITE", "GRAY", "RED", "ORANGE", "BLUE", "GREEN" }
-- hard-coded dark colours of older farm scripts -> the role they stand for
local ALIAS = {
	["26,26,32"] = "BG", ["48,48,58"] = "BTN", ["140,140,150"] = "GRAY", ["120,36,36"] = "RED",
	["40,110,200"] = "BLUE", ["215,110,30"] = "ORANGE",
}
local function ckey(c)
	return string.format("%d,%d,%d", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local function paletteFor(theme, accent)
	local p = {}
	for k, v in pairs(THEMES[theme]) do
		p[k] = v
	end
	p.GREEN = ACCENTS[accent][theme]
	return p
end
local function recolor(root, map)
	local function fix(o)
		pcall(function()
			if o:IsA("GuiObject") then
				local n = map[ckey(o.BackgroundColor3)]
				if n then
					o.BackgroundColor3 = n
				end
				if o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox") then
					local n2 = map[ckey(o.TextColor3)]
					if n2 then
						o.TextColor3 = n2
					end
				end
			elseif o:IsA("UIStroke") then
				local n = map[ckey(o.Color)]
				if n then
					o.Color = n
				end
			end
		end)
	end
	fix(root)
	for _, d in ipairs(root:GetDescendants()) do
		fix(d)
	end
end

local function currentNames()
	local theme, accent = Core.getGlobal("theme", "dark"), Core.getGlobal("accent", "green")
	if not THEMES[theme] then
		theme = "dark"
	end
	if not ACCENTS[accent] then
		accent = "green"
	end
	return theme, accent
end

function Core.applyTheme()
	local theme, accent = currentNames()
	local old, new, map = {}, paletteFor(theme, accent), {}
	for _, r in ipairs(ROLES) do
		old[r] = C[r]
	end
	for k, role in pairs(ALIAS) do
		map[k] = new[role]
	end
	for _, r in ipairs(ROLES) do
		map[ckey(old[r])] = new[r]
	end
	for _, r in ipairs(ROLES) do
		C[r] = new[r]
	end
	for i = #guis, 1, -1 do
		local g = guis[i]
		if g.Parent then
			recolor(g, map)
		else
			table.remove(guis, i)
		end
	end
	for _, g in ipairs(extraThemed) do
		if g.Parent then
			recolor(g, map)
		end
	end
end

function Core.setTheme(name)
	if not THEMES[name] then
		return
	end
	Core.setGlobal("theme", name)
	Core.applyTheme()
end

function Core.setAccent(name)
	if not ACCENTS[name] then
		return
	end
	Core.setGlobal("accent", name)
	Core.applyTheme()
end

-- a farm with its own ScreenGui: it follows the theme and the hide / show hotkey
function Core.registerGui(g)
	if not g or table.find(guis, g) then
		return
	end
	guis[#guis + 1] = g
	pcall(function()
		g.Enabled = not hidden
	end)
	local map = {}
	for k, role in pairs(ALIAS) do
		map[k] = C[role]
	end
	local theme, accent = "dark", "green"
	local base = paletteFor(theme, accent)
	for _, r in ipairs(ROLES) do
		map[ckey(base[r])] = C[r]
	end
	recolor(g, map)
end

do -- the saved theme is applied before the first GUI object is created
	Core.applyTheme()
end

-- ============================================================
-- Remembered position of a draggable frame (v3.0). Saved in the settings file under "pos_<key>".
-- ============================================================
function Core.rememberPos(frame, key)
	local saved = Core.getGlobal("pos_" .. key, {})
	if type(saved.xo) == "number" and type(saved.yo) == "number" then
		local cam = workspace.CurrentCamera
		local v = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local w, h = math.max(frame.Size.X.Offset, 40), math.max(frame.Size.Y.Offset, 40)
		local ax = (saved.xs or 0) * v.X + saved.xo
		local ay = (saved.ys or 0) * v.Y + saved.yo
		ax = math.clamp(ax, 0, math.max(0, v.X - w))
		ay = math.clamp(ay, 0, math.max(0, v.Y - h))
		frame.Position = UDim2.fromOffset(ax, ay)
	end
	local tok = 0
	frame:GetPropertyChangedSignal("Position"):Connect(function()
		tok = tok + 1
		local mine = tok
		task.delay(0.6, function()
			if mine == tok and frame.Parent and not Core.dead then
				local p = frame.Position
				Core.setGlobal("pos_" .. key, { xs = p.X.Scale, xo = p.X.Offset, ys = p.Y.Scale, yo = p.Y.Offset })
			end
		end)
	end)
end

-- ============================================================
-- Show / hide the whole interface (hotkey, floating button)
-- ============================================================
function Core.setVisible(v)
	hidden = not v
	for _, g in ipairs(guis) do
		pcall(function()
			g.Enabled = v
		end)
	end
end

function Core.toggleVisible()
	Core.setVisible(hidden)
	if hidden then
		Core.log("UI", "hidden")
	end
end

-- ============================================================
-- Toasts
-- ============================================================
local toastHolder, toasts, toastN = nil, {}, 0
local KIND = { info = "BLUE", ok = "GREEN", warn = "ORANGE", err = "RED" }

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
		local accent = C[KIND[kind or "info"] or "BLUE"]
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
	-- o.parent = a panel: the warning covers it completely (v3.2); without it a small window in the middle of the screen
	local cover = o.parent and o.parent.Parent and o.parent or nil
	local W, H = 300, 156
	if cover then
		W, H = cover.Size.X.Offset, cover.Size.Y.Offset
	end
	local box = mk("Frame", cover or g, {
		Name = "Confirm", Size = cover and UDim2.fromScale(1, 1) or UDim2.fromOffset(W, H),
		Position = cover and UDim2.new() or UDim2.new(0.5, -W / 2, 0.5, -H / 2),
		BackgroundColor3 = C.BG, BorderSizePixel = 0, Active = true,
	})
	modal = box
	ui.round(box, cover and 8 or 10)
	mk("UIStroke", box, { Color = o.countdown and C.RED or C.ORANGE, Thickness = 1.5 })
	ui.label(box, {
		Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 18), TextSize = 14,
		Font = ui.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = pickText(o, "title"),
	})
	ui.label(box, {
		Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -20, 0, math.max(20, H - 26 - 42)), TextSize = 12,
		TextWrapped = true, TextColor3 = C.GRAY, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, Text = pickText(o, "text"),
	})
	local by = H - 38
	local yes, no
	if o.countdown then -- one wide [Cancel (3)] button: when the count reaches zero the action runs by itself
		no = ui.button(box, { Position = UDim2.fromOffset(10, by), Size = UDim2.new(1, -20, 0, 30), TextSize = 14 })
	else
		yes = ui.button(box, {
			Position = UDim2.fromOffset(10, by), Size = UDim2.new(0.5, -14, 0, 30), TextSize = 13,
			BackgroundColor3 = C.RED, Text = pickText(o, "yes"),
		})
		no = ui.button(box, {
			Position = UDim2.new(0.5, 4, 0, by), Size = UDim2.new(0.5, -14, 0, 30), TextSize = 13, Text = pickText(o, "no"),
		})
	end
	-- explicit ZIndex everywhere: nothing of the panel underneath may draw over the warning or take its clicks
	box.ZIndex = 100
	for _, d in ipairs(box:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = 101
		end
	end
	local closed = false
	local function close(cb)
		if closed then
			return
		end
		closed = true
		pcall(box.Destroy, box)
		if cb then
			task.spawn(cb)
		end
	end
	if yes then
		yes.Activated:Connect(function()
			close(o.onYes)
		end)
	end
	no.Activated:Connect(function()
		close(o.onNo)
	end)
	if o.countdown then
		task.spawn(function()
			for i = o.countdown, 1, -1 do
				if closed then
					return
				end
				no.Text = pickText(o, "no") .. " (" .. i .. ")"
				task.wait(1)
			end
			close(o.onYes)
		end)
	end
end

-- ============================================================
-- Info window (v3.0): title + scrolling rich text + [Close]. Used for "About".
--   Core.info{ titleKey=|title=, textKey=|text=, closeKey= }
-- ============================================================
local infoBox
function Core.info(o)
	local g = Core.gui()
	if not g then
		return
	end
	if infoBox and infoBox.Parent then
		pcall(infoBox.Destroy, infoBox)
	end
	local box = mk("Frame", g, {
		Name = "Info", Size = UDim2.fromOffset(340, 300), Position = UDim2.new(0.5, -170, 0.5, -150),
		BackgroundColor3 = C.BG, BorderSizePixel = 0, Active = true, Draggable = true, ZIndex = 60,
	})
	infoBox = box
	ui.round(box, 10)
	mk("UIStroke", box, { Color = C.GREEN, Thickness = 1.5 })
	ui.label(box, {
		Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 22), TextSize = 15,
		Font = ui.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = pickText(o, "title"),
	})
	local scroll = mk("ScrollingFrame", box, {
		Position = UDim2.fromOffset(10, 36), Size = UDim2.new(1, -20, 1, -88), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 3, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
	})
	ui.label(scroll, {
		Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.WHITE, Text = pickText(o, "text"),
	})
	local close = ui.button(box, {
		Position = UDim2.new(0, 12, 1, -42), Size = UDim2.new(1, -24, 0, 32), TextSize = 14,
		BackgroundColor3 = C.GREEN, Text = o.closeKey and Core.t(o.closeKey) or Core.t("info_close"),
	})
	close.Activated:Connect(function()
		pcall(box.Destroy, box)
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
	if opts.posKey then
		Core.rememberPos(root, opts.posKey)
	end
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
				parent = root, countdown = 3, titleKey = "unload_title", textKey = "unload_text", noKey = "confirm_no",
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
local GuiService = game:GetService("GuiService")
local focused = true
addConn(UIS.WindowFocused:Connect(function()
	focused = true
end))
addConn(UIS.WindowFocusReleased:Connect(function()
	focused = false
end))

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


-- ============================================================
-- Anti-AFK (v3.0): the standard Idled trick, no visible actions. Hub setting "antiafk" (default on).
-- ============================================================
do
	local VU = game:GetService("VirtualUser")
	addConn(P.Idled:Connect(function()
		if not Core.getGlobal("antiafk", true) then
			return
		end
		pcall(function()
			VU:CaptureController()
			VU:ClickButton2(Vector2.new())
		end)
	end))
end

-- ============================================================
-- Hotkey + floating button (v3.0): show / hide every GUI of the project
-- ============================================================
Core.HOTKEYS = { "RightShift", "RightControl", "Insert", "Home", "F6" }
addConn(UIS.InputBegan:Connect(function(input, processed)
	if processed or Core.dead then
		return
	end
	if input.KeyCode and input.KeyCode.Name == Core.getGlobal("hotkey", "RightShift") then
		Core.toggleVisible()
	end
end))

local fabGui
function Core.updateFab()
	local want = Core.getGlobal("fab", UIS.TouchEnabled and not UIS.KeyboardEnabled)
	if not want or Core.dead then
		if fabGui then
			pcall(fabGui.Destroy, fabGui)
			fabGui = nil
		end
		return
	end
	if fabGui and fabGui.Parent then
		return
	end
	fabGui = Instance.new("ScreenGui")
	fabGui.Name, fabGui.ResetOnSpawn, fabGui.DisplayOrder = "HubCoreFab", false, 1001
	parentGui(fabGui)
	extraThemed[#extraThemed + 1] = fabGui
	local b = ui.button(fabGui, {
		Size = UDim2.fromOffset(40, 40), Position = UDim2.new(0, 8, 0.5, -20), TextSize = 20, Text = "☰",
		BackgroundColor3 = C.GREEN, Active = true, Draggable = true,
	})
	b.BackgroundTransparency = 0.15
	ui.round(b, 20)
	Core.rememberPos(b, "fab")
	local downAt
	b.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
			downAt = b.AbsolutePosition
		end
	end)
	b.Activated:Connect(function()
		if downAt and (b.AbsolutePosition - downAt).Magnitude > 6 then
			return -- it was a drag, not a tap
		end
		Core.toggleVisible()
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

-- ============================================================
-- Buff (v2.0): semi-automatic cooking helper, one system for all farms.
-- Shortly before the food buff ends it cooks the dish of the farm, takes it into the hand and asks the player to
-- eat it (eating is a real click, scripts cannot do it). Never more than one dish at a time: with a dish already in
-- the inventory nothing is cooked. Protocol: ToolEvent Get "Frying Pan" -> CookingRemotes.GetState / Start / Finish /
-- UseDish("Equip"). Buff timer: player attribute FoodBuffExpiresAt (server time).
-- Only "GrilledFish" is confirmed in the game; the other recipe ids are built the same way and are untested:
-- a wrong id just ends in a "cooking failed" message from the server.
-- ============================================================
local RS = game:GetService("ReplicatedStorage")

local BUFF = {
	fishing = { { recipe = "GrilledFish", tool = "Grilled Fish", needFish = true } },
	mining = { { recipe = "BreadRoll", tool = "Bread Roll" }, { recipe = "Onigiri", tool = "Onigiri" } },
	garden = { { recipe = "Taco", tool = "Taco" } },
}
local PAN = "Frying Pan"
local DISH_NAMES = {} -- every known dish tool, so that a second dish is never cooked
for _, n in ipairs({
	"Grilled Fish", "Sushi", "Squid Nigiri", "Tuna Nigiri", "Bonito Roll", "Ramen",
	"Taco", "Veggie Sandwich", "Vegetable Noodles", "Veggie Burger", "Tomato Pizza",
	"French Fries", "Bread Roll", "Onigiri", "Croissant",
	"Pancakes", "Donuts", "Cupcake", "Lemon Muffin", "Fruit Cake", "Apple Pie",
}) do
	DISH_NAMES[n] = true
end
local LEADS = { 15, 30, 45, 60 }
local REMIND_EVERY, REMIND_MAX, RETRY_AFTER, SAFE_WAIT = 10, 6, 120, 90

local B = { want = false, hold = false, msg = nil, msgUntil = 0 }

-- true while the buff needs the player's hands: farms must not swap tools / start a new action meanwhile
function Core.buffBusy()
	return B.want or B.hold
end

local function farmActive(farm)
	if Core.farmActive then
		local ok, r = pcall(Core.farmActive)
		if ok then
			return r ~= false
		end
	end
	local a = (farm == "fishing" and env.AF) or (farm == "garden" and env.AFARM)
	if type(a) == "table" then
		return a.enabled == true
	end
	return true
end

local function startBuff(scope, farm)
	local options = BUFF[farm]
	if not options then
		return
	end
	B.want, B.hold, B.msg = false, false, nil
	local cfg = Core.getFarm("buff_" .. farm, { on = false, dish = options[1].recipe, lead = 30 })
	local function save()
		Core.setFarm("buff_" .. farm, cfg)
	end
	local function optOf(id)
		for _, o in ipairs(options) do
			if o.recipe == id then
				return o
			end
		end
		return options[1]
	end
	local function setMsg(text, secs)
		B.msg, B.msgUntil = text, os.clock() + (secs or 6)
	end

	-- ----- tools -----
	local function eachHolder(fn)
		local c = P.Character
		if c then
			fn(c)
		end
		local bp = P:FindFirstChildOfClass("Backpack")
		if bp then
			fn(bp)
		end
	end
	local function findTool(name)
		local found
		eachHolder(function(h)
			if not found then
				local t = h:FindFirstChild(name)
				if t and t:IsA("Tool") then
					found = t
				end
			end
		end)
		return found
	end
	local function dishes()
		local list = {}
		eachHolder(function(h)
			for _, t in ipairs(h:GetChildren()) do
				if t:IsA("Tool") and DISH_NAMES[t.Name] then
					list[#list + 1] = t
				end
			end
		end)
		return list
	end
	local function equip(tool)
		local hum = P.Character and P.Character:FindFirstChildOfClass("Humanoid")
		if hum and tool then
			pcall(function()
				hum:EquipTool(tool)
			end)
		end
	end
	local function buffLeft()
		local e = P:GetAttribute("FoodBuffExpiresAt")
		if type(e) ~= "number" then
			return 0
		end
		return math.max(0, e - workspace:GetServerTimeNow())
	end
	local function inv(remote, ...)
		local args = table.pack(...)
		local ok, res = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		return ok and res or nil
	end

	-- ----- cooking: returns the dish tool, or nil + reason -----
	local function cook(opt)
		local CK = RS:FindFirstChild("CookingRemotes")
		if not CK then
			return nil, "CookingRemotes"
		end
		local pan = findTool(PAN)
		if not pan then
			pcall(function()
				RS.Events.ToolEvent:FireServer("Get", PAN)
			end)
			for _ = 1, 30 do
				pan = findTool(PAN)
				if pan then
					break
				end
				task.wait(0.1)
			end
		end
		if not pan then
			return nil, PAN
		end
		equip(pan)
		task.wait(0.6)
		local st = inv(CK.GetState)
		if opt.needFish and st and (st.fishCount or 0) <= 0 then
			return nil, "nofish"
		end
		local s = inv(CK.Start, opt.recipe)
		if not (s and s.ok and s.token and s.targets) then
			return nil, s and s.message or "Start"
		end
		task.wait(2 + math.random())
		local f = inv(CK.Finish, s.token, { s.targets[1] + (math.random() - 0.5) * 0.02 })
		if not (f and f.ok) then
			return nil, f and f.message or "Finish"
		end
		inv(CK.UseDish, "Equip", opt.recipe)
		for _ = 1, 30 do
			local d = findTool(opt.tool)
			if d then
				return d
			end
			task.wait(0.1)
		end
		return nil, opt.tool
	end

	-- dish in hand: remind until the player eats it (the buff is renewed) or the reminders run out
	local function holdAndRemind(dish)
		if dish.Parent ~= P.Character then
			equip(dish)
			task.wait(0.4)
		end
		B.hold = true
		for _ = 1, REMIND_MAX do
			if not scope.alive() or buffLeft() > cfg.lead or not dish.Parent then
				break
			end
			Core.toast(Core.t("buff_eat"), "warn", 4)
			for _ = 1, REMIND_EVERY do
				if not scope.alive() or buffLeft() > cfg.lead or not dish.Parent then
					break
				end
				task.wait(1)
			end
		end
		B.hold = false
	end

	local function prepare(opt)
		-- guard: never more than one dish (a second one makes every dish uneatable until a reset)
		local list = dishes()
		if #list > 1 then
			Core.log("BUFF", "%d dishes in the inventory, nothing cooked", #list)
			Core.toast(Core.t("buff_multi"), "warn", 6)
			setMsg(Core.t("buff_multi"), 20)
			return false
		end
		local dish = list[1]
		if dish and dish.Name ~= opt.tool then
			Core.log("BUFF", "another dish in the inventory: %s", dish.Name)
			Core.toast(Core.t("buff_other", dish.Name), "warn", 6)
			setMsg(Core.t("buff_other", dish.Name), 20)
			return false
		end
		-- wait for a moment when the farm can give up its tools (the farm pauses new actions while B.want is set)
		B.want = true
		local t0 = os.clock()
		while scope.alive() do
			local ok, safe = true, true
			if Core.buffSafe then
				ok, safe = pcall(Core.buffSafe)
			end
			if ok and safe then
				break
			end
			if os.clock() - t0 > SAFE_WAIT then
				B.want = false
				Core.log("BUFF", "no safe moment within %d s", SAFE_WAIT)
				Core.toast(Core.t("buff_stuck"), "warn", 4)
				return false
			end
			task.wait(0.2)
		end
		if not scope.alive() then
			B.want = false
			return false
		end
		B.hold, B.want = true, false -- no yield between the check and this: the farm cannot slip in
		if not dish then
			setMsg(Core.t("buff_cooking", opt.tool), 8)
			local d, why = cook(opt)
			if not d then
				B.hold = false
				if why == "nofish" then
					Core.toast(Core.t("buff_no_fish", opt.tool), "warn", 5)
					setMsg(Core.t("buff_no_fish", opt.tool), 20)
				else
					Core.log("BUFF", "cooking failed: %s", tostring(why))
					Core.toast(Core.t("buff_fail", tostring(why)), "err", 5)
					setMsg(Core.t("buff_fail", tostring(why)), 20)
				end
				return false
			end
			dish = d
			Core.toast(Core.t("buff_cooked"), "ok", 3)
		end
		holdAndRemind(dish)
		return true
	end

	-- ----- loop -----
	task.spawn(function()
		local retryAt = 0
		while scope.alive() and not Core.dead do
			task.wait(2)
			if cfg.on and os.clock() >= retryAt and not Core.paused() and farmActive(farm) and buffLeft() <= cfg.lead then
				local ok, err = pcall(prepare, optOf(cfg.dish))
				B.want, B.hold = false, false
				if not ok then
					Core.log("BUFF", "error: %s", tostring(err))
				end
				retryAt = os.clock() + RETRY_AFTER
			end
		end
	end)

	-- ----- dock window: the unified farm panel (v3.0) -----
	-- Row 1: [Hub] [ON/OFF] [settings] [X]   Rows 2-3: run time, counter, per hour, coins per hour
	-- Row 4: buff timer / status   Row 5: buff on/off, dish, lead   Row 6: [speed] [log]   (speed / ON-OFF / settings
	-- appear only when the farm registered the hooks in Core.farmHooks). The log pane shows the last 20 lines.
	local g = Core.gui()
	if not g then
		return
	end
	local function hooks()
		return Core.farmHooks or {}
	end
	local W = 224
	local root = ui.mk("Frame", g, {
		Name = "FarmDock", Size = UDim2.fromOffset(W, 150), Position = UDim2.new(1, -(W + 20), 0, 70),
		BackgroundColor3 = C.BG, BorderSizePixel = 0, Active = true, Draggable = true,
	})
	ui.round(root, 8)
	Core.rememberPos(root, "dock")
	local hubBtn = ui.button(root, { Position = UDim2.fromOffset(6, 6), Size = UDim2.fromOffset(58, 28), TextSize = 12 })
	local onBtn = ui.button(root, { Position = UDim2.fromOffset(68, 6), Size = UDim2.fromOffset(80, 28), TextSize = 12 })
	local gearBtn = ui.button(root, { Position = UDim2.fromOffset(154, 6), Size = UDim2.fromOffset(28, 28), TextSize = 16, Text = "⚙" })
	local xBtn = ui.button(root, {
		Position = UDim2.fromOffset(W - 34, 6), Size = UDim2.fromOffset(28, 28), TextSize = 12, Text = "X", BackgroundColor3 = C.RED,
	})
	local function dockLabel(y)
		return ui.label(root, {
			Position = UDim2.fromOffset(8, y), Size = UDim2.new(1, -16, 0, 16), TextSize = 11, TextColor3 = C.GRAY,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		})
	end
	local line1, line2, stat = dockLabel(38), dockLabel(54), dockLabel(70)
	local bw = (W - 12 - 8) / 3
	local buffBtn = ui.button(root, { Position = UDim2.fromOffset(6, 90), Size = UDim2.fromOffset(bw, 26), TextSize = 11, Font = ui.FONT })
	local dishBtn = ui.button(root, { Position = UDim2.fromOffset(10 + bw, 90), Size = UDim2.fromOffset(bw, 26), TextSize = 11, Font = ui.FONT })
	local leadBtn = ui.button(root, { Position = UDim2.fromOffset(14 + 2 * bw, 90), Size = UDim2.fromOffset(bw, 26), TextSize = 11, Font = ui.FONT })
	local speedBtn = ui.button(root, { Position = UDim2.fromOffset(6, 120), Size = UDim2.fromOffset(104, 24), TextSize = 11, Font = ui.FONT })
	local logBtn = ui.button(root, { Position = UDim2.fromOffset(114, 120), Size = UDim2.fromOffset(104, 24), TextSize = 11, Font = ui.FONT })
	Core.bindText(hubBtn, "dock_hub")

	-- log pane (under the dock)
	local pane = ui.mk("Frame", root, {
		Position = UDim2.new(0, 0, 1, 6), Size = UDim2.new(1, 0, 0, 190), BackgroundColor3 = C.BG, BorderSizePixel = 0, Visible = false,
	})
	ui.round(pane, 8)
	local copyBtn = ui.button(pane, { Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 22), TextSize = 11, Font = ui.FONT })
	Core.bindText(copyBtn, "dock_copy")
	local scroll = ui.mk("ScrollingFrame", pane, {
		Position = UDim2.fromOffset(6, 32), Size = UDim2.new(1, -12, 1, -38), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 3, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
	})
	local logLbl = ui.label(scroll, {
		Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 10, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.GRAY,
	})

	local function statusText()
		if not cfg.on then
			return Core.t("buff_off")
		end
		if B.msg and os.clock() < B.msgUntil then
			return B.msg
		end
		if B.hold then
			return Core.t("buff_eat")
		end
		if B.want then
			return Core.t("buff_wait")
		end
		local left = buffLeft()
		if left > 0 then
			return Core.t("buff_left", string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60)))
		end
		return Core.t("buff_none")
	end

	local function fmtTime(sec)
		sec = math.floor(sec)
		if sec >= 3600 then
			return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
		end
		return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
	end
	local function fmtNum(n)
		n = math.floor(n + 0.5)
		if n >= 1000000 then
			return string.format("%.1fM", n / 1000000)
		elseif n >= 10000 then
			return string.format("%.0fk", n / 1000)
		elseif n >= 1000 then
			return string.format("%.1fk", n / 1000)
		end
		return tostring(n)
	end

	-- layout of the top row depends on which hooks the farm has registered
	local function layoutTop()
		local h = hooks()
		gearBtn.Visible = h.settings ~= nil
		onBtn.Visible = h.toggle ~= nil
		local right = gearBtn.Visible and 150 or (W - 38)
		onBtn.Size = UDim2.fromOffset(math.max(40, right - 68), 28)
		speedBtn.Visible = h.speed ~= nil
		logBtn.Size = speedBtn.Visible and UDim2.fromOffset(104, 24) or UDim2.fromOffset(W - 12, 24)
		logBtn.Position = speedBtn.Visible and UDim2.fromOffset(114, 120) or UDim2.fromOffset(6, 120)
	end

	local function refresh()
		layoutTop()
		local h = hooks()
		local on = false
		if h.isOn then
			local ok, r = pcall(h.isOn)
			on = ok and r == true
		end
		onBtn.Text = Core.t(on and "v_on" or "v_off"):upper()
		onBtn.BackgroundColor3 = on and C.GREEN or C.RED
		buffBtn.Text = Core.t("buff_label") .. ": " .. Core.t(cfg.on and "v_on" or "v_off")
		buffBtn.BackgroundColor3 = cfg.on and C.GREEN or C.BTN
		dishBtn.Text = optOf(cfg.dish).tool
		leadBtn.Text = Core.t("buff_lead", cfg.lead)
		if h.speed and h.speed.label then
			local ok, r = pcall(h.speed.label)
			speedBtn.Text = Core.t("dock_speed", ok and tostring(r) or "?")
		end
		logBtn.Text = Core.t(pane.Visible and "dock_log_hide" or "dock_log")
		stat.Text = statusText()
	end
	refresh()

	hubBtn.Activated:Connect(function()
		if Core.toggleHub then
			Core.toggleHub()
		end
	end)
	onBtn.Activated:Connect(function()
		local h = hooks()
		if h.toggle then
			pcall(h.toggle)
		end
		refresh()
	end)
	gearBtn.Activated:Connect(function()
		local h = hooks()
		if h.settings then
			pcall(h.settings)
		end
	end)
	speedBtn.Activated:Connect(function()
		local h = hooks()
		if h.speed and h.speed.next then
			pcall(h.speed.next)
		end
		refresh()
	end)
	xBtn.Activated:Connect(function()
		Core.confirm({
			parent = root, countdown = 3, titleKey = "unload_title", textKey = "unload_text", noKey = "confirm_no",
			onYes = Core.unload,
		})
	end)
	logBtn.Activated:Connect(function()
		pane.Visible = not pane.Visible
		refresh()
	end)
	copyBtn.Activated:Connect(Core.copyLog)
	buffBtn.Activated:Connect(function()
		cfg.on = not cfg.on
		B.msg = nil
		save()
		refresh()
	end)
	dishBtn.Activated:Connect(function()
		for i, o in ipairs(options) do
			if o.recipe == cfg.dish then
				cfg.dish = options[i % #options + 1].recipe
				break
			end
		end
		save()
		refresh()
	end)
	leadBtn.Activated:Connect(function()
		local i = table.find(LEADS, cfg.lead) or 0
		cfg.lead = LEADS[i % #LEADS + 1]
		save()
		refresh()
	end)
	local offLang = Core.onLang(refresh)

	-- once per second: run time, counter, per-hour rates, buff status, log pane
	local runSec, wasOn, lastT = 0, false, os.clock()
	local function tick()
		local now = os.clock()
		local dt = now - lastT
		lastT = now
		local h = hooks()
		local on
		if h.isOn then
			local ok, r = pcall(h.isOn)
			on = ok and r == true
		else
			on = farmActive(farm)
		end
		if on and not wasOn then
			runSec = 0 -- a new run: the farm resets its own counters when it is switched on
		end
		wasOn = on
		if on and not Core.paused() then
			runSec = runSec + dt
		end
		local st
		if h.stats then
			local ok, r = pcall(h.stats)
			if ok and type(r) == "table" then
				st = r
			end
		end
		if st and (on or runSec > 0) then
			local count = tonumber(st.count) or 0
			line1.Text = Core.t("st_line1", fmtTime(runSec), Core.t(st.unitKey or "u_items"), fmtNum(count))
			if runSec >= 20 then
				local txt = Core.t("st_rate", fmtNum(count / runSec * 3600))
				if st.coins then
					txt = txt .. " · " .. Core.t("st_coins", fmtNum(st.coins / runSec * 3600))
				end
				line2.Text = txt
			else
				line2.Text = ""
			end
		else
			line1.Text = on and fmtTime(runSec) or Core.t("st_wait")
			line2.Text = ""
		end
		onBtn.Text = Core.t(on and "v_on" or "v_off"):upper()
		onBtn.BackgroundColor3 = on and C.GREEN or C.RED
		stat.Text = statusText()
		layoutTop()
		if pane.Visible then
			local from = math.max(1, #logBuf - 19)
			local lines = {}
			for i = from, #logBuf do
				lines[#lines + 1] = logBuf[i]
			end
			local text = #lines > 0 and table.concat(lines, "\n") or Core.t("dock_log_empty")
			if logLbl.Text ~= text then
				logLbl.Text = text
				scroll.CanvasPosition = Vector2.new(0, 1e6)
			end
		end
	end
	task.spawn(function()
		while scope.alive() and root.Parent do
			pcall(tick)
			task.wait(1)
		end
	end)
	scope.onCleanup(function()
		B.want, B.hold = false, false
		pcall(offLang)
		pcall(root.Destroy, root)
	end)
end

-- ============================================================
-- Farm launch: runs a farm script (source text) with a fresh scope; the dock window comes with it
-- ============================================================
function Core.launch(name, src, version)
	if Core.farmScope then
		pcall(Core.farmScope.stop)
	end
	local scope = Core.newScope()
	Core.farmScope, Core.farmName, Core.farmVersion = scope, name, version
	Core.farmActive, Core.buffSafe, Core.farmHooks = nil, nil, nil -- hooks of the previous farm
	scope.after = function()
		Core.farmHooks = nil
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
	-- after a death / respawn: the farm keeps working (farms with their own handler get the hook too)
	Core.onRespawn(scope, function(ch)
		local h = Core.farmHooks
		local on = false
		if h and h.isOn then
			local ok, r = pcall(h.isOn)
			on = ok and r == true
		end
		if not on then
			return
		end
		pcall(function()
			ch:WaitForChild("HumanoidRootPart", 10)
		end)
		Core.toast(Core.t("respawn_cont"), "info", 3)
		if h.onRespawn then
			pcall(h.onRespawn, ch)
		end
	end)
	local okB, eB = pcall(startBuff, scope, name)
	if not okB then
		Core.log("CORE", "buff start error: %s", tostring(eB))
	end
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
	Core.logUnload("hub")
	for _, c in ipairs(coreConns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(coreConns)
	pcall(function()
		if fabGui then
			fabGui:Destroy()
		end
	end)
	for _, g in ipairs(guis) do
		pcall(function()
			g:Destroy()
		end)
	end
	table.clear(guis)
	-- clean getgenv: nothing of the project stays behind
	for _, k in ipairs({ "STATE", "MFarmUnload", "AFARM", "_AFARM_THREADS", "_AFARM_CONNS" }) do
		env[k] = nil
	end
	pcall(function()
		_G.STATE = nil
	end)
	if env.HubCore == Core then
		env.HubCore = nil
	end
end

Core.logLoad("core " .. Core.VERSION)
pcall(Core.updateFab)
return Core
