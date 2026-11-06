// Appended to UI/Widget/BellMenu.js; the shipped CommonUI widget remains the menu.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const text = require("cpp").FText;
    function localized(zh, en) {
        return /^zh(?:[-_]|$)/i.test(UE.KismetInternationalizationLibrary.GetCurrentLanguage()) ? zh : en;
    }
    const prototype = exports.BellMenuMinXinInterface.prototype;
    const originalActivated = prototype.BP_OnActivated;
    const originalDeactivated = prototype.BP_OnDeactivated;
    const originalClose = prototype.ClickCloseButton_BrokenBell;
    const originalDestruct = prototype.Destruct;
    const originalFocusTarget = prototype.BP_GetDesiredFocusTarget;
    // Restore BP bindings/labels if CommonUI pools this instance for a story bell.
    const nativeButtons = [
        ["TeleportBtn_BrokenBell", "UI_BellMenu_23", "BndEvt__W_BellMenu_TeleportBtn_BrokenBell_K2Node_ComponentBoundEvent_9_CommonButtonBaseClicked__DelegateSignature"],
        ["TeleportBtn", "UI_BellMenu_01", "BndEvt__BellInteractWidget_TeleportBtn_K2Node_ComponentBoundEvent_1_CommonButtonBaseClicked__DelegateSignature"],
        ["ItemUpgradeButton", "UI_BellMenu_22", "BndEvt__W_BellMenu_WeaponUpgradeButton_K2Node_ComponentBoundEvent_2_CommonButtonBaseClicked__DelegateSignature"],
        ["ShopButton", "UI_BellMenu_15", "BndEvt__W_BellMenu_ShopButton_K2Node_ComponentBoundEvent_8_CommonButtonBaseClicked__DelegateSignature"],
        ["AbilityCultivation", "UI_BellMenu_20", "BndEvt__W_BellMenu_AbilityCultivation_K2Node_ComponentBoundEvent_7_CommonButtonBaseClicked__DelegateSignature"],
        ["ManualSave", "UI_BellMenu_09", undefined],
        ["JhsyButton", "UI_BellMenu_26", "BndEvt__W_BellMenu_JhsyButton_K2Node_ComponentBoundEvent_6_CommonButtonBaseClicked__DelegateSignature"],
        ["CloseBtn", "UI_BellMenu_02", "BndEvt__BellInteractWidget_CloseBtn_K2Node_ComponentBoundEvent_4_CommonButtonBaseClicked__DelegateSignature"]
    ];
    function restoreButtons(widget) {
        for (const {button, handler} of widget.pbzRogueButtonHandlers || [])
            button.OnButtonBaseClicked.Remove(handler);
        widget.pbzRogueButtonHandlers = undefined;
        const gate = widget.pbzRogueShopGate;
        if (gate) {
            gate.border.VisibleType = gate.visibleType;
            gate.border.HiddenType = gate.hiddenType;
            gate.border.SetVisibility(gate.visibility);
            widget.pbzRogueShopGate = undefined;
        }
        if (!widget.pbzRogueVisibilities)
            return;
        for (let i = 0; i < nativeButtons.length; i++) {
            const [name, key, binding] = nativeButtons[i];
            const button = widget[name];
            button.SetButtonTextByKey(key);
            button.SetVisibility(widget.pbzRogueVisibilities[i]);
            button.SetIsInteractionEnabled(true);
            if (binding)
                button.OnButtonBaseClicked.Add(widget, binding);
        }
        widget.pbzRogueVisibilities = undefined;
        widget.lastFocusedButton = undefined;
    }
    function owner(widget) {
        // Puerts resolves FWeakObjectProperty to its UObject automatically;
        // only the UE4SS/Lua boundary needs OwnerBell:Get().
        const bell = widget.OwnerBell;
        const player = UE.GameplayStatics.GetPlayerCharacter(widget, 0);
        return bell && UE.KismetSystemLibrary.IsValid(bell) &&
            bell.ActorHasTag("PBZRogue.NativeBell") && player &&
            player.ActorHasTag("PBZRogue.NativeBellPlayer") ? bell : undefined;
    }
    function signal(bell, suffix) {
        const tag = "PBZRogue.NativeBell" + suffix;
        if (!bell.ActorHasTag(tag))
            bell.Tags.Add(tag);
    }
    prototype.BP_OnActivated = function() {
        const bell = owner(this);
        if (!bell)
            return originalActivated.call(this);
        try {
            this.pbzRogueActionPending = false;
            this.playOpenSoundOnce();
            this.StopAllAnimations();
            this.Image_102.SetRenderOpacity(0);
            this.Image_50.SetRenderOpacity(0);
            this.Text.SetVisibility(UE.ESlateVisibility.Hidden);
            this.CurrentBellNameText.SetText(text.FromString(localized("无间试炼", "Endless Trials")));
            // ShopButton is inside a PBZVisibilityBorder gated by the story's
            // UI.VisibilityTag.Shop. Both query outcomes must stay visible for
            // this menu; setting only the child is undone by native tag refresh.
            if (!this.pbzRogueShopGate) {
                const border = this.ShopButton.GetParent();
                this.pbzRogueShopGate = {border, visibleType: border.VisibleType,
                    hiddenType: border.HiddenType, visibility: border.GetVisibility()};
            }
            const border = this.pbzRogueShopGate.border;
            border.VisibleType = UE.ESlateVisibility.SelfHitTestInvisible;
            border.HiddenType = UE.ESlateVisibility.SelfHitTestInvisible;
            border.SetVisibility(UE.ESlateVisibility.SelfHitTestInvisible);
            this.Activate();
            const group = this.GetButtonGroupByID("BellMenu");
            group.bBindButtonNavigation = true;
            group.RemoveAll();
            // Clear the BP component-bound callbacks as well as JS listeners:
            // hiding travel/save controls alone does not remove their actions.
            this.pbzRogueVisibilities = nativeButtons.map(([name]) => this[name].GetVisibility());
            for (const [name] of nativeButtons) {
                const button = this[name];
                button.OnButtonBaseClicked.Clear();
                button.SetVisibility(UE.ESlateVisibility.Collapsed);
                button.SetIsInteractionEnabled(false);
                if (button.RedPointBox)
                    button.RedPointBox.SetVisibility(UE.ESlateVisibility.Collapsed);
            }
            this.pbzRogueButtonHandlers = [];
            // Screen order is 下一波 → 商店 → 人物升级 → 重开本局 → 返回.
            const entries = [[this.TeleportBtn, localized("下一波", "Next Wave"), "Next"],
                [this.ShopButton, localized("商店", "Shop"), "Shop"],
                [this.AbilityCultivation, localized("人物升级", "Character Upgrades"), "Skills"],
                [this.ManualSave, localized("重开本局", "Restart Run"), "Restart"],
                [this.CloseBtn, localized("返回", "Back"), "Closed"]];
            for (const [button, label, action] of entries) {
                button.SetButtonText(text.FromString(label));
                button.SetVisibility(UE.ESlateVisibility.Visible);
                button.SetIsInteractionEnabled(true);
                const handler = () => {
                    if (this.pbzRogueActionPending || !this.IsActivated())
                        return;
                    if (action === "Closed") {
                        this.ClickCloseButton();
                        return;
                    }
                    if (!bell.ActorHasTag("PBZRogue.NativeBellAllowed"))
                        return;
                    this.pbzRogueActionPending = true;
                    this.lastFocusedButton = button;
                    this.setMenuButtonsInteractionEnabled(false);
                    signal(bell, action);
                };
                button.OnButtonBaseClicked.Add(handler);
                this.pbzRogueButtonHandlers.push({button, handler});
                group.AddWidget(button);
                button.DoSelectedAppearance(button.GetSelected());
            }
            // Explicit vertical navigation keeps the native spatial layout from
            // deciding the order; the five entries run top to bottom and wrap.
            const ordered = entries.map(([button]) => button);
            for (let i = 0; i < ordered.length; i++) {
                const previous = ordered[(i + ordered.length - 1) % ordered.length];
                const following = ordered[(i + 1) % ordered.length];
                ordered[i].SetNavigationRuleExplicit(2, previous);
                ordered[i].SetNavigationRuleExplicit(3, following);
                ordered[i].SetNavigationRuleExplicit(0, previous);
                ordered[i].SetNavigationRuleExplicit(1, following);
            }
            this.bindOptionSwitchSound(group);
            this.playButtonsFadeInStaggered();
            clearTimeout(this.focusTimerId);
            this.focusTimerId = setTimeout(() => {
                this.focusTimerId = 0;
                if (this.IsActivated())
                    (this.lastFocusedButton || this.TeleportBtn).SetFocus();
            }, 60);
            signal(bell, "MenuReady");
            signal(bell, "Entered");
        } catch (error) {
            console.error(error);
            signal(bell, "Error");
            try { this.DeactivateWidget(); }
            catch (cleanupError) { console.error("PBZRogue: bell menu cleanup failed", cleanupError); }
        }
    };
    prototype.BP_GetDesiredFocusTarget = function() {
        if (!owner(this))
            return originalFocusTarget.call(this);
        // Native focus selection also collapses TeleportBtn when travel is
        // disabled. Here it means Next Wave, which has no story travel gate.
        if (this.lastFocusedButton && UE.PBZBlueprintFunctionLibrary.CanFocusToWidget(this.lastFocusedButton))
            return this.lastFocusedButton;
        return this.TeleportBtn;
    };
    prototype.BP_OnDeactivated = function() {
        const bell = owner(this);
        if (bell)
            signal(bell, "Closed");
        // Retains native animation/latent action/focus cleanup. No tutorial was
        // armed in our activation branch, so it cannot queue a tutorial save.
        const result = originalDeactivated.call(this);
        restoreButtons(this);
        return result;
    };
    prototype.ClickCloseButton_BrokenBell = function() {
        if (owner(this))
            return this.ClickCloseButton();
        return originalClose.call(this);
    };
    prototype.Destruct = function() {
        restoreButtons(this);
        return originalDestruct.call(this);
    };
    exports.pbzRogueBellPolicyVersion = 1;
    // MainStart imports BellMenu, but deliberately does NOT import/register the
    // old MelodiousBell/GA module. Install the run-only actor policy explicitly.
    try {
        const actorPolicy = require("../../Level/Actor/Switch/MelodiousBell");
        if (actorPolicy.pbzRogueBellPolicyVersion !== 1)
            throw new Error("PBZRogue: native bell actor patch is missing");
    } catch (error) {
        exports.pbzRogueBellPolicyVersion = 0;
        console.error(error);
    }
})();
