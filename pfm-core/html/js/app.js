let NOTIFY_CONFIG = null;

const defaultConfig = {
    NotificationStyling: {
        group: false,
        position: "right",
        progress: true,
    },
    VariantDefinitions: {
        success: { classes: "success", icon: "check_circle" },
        primary: { classes: "primary", icon: "notifications" },
        warning: { classes: "warning", icon: "warning" },
        error: { classes: "error", icon: "error" },
        police: { classes: "police", icon: "local_police" },
        ambulance: { classes: "ambulance", icon: "fas fa-ambulance" },
    },
};

const MAX_VISIBLE = 6;

const fetchNui = async (evName, data) => {
    const resourceName = window.GetParentResourceName();
    const resp = await fetch(`https://${resourceName}/${evName}`, {
        body: JSON.stringify(data),
        headers: { "Content-Type": "application/json; charset=UTF8" },
        method: "POST",
    });
    return resp.json();
};

const determineStyleFromVariant = (variant) => {
    return NOTIFY_CONFIG.VariantDefinitions[variant] ?? NOTIFY_CONFIG.VariantDefinitions["primary"];
};

const fetchNotifyConfig = async () => {
    try {
        NOTIFY_CONFIG = await fetchNui("getNotifyConfig", {});
        if (!NOTIFY_CONFIG) NOTIFY_CONFIG = defaultConfig;
    } catch (error) {
        console.error("Failed to fetch notification config, using default", error);
        NOTIFY_CONFIG = defaultConfig;
    }
};

const POSITION_MAP = {
    "top-left": { top: "16px", left: "16px" },
    "top-right": { top: "16px", right: "16px" },
    top: { top: "16px", left: "50%", transform: "translateX(-50%)" },
    "bottom-left": { bottom: "16px", left: "16px" },
    "bottom-right": { bottom: "16px", right: "16px" },
    bottom: { bottom: "16px", left: "50%", transform: "translateX(-50%)" },
    left: { top: "50%", left: "16px", transform: "translateY(-50%)" },
    right: { top: "50%", right: "16px", transform: "translateY(-50%)" },
    center: { top: "50%", left: "50%", transform: "translate(-50%, -50%)" },
};

let container = null;
const activeNotifs = new Map(); // group key -> { item, count, timer }

const getContainer = () => {
    if (container) return container;
    const pos = NOTIFY_CONFIG.NotificationStyling.position ?? "right";
    const isBottom = pos.startsWith("bottom");
    container = document.createElement("div");
    container.id = "notify-container";
    Object.assign(container.style, {
        position: "fixed",
        display: "flex",
        flexDirection: isBottom ? "column-reverse" : "column",
        gap: "8px",
        zIndex: "9999",
        maxWidth: "400px",
        pointerEvents: "none",
        ...(POSITION_MAP[pos] ?? POSITION_MAP["right"]),
    });
    document.body.appendChild(container);
    return container;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const dismiss = (item, key) => {
    if (key && activeNotifs.has(key)) activeNotifs.delete(key);
    item.classList.remove("notify-show");
    item.classList.add("notify-hide");
    setTimeout(() => item.remove(), 350);
};

const showNotif = async ({ data }) => {
    if (data?.action !== "notify") return;

    if (!NOTIFY_CONFIG) {
        await fetchNotifyConfig();
    }

    const { text: message, type, length: duration = 5000, caption } = data;
    const style = determineStyleFromVariant(type ?? "primary");
    const showProgress = NOTIFY_CONFIG.NotificationStyling.progress && duration > 0;
    const grouping = NOTIFY_CONFIG.NotificationStyling.group;
    const groupKey = grouping ? `${type ?? "primary"}::${message}::${caption ?? ""}` : null;

    // grouped duplicate: bump the badge and reset the timer instead of stacking a copy
    if (groupKey && activeNotifs.has(groupKey)) {
        const entry = activeNotifs.get(groupKey);
        entry.count += 1;
        const badge = entry.item.querySelector(".notify-count");
        badge.textContent = entry.count > 99 ? "99+" : entry.count;
        badge.classList.remove("notify-count-show");
        void badge.offsetWidth; // restart pop animation
        badge.classList.add("notify-count-show");
        if (entry.timer) clearTimeout(entry.timer);
        const bar = entry.item.querySelector(".notify-progress");
        if (bar) {
            bar.style.animation = "none";
            void bar.offsetWidth;
            bar.style.animation = `notify-shrink ${duration}ms linear forwards`;
        }
        if (duration > 0) {
            entry.timer = setTimeout(() => dismiss(entry.item, groupKey), duration);
        }
        return;
    }

    const isFa = style.icon.startsWith("fa");
    const iconHtml = isFa ? `<i class="notify-icon ${style.icon}"></i>` : `<span class="notify-icon material-icons">${style.icon}</span>`;

    const TITLE_MAP = { success: "Success", primary: "Info", warning: "Warning", error: "Error", police: "Police", ambulance: "EMS" };
    const title = style.label || TITLE_MAP[type] || TITLE_MAP.primary;

    const item = document.createElement("div");
    item.className = `notify-item ${style.classes}`;
    item.innerHTML = `
        <div class="notify-icon-wrap">${iconHtml}</div>
        <div class="notify-content">
            <div class="notify-title">${title}</div>
            <div class="notify-message${!caption ? " notify-multiline" : ""}">${message}</div>
            ${caption ? `<div class="notify-caption">${caption}</div>` : ""}
        </div>
        <div class="notify-count"></div>
        ${showProgress ? `<div class="notify-progress" style="animation-duration:${duration}ms"></div>` : ""}
    `;

    const c = getContainer();
    // cap the stack so spam can't flood the screen
    while (c.children.length >= MAX_VISIBLE) {
        const oldest = c.children[0];
        for (const [key, entry] of activeNotifs) {
            if (entry.item === oldest) {
                if (entry.timer) clearTimeout(entry.timer);
                activeNotifs.delete(key);
                break;
            }
        }
        oldest.remove();
    }
    c.appendChild(item);

    let timer = null;
    if (duration > 0) {
        timer = setTimeout(() => dismiss(item, groupKey), duration);
    }
    if (groupKey) activeNotifs.set(groupKey, { item, count: 1, timer });

    await sleep(10);
    item.classList.add("notify-show");
};

window.addEventListener("message", showNotif);
window.addEventListener("load", fetchNotifyConfig);
