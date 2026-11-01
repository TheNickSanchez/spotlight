local _ = require("gettext")
return {
    fullname = _("Spotlight"),
    description = _([[Lights up the current sentence and moves the light one sentence at a time, by tap or on its own at your reading pace.]]),
    -- Read by plugin stores (Storefront, AppStore) to show updates. Keep in
    -- step with VERSION in main.lua (a test checks this).
    version = "0.5.2",
}
