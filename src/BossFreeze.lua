local Native = require('Native')
local Freeze = {}
Freeze.__index = Freeze
local serial = 0
local executed_path = '/PBZCombatAsset/ActorData/Mobs/054_ZuoShang/Ability/Abilities/GA_ZuoShang_CA_GEd_01.GA_ZuoShang_CA_GEd_01_C'

-- Deliberately bounded: primary ticks and native actor slomo, not suspension
-- of asynchronous StateTree events, world timers, projectiles or summons.
function Freeze.new(battle)
    serial = serial + 1
    return setmetatable({battle = battle, held = {}, id = FName('PBZRogue.RoofFreeze.' .. serial)}, Freeze)
end

local function live(battle, member)
    return member and not member.dead and Native.valid(member.pawn)
        and battle:owns_group(member.group) and Native.same(member.pawn.MobGroup, member.group)
        and member.pawn:IsAlive()
end

function Freeze:source()
    local battle = self.battle
    if not battle.active or not battle.music_plan or not Native.valid(battle.player) then return end
    local has_source = false
    for _, entry in ipairs(battle.music_plan) do
        if entry.enemy.id == 'zuo_shang' and live(battle, entry.member) then has_source = true; break end
    end
    if not has_source then return end
    -- Do not load a dormant cinematic ability merely to inspect it.
    local class = StaticFindObject(executed_path)
    if not Native.valid(class) then return end
    local library = Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
    local asc = library:GetAbilitySystemComponent(battle.player)
    if not Native.valid(asc) then return end
    local utils = Native.cdo('/Script/SGameUtils.Default__AbilityUtils')
    local function executor(instances)
        for _, ability in ipairs(Native.array(instances)) do
            if Native.valid(ability) and Native.same(ability:GetClass(), class)
                and utils:IsAbilityActive(ability)
                and Native.same(ability:GetAvatarActorFromActorInfo(), battle.player) then
                local info = ability['Execution Info']
                local pawn, target = info.Executor:Get(), info.Target:Get()
                if Native.valid(pawn) and Native.same(target, battle.player) then
                    local member = battle.members[pawn:GetAddress()]
                    if live(battle, member) and member.enemy and member.enemy.id == 'zuo_shang'
                        and Native.same(member.pawn, pawn) then return member end
                end
            end
        end
    end
    for _, spec in ipairs(Native.array(asc.ActivatableAbilities.Items)) do
        if spec.ActiveCount > 0 then
            local member = executor(spec.NonReplicatedInstances) or executor(spec.ReplicatedInstances)
            if member then return member end
        end
    end
end

function Freeze:slomo(pawn, value)
    pawn:ApplySlomo(self.id, value)
    -- NPC's own tick is about to stop. Recompute its native dilation now.
    -- SetSlomoValue(..., 1) erases only this ID; StopSlomo handles timed entries.
    Native.cdo('/Script/SGameCombatSystem.Default__RuntimeSlomoDataHelper'):Tick(pawn['Runtime Slomo Data'])
end

function Freeze:hold(member)
    local pawn = member.pawn
    local controller = pawn:GetController()
    local entry = {member = member, pawn = pawn, controller = controller, ticks = {}}
    self.held[member] = entry -- Publish before mutation so error teardown can restore it.
    local component_class = Native.load_class('/Script/Engine.ActorComponent')
    local function stop(actor)
        if not Native.valid(actor) then return end
        local tick = {object = actor, owner = actor, actor = true, enabled = actor:IsActorTickEnabled()}
        entry.ticks[#entry.ticks + 1] = tick
        if tick.enabled then actor:SetActorTickEnabled(false) end
        for _, component in ipairs(Native.array(actor:K2_GetComponentsByClass(component_class))) do
            local saved = {object = component, owner = actor, enabled = component:IsComponentTickEnabled()}
            entry.ticks[#entry.ticks + 1] = saved
            if saved.enabled then component:SetComponentTickEnabled(false) end
        end
    end
    entry.slomo = true
    self:slomo(pawn, 0)
    stop(pawn)
    stop(controller)
end

function Freeze:release(member, world_ended)
    local entry = self.held[member]
    if not entry then return end
    if not world_ended then
        if entry.slomo and Native.valid(entry.pawn) then
            self:slomo(entry.pawn, 1)
            entry.slomo = false
        end
        -- A native death or controller transfer must not have its new tick
        -- policy overwritten by an old live-pawn snapshot.
        if Native.valid(entry.pawn) and entry.pawn:IsAlive() and not member.dead then
            for _, tick in ipairs(entry.ticks) do
                local owner_matches = Native.same(tick.owner, entry.pawn)
                    or (Native.valid(entry.controller) and Native.same(tick.owner, entry.controller)
                        and Native.same(entry.pawn:GetController(), entry.controller))
                if tick.enabled and owner_matches and Native.valid(tick.object)
                    and (tick.actor or Native.same(tick.object:GetOwner(), tick.owner)) then
                    if tick.actor then tick.object:SetActorTickEnabled(true)
                    else tick.object:SetComponentTickEnabled(true) end
                    tick.enabled = false
                end
            end
        end
    end
    self.held[member] = nil
end

function Freeze:update()
    local battle = self.battle
    local source = self:source()
    -- Release before acquiring: a previously frozen boss may now own the grab.
    for member, entry in pairs(self.held) do
        if not source or member == source or not live(battle, member)
            or not Native.same(entry.controller, member.pawn:GetController()) then
            self:release(member, false)
        end
    end
    if not source then return end
    for _, plan in ipairs(battle.music_plan) do
        local member = plan.member
        if member ~= source and member.combat_ready and live(battle, member) and not self.held[member] then
            self:hold(member)
        end
    end
end

function Freeze:is_held(member)
    return self.held[member] ~= nil
end

function Freeze:clear(world_ended)
    for member in pairs(self.held) do self:release(member, world_ended) end
end

return Freeze
