// Appended to UI/Widget/StartMenu.js. Physical input stays in CommonUI/PBZ;
// only action identifiers cross the existing reflected save-test bridge to Lua.
(() => {
    const puerts = require("puerts");
    const valid = object => !!object && UE.KismetSystemLibrary.IsValid(object);
    const path = object => UE.KismetSystemLibrary.GetPathName(object);
    function emit(context, event, ...parts) {
        const save = UE.SubsystemBlueprintLibrary.GetGameInstanceSubsystem(context, UE.PBZSaveLoadSubsystem.StaticClass());
        if (!valid(save))
            throw new Error("PBZRogue: UI event bridge has no save subsystem");
        save.RecordFiredDelegateForTest("PBZRogue.UI." + event + "|" + parts.join("|"), new UE.JsonObjectWrapper(), 0, false);
    }
    function collectButtons(widget, result) {
        if (!valid(widget))
            return result;
        if (widget instanceof UE.CommonButtonBase) {
            if (widget.GetIsEnabled() && widget.GetIsFocusable())
                result.push(widget);
        } else if (widget instanceof UE.PanelWidget) {
            for (let i = 0; i < widget.GetChildrenCount(); ++i)
                collectButtons(widget.GetChildAt(i), result);
        }
        return result;
    }
    function detachButtons(owner) {
        for (const [button, handler] of owner.pbzRogueClickBindings || []) {
            if (valid(button))
                button.OnButtonBaseClicked.Remove(handler);
        }
        owner.pbzRogueClickBindings = undefined;
    }
    // Generate once a live context can report startup exceptions through the
    // proven bridge, rather than aborting the module import without a receiver.
    function createPageClass() {
    class PBZRoguePage extends UE.PBZActivatableWidget {
        OnInitialized() {
            // A native PBZActivatableWidget has no designer tree. Build the host
            // before CommonUI adds its Slate widget to the layer stack.
            if (!valid(this.WidgetTree))
                this.WidgetTree = UE.NewObject(UE.WidgetTree.StaticClass(), this);
            this.WidgetTree.RootWidget = UE.NewObject(UE.Overlay.StaticClass(), this.WidgetTree);
            this.bHasScriptImplementedTick = true;
            this.InputConfig = UE.EPBZWidgetInputMode.Menu;
            this.bBindDefaultBackKey = false;
            this.bPauseGameWhenOpen = false;
        }
        BP_OnActivated() {
            detachButtons(this);
            this.pbzRogueButtons = undefined;
            this.ClearBackKey();
            UIHelper_1.default.bindKeySafe(this, "PBZRogueConfirm", UIHelper_1.default.MakePBZInputDataTableHandle("DefaultConfirm"), false, () => {
                if (!this.IsActivated())
                    return;
                const controller = this.GetOwningPlayer();
                const button = (this.pbzRogueButtons || []).find(item => valid(item) && item.GetIsEnabled()
                    && (item.HasUserFocus(controller) || item.HasUserFocusedDescendants(controller)));
                if (button)
                    emit(this, "Confirm", path(this), path(button));
            }, UE.EInputEvent.IE_Pressed);
            UIHelper_1.default.bindKeySafe(this, "PBZRogueBack", UIHelper_1.default.MakePBZInputDataTableHandle("DefaultBack"), false, () => {
                if (this.IsActivated())
                    emit(this, "Back", path(this));
            }, UE.EInputEvent.IE_Pressed);
            // Publish the native Escape/B return action to PBZActionBar, exactly
            // as native screens do. Backspace remains an undisplayed alias.
            UIHelper_1.default.bindKeySafe(this, "PBZRogueEscape", UIHelper_1.default.MakePBZInputDataTableHandle("Return_Game"), true, () => {
                if (this.IsActivated())
                    emit(this, "Back", path(this));
            }, UE.EInputEvent.IE_Pressed);
        }
        Tick() {
            if (!this.IsActivated() || this.pbzRogueButtons)
                return;
            const buttons = collectButtons(this.WidgetTree.RootWidget, []);
            if (!buttons.length)
                return; // Lua finishes the page in the same game-thread update.
            this.pbzRogueButtons = buttons;
            this.pbzRogueClickBindings = new Map();
            for (const button of buttons) {
                const handler = () => {
                    if (this.IsActivated() && valid(button) && button.GetIsEnabled())
                        emit(this, "Click", path(this), path(button));
                };
                button.OnButtonBaseClicked.Add(handler);
                this.pbzRogueClickBindings.set(button, handler);
            }
            emit(this, "Ready", path(this));
        }
        BP_GetDesiredFocusTarget() {
            return collectButtons(this.WidgetTree && this.WidgetTree.RootWidget, [])[0];
        }
        BP_OnDeactivated() {
            this.RemoveKey("DefaultConfirm");
            this.RemoveKey("DefaultBack");
            this.RemoveKey("Return_Game");
            detachButtons(this);
            this.pbzRogueButtons = undefined;
        }
        Destruct() {
            detachButtons(this);
            this.pbzRogueButtons = undefined;
        }
    }
        // This game's native UE constructors have a null prototype chain.
        // makeUClass calls cls.hasOwnProperty; supply it only on our subclass.
        Object.defineProperty(PBZRoguePage, "hasOwnProperty", {value: Object.prototype.hasOwnProperty});
        return puerts.makeUClass(PBZRoguePage);
    }
    function createDeathWatcherClass() {
        class PBZRogueDeathWatcher extends UE.Object {
            Constructor() {
                const component = UE.KismetSystemLibrary.GetOuterObject(this);
                if (!valid(component) || !(component instanceof UE.NiagaraComponent))
                    return;
                const token = String(UE.KismetSystemLibrary.GetObjectName(this));
                const finished = () => {
                    if (!valid(component))
                        return;
                    // AutoRelease may reuse this component after the broadcast.
                    component.OnSystemFinished.Remove(finished);
                    const save = UE.SubsystemBlueprintLibrary.GetGameInstanceSubsystem(component, UE.PBZSaveLoadSubsystem.StaticClass());
                    if (valid(save))
                        emit(component, "DissolveFinished", token);
                };
                component.OnSystemFinished.Add(finished);
                emit(component, "DissolveBound", token);
            }
        }
        Object.defineProperty(PBZRogueDeathWatcher, "hasOwnProperty", {value: Object.prototype.hasOwnProperty});
        return puerts.makeUClass(PBZRogueDeathWatcher);
    }
    // Lua supplies scalar item identity through a short-lived named UObject.
    // The native widget's own mixin owns all rich text, icons and stat loading.
    function createDescriptionClass() {
        class PBZRogueDescription extends UE.Object {
            Constructor() {
                const widget = UE.KismetSystemLibrary.GetOuterObject(this);
                try {
                    const [, kind, item, levelText, soulText] = String(this.GetName()).split(";");
                    const level = Number(levelText);
                    const backpack = UE.SubsystemBlueprintLibrary.GetWorldSubsystem(widget, UE.PBZBackPackSubsystem.StaticClass());
                    if (!valid(widget) || !valid(backpack) || !Number.isInteger(level))
                        throw new Error("PBZRogue: invalid native description context");
                    widget.InitLayout();
                    if (kind === "weapons")
                        widget.initMainWeapon_Normal(item, level, soulText === "1", backpack);
                    else if (kind === "shadow")
                        widget.initShaChiWeapon_Normal(item, level, soulText === "1", backpack);
                    else if (kind === "medicine")
                        widget.initMedicine_Normal(item, level, backpack);
                    else if (kind === "accessory")
                        widget.initAccessory_Normal(item, level, backpack);
                    else
                        throw new Error("PBZRogue: unsupported description kind " + kind);
                    // This is an information popup, not the native upgrade screen.
                    for (const name of ["BottomBox", "PreviewUpgradeBox", "CurrentPreviewText", "HB_Arrows", "W_LongPressButton", "W_Upgrade_NeedItemPanel", "BuySellEntryBox"])
                        if (valid(widget[name]))
                            widget[name].SetVisibility(UE.ESlateVisibility.Collapsed);
                    if (widget.scrollRecipientGuardTimer) {
                        clearTimeout(widget.scrollRecipientGuardTimer);
                        widget.scrollRecipientGuardTimer = 0;
                    }
                    widget.UnregisterScrollRecipientExternal(widget.PBZScrollBox);
                    widget.SetVisibility(UE.ESlateVisibility.HitTestInvisible);
                    emit(widget, "DescriptionReady", path(widget));
                } catch (error) {
                    emit(widget, "Error", String(error && error.stack || error));
                    throw error;
                }
            }
        }
        Object.defineProperty(PBZRogueDescription, "hasOwnProperty", {value: Object.prototype.hasOwnProperty});
        return puerts.makeUClass(PBZRogueDescription);
    }
    let descriptionClass;
    let deathWatcherClass;
    let pageClass;
    const prototype = exports.StartmenuMinXinInterface.prototype;
    const construct = prototype.Construct;
    const tick = prototype.Tick;
    const destruct = prototype.Destruct;
    prototype.Construct = function (...args) {
        const result = construct.apply(this, args);
        this.pbzRogueClickBindings = new Map();
        try {
            if (!pageClass)
                pageClass = createPageClass();
            emit(this, "Class", path(pageClass));
            if (!deathWatcherClass)
                deathWatcherClass = createDeathWatcherClass();
            emit(this, "DissolveClass", path(deathWatcherClass));
            if (!descriptionClass)
                descriptionClass = createDescriptionClass();
            emit(this, "DescriptionClass", path(descriptionClass));
        } catch (error) {
            emit(this, "Error", String(error && error.stack || error));
            throw error;
        }
        return result;
    };
    prototype.Tick = function (...args) {
        const result = tick.apply(this, args);
        if (!this.IsActivated())
            return result;
        const group = this.GetButtonGroupByID("StartMenu");
        if (!valid(group))
            return result;
        const bindings = this.pbzRogueClickBindings;
        for (let i = 0; i < group.GetButtonCount(); ++i) {
            const button = group.GetButtonBaseAtIndex(i);
            if (!valid(button) || bindings.has(button))
                continue;
            const handler = () => {
                if (this.IsActivated() && valid(button) && button.GetIsEnabled())
                    emit(this, "Menu", path(button));
            };
            button.OnButtonBaseClicked.Add(handler);
            bindings.set(button, handler);
        }
        return result;
    };
    prototype.Destruct = function (...args) {
        detachButtons(this);
        return destruct.apply(this, args);
    };
})();
