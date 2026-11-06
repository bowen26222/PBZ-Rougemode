local Native = require('Native')
local UIArt = require('UIArt')
local HudUI = require('HudUI')
local Locale = require('Locale')
local ShopUI = {}
ShopUI.__index = ShopUI
local active_ui
local page_class_path, page_bridge_error
local description_class_path, description_serial = nil, 0
local description_root = '/Game/PBZContent/UI/UINew/HUD/'
local description_classes = {
    weapon = description_root .. 'W_UnifiedTextDescription_Weapon.W_UnifiedTextDescription_Weapon_C',
    item = description_root .. 'W_UnifiedTextDescription.W_UnifiedTextDescription_C',
}
local button_class_path = '/Game/PBZContent/UI/UINew/Common/W_MenuButton_V2_SelectedVersion.W_MenuButton_V2_SelectedVersion_C'
local action_bar_class = '/Game/PBZContent/UI/Foundation/Widgets/BottomBar/WB_PBZTriggerBoundAction.WB_PBZTriggerBoundAction_C'
local soul_icon = '/Game/PBZContent/UI/Texture/PauseMenu/T_Dust_V2.T_Dust_V2'
local calligraphy_path = '/Game/PBZContent/UI/Fonts/ZH_ZiKuTangKuangShanKaiShuJF_Font.ZH_ZiKuTangKuangShanKaiShuJF_Font'
local english_title_path = '/Game/PBZContent/UI/Fonts/EN_AlverataCYR_Medium_Title_Font.EN_AlverataCYR_Medium_Title_Font'
local english_body_path = '/Game/PBZContent/UI/Fonts/EN_FTThymesEXT_Regular_Body_Font.EN_FTThymesEXT_Regular_Body_Font'
local english_button_path = '/Game/PBZContent/UI/Fonts/EN_Chaco-Medium_Font.EN_Chaco-Medium_Font'
local wallet_users, wallet_decorations = 0, {}

-- Match the existing PlayerSavePatch bridge: only strings enter Lua, never
-- FScriptDelegate or FKey tables. Actions are drained by the owning UI tick.
RegisterHook('/Script/ProjectPBZ.PBZSaveLoadSubsystem:RecordFiredDelegateForTest', function(_, slot)
    local event, payload = Native.name(slot:get()):match('^PBZRogue%.UI%.([^|]+)|(.*)$')
    if event == 'Class' then
        page_class_path = payload
        page_bridge_error = nil
        return
    end
    if event == 'DescriptionClass' then description_class_path = payload; return end
    if event == 'Error' then
        page_bridge_error = payload
        print('[PBZRogue] Native UI bridge: ' .. payload .. '\n')
        return
    end
    local ui = active_ui
    if not ui then return end
    if event == 'DescriptionReady' then ui.description_ready = payload; return end
    if event == 'Ready' and payload == ui.page_path then
        ui.native_ready = true
        return
    end
    if not ui.input_active or ui.busy or ui.pending_action then return end
    local action
    if event == 'Click' or event == 'Confirm' then
        local page, button = payload:match('^([^|]+)|(.*)$')
        if page == ui.page_path then action = ui.actions[button] end
    elseif event == 'Back' and payload == ui.page_path then
        action = ui.cancel
    end
    if action then
        ui.input_active = false
        ui.pending_action = {generation = ui.generation, action = action}
    end
end)

local function padding(value)
    return {Left = value, Top = value, Right = value, Bottom = value}
end

local function rect(widget, x, y, width, height)
    -- English canvas children live in DownOnly ScaleBoxes, so their native
    -- text and buttons can keep their desired size without overflowing cards.
    local parent = widget:GetParent()
    local layout = Native.valid(parent) and parent:IsA('/Script/UMG.ScaleBox') and parent or widget
    local slot = layout.Slot
    slot:SetPosition({X = x, Y = y})
    slot:SetSize({X = width, Y = height})
    return widget
end

local function align_button_label(button, alignment)
    local text = button.ButtonTextBlock
    local layers = text:GetParent():GetParent()
    local group = layers:GetParent()
    assert(group:IsA('/Script/UMG.HorizontalBox'), 'Native menu text layout changed')
    layers.Slot:SetPadding(padding(0))
    group.Slot:SetHorizontalAlignment(alignment)
    group.Slot:SetPadding(padding(0))
    text:SetJustification(alignment == 2 and 1 or 0)
end

local function money(value)
    local amount = tostring(value or 0)
    return amount:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

function ShopUI.new(controller, world)
    local self = setmetatable({controller = controller, world = world, buttons = {}, actions = {}}, ShopUI)
    self.library = Native.cdo('/Script/UMG.Default__WidgetBlueprintLibrary')
    self.extensions = Native.cdo('/Script/CommonGame.Default__CommonUIExtensions')
    self.gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
    self.router = Native.subsystem(world, '/Script/ProjectPBZ.PBZUIActionRouterBase')
    self.button_group = Native.retain(Native.construct('/Script/ProjectPBZ.PBZButtonGroup', controller))
    self.button_group:SetSelectionRequired(false)
    self.button_class = Native.load_class(button_class_path)
    self.art = UIArt.new(world)
    return self
end

function ShopUI:preload_shop(model)
    -- Game-thread preparation only: resolve classes/CDOs (including the menu
    -- button's hard-referenced Font) without constructing or activating a page.
    if not self.shop_classes_preloaded then
        assert(page_class_path, page_bridge_error or 'Native UI input bridge is unavailable; rebuild the native patch')
        Native.load_class(page_class_path):GetCDO()
        Native.load_class(action_bar_class):GetCDO()
        assert(description_class_path, 'Native item description bridge is unavailable; rebuild the native patch')
        Native.load_class(description_class_path):GetCDO()
        for _, path in pairs(description_classes) do Native.load_class(path):GetCDO() end
        self.button_class:GetCDO()
        for _, class in ipairs({'WidgetTree', 'CanvasPanel', 'Overlay', 'SizeBox',
            'ScaleBox', 'Image', 'HorizontalBox', 'VerticalBox', 'TextBlock'}) do
            Native.load_class('/Script/UMG.' .. class):GetCDO()
        end
        self.shop_classes_preloaded = true
    end
    self.art:preload_shop(model)
    if Locale.is_chinese() then
        Native.load_object(calligraphy_path)
    else
        Native.load_object(english_title_path)
        Native.load_object(english_body_path)
        Native.load_object(english_button_path)
    end
    self.art:icon(soul_icon)
end

function ShopUI:widget(class)
    local widget = Native.construct('/Script/UMG.' .. class, self.tree)
    widget:SetVisibility(4) -- Layout only; native buttons remain hit-testable.
    return widget
end

function ShopUI:text(parent, value, size, wrap_width)
    local text = self:widget('TextBlock')
    text:SetText(Native.text(value or ''))
    text:SetAutoWrapText(Locale.is_chinese())
    if wrap_width and not Locale.is_chinese() then text.WrapTextAt = wrap_width end
    text:SetVisibility(3)
    text:SetShadowColorAndOpacity({R = 0, G = 0, B = 0, A = 0.85})
    text:SetShadowOffset({X = 1, Y = 2})
    text:SetColorAndOpacity({SpecifiedColor = {R = 0.92, G = 0.92, B = 0.92, A = 1}, ColorUseRule = 0})
    text:SetFont(self.button_class:GetCDO().Font)
    local font = text.Font
    if not Locale.is_chinese() then
        font.FontObject, font.TypefaceFontName = Native.load_object(english_body_path), FName('Default')
    end
    font.Size = size or 22
    font.FontMaterial = nil
    font.OutlineSettings.OutlineMaterial = nil
    font.LetterSpacing = 0
    font.bForceMonospaced = false
    text:SetFont(font)
    if not Locale.is_chinese() and parent:IsA('/Script/UMG.CanvasPanel') then
        local scale = self:widget('ScaleBox')
        scale:SetStretch(2)
        scale:SetStretchDirection(1) -- DownOnly.
        parent:AddChild(scale)
        scale:SetContent(text)
    else
        parent:AddChild(text)
    end
    return text
end

function ShopUI:button(parent, id, label, enabled, action, font_size)
    local button = self.library:Create(self.world, self.button_class, self.controller)
    assert(Native.valid(button), 'Cannot create native shop button')
    -- Keep CommonUI from restoring its hidden glyph's width on focus or input changes.
    button.InputActionWidget:SetCollapsedWhenInvisible(true)
    button:SetHideInputAction(true)
    button:SetButtonText(Native.text(label))
    local text = button.ButtonTextBlock
    assert(Native.valid(text), 'Native menu button label is unavailable')
    local font = text.Font
    if not Locale.is_chinese() then
        font.FontObject, font.TypefaceFontName = Native.load_object(english_button_path), FName('Default')
    end
    font.Size = font_size or 26
    font.FontMaterial, font.OutlineSettings.OutlineMaterial = nil, nil
    font.OutlineSettings.OutlineSize = 1
    font.OutlineSettings.OutlineColor = {R = 0, G = 0, B = 0, A = 1}
    text:SetFont(font)
    text:SetShadowOffset({X = 1, Y = 2})
    text:SetShadowColorAndOpacity({R = 0, G = 0, B = 0, A = 1})
    -- Native focus still draws its ink brush; opaque glyphs stay readable over
    -- the unmasked game scene, including pale stone and bright effects.
    button.SelectedOpacity, button.UnselectedOpacity = 1, 1
    button:SetMinDimensions(240, 34)
    -- Availability gates activation, not navigation or hover.
    button:SetIsFocusable(true)
    button:SetIsInteractableWhenSelected(true)
    button:SetIsSelected(false, false)
    button:SetIsEnabled(true)
    button:SetIsInteractionEnabled(enabled ~= false)
    button:SetVisibility(0)
    local slot
    if not Locale.is_chinese() and parent:IsA('/Script/UMG.CanvasPanel') then
        local scale = self:widget('ScaleBox')
        scale:SetStretch(2)
        scale:SetStretchDirection(1) -- Fit the full native button, including its ink ends.
        slot = parent:AddChild(scale)
        scale:SetContent(button)
    else
        slot = parent:AddChild(button)
    end
    if slot:IsA('/Script/UMG.VerticalBoxSlot') then
        slot:SetPadding(padding(5))
        slot:SetHorizontalAlignment(2)
    end
    self.button_group:AddWidget(button)
    self.buttons[#self.buttons + 1] = {id = id, widget = button}
    local path = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetPathName(button))
    self.actions[path] = enabled ~= false and action or nil
    return button, path
end

function ShopUI:wallet(visible)
    if (self.wallet_visible == true) == visible then return end
    self.wallet_visible = visible
    wallet_users = wallet_users + (visible and 1 or -1)
    -- The replacement modal and its underlying shop share the native wallet.
    if (visible and wallet_users > 1) or (not visible and wallet_users > 0) then return end
    if visible then
        local instance = self.gameplay:GetGameInstance(self.world)
        for _, wallet in ipairs(FindAllOf('W_Dust_Tips_C') or {}) do
            if Native.valid(wallet) and Native.same(self.gameplay:GetGameInstance(wallet), instance) then
                local effect = wallet.NiagaraSystemWidget_131
                assert(Native.valid(effect), 'Native wallet decoration is unavailable')
                wallet_decorations[#wallet_decorations + 1] = {widget = effect, opacity = effect.RenderOpacity}
                effect:SetRenderOpacity(0)
            end
        end
    end
    local library = Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
    local prefix = visible and 'GameplayEvent.UI.Show' or 'GameplayEvent.UI.Hide'
    for _, name in ipairs({'DustTips', 'Rongshu'}) do
        library:SendGameplayEventToActor(self.world, {TagName = FName(prefix .. name)}, {})
    end
    if not visible then
        for _, decoration in ipairs(wallet_decorations) do
            if Native.valid(decoration.widget) then decoration.widget:SetRenderOpacity(decoration.opacity) end
        end
        wallet_decorations = {}
    end
end

function ShopUI:action_bar()
    -- Same container and footer slot as W_AbilityWidget. PBZActionBar creates
    -- WB_TriggerBoundButton entries from the active page's visible bindings.
    local bar = self.library:Create(self.world, Native.load_class(action_bar_class), self.controller)
    assert(Native.valid(bar), 'Native ability action bar is unavailable')
    -- Fill the viewport, then align the native content itself. An auto-sized
    -- SafeZone can request a viewport-sized box and leave its action row centered.
    local footer = self:widget('CanvasPanel')
    footer:SetVisibility(4) -- SelfHitTestInvisible; native children remain interactive.
    local host_slot = self.tree.RootWidget:AddChildToOverlay(footer)
    host_slot:SetHorizontalAlignment(0)
    host_slot:SetVerticalAlignment(0)
    local slot = footer:AddChildToCanvas(bar)
    slot:SetAnchors({Minimum = {X = 0, Y = 0}, Maximum = {X = 1, Y = 1}})
    slot:SetOffsets({Left = 30, Top = 0, Right = 100, Bottom = 38})
    local row_host = self:widget('Overlay')
    bar.ActionBarSZ:SetContent(row_host)
    local row_slot = row_host:AddChildToOverlay(bar.ActionBar)
    row_slot:SetHorizontalAlignment(3) -- HAlign_Right
    row_slot:SetVerticalAlignment(3) -- VAlign_Bottom
end

function ShopUI:price_label(parent, value, x, y, size)
    local row = self:widget('HorizontalBox')
    local slot = parent:AddChildToCanvas(row)
    slot:SetPosition({X = x, Y = y})
    slot:SetAlignment({X = 0.5, Y = 0})
    slot:SetAutoSize(true)
    local icon_box = self:widget('SizeBox')
    icon_box:SetWidthOverride(size)
    icon_box:SetHeightOverride(size)
    local icon = self:widget('Image')
    icon:SetBrushFromTexture(self.art:icon(soul_icon), true)
    icon_box:SetContent(icon)
    local icon_slot = row:AddChildToHorizontalBox(icon_box)
    icon_slot:SetVerticalAlignment(2)
    icon_slot:SetPadding({Left = 0, Top = 0, Right = 6, Bottom = 0})
    local amount = self:text(row, value ~= nil and money(value) or '', size)
    amount:SetAutoWrapText(false)
    amount.Slot:SetVerticalAlignment(2)
    return amount, row
end

function ShopUI:begin_page(title, subtitle, backdrop)
    if self.wallet_visible then self:wallet(false) end
    if not self.captured then
        self.was_paused = self.gameplay:IsGamePaused(self.world)
        self.captured = true
    end
    self.input_active = false
    self.pending_action, self.pending_focus = nil, nil
    self.native_ready = false
    self.generation = (self.generation or 0) + 1
    -- Invalidate routing before deactivation broadcasts or the stack can reuse
    -- the old page. Never mutate the stack from inside a button's broadcast.
    local old_page = self.page
    self.page, self.page_path = nil, nil
    self.actions, self.buttons, self.nav, self.cancel = {}, {}, nil, nil
    self.offer_views, self.section_reasons = nil, nil
    self.tooltip, self.hover_view = nil, nil
    self.entrance, self.entrance_started = nil, nil
    self.button_group:DeselectAll()
    self.button_group:RemoveAll()
    if Native.valid(old_page) then self.extensions:PopContentFromLayer(old_page) end
    self.gameplay:SetGamePaused(self.world, false)
    assert(page_class_path, page_bridge_error or 'Native UI input bridge is unavailable; rebuild the native patch')
    local local_player = self.extensions:GetLocalPlayerFromController(self.controller)
    self.page = self.extensions:PushContentToLayer_ForPlayer(local_player,
        {TagName = FName(self.layer or 'UI.Layer.Menu')}, Native.load_class(page_class_path))
    assert(Native.valid(self.page), 'Cannot open the native mode page')
    self.page_path = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetPathName(self.page))
    self.tree = self.page.WidgetTree
    local host = self.tree.RootWidget
    assert(Native.valid(host) and host:IsA('/Script/UMG.Overlay'), 'Native mode content host is unavailable')
    host:ClearChildren()
    local layout = Native.cdo('/Script/UMG.Default__WidgetLayoutLibrary')
    local viewport, dpi = layout:GetViewportSize(self.world), layout:GetViewportScale(self.world)
    local frame = self:widget('SizeBox')
    frame:SetWidthOverride(viewport.X / dpi)
    frame:SetHeightOverride(viewport.Y / dpi)
    local host_slot = host:AddChildToOverlay(frame)
    host_slot:SetHorizontalAlignment(0)
    host_slot:SetVerticalAlignment(0)
    local scale = self:widget('ScaleBox')
    scale:SetStretch(2) -- EStretch::ScaleToFit, not Fill.
    frame:SetContent(scale)
    local size = self:widget('SizeBox')
    size:SetWidthOverride(1600)
    size:SetHeightOverride(1000)
    scale:SetContent(size)
    local layers = self:widget('Overlay')
    size:SetContent(layers)
    local modal = self.layer == 'UI.Layer.GameSystem'
    if not modal and backdrop ~= false then
        local art_scale = self:widget('ScaleBox')
        art_scale:SetStretch(2)
        local background = self:widget('Image')
        background:SetVisibility(3)
        background:SetBrushFromTexture(self.art:background(), true)
        art_scale:SetContent(background)
        local slot = layers:AddChildToOverlay(art_scale)
        slot:SetHorizontalAlignment(0)
        slot:SetVerticalAlignment(0)
    end
    local canvas = self:widget('CanvasPanel')
    local canvas_slot = layers:AddChildToOverlay(canvas)
    canvas_slot:SetHorizontalAlignment(0)
    canvas_slot:SetVerticalAlignment(0)
    self.canvas = canvas
    if modal then
        if backdrop ~= false then
            -- The modal owns its ink plate; the underlying shop stays visible.
            local panel = self:widget('Image')
            panel:SetVisibility(0)
            panel:SetBrushFromTexture(self.art:modal_background(), true)
            canvas:AddChild(panel)
            rect(panel, 240, 110, 1120, 780)
        end
        self.title_text = rect(self:text(canvas, title, 34), 320, 184, 960, 54)
        self.subtitle_text = rect(self:text(canvas, subtitle, 22, 960), 320, 250, 960, 160)
    else
        self.title_text = rect(self:text(canvas, title, 42), 80, 36, 1060, 64)
        self.subtitle_text = rect(self:text(canvas, subtitle, 23, 1100), 80, 102, 1100, 40)
    end
    local content = self:widget('VerticalBox')
    canvas:AddChild(content)
    rect(content, modal and 320 or 80, modal and 420 or 160,
        modal and 960 or 1440, modal and 360 or 790)
    self.content = content
    return content
end

function ShopUI:finish_page(focus_id)
    local modal = self.layer == 'UI.Layer.GameSystem'
    self.status = rect(self:text(self.canvas, self.status_text or '', 20),
        modal and 320 or 470, modal and 800 or 963, modal and 960 or 730, 34)
    local focus
    if self.nav then
        self:apply_grid_navigation()
    else
        local count = #self.buttons
        for index, entry in ipairs(self.buttons) do
            local previous = self.buttons[(index - 2) % count + 1].widget
            local following = self.buttons[index % count + 1].widget
            entry.widget:SetNavigationRuleExplicit(2, previous)
            entry.widget:SetNavigationRuleExplicit(3, following)
            entry.widget:SetNavigationRuleExplicit(0, previous)
            entry.widget:SetNavigationRuleExplicit(1, following)
        end
    end
    for _, entry in ipairs(self.buttons) do
        if entry.id == focus_id then focus = entry.widget end
    end
    active_ui = self
    self.input_active = false
    focus = focus or assert(self.buttons[1], 'Mode page requires an action').widget
    -- Wait for the native delegate bindings and active layer before focus/pause.
    self.pending_focus = focus
end

-- Three offer columns sit above the fixed-service row. The native footer owns
-- return input independently; it is not a fake offer in the navigation grid.
function ShopUI:apply_grid_navigation()
    local nav = self.nav
    local function link(from, direction, to)
        if from and to and from ~= to then from:SetNavigationRuleExplicit(direction, to) end
    end
    local function at(list, index)
        if list and index >= 1 and index <= #list then return list[index] end
    end
    local fixed_top = nav.fixed[1]
    for column_index, column in ipairs(nav.columns) do
        for row_index, widget in ipairs(column) do
            local service = at(nav.fixed, nav.column_fixed[column_index]) or fixed_top
            link(widget, 2, at(column, row_index - 1) or service)
            link(widget, 3, at(column, row_index + 1) or service)
            local left, right = nav.columns[column_index - 1], nav.columns[column_index + 1]
            if left then link(widget, 0, at(left, row_index) or left[#left]) end
            if right then link(widget, 1, at(right, row_index) or right[#right]) end
        end
    end
    for index, widget in ipairs(nav.fixed) do
        link(widget, 0, nav.fixed[index - 1] or nav.fixed[#nav.fixed])
        link(widget, 1, nav.fixed[index + 1] or nav.fixed[1])
        local column = nav.columns[nav.fixed_column[index]]
        if column then
            link(widget, 2, column[#column])
            link(widget, 3, column[1])
        end
    end
end

function ShopUI:dispatch_pending()
    local pending = self.pending_action
    if not pending then return false end
    self.pending_action = nil
    self:animate_entrance(true)
    if pending.generation ~= self.generation or not Native.valid(self.page)
        or not self.page:IsActivated() then return true end
    self.busy = true
    local ok, err = xpcall(pending.action, debug.traceback)
    self.busy = false
    if pending.generation == self.generation and active_ui == self and Native.valid(self.page)
        and self.page:IsActivated() and not self.pending_focus then self.input_active = true end
    if not ok then
        print('[PBZRogue] UI action failed: ' .. tostring(err) .. '\n')
        if self.on_error then self.on_error(err) else self:set_status(Locale.text('操作失败：', 'Action failed: ') .. tostring(err)) end
    end
    return true
end

function ShopUI:animate_entrance(finish)
    if not self.entrance then return end
    if not finish and (not self.native_ready or not Native.valid(self.page)
        or not Native.same(self.router:GetActiveWidget(), self.page)) then return end
    local now = self.gameplay:GetRealTimeSeconds(self.world)
    self.entrance_started = self.entrance_started or now
    local progress = finish and 1 or math.min(1, math.max(0, (now - self.entrance_started) / 0.55))
    local opacity = progress * progress * (3 - 2 * progress)
    for _, view in ipairs(self.entrance) do
        view.image:SetRenderOpacity(opacity)
        view.ink:SetRenderOpacity(opacity)
    end
    if progress == 1 then self.entrance, self.entrance_started = nil, nil end
end

function ShopUI:focus_pending()
    if self.target_ui then self.target_ui:focus_pending(); return end
    if self:dispatch_pending() then return end
    if Native.valid(self.hud_page) then
        local hidden = Native.valid(self.page) or self.router:IsMenuInputModeUI()
        self.hud_page:SetVisibility(hidden and 1 or 4)
    end
    local focus = self.pending_focus
    if active_ui ~= self or not self.native_ready or not Native.valid(self.page) or not Native.valid(focus) then return end
    if not Native.same(self.router:GetActiveWidget(), self.page) or self.page:IsAnyAnimationPlaying() then return end
    self.pending_focus = nil
    focus:SetUserFocus(self.controller)
    focus:SetKeyboardFocus()
    self.input_active = true
    if self.offer_views or self.show_wallet then self:wallet(true) end
    -- CommonUI receives physical input while paused; PlayerController polling
    -- does not. Pause only after the native layer has acquired focus.
    self.gameplay:SetGamePaused(self.world, true)
end

function ShopUI:set_status(message)
    self.status_text = message or ''
    if Native.valid(self.status) then self.status:SetText(Native.text(self.status_text)) end
end

function ShopUI:buy(offer, target)
    local ok, message = self.callbacks.purchase(offer.id, target, offer)
    self.status_text = ok and '' or (message or Locale.text('购买失败；未扣费', 'Purchase failed; no Souls spent'))
    self:update(self.callbacks.refresh(), offer.id)
    self:close_target(offer.id)
end

function ShopUI:close_target(focus_id)
    local target_ui = self.target_ui
    if not target_ui then return end
    self.target_ui = nil
    active_ui = self
    self.input_active = false
    self.pending_focus = assert(self.offer_views[focus_id], 'Missing source offer').widget
    target_ui:destroy()
end

function ShopUI:select_target(offer)
    local model = self.callbacks.refresh()
    local current
    for _, section in ipairs(model.sections) do
        for _, candidate in ipairs(section.offers) do if candidate.id == offer.id then current = candidate end end
    end
    if current ~= offer or not offer.enabled or offer.sold then
        self.status_text = offer.reason or Locale.text('商品已失效；未扣费', 'Offer unavailable; no Souls spent')
        self:update(model, offer.id)
        return
    end
    self:update(model)
    if self.tooltip then self.tooltip.panel:SetVisibility(1) end
    self.hover_view = nil
    local target_ui = ShopUI.new(self.controller, self.world)
    -- A layer reuses its active widget of the same class. Use the native modal
    -- layer so the chooser cannot overwrite the still-live shop page.
    target_ui.layer = 'UI.Layer.GameSystem'
    self.target_ui = target_ui
    target_ui.on_error = self.on_error
    local refresh = function()
        self:update(self.callbacks.refresh(), offer.id)
        self:close_target(offer.id)
    end
    -- Keep the shop underneath the chooser; returning never rebuilds its list.
    target_ui:begin_page(offer.title, '')
    target_ui.show_wallet = true
    target_ui.subtitle_text:SetVisibility(1)
    rect(target_ui.title_text, 360, 184, 620, 54)
    local title_font = target_ui.title_text.Font
    title_font.FontObject = Native.load_object(Locale.text(calligraphy_path, english_title_path))
    title_font.TypefaceFontName = FName('Default')
    target_ui.title_text:SetFont(title_font)
    local _, price_row = target_ui:price_label(target_ui.canvas, offer.price, 1240, 190, 26)
    price_row.Slot:SetAlignment({X = 1, Y = 0})
    target_ui:action_bar()
    local row_height = math.min(104, 450 / #offer.targets)
    for index, target in ipairs(offer.targets) do
        local y = 310 + (index - 1) * row_height
        local button = target_ui:button(target_ui.canvas, target.key, target.title, model.balance >= offer.price,
            function() self:buy(offer, target.key) end, 24)
        rect(button, 320, y, 960, 42)
        align_button_label(button, 0)
        button.UseScaleChangeSpacers = false
        button.Image_62:SetDesiredSizeOverride({X = 8, Y = 42})
        button.Image_105:SetDesiredSizeOverride({X = 8, Y = 42})
        local detail = rect(target_ui:text(target_ui.canvas, target.detail or '', 18), 328, y + 44, 944, 32)
        local font = detail.Font
        if Locale.is_chinese() then
            font.FontObject, font.TypefaceFontName = title_font.FontObject, FName('Default')
            detail:SetFont(font)
        end
        detail:SetJustification(0)
        detail:SetVisibility(3)
    end
    target_ui.cancel = refresh
    target_ui:finish_page()
end

function ShopUI:update_offer(view, offer)
    view.offer = offer
    if self.hover_view == view then self.hover_view = nil end
    local enabled = offer.enabled ~= false and not offer.sold
    view.widget:SetButtonText(Native.text(offer.title))
    view.widget:SetIsInteractionEnabled(enabled)
    self.actions[view.path] = enabled and view.action or nil
    view.service:SetText(Native.text(offer.service or ''))
    view.price:SetText(Native.text(offer.price ~= nil and money(offer.price) or ''))
    view.reason:SetText(Native.text(offer.sold and Locale.text('已售罄', 'Sold out')
        or (not enabled and (offer.reason or Locale.text('暂不可购买', 'Unavailable')) or '')))
    if view.icon_path ~= offer.icon then
        local texture, bounds = self.art:icon(offer.icon)
        if bounds then
            -- Fit the visible artwork, not the large transparent render canvas.
            local brush = self.library:MakeBrushFromTexture(texture, bounds[5], bounds[6])
            local uv = brush.UVRegion
            uv.min.X, uv.min.Y = bounds[1], bounds[2]
            uv.max.X, uv.max.Y = bounds[3], bounds[4]
            uv.bIsValid = true
            view.image:SetBrush(brush)
        else
            view.image:SetBrushFromTexture(texture, true)
        end
        view.icon_path = offer.icon
    end
end

function ShopUI:offer(parent, offer, width, icon_height)
    local view = {panel = parent, width = width, icon_height = icon_height}
    view.action = function()
        local current = view.offer
        if current.targets then self:select_target(current) else self:buy(current) end
    end
    local ink = self:widget('Image')
    ink:SetVisibility(3) -- Decorative only; never intercept native input.
    ink:SetBrushFromTexture(self.art:hud_texture('shop-icon-ink.png'), true)
    view.ink = ink
    parent:AddChild(ink)
    local ink_size = icon_height * 1.35
    rect(ink, (width - ink_size) / 2, (icon_height - ink_size) / 2, ink_size, ink_size)
    local picture = self:widget('ScaleBox')
    picture:SetStretch(2)
    parent:AddChild(picture)
    rect(picture, 40, 0, width - 80, icon_height)
    view.image = self:widget('Image')
    view.image:SetVisibility(offer.tooltip and 0 or 3)
    picture:SetContent(view.image)
    local widget, path = self:button(parent, offer.id, '', true, view.action, 26)
    rect(widget, 12, icon_height, width - 24, 34)
    align_button_label(widget, 2)
    -- The native menu reserves 110 px on each side for its animated ink ends.
    -- Fit those ends to cards; retain the original brush instead of clipping it.
    widget.UseScaleChangeSpacers = false
    widget.Image_62:SetDesiredSizeOverride({X = 8, Y = 34})
    widget.Image_105:SetDesiredSizeOverride({X = 8, Y = 34})
    -- SetHideInputAction owns glyph visibility across all native focus transitions.
    view.widget, view.path = widget, path
    local service_line = self:widget('ScaleBox')
    service_line:SetStretch(2)
    service_line:SetStretchDirection(1) -- DownOnly: long inherited-slot summaries stay inside their card.
    parent:AddChild(service_line)
    rect(service_line, 8, icon_height + 34, width - 16, 18)
    view.service = self:text(service_line, '', width < 400 and 19 or 17)
    view.price = self:price_label(parent, offer.price, width / 2, icon_height + 51, width < 400 and 28 or 24)
    view.reason = rect(self:text(parent, '', 14), 8, icon_height + 82, width - 16, 16)
    for _, text in ipairs({view.service, view.price, view.reason}) do
        text:SetJustification(1)
        text:SetAutoWrapText(false)
    end
    view.reason:SetColorAndOpacity({SpecifiedColor = {R = 0.86, G = 0.64, B = 0.59, A = 1}, ColorUseRule = 0})
    self.offer_views[offer.id] = view
    self:update_offer(view, offer)
    view.image:SetRenderOpacity(0)
    view.ink:SetRenderOpacity(0)
    self.entrance[#self.entrance + 1] = view
    return widget
end

-- Native Slate owns hover detection, including DPI/window scaling and occlusion.
-- Place the display-only popup in the same 1600 x 1000 canvas as its source card.
local function update_tooltip(ui)
    if not ui.offer_views then return end
    local view
    if ui.input_active and not ui.target_ui and Native.valid(ui.page)
        and Native.same(ui.router:GetActiveWidget(), ui.page) then
        for _, candidate in pairs(ui.offer_views) do
            if candidate.offer.tooltip and candidate.image:IsHovered() then
                view = candidate
                break
            end
        end
    end
    if not view then
        if ui.tooltip then ui.tooltip.panel:SetVisibility(1) end
        ui.hover_view = nil
        return
    end
    local tip = ui.tooltip
    if not tip then
        local panel = ui:widget('Border')
        panel:SetVisibility(3) -- Display-only, including all native descendants.
        panel:SetBrushColor({R = 0.025, G = 0.025, B = 0.025, A = 0.97})
        panel:SetPadding(padding(20))
        ui.canvas:AddChild(panel)
        panel.Slot:SetZOrder(100)
        local scale = ui:widget('ScaleBox')
        scale:SetStretch(2)
        scale:SetStretchDirection(1)
        panel:SetContent(scale)
        tip = {panel = panel, scale = scale}
        ui.tooltip = tip
    end
    if ui.hover_view ~= view then
        local data = view.offer.tooltip
        local class_path = description_classes[data.side == 'right' and 'weapon' or 'item']
        -- Remove the previous native widget so its Destruct cancels async text
        -- loads and scroll timers; no hidden widget retains an input recipient.
        tip.scale:ClearChildren()
        local content = ui.library:Create(ui.world, Native.load_class(class_path), ui.controller)
        assert(Native.valid(content), 'Cannot create native item description')
        tip.content = content
        tip.scale:SetContent(content)
        tip.panel:SetVisibility(3)
        content:ForceLayoutPrepass()
        description_serial = description_serial + 1
        local token = table.concat({'PBZRogueDesc', data.kind, data.item, data.level,
            data.soul and '1' or '0', description_serial}, ';')
        ui.description_ready = nil
        local bridge = StaticConstructObject(Native.load_class(description_class_path), content, FName(token))
        local path = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetPathName(content))
        assert(Native.valid(bridge) and ui.description_ready == path,
            page_bridge_error or 'Native item description did not initialize')
        content:ForceLayoutPrepass()
        local desired = content:GetDesiredSize()
        local height = math.min(800, math.max(160, desired.Y * math.min(1, 380 / math.max(1, desired.X)) + 40))
        local position = view.panel.Slot:GetPosition()
        local size = view.image.Brush.ImageSize
        local scale = math.min((view.width - 80) / size.X, view.icon_height / size.Y)
        local left = position.X + (view.width - size.X * scale) / 2
        local top = position.Y + (view.icon_height - size.Y * scale) / 2
        local x = data.side == 'right' and left + size.X * scale + 16 or left - 436
        rect(tip.panel, math.max(16, math.min(1164, x)), math.max(16, math.min(984 - height, top)), 420, height)
        ui.hover_view = view
    end
end

function ShopUI:show(model, callbacks)
    self.callbacks = callbacks
    self.status_text = ''
    self:update(model)
end

function ShopUI:update(model, focus_id)
    self.model = model
    if self.offer_views then
        for index, section in ipairs(model.sections) do
            for _, offer in ipairs(section.offers) do
                self:update_offer(assert(self.offer_views[offer.id], 'Shop offer changed during refresh'), offer)
            end
            self.section_reasons[index]:SetText(Native.text(section.reason or ''))
        end
        for _, offer in ipairs(model.fixed) do
            self:update_offer(assert(self.offer_views[offer.id], 'Shop service changed during refresh'), offer)
        end
        self:set_status(self.status_text)
        return
    end
    self:begin_page('', '')
    self.offer_views, self.section_reasons = {}, {}
    self.entrance = {}
    self.title_text:SetVisibility(1)
    self.subtitle_text:SetVisibility(1)
    local title_scale = self:widget('ScaleBox')
    title_scale:SetStretch(2)
    title_scale:SetVisibility(3)
    self.canvas:AddChild(title_scale)
    rect(title_scale, -76, 100, 288, 288)
    local title = self:widget('Image')
    title:SetVisibility(3)
    title:SetBrushFromTexture(self.art:shop_title(), true)
    title_scale:SetContent(title)
    local nav_columns = {}
    for column_index, section in ipairs(model.sections) do
        local x = 80 + (column_index - 1) * 480
        local heading_scale = self:widget('ScaleBox')
        heading_scale:SetStretch(2)
        heading_scale:SetVisibility(3)
        self.canvas:AddChild(heading_scale)
        rect(heading_scale, x + 90, 92, 300, 44)
        local heading = self:widget('Image')
        heading:SetVisibility(3)
        heading:SetBrushFromTexture(self.art:hud_texture(
            'shop-heading-' .. column_index .. Locale.text('.png', '-en.png')), true)
        heading_scale:SetContent(heading)
        local column = {}
        for row_index, offer in ipairs(section.offers) do
            local panel = self:widget('CanvasPanel')
            self.canvas:AddChild(panel)
            rect(panel, x, 132 + (row_index - 1) * 188, 480, 188)
            local widget = self:offer(panel, offer, 480, 90)
            column[#column + 1] = widget
        end
        nav_columns[#nav_columns + 1] = column
        local reason = rect(self:text(self.canvas, section.reason or '', 18),
            x + 20, 132 + #section.offers * 188, 440, 28)
        reason:SetJustification(1)
        self.section_reasons[#self.section_reasons + 1] = reason
    end
    rect(self:text(self.canvas, Locale.text('固定服务', 'Fixed Services'), 23),
        80, 714, Locale.is_chinese() and 200 or 300, 34)
    local nav_fixed = {}
    for index, offer in ipairs(model.fixed) do
        local panel = self:widget('CanvasPanel')
        self.canvas:AddChild(panel)
        rect(panel, 80 + (index - 1) * 360, 748, 360, 206)
        local widget = self:offer(panel, offer, 360, 108)
        nav_fixed[#nav_fixed + 1] = widget
    end
    self:action_bar()
    self.cancel = function() self.callbacks.close() end
    if #nav_columns > 0 and #nav_fixed > 0 then
        self.nav = {columns = nav_columns, fixed = nav_fixed,
            column_fixed = {1, 2, 4}, fixed_column = {1, 2, 2, 3}}
    end
    self:finish_page(focus_id)
end

function ShopUI:start_page(note, choices)
    self.status_text = ''
    self:begin_page('', '')
    self.title_text:SetVisibility(1)
    self.subtitle_text:SetVisibility(1)
    local title_scale = self:widget('ScaleBox')
    title_scale:SetStretch(2)
    title_scale:SetVisibility(3)
    self.canvas:AddChild(title_scale)
    rect(title_scale, 80, 28, 440, 126)
    local title = self:widget('Image')
    title:SetVisibility(3)
    title:SetBrushFromTexture(self.art:hud_texture(Locale.text('mode-title.png', 'mode-title-en.png')), true)
    title_scale:SetContent(title)
    local title_font = Native.load_object(Locale.text(calligraphy_path, english_title_path))
    local body_font = Native.load_object(Locale.text(calligraphy_path, english_body_path))
    local sections = {
        {title = Locale.text('游戏循环', 'The Trial'), body = Locale.text(
            '两波小怪 → 中场休整 → 首领战 → 层末休整，逐层挑战，永无终点。\n\n靠近中央铃铛，可进入商店或人物升级。选择「下一波」才会开战。\n\n从铃铛出战前，回满生命、药品和影之武装点数；两波小怪之间不补给。\n\n每波结束自动存档，退出后可续局。死亡结束本局，重来不继承成长。',
            'Two enemy waves, a rest, a boss fight, then another rest. Climb floor after floor with no end.\n\nVisit the central bell to shop or upgrade your character. Combat starts only when you choose “Next Wave”.\n\nLeaving the bell restores health, medicine and Phantom Edge charges. There is no refill between the two enemy waves.\n\nProgress saves after each wave, so you can quit and resume. Death ends the run; restarting resets all progress.')},
        {title = Locale.text('购买系统', 'The Shop'), body = Locale.text(
            '击败敌人获得「魂」，用于购买装备与强化。\n\n商店随机提供武器、影之武装、饰品／药品各三项。升级、购买替换与武器铸魂沿用游戏装备系统。\n\n下方固定提供生命上限、攻击力、杀气上限升级，以及榕树之心购买；榕树之心用于人物技能升级。\n\n随机商品购买后售罄，重开商店不会刷新。替换时选择目标栏位，取消不扣魂。',
            'Defeat enemies to earn Souls for equipment and upgrades.\n\nThe shop offers three random choices each of weapons, Phantom Edges, and accessories or medicine. Equipment upgrades, replacements and weapon Soul Tempering use the game’s equipment system.\n\nFixed services below improve max health, attack and max Sha-Chi, and sell The Banyan’s Heart for character skills.\n\nRandom offers sell out when bought. Reopening does not reroll them. Choose a slot when replacing gear; canceling costs no Souls.')}
    }
    for index, section in ipairs(sections) do
        local x = 100 + (index - 1) * 740
        for _, entry in ipairs({
            {text = section.title, size = 36, y = 195, height = 58, font = title_font},
            {text = section.body, size = 25, y = 270, height = 440, font = body_font}
        }) do
            local text = rect(self:text(self.canvas, entry.text, entry.size, 620), x, entry.y, 620, entry.height)
            local font = text.Font
            font.FontObject, font.TypefaceFontName = entry.font, FName('Default')
            text:SetFont(font)
            text:SetJustification(0)
        end
    end
    rect(self:text(self.canvas, note or '', 20), 100, 706, 1380, 36)
    for index, choice in ipairs(choices) do
        local button = self:button(self.canvas, choice.id, choice.label, true, choice.on_select)
        rect(button, 520, 760 + (index - 1) * 94, 560, 72)
        align_button_label(button, 2)
        if choice.id == 'quit' then self.cancel = choice.on_select end
    end
    self:finish_page()
end

function ShopUI:confirm_restart(confirm, cancel)
    assert(not self.target_ui, 'A modal is already open')
    local dialog = ShopUI.new(self.controller, self.world)
    dialog.layer = 'UI.Layer.GameSystem'
    dialog.on_error = self.on_error
    self.target_ui = dialog
    dialog:begin_page(Locale.text('重开本局？', 'Restart this run?'),
        Locale.text('当前局的装备、强化和进度将全部清除。\n确认后从第 1 层开始，无法撤销。',
            'All equipment, upgrades and progress in this run will be lost.\nYou will start again on Floor 1. This cannot be undone.'))
    dialog.title_text:SetJustification(1)
    dialog.subtitle_text:SetJustification(1)
    for index, choice in ipairs({
        {id = 'cancel', label = Locale.text('取消，返回铃铛', 'Cancel — Return to Bell'), action = cancel},
        {id = 'confirm', label = Locale.text('确认重开', 'Restart Run'), action = function()
            local ok, message = confirm()
            if ok == false then dialog:set_status(message) end
        end}
    }) do
        local button = dialog:button(dialog.canvas, choice.id, choice.label, true, choice.action)
        rect(button, 520, 460 + (index - 1) * 110, 560, 72)
        align_button_label(button, 2)
    end
    dialog.cancel = cancel
    dialog:action_bar()
    dialog:finish_page('cancel')
end

function ShopUI:death_page(choices)
    self.status_text = ''
    -- Leave the native death page on Menu; only the actions occupy GameSystem.
    self.layer = 'UI.Layer.GameSystem'
    self:begin_page('', '', false)
    self.title_text:SetVisibility(1)
    self.subtitle_text:SetVisibility(1)
    for index, choice in ipairs(choices) do
        local button = self:button(self.canvas, choice.id, choice.label, true, choice.on_select)
        rect(button, 520, 620 + (index - 1) * 100, 560, 72)
        align_button_label(button, 2)
        if choice.id == 'quit' then self.cancel = choice.on_select end
    end
    self:finish_page('restart')
end

function ShopUI:message(title, body, choices)
    self.status_text = ''
    self:begin_page(title, body)
    -- Error and end-of-run messages retain the native bounded action stack.
    rect(self.subtitle_text, 250, 170, 1100, 300)
    self.subtitle_text:SetJustification(1)
    for index, choice in ipairs(choices) do
        local button = self:button(self.canvas, choice.id, choice.label, true, choice.on_select)
        rect(button, 520, 620 + (index - 1) * 100, 560, 86)
        if choice.id == 'quit' then self.cancel = choice.on_select end
    end
    rect(self:text(self.canvas, Locale.text('上下选择    确认    返回', 'Up / Down: Select    Confirm    Back'), 20),
        560, 940, 480, 32):SetJustification(1)
    self:finish_page()
end

function ShopUI:hide(world_ended)
    if self.wallet_visible then
        if world_ended then
            wallet_users = wallet_users - 1
            if wallet_users == 0 then wallet_decorations = {} end
        else
            self:wallet(false)
        end
    end
    self.wallet_visible = false
    -- Unpublish every callback/widget before PopContent's lifecycle broadcasts.
    local page = self.page
    self.input_active, self.native_ready = false, false
    self.generation = (self.generation or 0) + 1
    self.pending_action, self.pending_focus = nil, nil
    self.page, self.page_path, self.tree, self.status = nil, nil, nil, nil
    self.buttons, self.actions, self.nav, self.cancel = {}, {}, nil, nil
    self.offer_views, self.section_reasons, self.title_text, self.subtitle_text = nil, nil, nil, nil
    self.tooltip, self.hover_view = nil, nil
    self.canvas, self.content, self.show_wallet = nil, nil, nil
    self.entrance, self.entrance_started = nil, nil
    if self.target_ui then
        local target_ui = self.target_ui
        self.target_ui = nil
        target_ui:destroy(world_ended)
    end
    if active_ui == self then active_ui = nil end
    if not world_ended then
        if Native.valid(self.button_group) then self.button_group:RemoveAll() end
        if Native.valid(page) then self.extensions:PopContentFromLayer(page) end
        if self.captured then self.gameplay:SetGamePaused(self.world, self.was_paused) end
    end
    self.captured = false
end

function ShopUI:hud(model)
    local language = Locale.language()
    if Native.valid(self.hud_page) and self.hud_language ~= language then
        self.hud_page:RemoveFromParent()
        self.hud_page, self.hud_view = nil, nil
    end
    if not Native.valid(self.hud_page) then
        self.hud_page = self.library:Create(self.world, Native.load_class('/Script/ProjectPBZ.PBZCommonUserWidget'), self.controller)
        local tree = self.hud_page.WidgetTree
        if not Native.valid(tree) then
            tree = Native.construct('/Script/UMG.WidgetTree', self.hud_page)
            self.hud_page.WidgetTree = tree
        end
        local canvas = Native.construct('/Script/UMG.CanvasPanel', tree)
        tree.RootWidget = canvas
        self.hud_view = HudUI.new(tree, canvas, self.art, self.button_class:GetCDO().Font)
        self.hud_page:SetVisibility(Native.valid(self.page) and 1 or 4)
        self.hud_page:AddToViewport(9000)
        self.hud_language = language
    end
    self.hud_view:update(model)
end

function ShopUI:destroy(world_ended)
    self:hide(world_ended)
    if not world_ended and Native.valid(self.hud_page) then self.hud_page:RemoveFromParent() end
    self.hud_page, self.hud_view = nil, nil
    Native.release(self.button_group)
    self.button_group = nil
    if self.art then self.art:destroy(); self.art = nil end
    self.callbacks, self.model = nil, nil
end

-- Zero delay is once per EngineTick in the pinned loader, including while paused.
-- Keep visual interpolation off the 250 ms gameplay/save loop; no async Lua.
LoopInGameThreadWithDelay(0, function()
    local ui = active_ui
    if not ui or (not ui.entrance and not ui.offer_views) then return end
    local ok, message = pcall(function()
        ui:animate_entrance()
        update_tooltip(ui)
    end)
    if not ok then
        ui.entrance, ui.entrance_started = nil, nil
        if ui.on_error then ui.on_error(message) else ui:set_status(message) end
    end
end)

return ShopUI
