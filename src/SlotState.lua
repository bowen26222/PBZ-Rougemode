local SlotState = {}
SlotState.__index = SlotState

local function level(value, name)
    assert(type(value) == "number" and value >= 0 and value % 1 == 0 and value < math.huge,
        name .. " must be a non-negative integer")
    return value
end

-- Native baselines differ: weapons start at 1; accessory/medicine refinement starts at 0.
-- The caller supplies native caps; only weapon/shadow purchases use milestone levels.
function SlotState.new(nativeLevel, snapSoul)
    assert(type(snapSoul) == "boolean", "snapSoul must be a boolean")
    return setmetatable({level = level(nativeLevel, "nativeLevel"), snapSoul = snapSoul}, SlotState)
end

function SlotState:effective_level(nativeMax)
    return math.min(self.level, level(nativeMax, "nativeMax"))
end

-- Replacement retains the slot's level, but soul belongs to the outgoing item.
function SlotState:replacement(nativeMax)
    return {level = self:effective_level(nativeMax), snapSoul = false}
end

function SlotState:commit_replacement(actualNativeLevel, nativeMax, nativeSnapSoul)
    assert(actualNativeLevel == self:effective_level(nativeMax), "replacement did not retain slot level")
    assert(nativeSnapSoul == false, "replacement unexpectedly retained snap soul")
    self.snapSoul = false
end

-- Weapons advance three native levels per purchase; shadow arms keep the native
-- five-level steps. Milestones also absorb levels left over from older schemes.
local upgrade_steps = {
    weapons = {4, 7, 10, 13, 16, 19, 22, 25, 28, 30},
    shadow = {5, 10, 15, 20, 25, 30},
}

function SlotState:next_weapon_level(nativeMax, kind)
    local current = self:effective_level(nativeMax)
    for _, milestone in ipairs(upgrade_steps[kind or 'weapons'] or upgrade_steps.weapons) do
        local target = math.min(milestone, nativeMax, 30)
        if target > current then return target end
    end
end

-- Call only after reading back a successful native upgrade; failed operations do not commit.
function SlotState:commit_upgrade(previousNativeLevel, actualNativeLevel, nativeMax)
    level(previousNativeLevel, "previousNativeLevel")
    level(actualNativeLevel, "actualNativeLevel")
    level(nativeMax, "nativeMax")
    assert(previousNativeLevel == self:effective_level(nativeMax), "native equipment and slot level differ")
    assert(actualNativeLevel > previousNativeLevel and actualNativeLevel <= nativeMax,
        "native upgrade did not advance within its cap")
    self.level = math.max(self.level, actualNativeLevel)
end

function SlotState:commit_snap_soul(nativeSnapSoul)
    assert(nativeSnapSoul == true, "native snap soul was not confirmed")
    self.snapSoul = true
end

return SlotState
