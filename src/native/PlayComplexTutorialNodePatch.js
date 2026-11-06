// Appended to FlowNode/PlayComplexTutorialNode.js.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    exports.playComplexTutorialNodeInterface.prototype.K2_ExecuteInput = function() {
        // Match the shipped empty-TutorialID/previously-acquired-weapon branch:
        // finish the flow without loading, pushing, marking help encountered or
        // taking CommonUI's menu input/time ownership.
        this.TriggerOutput("立即执行");
        this.TriggerOutput("界面关闭", true);
    };
})();
