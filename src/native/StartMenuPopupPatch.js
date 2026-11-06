// Appended to the shipped UI/Widget/StartMenu.js in the isolated-mode pak.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;

    const prototype = exports.StartmenuMinXinInterface.prototype;
    // Stop at the enqueue boundary, before ownership polling or native first-launch
    // flow activation. False means no push: the menu's Tick may safely continue.
    prototype.TryStartFirstLaunchGuide = function() { return false; };
    prototype.tryShowEntitlementNotify = function() { return false; };
    // Keep the ordinary StartMenu lifecycle and all confirmation pages intact.
    // The isolated run's own ready/confirmation UI is not part of these producers.
})();
