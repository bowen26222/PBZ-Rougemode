local Native = require('Native')
local Locale = require('Locale')
local MenuEntry = {}
local menu_state = nil

local function valid(object)
    return object and object:IsValid()
end

local function same(left, right)
    return valid(left) and valid(right) and left:GetAddress() == right:GetAddress()
end

local function slot_values(slot)
    return {
        padding = {Left = slot.Padding.Left, Top = slot.Padding.Top,
            Right = slot.Padding.Right, Bottom = slot.Padding.Bottom},
        size = {Value = slot.Size.Value, SizeRule = slot.Size.SizeRule},
        horizontal = slot.HorizontalAlignment,
        vertical = slot.VerticalAlignment,
    }
end

local function apply_slot(slot, values)
    slot:SetPadding(values.padding)
    slot:SetSize(values.size)
    slot:SetHorizontalAlignment(values.horizontal)
    slot:SetVerticalAlignment(values.vertical)
end

local function move_to_top(panel, button)
    local index = panel:GetChildIndex(button)
    -- UPanelWidget has no reflected runtime InsertChildAt. Rotate preceding
    -- children behind the entry, preserving each original widget and slot style.
    for _ = 1, index do
        local child = panel:GetChildAt(0)
        local values = slot_values(child.Slot)
        assert(panel:RemoveChildAt(0), 'Failed to detach menu child for ordering')
        apply_slot(panel:AddChildToVerticalBox(child), values)
    end
    assert(same(panel:GetChildAt(0), button), 'Endless entry must be the first menu child')
end

local function reorder_group(menu, button)
    local group = menu:GetButtonGroupByID(FName('StartMenu'))
    assert(valid(group), 'Native StartMenu button group is unavailable')
    if group:GetButtonCount() == 0 or not same(group:GetButtonBaseAtIndex(0), button) then
        local others = {}
        for index = 0, group:GetButtonCount() - 1 do
            local item = group:GetButtonBaseAtIndex(index)
            if not same(item, button) then others[#others + 1] = item end
        end
        group:RemoveAll()
        group:AddWidget(button)
        for _, item in ipairs(others) do group:AddWidget(item) end
    end

    local focus = StaticFindObject('/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary')
    local first, last = button, button
    for index = 1, group:GetButtonCount() - 1 do
        local item = group:GetButtonBaseAtIndex(index)
        if focus:CanFocusToWidget(item) then
            if same(first, button) then first = item end
            last = item
        end
    end
    -- EUINavigation.Up=2, Down=3. Original buttons' custom navigation reads
    -- this live group's order, so only the new button needs explicit rules.
    button:SetNavigationRuleExplicit(2, last)
    button:SetNavigationRuleExplicit(3, first)
end


-- The Puerts bridge receives OnButtonBaseClicked, including CommonUI's gamepad
-- activation path. HandleButtonClicked is only an internal mouse-button thunk.
RegisterHook('/Script/ProjectPBZ.PBZSaveLoadSubsystem:RecordFiredDelegateForTest', function(_, slot)
    local path = Native.name(slot:get()):match('^PBZRogue%.UI%.Menu|(.*)$')
    local state = menu_state
    if not path or not state or state.entering or state.pending
        or path ~= state.path then return end
    state.pending = true
end)

-- Drop references before the start-menu level is unloaded.
function MenuEntry.release()
    menu_state = nil
end

-- Called once by main's game-thread update, never inside Slate's broadcast.
-- Returning true tells the caller not to touch the old menu after a transition.
function MenuEntry.dispatch_pending()
    local state = menu_state
    if not state or not state.pending then return false end
    state.pending = false
    if state.entering or not valid(state.menu) or not state.menu:IsActivated()
        or not valid(state.button) or not state.button:GetIsEnabled() then return false end
    state.entering = true
    local ok, message = xpcall(function() state.on_enter(state.menu) end, debug.traceback)
    if menu_state == state then state.entering = false end
    if not ok then error(message) end
    return true
end

function MenuEntry.install(menu, on_enter)
    assert(valid(menu) and menu:IsActivated(), 'An active native start menu is required')
    assert(type(on_enter) == 'function', 'A real mode-entry handler is required')
    local state = menu_state
    local created = false
    if not state or not same(state.menu, menu) or not valid(state.button) then
        local source = menu.NewGame
        local panel = source:GetParent()
        assert(valid(panel), 'Native menu button container is unavailable')
        local factory = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
        local button = factory:Create(menu, source:GetClass(), menu:GetOwningPlayer())
        assert(valid(button), 'Native CreateWidget failed')
        apply_slot(panel:AddChildToVerticalBox(button), slot_values(source.Slot))
        button:SetMinDimensions(source.MinWidth, source.MinHeight)
        button:SetIsEnabled(true)
        button:SetIsFocusable(true)
        button:SetVisibility(0)
        state = {menu = menu, button = button, on_enter = on_enter, entering = false,
            path = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetPathName(button))}
        menu_state = state
        created = true
    end
    state.on_enter = on_enter
    local language = Locale.language()
    if state.language ~= language then
        state.button:SetButtonText(Native.text(Locale.text('无尽修炼', 'Endless Trials')))
        state.button.ButtonTextBlock:SetFont(menu.NewGame.ButtonTextBlock.Font)
        state.language = language
    end
    move_to_top(state.button:GetParent(), state.button)
    reorder_group(menu, state.button)
    if created then state.button:SetFocus() end
    return state.button
end

return MenuEntry
