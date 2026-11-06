// Appended to UI/Widget/TutorialComplex.js. The flow-node guard is the primary
// prevention; this covers direct/preloaded widget entry without taking JS locks.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const prototype = exports.TutorialComplexInterface.prototype;
    function clearTutorial() {
        if (this.pbzRogueCloseTimer) {
            clearTimeout(this.pbzRogueCloseTimer);
            this.pbzRogueCloseTimer = 0;
        }
        this.clearPresentation();
        this.releaseActionButton();
        this.StopAllAnimations();
    }
    // Do not add the original Construct's AI.Hatred.CanNotBeHatred tag, or
    // remove somebody else's copy in Destruct when we never acquired it.
    prototype.Construct = clearTutorial;
    prototype.Destruct = clearTutorial;
    prototype.InitArray = clearTutorial;
    prototype.InitTutorialDataByDataTable = clearTutorial;
    prototype.BP_OnDeactivated = clearTutorial;
    prototype.BP_OnActivated = function() {
        clearTutorial.call(this);
        // AsyncAction.AfterPush attaches the flow's close delegate after widget
        // activation. Deactivate on the next JS task so that delegate is present.
        this.pbzRogueCloseTimer = setTimeout(() => {
            this.pbzRogueCloseTimer = 0;
            if (!UE.KismetSystemLibrary.IsValid(this))
                return;
            this.DeactivateWidget();
            UE.CommonUIExtensions.PopContentFromLayer(this);
        }, 0);
    };
})();
