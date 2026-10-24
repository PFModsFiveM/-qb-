const InventoryContainer = Vue.createApp({
    data() {
        return this.getInitialState();
    },
    computed: {
        playerWeight() {
            const weight = Object.values(this.playerInventory).reduce((total, item) => {
                if (item && item.weight !== undefined && item.amount !== undefined) {
                    return total + item.weight * item.amount;
                }
                return total;
            }, 0);
            return isNaN(weight) ? 0 : weight;
        },
        otherInventoryWeight() {
            const weight = Object.values(this.otherInventory).reduce((total, item) => {
                if (item && item.weight !== undefined && item.amount !== undefined) {
                    return total + item.weight * item.amount;
                }
                return total;
            }, 0);
            return isNaN(weight) ? 0 : weight;
        },
        weightBarClass() {
            const weightPercentage = (this.playerWeight / this.maxWeight) * 100;
            if (weightPercentage < 50) return "low";
            if (weightPercentage < 75) return "medium";
            return "high";
        },
        otherWeightBarClass() {
            const weightPercentage = (this.otherInventoryWeight / this.otherInventoryMaxWeight) * 100;
            if (weightPercentage < 50) return "low";
            if (weightPercentage < 75) return "medium";
            return "high";
        },
        shouldCenterInventory() {
            return this.isOtherInventoryEmpty;
        },
        mainSlots() {
            const out = [];
            for (let i = this.pockets + 1; i <= this.totalSlots; i++) out.push(i);
            return out;
        },
        backpackWeight() {
            const weight = Object.values(this.backpackInventory).reduce((total, item) => {
                if (item && item.weight !== undefined && item.amount !== undefined) {
                    return total + item.weight * item.amount;
                }
                return total;
            }, 0);
            return isNaN(weight) ? 0 : weight;
        },
        infoDescription() {
            const item = this.infoItem;
            if (!item) return "";
            if (item.info && item.info.description) return item.info.description;
            return item.description || "No description available.";
        },
        infoMeta() {
            const item = this.infoItem;
            if (!item || !item.info || item.info.display === false) return {};
            const out = {};
            for (const [key, value] of Object.entries(item.info)) {
                if (key === "description" || key === "display" || key === "quality") continue;
                if (key === "attachments") {
                    out["attachments"] = Object.keys(value || {}).length;
                    continue;
                }
                if (typeof value === "object") continue;
                out[this.formatKey(key)] = value;
            }
            return out;
        },
    },
    watch: {
        transferAmount(newVal) {
            if (newVal !== null && newVal < 1) this.transferAmount = 1;
        },
    },
    methods: {
        getInitialState() {
            return {
                // Config Options
                maxWeight: 0,
                totalSlots: 0,
                // Escape Key
                isInventoryOpen: false,
                // Single pane
                isOtherInventoryEmpty: true,
                // Error handling
                errorSlot: null,
                // Player Inventory
                playerInventory: {},
                inventoryLabel: "Inventory",
                totalWeight: 0,
                // Other inventory
                otherInventory: {},
                otherInventoryName: "",
                otherInventoryLabel: "Drop",
                otherInventoryMaxWeight: 1000000,
                otherInventorySlots: 100,
                isShopInventory: false,
                // Where item is coming from
                inventory: "",
                // Context Menu
                showContextMenu: false,
                contextMenuPosition: { top: "0px", left: "0px" },
                contextMenuItem: null,
                showSubmenu: false,
                // Hotbar
                showHotbar: false,
                hotbarItems: [],
                // Item box notifications (stacking)
                itemNotifications: [],
                // Required items box
                showRequiredItems: false,
                requiredItems: [],
                // Attachments
                selectedWeapon: null,
                showWeaponAttachments: false,
                selectedWeaponAttachments: [],
                // Dragging and dropping
                currentlyDraggingItem: null,
                currentlyDraggingSlot: null,
                dragStartX: 0,
                dragStartY: 0,
                ghostElement: null,
                dragStartInventoryType: "player",
                transferAmount: null,
                // v2 features
                searchQuery: "",
                favorites: this.loadFavorites ? this.loadFavorites() : [],
                infoItem: null,
                hoveredItem: null,
                // v3: sections
                playerInfo: null,
                pockets: 5,
                backpackMeta: null,
                backpackInventory: {},
            };
        },

        /* ── v2 helpers ──────────────────────────────────────── */
        loadFavorites() {
            try {
                return JSON.parse(localStorage.getItem("pfm-inv-favorites")) || [];
            } catch (e) {
                return [];
            }
        },
        saveFavorites() {
            try {
                localStorage.setItem("pfm-inv-favorites", JSON.stringify(this.favorites));
            } catch (e) {}
        },
        favKey(item) {
            return item.info && item.info.serie ? item.name + "::" + item.info.serie : item.name;
        },
        isFavorite(item) {
            if (!item) return false;
            return this.favorites.includes(this.favKey(item));
        },
        toggleFavorite(item) {
            if (!item) return;
            const key = this.favKey(item);
            const idx = this.favorites.indexOf(key);
            if (idx === -1) this.favorites.push(key);
            else this.favorites.splice(idx, 1);
            this.saveFavorites();
            this.showContextMenu = false;
        },
        hoverItem(item) {
            this.hoveredItem = item;
            if (item) this.infoItem = item;
        },
        usedSlots(inventoryType) {
            const inv = inventoryType === "player" ? this.playerInventory : this.otherInventory;
            return Object.values(inv).filter(Boolean).length;
        },
        hasQuality(item) {
            return item && item.info && "quality" in item.info;
        },
        qualityOf(item) {
            return Math.max(0, Math.min(100, Math.round(item.info.quality)));
        },
        qualityClass(item) {
            const q = this.qualityOf(item);
            return q > 75 ? "high" : q > 25 ? "medium" : "low";
        },
        matchesSearch(item) {
            if (!this.searchQuery) return true;
            if (!item) return false;
            const q = this.searchQuery.toLowerCase();
            return (item.label || "").toLowerCase().includes(q) || (item.name || "").toLowerCase().includes(q);
        },
        slotClasses(slot, inventoryType) {
            const item = this.getItemInSlot(slot, inventoryType);
            const classes = {};
            if (this.errorSlot === slot && inventoryType === "player") classes["invalid-slot-highlight"] = true;
            if (this.searchQuery && item) {
                if (this.matchesSearch(item)) classes["search-hit"] = true;
                else classes["search-dim"] = true;
            } else if (this.searchQuery && !item) {
                classes["search-dim"] = true;
            }
            return classes;
        },
        async quickStack() {
            // move every non-favorite stack whose item already exists in the container
            if (this.isOtherInventoryEmpty || this.isShopInventory) return;
            const targetNames = new Set(Object.values(this.otherInventory).filter(Boolean).map((i) => i.name));
            const candidates = Object.values(this.playerInventory).filter((i) => i && !i.unique && targetNames.has(i.name) && !this.isFavorite(i));
            for (const item of candidates) {
                const prevAmount = this.transferAmount;
                this.transferAmount = item.amount;
                this.moveItemBetweenInventories(item, "player");
                this.transferAmount = prevAmount;
                await new Promise((r) => setTimeout(r, 60));
            }
        },
        // Mirrors the server's merge rule (pfm-inventory server/freshness.lua CanStack): perishables
        // only stack within one batch at matching freshness, so no item loses its own state.
        canStackItems(a, b) {
            if (!a || !b || a.name !== b.name || a.unique || b.unique) return false;
            const fa = a.info && a.info.fresh;
            const fb = b.info && b.info.fresh;
            if (!fa && !fb) return true;
            if (!fa || !fb || fa.batch !== fb.batch) return false;
            const pa = a.info.freshDisplay && a.info.freshDisplay.pct;
            const pb = b.info.freshDisplay && b.info.freshDisplay.pct;
            return pa == null || pb == null || Math.abs(pa - pb) <= 1;
        },
        freshOf(item) {
            return item && item.info && item.info.freshDisplay ? item.info.freshDisplay : null;
        },
        async tidyInventory() {
            // combine stackable duplicates into the earliest slot (perishables: per batch)
            const inv = this.playerInventory;
            const byName = {};
            for (const item of Object.values(inv)) {
                if (!item || item.unique) continue;
                const key = item.name + "|" + ((item.info && item.info.fresh && item.info.fresh.batch) || "");
                (byName[key] = byName[key] || []).push(item);
            }
            let merged = 0;
            for (const stacks of Object.values(byName)) {
                if (stacks.length < 2) continue;
                stacks.sort((a, b) => a.slot - b.slot);
                const target = stacks[0];
                for (const src of stacks.slice(1)) {
                    if (!this.canStackItems(src, target)) continue;
                    const amt = src.amount;
                    target.amount += amt;
                    delete inv[src.slot];
                    this.postInventoryData("player", "player", src.slot, target.slot, 0, amt);
                    merged++;
                    await new Promise((r) => setTimeout(r, 60));
                }
            }
            if (merged === 0) this.inventoryError(null);
        },

        /* ── open / update / close ───────────────────────────── */
        openInventory(data) {
            if (this.showHotbar) {
                this.toggleHotbar(false);
            }

            this.isInventoryOpen = true;
            this.maxWeight = data.maxweight;
            this.totalSlots = data.slots;
            this.playerInventory = {};
            this.otherInventory = {};
            this.searchQuery = "";
            this.infoItem = null;
            this.playerInfo = data.playerInfo || null;
            this.pockets = Math.min(data.pockets || 5, data.slots);
            this.backpackMeta = null;
            this.backpackInventory = {};
            if (data.backpack && data.backpack.name) {
                this.backpackMeta = {
                    name: data.backpack.name,
                    label: data.backpack.label || "Backpack",
                    maxweight: data.backpack.maxweight || 30000,
                    slots: data.backpack.slots || 20,
                };
                const src = data.backpack.inventory || {};
                const list = Array.isArray(src) ? src : Object.values(src);
                for (const item of list) {
                    if (item && item.slot) this.backpackInventory[item.slot] = item;
                }
            }

            if (data.inventory) {
                if (Array.isArray(data.inventory)) {
                    data.inventory.forEach((item) => {
                        if (item && item.slot) {
                            this.playerInventory[item.slot] = item;
                        }
                    });
                } else if (typeof data.inventory === "object") {
                    for (const key in data.inventory) {
                        const item = data.inventory[key];
                        if (item && item.slot) {
                            this.playerInventory[item.slot] = item;
                        }
                    }
                }
            }

            if (data.other) {
                if (data.other && data.other.inventory) {
                    if (Array.isArray(data.other.inventory)) {
                        data.other.inventory.forEach((item) => {
                            if (item && item.slot) {
                                this.otherInventory[item.slot] = item;
                            }
                        });
                    } else if (typeof data.other.inventory === "object") {
                        for (const key in data.other.inventory) {
                            const item = data.other.inventory[key];
                            if (item && item.slot) {
                                this.otherInventory[item.slot] = item;
                            }
                        }
                    }
                }

                this.otherInventoryName = data.other.name;
                this.otherInventoryLabel = data.other.label;
                this.otherInventoryMaxWeight = data.other.maxweight;
                this.otherInventorySlots = data.other.slots;

                if (this.otherInventoryName.startsWith("shop-")) {
                    this.isShopInventory = true;
                } else {
                    this.isShopInventory = false;
                }

                this.isOtherInventoryEmpty = false;
            }
        },
        updateInventory(data) {
            this.playerInventory = {};

            if (data.inventory) {
                if (Array.isArray(data.inventory)) {
                    data.inventory.forEach((item) => {
                        if (item && item.slot) {
                            this.playerInventory[item.slot] = item;
                        }
                    });
                } else if (typeof data.inventory === "object") {
                    for (const key in data.inventory) {
                        const item = data.inventory[key];
                        if (item && item.slot) {
                            this.playerInventory[item.slot] = item;
                        }
                    }
                }
            }

            if (data.otherItems) {
                // route by inventory name: backpack updates go to the backpack pane
                const name = data.otherName || "";
                const isBackpack = this.backpackMeta && name === this.backpackMeta.name;
                const target = isBackpack ? this.backpackInventory : this.otherInventory;
                for (const key of Object.keys(target)) delete target[key];
                const list = Array.isArray(data.otherItems) ? data.otherItems : Object.values(data.otherItems);
                for (const item of list) {
                    if (item && item.slot) target[item.slot] = item;
                }
            }

            if (data.errorSlot) this.inventoryError(data.errorSlot, data.errorInventory);
        },
        async closeInventory() {
            this.clearDragData();
            let inventoryName = this.otherInventoryName;
            const favorites = this.favorites;
            Object.assign(this, this.getInitialState());
            this.favorites = favorites;
            try {
                await axios.post("https://pfm-inventory/CloseInventory", { name: inventoryName });
            } catch (error) {
                console.error("Error closing inventory:", error);
            }
        },
        clearTransferAmount() {
            this.transferAmount = null;
        },
        getItemInSlot(slot, inventoryType) {
            if (inventoryType === "player") {
                return this.playerInventory[slot] || null;
            } else if (inventoryType === "other") {
                return this.otherInventory[slot] || null;
            } else if (inventoryType === "backpack") {
                return this.backpackInventory[slot] || null;
            }
            return null;
        },
        getHotbarItemInSlot(slot) {
            return this.hotbarItems[slot - 1] || null;
        },
        containerMouseDownAction(event) {
            if (event.button === 0 && this.showContextMenu) {
                this.showContextMenu = false;
            }
        },
        handleMouseDown(event, slot, inventory) {
            if (event.button === 1) return; // skip middle mouse
            event.preventDefault();
            const itemInSlot = this.getItemInSlot(slot, inventory);
            if (event.button === 0) {
                if (event.shiftKey && itemInSlot) {
                    this.splitAndPlaceItem(itemInSlot, inventory);
                } else if (event.ctrlKey && itemInSlot && !this.isShopInventory && (!this.isOtherInventoryEmpty || this.backpackMeta)) {
                    // ctrl+click: quick-transfer half the stack (container first, else backpack)
                    const target = inventory === "backpack" ? "player" : !this.isOtherInventoryEmpty ? "other" : "backpack";
                    const prevAmount = this.transferAmount;
                    this.transferAmount = Math.max(1, Math.ceil(itemInSlot.amount / 2));
                    this.moveItemBetweenInventories(itemInSlot, inventory, target);
                    this.transferAmount = prevAmount;
                } else {
                    this.startDrag(event, slot, inventory);
                }
            } else if (event.button === 2 && itemInSlot) {
                if (inventory === "backpack") {
                    // right-click in the backpack always pulls back to the player
                    this.moveItemBetweenInventories(itemInSlot, "backpack", "player");
                    return;
                }
                if (inventory === "other" && this.otherInventoryName.startsWith("shop-")) {
                    this.handlePurchase(slot, itemInSlot.slot, itemInSlot, 1);
                    return;
                }
                if (!this.isOtherInventoryEmpty && inventory !== "backpack") {
                    this.moveItemBetweenInventories(itemInSlot, inventory);
                } else {
                    this.showContextMenuOptions(event, itemInSlot);
                }
            }
        },
        moveItemBetweenInventories(item, sourceInventoryType, targetInventoryType) {
            targetInventoryType = targetInventoryType || (sourceInventoryType === "player" ? "other" : "player");
            const sourceInventory = this.getInventoryByType(sourceInventoryType);
            const targetInventory = this.getInventoryByType(targetInventoryType);
            const targetCap = this.capacityOf(targetInventoryType);
            const targetWeight = targetCap.weight;
            const maxTargetWeight = targetCap.max;
            const targetMaxSlots = targetCap.slots;
            const amountToTransfer = this.transferAmount !== null ? this.transferAmount : 1;
            let targetSlot = null;

            const sourceItem = sourceInventory[item.slot];
            if (!sourceItem || sourceItem.amount < amountToTransfer) {
                this.inventoryError(item.slot);
                return;
            }

            const totalWeightAfterTransfer = targetWeight + sourceItem.weight * amountToTransfer;

            if (totalWeightAfterTransfer > maxTargetWeight) {
                this.inventoryError(item.slot);
                return;
            }

            if (item.unique) {
                targetSlot = this.findNextAvailableSlot(targetInventory, targetMaxSlots);
                if (targetSlot === null) {
                    this.inventoryError(item.slot);
                    return;
                }

                const newItem = {
                    ...item,
                    inventory: targetInventoryType,
                    amount: amountToTransfer,
                };
                targetInventory[targetSlot] = newItem;
                newItem.slot = targetSlot;
            } else {
                const targetItemKey = Object.keys(targetInventory).find((key) => this.canStackItems(item, targetInventory[key]));
                const targetItem = targetInventory[targetItemKey];

                if (!targetItem) {
                    const newItem = {
                        ...item,
                        inventory: targetInventoryType,
                        amount: amountToTransfer,
                    };

                    targetSlot = this.findNextAvailableSlot(targetInventory, targetMaxSlots);
                    if (targetSlot === null) {
                        this.inventoryError(item.slot);
                        return;
                    }

                    targetInventory[targetSlot] = newItem;
                    newItem.slot = targetSlot;
                } else {
                    targetItem.amount += amountToTransfer;
                    targetSlot = targetItem.slot;
                }
            }

            sourceItem.amount -= amountToTransfer;

            if (sourceItem.amount <= 0) {
                delete sourceInventory[item.slot];
            }

            this.postInventoryData(sourceInventoryType, targetInventoryType, item.slot, targetSlot, sourceItem.amount, amountToTransfer);
        },
        moveToBackpack(item) {
            if (!this.backpackMeta || !item) return;
            const prevAmount = this.transferAmount;
            this.transferAmount = item.amount;
            this.moveItemBetweenInventories(item, "player", "backpack");
            this.transferAmount = prevAmount;
            this.showContextMenu = false;
        },
        startDrag(event, slot, inventoryType) {
            event.preventDefault();
            const item = this.getItemInSlot(slot, inventoryType);
            if (!item) return;
            const slotElement = event.target.closest(".item-slot");
            if (!slotElement) return;
            const ghostElement = this.createGhostElement(slotElement);
            document.body.appendChild(ghostElement);
            const offsetX = ghostElement.offsetWidth / 2;
            const offsetY = ghostElement.offsetHeight / 2;
            ghostElement.style.left = `${event.clientX - offsetX}px`;
            ghostElement.style.top = `${event.clientY - offsetY}px`;
            this.ghostElement = ghostElement;
            this.currentlyDraggingItem = item;
            this.currentlyDraggingSlot = slot;
            this.dragStartX = event.clientX;
            this.dragStartY = event.clientY;
            this.dragStartInventoryType = inventoryType;
            this.showContextMenu = false;
        },
        createGhostElement(slotElement) {
            const ghostElement = slotElement.cloneNode(true);
            ghostElement.classList.add("drag-ghost");
            ghostElement.style.position = "absolute";
            ghostElement.style.pointerEvents = "none";
            ghostElement.style.opacity = "0.75";
            ghostElement.style.zIndex = "1000";
            ghostElement.style.transform = "scale(1.04) rotate(2deg)";
            ghostElement.style.width = getComputedStyle(slotElement).width;
            ghostElement.style.height = getComputedStyle(slotElement).height;
            ghostElement.style.boxSizing = "border-box";
            return ghostElement;
        },
        drag(event) {
            if (!this.currentlyDraggingItem) return;
            const centeredX = event.clientX - this.ghostElement.offsetWidth / 2;
            const centeredY = event.clientY - this.ghostElement.offsetHeight / 2;
            this.ghostElement.style.left = `${centeredX}px`;
            this.ghostElement.style.top = `${centeredY}px`;
        },
        endDrag(event) {
            if (!this.currentlyDraggingItem) {
                return;
            }

            const elementsUnderCursor = document.elementsFromPoint(event.clientX, event.clientY);

            const backpackSlotElement = elementsUnderCursor.find((el) => el.classList.contains("item-slot") && el.closest(".backpack-section"));

            const playerSlotElement = elementsUnderCursor.find((el) => el.classList.contains("item-slot") && el.closest(".player-inventory-section") && !el.closest(".backpack-section"));

            const otherSlotElement = elementsUnderCursor.find((el) => el.classList.contains("item-slot") && el.closest(".other-inventory-section"));

            if (backpackSlotElement) {
                const targetSlot = Number(backpackSlotElement.dataset.slot);
                if (targetSlot && !(targetSlot === this.currentlyDraggingSlot && this.dragStartInventoryType === "backpack")) {
                    if (this.currentlyDraggingItem && (this.currentlyDraggingItem.name === "backpack" || this.dragStartInventoryType === "other" && this.isShopInventory)) {
                        this.inventoryError(this.currentlyDraggingSlot);
                    } else {
                        this.handleItemDrop("backpack", targetSlot);
                    }
                }
                this.clearDragData();
                return;
            }

            if (playerSlotElement) {
                const targetSlot = Number(playerSlotElement.dataset.slot);
                if (targetSlot && !(targetSlot === this.currentlyDraggingSlot && this.dragStartInventoryType === "player")) {
                    this.handleDropOnPlayerSlot(targetSlot);
                }
            } else if (otherSlotElement) {
                const targetSlot = Number(otherSlotElement.dataset.slot);
                if (targetSlot && !(targetSlot === this.currentlyDraggingSlot && this.dragStartInventoryType === "other")) {
                    this.handleDropOnOtherSlot(targetSlot);
                }
            } else if (this.isOtherInventoryEmpty && this.dragStartInventoryType === "player") {
                const isOverInventoryGrid = elementsUnderCursor.some((el) => el.classList.contains("inventory-grid") || el.classList.contains("item-grid"));

                if (!isOverInventoryGrid) {
                    this.handleDropOnInventoryContainer();
                }
            }

            this.clearDragData();
        },
        handleDropOnPlayerSlot(targetSlot) {
            if (this.isShopInventory && this.dragStartInventoryType === "other") {
                const { currentlyDraggingSlot, currentlyDraggingItem, transferAmount } = this;
                const targetInventory = this.getInventoryByType("player");
                const targetItem = targetInventory[targetSlot];
                if ((targetItem && targetItem.name !== currentlyDraggingItem.name) || (targetItem && targetItem.name === currentlyDraggingItem.name && currentlyDraggingItem.unique)) {
                    this.inventoryError(currentlyDraggingSlot);
                    return;
                }
                this.handlePurchase(targetSlot, currentlyDraggingSlot, currentlyDraggingItem, transferAmount);
            } else {
                this.handleItemDrop("player", targetSlot);
            }
        },
        handleDropOnOtherSlot(targetSlot) {
            this.handleItemDrop("other", targetSlot);
        },
        async handleDropOnInventoryContainer() {
            if (this.isOtherInventoryEmpty && this.dragStartInventoryType === "player") {
                const newItem = {
                    ...this.currentlyDraggingItem,
                    amount: this.currentlyDraggingItem.amount,
                    slot: 1,
                    inventory: "other",
                };
                const draggingItem = this.currentlyDraggingItem;
                try {
                    const response = await axios.post("https://pfm-inventory/DropItem", {
                        ...newItem,
                        fromSlot: this.currentlyDraggingSlot,
                    });

                    if (response.data) {
                        this.otherInventory[1] = newItem;
                        const draggingItemKey = Object.keys(this.playerInventory).find((key) => this.playerInventory[key] === draggingItem);
                        if (draggingItemKey) {
                            delete this.playerInventory[draggingItemKey];
                        }
                        this.otherInventoryName = response.data;
                        this.otherInventoryLabel = response.data;
                        this.isOtherInventoryEmpty = false;
                        this.clearDragData();
                    }
                } catch (error) {
                    this.inventoryError(this.currentlyDraggingSlot);
                }
            }
            this.clearDragData();
        },
        clearDragData() {
            if (this.ghostElement) {
                document.body.removeChild(this.ghostElement);
                this.ghostElement = null;
            }
            this.currentlyDraggingItem = null;
            this.currentlyDraggingSlot = null;
        },
        getInventoryByType(inventoryType) {
            if (inventoryType === "backpack") return this.backpackInventory;
            return inventoryType === "player" ? this.playerInventory : this.otherInventory;
        },
        capacityOf(inventoryType) {
            if (inventoryType === "player") return { weight: this.playerWeight, max: this.maxWeight, slots: this.totalSlots };
            if (inventoryType === "backpack") return { weight: this.backpackWeight, max: this.backpackMeta ? this.backpackMeta.maxweight : 0, slots: this.backpackMeta ? this.backpackMeta.slots : 0 };
            return { weight: this.otherInventoryWeight, max: this.otherInventoryMaxWeight, slots: this.otherInventorySlots };
        },
        handleItemDrop(targetInventoryType, targetSlot) {
            try {
                const isShop = this.otherInventoryName.indexOf("shop-");
                if (this.dragStartInventoryType === "other" && targetInventoryType === "other" && isShop !== -1) {
                    return;
                }

                const targetSlotNumber = parseInt(targetSlot, 10);
                if (isNaN(targetSlotNumber)) {
                    throw new Error("Invalid target slot number");
                }

                const sourceInventory = this.getInventoryByType(this.dragStartInventoryType);
                const targetInventory = this.getInventoryByType(targetInventoryType);

                const sourceItem = sourceInventory[this.currentlyDraggingSlot];
                if (!sourceItem) {
                    throw new Error("No item in the source slot to transfer");
                }

                const amountToTransfer = this.transferAmount !== null ? this.transferAmount : sourceItem.amount;
                if (sourceItem.amount < amountToTransfer) {
                    throw new Error("Insufficient amount of item in source inventory");
                }

                if (targetInventoryType === "other" && this.isShopInventory && this.dragStartInventoryType !== "other") {
                    throw new Error("Cannot put items into a shop");
                }

                if (targetInventoryType !== this.dragStartInventoryType) {
                    const cap = this.capacityOf(targetInventoryType);
                    const totalWeightAfterTransfer = cap.weight + sourceItem.weight * amountToTransfer;
                    if (totalWeightAfterTransfer > cap.max) {
                        throw new Error("Insufficient weight capacity in target inventory");
                    }
                }

                const targetItem = targetInventory[targetSlotNumber];

                if (targetItem) {
                    if (this.canStackItems(sourceItem, targetItem)) {
                        targetItem.amount += amountToTransfer;
                        sourceItem.amount -= amountToTransfer;
                        if (sourceItem.amount <= 0) {
                            delete sourceInventory[this.currentlyDraggingSlot];
                        }
                        this.postInventoryData(this.dragStartInventoryType, targetInventoryType, this.currentlyDraggingSlot, targetSlotNumber, sourceItem.amount, amountToTransfer);
                    } else {
                        sourceInventory[this.currentlyDraggingSlot] = targetItem;
                        targetInventory[targetSlotNumber] = sourceItem;
                        sourceInventory[this.currentlyDraggingSlot].slot = this.currentlyDraggingSlot;
                        targetInventory[targetSlotNumber].slot = targetSlotNumber;
                        this.postInventoryData(this.dragStartInventoryType, targetInventoryType, this.currentlyDraggingSlot, targetSlotNumber, sourceItem.amount, targetItem.amount);
                    }
                } else {
                    sourceItem.amount -= amountToTransfer;
                    if (sourceItem.amount <= 0) {
                        delete sourceInventory[this.currentlyDraggingSlot];
                    }
                    targetInventory[targetSlotNumber] = { ...sourceItem, amount: amountToTransfer, slot: targetSlotNumber };
                    this.postInventoryData(this.dragStartInventoryType, targetInventoryType, this.currentlyDraggingSlot, targetSlotNumber, sourceItem.amount, amountToTransfer);
                }
            } catch (error) {
                console.error(error.message);
                this.inventoryError(this.currentlyDraggingSlot);
            } finally {
                this.clearDragData();
            }
        },
        async handlePurchase(targetSlot, sourceSlot, sourceItem, transferAmount) {
            try {
                const response = await axios.post("https://pfm-inventory/AttemptPurchase", {
                    item: sourceItem,
                    amount: transferAmount || sourceItem.amount,
                    shop: this.otherInventoryName,
                });
                if (response.data) {
                    const sourceInventory = this.getInventoryByType("other");
                    const targetInventory = this.getInventoryByType("player");
                    const amountToTransfer = transferAmount !== null ? transferAmount : sourceItem.amount;
                    if (sourceItem.amount < amountToTransfer) {
                        this.inventoryError(sourceSlot, "other");
                        return;
                    }
                    let targetItem = targetInventory[targetSlot];
                    if (!targetItem || targetItem.name !== sourceItem.name) {
                        let foundSlot = Object.keys(targetInventory).find((slot) => targetInventory[slot] && targetInventory[slot].name === sourceItem.name);
                        if (foundSlot) {
                            targetInventory[foundSlot].amount += amountToTransfer;
                        } else {
                            const targetInventoryKeys = Object.keys(targetInventory);
                            if (targetInventoryKeys.length < this.totalSlots) {
                                let freeSlot = Array.from({ length: this.totalSlots }, (_, i) => i + 1).find((i) => !(i in targetInventory));
                                targetInventory[freeSlot] = {
                                    ...sourceItem,
                                    amount: amountToTransfer,
                                };
                            } else {
                                this.inventoryError(sourceSlot, "other");
                                return;
                            }
                        }
                    } else {
                        targetItem.amount += amountToTransfer;
                    }
                    sourceItem.amount -= amountToTransfer;
                    if (sourceItem.amount <= 0) {
                        delete sourceInventory[sourceSlot];
                    }
                } else {
                    this.inventoryError(sourceSlot, "other");
                }
            } catch (error) {
                this.inventoryError(sourceSlot, "other");
            }
        },
        async dropItem(item, quantity) {
            if (this.isFavorite(item)) return;
            if (item && item.name) {
                const playerItemKey = Object.keys(this.playerInventory).find((key) => this.playerInventory[key] && this.playerInventory[key].slot === item.slot);
                if (playerItemKey) {
                    let amountToGive;

                    if (typeof quantity === "string") {
                        switch (quantity) {
                            case "half":
                                amountToGive = Math.ceil(item.amount / 2);
                                break;
                            case "all":
                                amountToGive = item.amount;
                                break;
                            default:
                                console.error("Invalid quantity specified.");
                                return;
                        }
                    } else if (typeof quantity === "number" && quantity > 0) {
                        amountToGive = quantity;
                    } else {
                        console.error("Invalid quantity type specified.");
                        return;
                    }

                    if (amountToGive > item.amount) {
                        amountToGive = item.amount;
                    }

                    const newItem = {
                        ...item,
                        amount: amountToGive,
                        slot: 1,
                        inventory: "other",
                    };

                    try {
                        const response = await axios.post("https://pfm-inventory/DropItem", {
                            ...newItem,
                            fromSlot: item.slot,
                        });

                        if (response.data) {
                            delete this.playerInventory[playerItemKey];
                            this.otherInventory[1] = newItem;
                            this.otherInventoryName = response.data;
                            this.otherInventoryLabel = response.data;
                            this.isOtherInventoryEmpty = false;
                        }
                    } catch (error) {
                        this.inventoryError(item.slot);
                    }
                }
            }
            this.showContextMenu = false;
        },
        async useItem(item) {
            if (!item || item.useable === false) {
                return;
            }
            const playerItemKey = Object.keys(this.playerInventory).find((key) => this.playerInventory[key] && this.playerInventory[key].slot === item.slot);
            if (playerItemKey) {
                try {
                    await axios.post("https://pfm-inventory/UseItem", {
                        inventory: "player",
                        item: item,
                    });
                    if (item.shouldClose) {
                        this.closeInventory();
                    }
                } catch (error) {
                    console.error("Error using the item: ", error);
                }
            }
            this.showContextMenu = false;
        },
        showContextMenuOptions(event, item) {
            event.preventDefault();
            if (this.contextMenuItem && this.contextMenuItem.name === item.name && this.showContextMenu) {
                this.showContextMenu = false;
                this.contextMenuItem = null;
            } else {
                if (item.inventory === "other") {
                    const matchingItemKey = Object.keys(this.playerInventory).find((key) => this.playerInventory[key].name === item.name);
                    const matchingItem = this.playerInventory[matchingItemKey];

                    if (matchingItem && matchingItem.unique) {
                        const newItemKey = Object.keys(this.playerInventory).length + 1;
                        const newItem = {
                            ...item,
                            inventory: "player",
                            amount: 1,
                        };
                        this.playerInventory[newItemKey] = newItem;
                    } else if (matchingItem) {
                        matchingItem.amount++;
                    } else {
                        const newItemKey = Object.keys(this.playerInventory).length + 1;
                        const newItem = {
                            ...item,
                            inventory: "player",
                            amount: 1,
                        };
                        this.playerInventory[newItemKey] = newItem;
                    }
                    item.amount--;

                    if (item.amount <= 0) {
                        const itemKey = Object.keys(this.otherInventory).find((key) => this.otherInventory[key] === item);
                        if (itemKey) {
                            delete this.otherInventory[itemKey];
                        }
                    }
                }
                const menuLeft = event.clientX;
                const menuTop = event.clientY;
                this.showContextMenu = true;
                this.contextMenuPosition = {
                    top: `${menuTop}px`,
                    left: `${menuLeft}px`,
                };
                this.contextMenuItem = item;
            }
        },
        async giveItem(item, quantity) {
            if (this.isFavorite(item)) return;
            if (item && item.name) {
                const selectedItem = item;
                const playerHasItem = Object.values(this.playerInventory).some((invItem) => invItem && invItem.name === selectedItem.name);

                if (playerHasItem) {
                    let amountToGive;
                    if (typeof quantity === "string") {
                        switch (quantity) {
                            case "half":
                                amountToGive = Math.ceil(selectedItem.amount / 2);
                                break;
                            case "all":
                                amountToGive = selectedItem.amount;
                                break;
                            default:
                                console.error("Invalid quantity specified.");
                                return;
                        }
                    } else {
                        amountToGive = quantity;
                    }

                    if (amountToGive > selectedItem.amount) {
                        console.error("Specified quantity exceeds available amount.");
                        return;
                    }

                    try {
                        const response = await axios.post("https://pfm-inventory/GiveItem", {
                            item: selectedItem,
                            amount: amountToGive,
                            slot: selectedItem.slot,
                            info: selectedItem.info,
                        });
                        if (!response.data) return;

                        this.playerInventory[selectedItem.slot].amount -= amountToGive;
                        if (this.playerInventory[selectedItem.slot].amount === 0) {
                            delete this.playerInventory[selectedItem.slot];
                        }
                    } catch (error) {
                        console.error("An error occurred while giving the item:", error);
                    }
                } else {
                    console.error("Player does not have the item in their inventory. Item cannot be given.");
                }
            }
            this.showContextMenu = false;
        },
        findNextAvailableSlot(inventory, maxSlots) {
            const limit = maxSlots || this.totalSlots;
            for (let slot = 1; slot <= limit; slot++) {
                if (!inventory[slot]) {
                    return slot;
                }
            }
            return null;
        },
        splitAndPlaceItem(item, inventoryType) {
            const inventoryRef = this.getInventoryByType(inventoryType);
            if (item && item.amount > 1) {
                const originalSlot = Object.keys(inventoryRef).find((key) => inventoryRef[key] === item);
                if (originalSlot !== undefined) {
                    const newItem = { ...item, amount: Math.ceil(item.amount / 2) };
                    const nextSlot = this.findNextAvailableSlot(inventoryRef, this.capacityOf(inventoryType).slots);
                    if (nextSlot !== null) {
                        inventoryRef[nextSlot] = newItem;
                        inventoryRef[originalSlot] = { ...item, amount: Math.floor(item.amount / 2) };
                        this.postInventoryData(inventoryType, inventoryType, originalSlot, nextSlot, item.amount, newItem.amount);
                    }
                }
            }
            this.showContextMenu = false;
        },
        toggleHotbar(data) {
            if (data.open) {
                this.hotbarItems = data.items;
                this.showHotbar = true;
            } else {
                this.showHotbar = false;
                this.hotbarItems = [];
            }
        },
        showItemNotification(itemData) {
            const kind = itemData.type === "add" ? "add" : itemData.type === "use" ? "use" : "remove";
            const n = {
                id: Date.now() + Math.random(),
                label: itemData.item.label,
                image: "images/" + itemData.item.image,
                type: itemData.type === "add" ? "Received" : itemData.type === "use" ? "Used" : "Removed",
                kind,
                amount: itemData.amount || 1,
            };
            this.itemNotifications.push(n);
            if (this.itemNotifications.length > 5) this.itemNotifications.shift();
            setTimeout(() => {
                const idx = this.itemNotifications.findIndex((x) => x.id === n.id);
                if (idx !== -1) this.itemNotifications.splice(idx, 1);
            }, 3200);
        },
        showRequiredItem(data) {
            if (data.toggle) {
                this.requiredItems = data.items;
                this.showRequiredItems = true;
            } else {
                setTimeout(() => {
                    this.showRequiredItems = false;
                    this.requiredItems = [];
                }, 100);
            }
        },
        inventoryError(slot, inventory = "player") {
            const slotElement = document.querySelector(`.${inventory == "player" ? "player" : "other"}-inventory-section [data-slot="${slot}"]`);
            if (slotElement) {
                slotElement.classList.add("error");
            }
            axios.post("https://pfm-inventory/PlayDropFail", {}).catch((error) => {
                console.error("Error playing drop fail:", error);
            });
            setTimeout(() => {
                if (slotElement) {
                    slotElement.classList.remove("error");
                }
            }, 1000);
        },
        copySerial() {
            if (!this.contextMenuItem) {
                return;
            }
            const item = this.contextMenuItem;
            if (item) {
                const el = document.createElement("textarea");
                el.value = item.info.serie;
                document.body.appendChild(el);
                el.select();
                document.execCommand("copy");
                document.body.removeChild(el);
            }
            this.showContextMenu = false;
        },
        openWeaponAttachments() {
            if (!this.contextMenuItem && !this.showWeaponAttachments) {
                return;
            }
            if (!this.showWeaponAttachments) {
                this.selectedWeapon = this.contextMenuItem;
                this.showWeaponAttachments = true;
                axios
                    .post("https://pfm-inventory/GetWeaponData", JSON.stringify({ weapon: this.selectedWeapon.name, ItemData: this.selectedWeapon }))
                    .then((response) => {
                        const data = response.data;
                        if (data.AttachmentData !== null && data.AttachmentData !== undefined) {
                            if (data.AttachmentData.length > 0) {
                                this.selectedWeaponAttachments = data.AttachmentData;
                            }
                        }
                    })
                    .catch((error) => {
                        console.error(error);
                    });
            } else {
                this.showWeaponAttachments = false;
                this.selectedWeapon = null;
                this.selectedWeaponAttachments = [];
            }
            this.showContextMenu = false;
        },
        removeAttachment(attachment) {
            if (!this.selectedWeapon) {
                return;
            }
            const index = this.selectedWeaponAttachments.indexOf(attachment);
            if (index !== -1) {
                this.selectedWeaponAttachments.splice(index, 1);
            }
            axios
                .post("https://pfm-inventory/RemoveAttachment", JSON.stringify({ AttachmentData: attachment, WeaponData: this.selectedWeapon }))
                .then((response) => {
                    this.selectedWeapon = response.data.WeaponData;
                    if (response.data.Attachments) {
                        this.selectedWeaponAttachments = response.data.Attachments;
                    }
                    const nextSlot = this.findNextAvailableSlot(this.playerInventory);
                    if (nextSlot !== null) {
                        response.data.itemInfo.amount = 1;
                        this.playerInventory[nextSlot] = response.data.itemInfo;
                    }
                })
                .catch((error) => {
                    console.error(error);
                    this.selectedWeaponAttachments.splice(index, 0, attachment);
                });
        },
        formatKey(key) {
            return key.replace(/_/g, " ").charAt(0).toUpperCase() + key.slice(1);
        },
        postInventoryData(fromInventory, toInventory, fromSlot, toSlot, fromAmount, toAmount) {
            const resolveName = (type) => {
                if (type === "other") return this.otherInventoryName;
                if (type === "backpack") return this.backpackMeta ? this.backpackMeta.name : type;
                return type;
            };
            let fromInventoryName = resolveName(fromInventory);
            let toInventoryName = resolveName(toInventory);

            axios
                .post("https://pfm-inventory/SetInventoryData", {
                    fromInventory: fromInventoryName,
                    toInventory: toInventoryName,
                    fromSlot,
                    toSlot,
                    fromAmount,
                    toAmount,
                })
                .then((response) => {
                    this.clearDragData();
                })
                .catch((error) => {
                    console.error("Error posting inventory data:", error);
                });
        },
    },
    mounted() {
        window.addEventListener("keydown", (event) => {
            const key = event.key;
            if (key === "Escape" || key === "Tab") {
                if (this.isInventoryOpen) {
                    this.closeInventory();
                }
            }
            // F favorites the hovered item (ignore while typing in search/amount)
            if ((key === "f" || key === "F") && this.isInventoryOpen && this.hoveredItem && document.activeElement.tagName !== "INPUT") {
                this.toggleFavorite(this.hoveredItem);
            }
        });

        window.addEventListener("message", (event) => {
            switch (event.data.action) {
                case "open":
                    this.openInventory(event.data);
                    break;
                case "close":
                    this.closeInventory();
                    break;
                case "update":
                    this.updateInventory(event.data);
                    break;
                case "toggleHotbar":
                    this.toggleHotbar(event.data);
                    break;
                case "itemBox":
                    this.showItemNotification(event.data);
                    break;
                case "requiredItem":
                    this.showRequiredItem(event.data);
                    break;
                case "theme": {
                    // PF global UI theme (broadcast by pf-hud)
                    const t = event.data.theme;
                    if (!t) break;
                    const r = document.documentElement.style;
                    const hexToRgba = (h, a) => {
                        const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || "");
                        return m ? `rgba(${parseInt(m[1], 16)},${parseInt(m[2], 16)},${parseInt(m[3], 16)},${a})` : null;
                    };
                    const op = t.opacity ?? 0.92;
                    if (t.primary) {
                        r.setProperty("--inv-bg", hexToRgba(t.primary, op));
                        r.setProperty("--inv-bg-head", hexToRgba(t.primary, Math.min(1, op + 0.03)));
                    }
                    if (t.secondary) {
                        r.setProperty("--inv-slot", hexToRgba(t.secondary, 0.55));
                        r.setProperty("--inv-slot-hover", hexToRgba(t.secondary, 0.85));
                        r.setProperty("--inv-slot-spread", hexToRgba(t.secondary, 0.6));
                    }
                    if (t.accent) r.setProperty("--inv-accent", t.accent);
                    if (t.text) {
                        r.setProperty("--inv-fg", t.text);
                        r.setProperty("--inv-dim", hexToRgba(t.text, 0.55));
                    }
                    break;
                }
                default:
                    console.warn(`Unexpected action: ${event.data.action}`);
            }
        });
    },
});

InventoryContainer.mount("#app");
