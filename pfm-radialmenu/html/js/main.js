"use strict";

var QBRadialMenu = null;
var toggleConfig = false;
var keybindConfig = false;
$(document).ready(function () {
    window.addEventListener("message", function (event) {
        switch (event.data.action) {
            case "ui":
                toggleConfig = event.data.toggle;
                keybindConfig = event.data.keybind;
                if (event.data.radial) {
                    createMenu(event.data.items);
                    QBRadialMenu.open();
                } else {
                    QBRadialMenu.close(true);
                }
                if (toggleConfig === false) {
                    $(document).on("keyup", function (e) {
                        if ((e.key == keybindConfig) | (e.key === keybindConfig.toLowerCase())) {
                            QBRadialMenu.close();
                        }
                    });
                } else {
                    $(document).on("keydown", function (e) {
                        switch (e.key) {
                            case keybindConfig:
                                QBRadialMenu.close();
                                break;
                        }
                    });
                }
        }
    });
});
function createMenu(items) {
    QBRadialMenu = new RadialMenu({
        parent: document.body,
        size: 375,
        menuItems: items,
        onClick: function (item) {
            if (item.shouldClose) {
                QBRadialMenu.close(true);
            }

            if (item.items == null && item.shouldClose != null) {
                $.post(
                    "https://pfm-radialmenu/selectItem",
                    JSON.stringify({
                        itemData: item,
                    })
                );
            }
        },
    });
}

// controller (pfm-ui): the D-pad or stick turns the selection round the wheel, A uses it (or opens
// its sub-menu), B goes back a level or closes
if (window.PfmPad) {
    const radialOpen = () => QBRadialMenu && QBRadialMenu.currentMenu;
    const turn = (step) => () => {
        if (radialOpen()) QBRadialMenu.selectDelta(step);
    };
    PfmPad.on("right", turn(1));
    PfmPad.on("down", turn(1));
    PfmPad.on("left", turn(-1));
    PfmPad.on("up", turn(-1));
    PfmPad.on("select", () => {
        if (!radialOpen()) return;
        if (QBRadialMenu.getSelectedIndex() < 0) QBRadialMenu.selectDelta(0);
        else QBRadialMenu.handleClick();
    });
    PfmPad.on("back", () => {
        if (radialOpen()) QBRadialMenu.handleCenterClick();
    });
}

// Close on escape pressed
$(document).on("keydown", function (e) {
    switch (e.key) {
        case "Escape":
            QBRadialMenu.close();
            break;
    }
});
