local Native = require('Native')
local Locale = require('Locale')
local DeathPresentation = {}
DeathPresentation.__index = DeathPresentation
local active, watcher_class_path
local hooks_installed, serial = false, 0
local npc_path = '/Game/RenewalContent/Prototypes/Character/BP_RenewalNPC.BP_RenewalNPC_C'

RegisterHook('/Script/ProjectPBZ.PBZSaveLoadSubsystem:RecordFiredDelegateForTest', function(_, slot)
    local event, token = Native.name(slot:get()):match('^PBZRogue%.UI%.(Dissolve[^|]+)|(.*)$')
    if event == 'DissolveClass' then watcher_class_path = token; return end
    local owner = active
    local effect = owner and owner.effects[token]
    if not effect then return end
    if event == 'DissolveBound' then effect.bound = true
    elseif event == 'DissolveFinished' then owner:finish(token) end
end)

function DeathPresentation.new(battle)
    assert(watcher_class_path, Locale.text('原生消散完成桥未加载；请完整更新模组后重新启动游戏', 'The native dissolve completion bridge is not loaded. Fully update the mod and restart the game.'))
    local self = setmetatable({battle = battle, waiting = {}, effects = {}, components = {},
        watcher_class = Native.load_class(watcher_class_path),
        mesh_class = Native.load_class('/Script/Engine.SkeletalMeshComponent'),
        socket_interface = Native.load_class('/Script/SGameUtils.SocketComponentHolder'),
        system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary'),
        weapons = Native.cdo('/Script/SGameCombatSystem.Default__WeaponUtils'),
        main_slot = {TagName = FName('Weapon.Slot.Main')}}, DeathPresentation)
    active = self
    if not hooks_installed then
        -- Blueprint RegisterHook's second callback is POST-only. Native latent
        -- entry 842 synchronously spawns all body/weapon death systems, then returns.
        -- This offset is limited to the executable/build pinned by main.lua.
        RegisterHook(npc_path .. ':ExecuteUbergraph_BP_RenewalNPC', function(context, entry)
            if entry:get() ~= 842 then return end
            local owner, pawn = active, context:get()
            if not owner or not Native.valid(pawn) then return end
            local member = owner.battle.members[pawn:GetAddress()]
            if member then
                local ok, message = xpcall(function() owner:spawn_complete(member) end, debug.traceback)
                if not ok then owner.error = message end
            end
        end)
        hooks_installed = true
    end
    return self
end

function DeathPresentation:arm(member)
    if member.presentation_started then return end
    member.presentation_started = true
    if Native.valid(member.pawn) and not member.pawn.DisableDeathDissol then
        self.waiting[member] = true
    end
end

function DeathPresentation:cancel(member)
    self.waiting[member] = nil
    member.presentation_started = nil
    -- Previously emitted particles still finish naturally. Their tokens cannot
    -- close the pending native spawn pass of a later death of the same pawn.
end

function DeathPresentation:finish(token)
    local effect = self.effects[token]
    if not effect then return end
    effect.finished = true
    self.effects[token] = nil
    if self.components[effect.address] == token then self.components[effect.address] = nil end
    if effect.watcher then Native.release(effect.watcher) end
end

function DeathPresentation:watch(component)
    local address = component:GetAddress()
    if self.components[address] then return end
    serial = serial + 1
    local token = 'PBZRogueDeath_' .. serial
    local effect = {component = component, address = address}
    self.effects[token], self.components[address] = effect, token
    -- The Puerts UObject constructor binds OnSystemFinished synchronously, with
    -- this exact component as Outer. No Lua FScriptDelegate or tick-time scan.
    local watcher = StaticConstructObject(self.watcher_class, component, FName(token))
    assert(Native.valid(watcher) and effect.bound, Locale.text('无法绑定原生消散完成事件', 'Could not bind the native dissolve completion event'))
    if not effect.finished then effect.watcher = Native.retain(watcher) end
end

function DeathPresentation:scan(target, asset)
    if not Native.valid(target) or not Native.valid(asset) then return end
    local children = {}
    target:GetChildrenComponents(true, children)
    for _, component in ipairs(Native.array(children)) do
        if Native.valid(component) and component:IsA('/Script/Niagara.NiagaraComponent')
            and Native.same(component:GetAsset(), asset) then
            self:watch(component)
        end
    end
end

function DeathPresentation:spawn_complete(member)
    local pawn = member.pawn
    self:arm(member)
    for _, mesh in ipairs(Native.array(pawn:K2_GetComponentsByClass(self.mesh_class))) do
        self:scan(mesh, pawn.VanishParticle)
    end
    -- Match the native pass, including weapon actors detached from the pawn.
    local weapons = pawn['Character Weapons Component']
    if Native.valid(weapons) then
        for index = 0, weapons:GetSlotWeapons(self.main_slot) - 1 do
            local actors = {}
            self.weapons:GetWeaponActorsByWeaponIndexAndDisplayIndex(pawn, self.main_slot, index, -1, actors)
            for _, actor in ipairs(Native.array(actors)) do
                if Native.valid(actor) and self.system:DoesImplementInterface(actor, self.socket_interface) then
                    self:scan(actor:GetSocketComponent(), pawn.VanishParticleWeapon)
                end
            end
        end
    end
    -- A completed pre-culled/empty spawn pass is valid. An empty scan BEFORE
    -- this callback is not completion: native death/vanish delays still own it.
    self.waiting[member] = nil
end

function DeathPresentation:complete()
    assert(not self.error, self.error)
    for member in pairs(self.waiting) do
        if not Native.valid(member.pawn) then self.waiting[member] = nil end
    end
    for token, effect in pairs(self.effects) do
        if not Native.valid(effect.component) then self:finish(token) end
    end
    return next(self.waiting) == nil and next(self.effects) == nil
end

function DeathPresentation:clear()
    self.error = nil
    for token in pairs(self.effects) do self:finish(token) end
    self.waiting = {}
end

function DeathPresentation:destroy()
    self:clear()
    if active == self then active = nil end
end

return DeathPresentation
