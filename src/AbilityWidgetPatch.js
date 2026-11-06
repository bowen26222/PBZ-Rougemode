// Appended to the shipped UI/Widget/AbilityWidget.js inside the isolated-mode pak.
// The module finishes evaluating before its exported mixin is registered by its caller.
(() => {
    function localized(zh, en) {
        return /^zh(?:[-_]|$)/i.test(UE.KismetInternationalizationLibrary.GetCurrentLanguage()) ? zh : en;
    }
    const modeTag = "PBZRogue.NativeSkills";
    const readyTag = "PBZRogue.NativeSkillsReady";
    // DT_AbilityNodesTable GEClassArray: IncreaseAttack, IncreaseShachi, IncreaseHealth.
    // Accessory, medicine, execution and other skill effects in these bands stay native.
    const disabledNodes = new Set(["HeiShi8", "ShaChiHuPo8", "MemoryFlower8"]);
    const prototype = exports.abilityWidgetMixinInterface.prototype;
    const originalActivated = prototype.BP_OnActivated;
    const originalConditions = prototype.checkNodeActivationConditions;
    const originalState = prototype.getabilityNodeState;
    const originalDescription = prototype.updateDescByCheckCondition;
    const originalPurchase = prototype.executeActivateNode;
    function modePlayer(widget) {
        const player = UE.GameplayStatics.GetPlayerCharacter(widget, 0);
        return player && player.ActorHasTag(modeTag) ? player : undefined;
    }
    function conditions(widget, nodeID, component, data) {
        const node = component.AbilityNodeMap.Get(nodeID);
        if (!node)
            throw new Error("PBZRogue: native ability node missing: " + nodeID);
        const backpack = TsHelper_1.default.getWorldSubsystem(widget, UE.PBZBackPackSubsystem.StaticClass());
        const currentDust = TsHelper_1.default.getcurrentDust(widget);
        const requiredDust = node.GetConsumeDust(node.Level + 1);
        const materials = [];
        // Only actual heart consumption remains; NeedMaterialCount is a historical
        // upgrade-item ownership gate, not a purchase cost, and is never consulted.
        for (const [itemID, need] of data.NeedMaterials) {
            if (itemID === "I_060002")
                materials.push({ itemID, need, has: backpack.GetUsePropAmount(itemID) });
        }
        void data.ConsumeDust; // Keep the by-value struct alive through its borrowed map iteration.
        const result = {
            state: AbilityNodeState.NotActivate,
            failReason: NodeActivationFailReason.None,
            hasParentNodes: false,
            parentNodeIDs: [],
            unlockedParentNodeIDs: [],
            missingSpecialMaterials: {},
            missingNormalMaterials: materials.filter(material => material.has < material.need),
            requiredMaterials: materials,
            requiredDust,
            currentDust
        };
        if (disabledNodes.has(nodeID))
            return result;
        if (node.IsMaxLevel() || node.Level >= data.MaxLevel) {
            result.state = AbilityNodeState.Activated;
            return result;
        }
        if (currentDust < requiredDust)
            result.dustShortage = { need: requiredDust, has: currentDust };
        result.state = result.dustShortage || result.missingNormalMaterials.length > 0
            ? AbilityNodeState.CanActivateNotMaterial
            : node.Level > 0 ? AbilityNodeState.ActivatedNotMaxLevel : AbilityNodeState.CanActivatEnoughMaterial;
        return result;
    }
    prototype.checkNodeActivationConditions = function(nodeID, nodeType, component, manager, data) {
        if (!modePlayer(this))
            return originalConditions.call(this, nodeID, nodeType, component, manager, data);
        return conditions(this, nodeID, component, data);
    };
    prototype.getabilityNodeState = function(nodeID, nodeType, component, manager, data) {
        if (!modePlayer(this))
            return originalState.call(this, nodeID, nodeType, component, manager, data);
        return conditions(this, nodeID, component, data).state;
    };
    prototype.updateDescByCheckCondition = function(nodeID, component, manager, data) {
        if (!modePlayer(this) || !disabledNodes.has(nodeID))
            return originalDescription.call(this, nodeID, component, manager, data);
        this.currentSelectedNodeID = nodeID;
        this.currentCheckConditionResult = conditions(this, nodeID, component, data);
        this.W_Upgrade_NeedItemPanel.SetVisibility(UE.ESlateVisibility.Collapsed);
        this.NotActivateEntryBox.Reset();
        this.BottomSwitcher.SetActiveWidgetIndex(3);
        this.W_LongPressButton.Init(false,
            cpp_1.FText.FromString(localized("本模式禁用属性修行，请在铃铛商店购买原生升级道具",
                "Stat cultivation is disabled in this mode. Buy stat upgrade items at the bell shop.")), 0);
        this.W_LongPressButton.InitTextColor(this.AbilityUIConfig.HoldButtonAbilityMaterialInsufficientColor);
    };
    prototype.executeActivateNode = function() {
        if (!modePlayer(this))
            return originalPurchase.call(this);
        const nodeID = this.getCurrentSelectedNodeID();
        if (this.resetCascadeActive || !nodeID || disabledNodes.has(nodeID))
            return;
        const component = UE.PBZBlueprintFunctionLibrary.GetPBZAbilityNodesComponent(this);
        const manager = TsHelper_1.default.getWorldSubsystem(this, UE.PBZAbilityNodesManager.StaticClass());
        const data = UE.PBZAbilityNodesManager.GetAbilityTableNodeData(nodeID);
        const result = conditions(this, nodeID, component, data);
        this.currentCheckConditionResult = result;
        if (result.state !== AbilityNodeState.CanActivatEnoughMaterial &&
            result.state !== AbilityNodeState.ActivatedNotMaxLevel) {
            this.updateDescByCheckCondition(nodeID, component, manager, data);
            return;
        }
        // Original code removes dust/hearts, activates the real node/GE and emits
        // its native events. Refunds and node save/load remain completely native.
        return originalPurchase.call(this);
    };
    prototype.BP_OnActivated = function() {
        const result = originalActivated.call(this);
        const player = modePlayer(this);
        if (player && !player.ActorHasTag(readyTag))
            player.Tags.Add(readyTag);
        return result;
    };
})();
