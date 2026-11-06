-- Read-only PBZ build 26266538 investigation. Does not load saves or modify gameplay.
local SlotState = require("SlotState")
local PREFIX = "[PBZRogueInspector] "
local attempts = 0
local finished = false

local function log(message)
    print(PREFIX .. message .. "\n")
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function inspect(label, callback)
    local ok, result = pcall(callback)
    if ok then
        log(label .. "=" .. tostring(result))
    else
        log(label .. " ERROR " .. tostring(result))
    end
    return ok
end

local function inspect_native_data()
    local health = StaticFindObject("/PBZCombatAsset/Config/Level/CV_AttributeCurve_Monster_Health.CV_AttributeCurve_Monster_Health")
    local attack = StaticFindObject("/PBZCombatAsset/Config/Level/CV_AttributeCurve_Monster_Attack.CV_AttributeCurve_Monster_Attack")
    local backpack = StaticFindObject("/Script/ProjectPBZ.Default__PBZBackPackSubsystem")
    if not valid(health) or not valid(attack) or not valid(backpack) then
        return false
    end

    log("BEGIN native configuration queries (no gameplay writes)")
    for _, level in ipairs({1, 25, 50, 200, 201, 500, 501, 1000}) do
        inspect("curve.health[" .. level .. "]", function()
            return health:GetFloatValue(level)
        end)
        inspect("curve.attack[" .. level .. "]", function()
            return attack:GetFloatValue(level)
        end)
    end

    -- Query IDs, not localized DataTable row names. Caps may depend on the current cycle.
    inspect("weapon.Tang.max", function()
        return backpack:GetWeaponMaxLevel(FName("Tang"), true)
    end)
    inspect("shadow.BrutalAxe.max", function()
        return backpack:GetWeaponMaxLevel(FName("BrutalAxe"), false)
    end)
    inspect("medicine.Hulu.max", function()
        return backpack:GetMedicineMaxLevel(FName("Hulu"))
    end)
    for _, id in ipairs({"AC_Loot", "AC_PerfectFrame", "AC_Health"}) do
        inspect("accessory." .. id .. ".configured_base_max", function()
            local data = backpack:GetAccessoryData(FName(id))
            return data.MaxRefineLevel
        end)
    end

    local instance = FindFirstOf("PBZBackPackSubsystem")
    if valid(instance) then
        for _, id in ipairs({"AC_Loot", "AC_PerfectFrame", "AC_Health"}) do
            inspect("accessory." .. id .. ".effective_max", function()
                return instance:GetAccessoryMaxRefineLevel(FName(id))
            end)
        end
        inspect("slot.native_cap_replacement_preview", function()
            local high = instance:GetAccessoryMaxRefineLevel(FName("AC_PerfectFrame"))
            local low = instance:GetAccessoryMaxRefineLevel(FName("AC_Loot"))
            assert(high > low and low > 0, "accessory configuration is not ready")
            local slot = SlotState.new(high, false)
            local capped = slot:replacement(low)
            local restored = slot:replacement(high)
            assert(capped.level == low and restored.level == high and slot.level == high)
            return string.format("retained=%d; low_item=%d; restored_item=%d (preview only, no equip operation)",
                slot.level, capped.level, restored.level)
        end)
    else
        log("No live backpack instance; cycle-dependent accessory caps were not queried.")
    end
    log("END native configuration queries")
    return true
end

log("Loaded. No cheats, save writes, equipment changes or recovery are enabled.")
LoopAsync(1000, function()
    if finished then return true end
    attempts = attempts + 1
    ExecuteInGameThread(function()
        if finished then return end
        local ok, ready = pcall(inspect_native_data)
        if not ok then
            log("Investigation stopped: " .. tostring(ready))
            finished = true
        elseif ready then
            finished = true
        elseif attempts >= 120 then
            log("Investigation stopped: required native objects did not load within 120 attempts.")
            finished = true
        end
    end)
    return false
end)
