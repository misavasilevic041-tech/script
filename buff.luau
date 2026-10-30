-- Module: buff (cooking helper), semi-automatic. Loaded by the hub as an add-on of the fishing farm.
-- Before the food buff ends it cooks GrilledFish, takes the dish into the hand and asks you to eat it.
-- Eating is done by the player (the click method is unreliable on some executors).
-- Protocol (from protocol_test.luau): ToolEvent Get "Frying Pan" -> CookingRemotes.GetState / Start / Finish / UseDish("Equip").
-- Buff timer: player attribute FoodBuffExpiresAt (server time).
local scope, farm = ...
local env = (getgenv and getgenv()) or _G
local Core = env.HubCore
if not Core then
	return
end
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local RECIPE, DISH_TOOL, PAN_TOOL = "GrilledFish", "Grilled Fish", "Frying Pan"
local LEAD = 30 -- seconds before the buff ends when cooking starts
local REMIND_EVERY, REMIND_MAX, RETRY_AFTER = 10, 6, 120

Core.addStrings({
	ru = {
		buff_eat = "Съешь блюдо сейчас!",
		buff_no_fish = "Нет рыбы для готовки баффа",
		buff_fail = "Готовка не удалась: %s",
		buff_only_fish = "Бафф работает только с рыбалкой",
		buff_cooked = "Блюдо готово и в руке",
	},
	en = {
		buff_eat = "Eat the dish now!",
		buff_no_fish = "No fish to cook the buff",
		buff_fail = "Cooking failed: %s",
		buff_only_fish = "The buff works only with fishing",
		buff_cooked = "Dish is ready and in your hand",
	},
})

if Core.farmName ~= "fishing" then
	Core.toast(Core.t("buff_only_fish"), "warn", 4)
	return
end

local function findTool(name)
	local c = lp.Character
	return (c and c:FindFirstChild(name)) or lp.Backpack:FindFirstChild(name)
end

local function equip(tool)
	local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
	if hum and tool then
		pcall(function()
			hum:EquipTool(tool)
		end)
	end
end

local function waitTool(name, tries)
	for _ = 1, tries do
		local t = findTool(name)
		if t then
			return t
		end
		task.wait(0.1)
	end
end

local function buffLeft()
	local e = lp:GetAttribute("FoodBuffExpiresAt")
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

-- returns the dish tool (cooks it if there is none yet), nil + reason on failure
local function ensureDish()
	local dish = findTool(DISH_TOOL)
	if dish then
		return dish
	end
	local CK = RS:FindFirstChild("CookingRemotes")
	if not CK then
		return nil, "CookingRemotes"
	end
	local pan = findTool(PAN_TOOL)
	if not pan then
		pcall(function()
			RS.Events.ToolEvent:FireServer("Get", PAN_TOOL)
		end)
		pan = waitTool(PAN_TOOL, 30)
	end
	if not pan then
		return nil, PAN_TOOL
	end
	equip(pan)
	task.wait(0.6)
	local st = inv(CK.GetState)
	if st and (st.fishCount or 0) <= 0 then
		return nil, "nofish"
	end
	local s = inv(CK.Start, RECIPE)
	if not (s and s.ok and s.token and s.targets) then
		return nil, s and s.message or "Start"
	end
	task.wait(2 + math.random())
	local f = inv(CK.Finish, s.token, { s.targets[1] + (math.random() - 0.5) * 0.02 })
	if not (f and f.ok) then
		return nil, f and f.message or "Finish"
	end
	inv(CK.UseDish, "Equip", RECIPE)
	dish = waitTool(DISH_TOOL, 30)
	if not dish then
		return nil, DISH_TOOL
	end
	return dish
end

local function prepare()
	local dish, why = ensureDish()
	if not dish then
		if why == "nofish" then
			Core.toast(Core.t("buff_no_fish"), "warn", 4)
		else
			Core.log("BUFF", "cooking failed: %s", tostring(why))
			Core.toast(Core.t("buff_fail", tostring(why)), "err", 5)
		end
		return false
	end
	if dish.Parent ~= lp.Character then
		equip(dish)
		task.wait(0.4)
	end
	Core.toast(Core.t("buff_cooked"), "ok", 3)
	-- remind until the buff is renewed (the player eats) or the reminders run out
	for _ = 1, REMIND_MAX do
		if not scope.alive() or buffLeft() > LEAD then
			return true
		end
		Core.toast(Core.t("buff_eat"), "warn", 4)
		for _ = 1, REMIND_EVERY do
			if not scope.alive() or buffLeft() > LEAD then
				return true
			end
			task.wait(1)
		end
	end
	return true
end

task.spawn(function()
	local retryAt = 0
	while scope.alive() and not Core.dead do
		task.wait(2)
		if buffLeft() <= LEAD and os.clock() >= retryAt and not Core.paused() then
			prepare()
			retryAt = os.clock() + RETRY_AFTER
		end
	end
end)
