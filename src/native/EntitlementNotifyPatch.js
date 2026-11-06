// Appended to the shipped UI/Widget/EntitlementNotify.js in the isolated-mode pak.
// Block both production and debug producers before CommonUI acquires a modal layer.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;

    // Rebind the local functions as well as their exports: the debug preview and
    // queue callbacks inside the shipped module call local bindings directly.
    startEntitlementNotifyFlow = function() { return false; };
    startEntitlementNotifyPreview = function() { return false; };
    installEntitlementNotifyDebugPoller = function() {};
    exports.startEntitlementNotifyFlow = startEntitlementNotifyFlow;
    exports.startEntitlementNotifyPreview = startEntitlementNotifyPreview;
    exports.installEntitlementNotifyDebugPoller = installEntitlementNotifyDebugPoller;
    // Do not call MarkEntitlementNotified or touch ownership/reward delivery.
    // A normal launch must retain its pending first-purchase notifications.
})();
