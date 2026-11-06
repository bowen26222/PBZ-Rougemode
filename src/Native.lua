local Native = {}
local cache = {}
local lifetime_owner
local retained = {}

function Native.valid(object)
    return object ~= nil and object:IsValid()
end

function Native.same(left, right)
    return Native.valid(left) and Native.valid(right) and left:GetAddress() == right:GetAddress()
end

function Native.bind_lifetime(context)
    local owner = Native.cdo('/Script/Engine.Default__GameplayStatics'):GetGameInstance(context)
    assert(Native.valid(owner), 'Native lifetime owner is unavailable')
    assert(not lifetime_owner or Native.same(lifetime_owner, owner), 'Cannot change native lifetime owner during a run')
    lifetime_owner = owner
end

function Native.retain(object)
    assert(Native.valid(lifetime_owner) and Native.valid(object), 'Cannot retain an invalid native object')
    local address = object:GetAddress()
    if not retained[address] then
        -- Lua wrappers do not keep UObjects alive. Preserve the game's references
        -- and add a real GC-visible reference for this isolated run.
        local references = Native.array(lifetime_owner.ReferencedObjects)
        local existing = 0
        for _, reference in ipairs(references) do
            if Native.same(reference, object) then existing = existing + 1 end
        end
        references[#references + 1] = object
        lifetime_owner.ReferencedObjects = references
        retained[address] = {object = object, existing = existing}
    end
    return object
end

function Native.release(object)
    if not Native.valid(object) then return end
    local address = object:GetAddress()
    local entry = retained[address]
    if not entry or entry.permanent or not Native.same(entry.object, object) then return end
    assert(Native.valid(lifetime_owner), 'Native lifetime owner is unavailable')
    local references = Native.array(lifetime_owner.ReferencedObjects)
    local count, last = 0, nil
    for index, reference in ipairs(references) do
        if Native.same(reference, object) then count, last = count + 1, index end
    end
    -- Remove only our extra reference, never the game's pre-existing references.
    if count > entry.existing then
        table.remove(references, last)
        lifetime_owner.ReferencedObjects = references
    end
    retained[address] = nil
end

function Native.cdo(path)
    local object = cache[path]
    if not Native.valid(object) then
        object = StaticFindObject(path)
        assert(Native.valid(object), 'Native default object is unavailable: ' .. path)
        cache[path] = object
    end
    return object
end

function Native.load_object(path)
    local object = StaticFindObject(path)
    if not Native.valid(object) then object = LoadAsset(path) end
    assert(Native.valid(object), 'Cannot load native asset: ' .. path)
    if lifetime_owner and path:sub(1, 8) ~= '/Script/' then
        Native.retain(object)
        retained[object:GetAddress()].permanent = true
    end
    return object
end

function Native.load_class(path)
    local class = StaticFindObject(path)
    if not Native.valid(class) then
        local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
        local soft = system:Conv_SoftClassPathToSoftClassRef(system:MakeSoftClassPath(path))
        class = system:LoadClassAsset_Blocking(soft)
    end
    assert(Native.valid(class) and class:IsClass(), 'Cannot load native class: ' .. path)
    if lifetime_owner and path:sub(1, 8) ~= '/Script/' then
        Native.retain(class)
        retained[class:GetAddress()].permanent = true
    end
    return class
end

function Native.name(value)
    if type(value) == 'string' then return value end
    return value:ToString()
end

function Native.array(array)
    if type(array) == 'table' then
        for index, value in ipairs(array) do
            if type(value) == 'userdata' then
                local kind = value:type()
                if kind == 'RemoteUnrealParam' or kind == 'LocalUnrealParam' then
                    array[index] = value:get()
                end
            end
        end
        return array
    end
    local result = {}
    array:ForEach(function(_, value) result[#result + 1] = value:get() end)
    return result
end

function Native.subsystem(context, class_path)
    local class = Native.load_class(class_path)
    local library = Native.cdo('/Script/Engine.Default__SubsystemBlueprintLibrary')
    local math_library = Native.cdo('/Script/Engine.Default__KismetMathLibrary')
    local result
    if math_library:ClassIsChildOf(class, StaticFindObject('/Script/Engine.WorldSubsystem')) then
        result = library:GetWorldSubsystem(context, class)
    elseif math_library:ClassIsChildOf(class, StaticFindObject('/Script/Engine.LocalPlayerSubsystem')) then
        result = library:GetLocalPlayerSubsystem(context, class)
    else
        assert(math_library:ClassIsChildOf(class, StaticFindObject('/Script/Engine.GameInstanceSubsystem')),
            'Unsupported subsystem scope: ' .. class_path)
        result = library:GetGameInstanceSubsystem(context, class)
    end
    assert(Native.valid(result), 'Native subsystem is not initialized: ' .. class_path)
    return result
end

function Native.player(context)
    return Native.cdo('/Script/Engine.Default__GameplayStatics'):GetPlayerPawn(context, 0)
end

function Native.controller(context)
    return Native.cdo('/Script/Engine.Default__GameplayStatics'):GetPlayerController(context, 0)
end

function Native.health(player)
    local ability_system = Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
        :GetAbilitySystemComponent(player)
    if not Native.valid(ability_system) then return nil end
    local attributes = ability_system:GetAttributeSet(Native.load_class('/Script/CharacterBasics.BasicAttributeSet'))
    if not Native.valid(attributes) then return nil end
    return attributes.Health.CurrentValue
end

function Native.construct(class_path, outer)
    local object = StaticConstructObject(Native.load_class(class_path), outer)
    assert(Native.valid(object), 'Cannot construct native object: ' .. class_path)
    return object
end

function Native.text(value)
    return Native.cdo('/Script/Engine.Default__KismetTextLibrary'):Conv_StringToText(tostring(value))
end

return Native
