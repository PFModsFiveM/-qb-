let buttonParams = [];
let images = [];
let focusIndex = -1;

const buttonsEl = document.getElementById("buttons");
const imageHoverEl = document.getElementById("imageHover");
const imageEl = document.getElementById("image");

const isImageIcon = (icon) =>
    typeof icon === "string" && (icon.includes("/") || /\.(png|jpe?g|webp|gif|svg)$/i.test(icon));

const iconHtml = (icon) => {
    if (!icon) return "";
    if (isImageIcon(icon)) {
        return `<div class="icon"><img src="${icon}" onerror="this.parentElement.remove();" /></div>`;
    }
    return `<div class="icon"><i class="${icon}"></i></div>`;
};

const getButtonRender = (header, message, id, isMenuHeader, isDisabled, icon, order, hotkey) => {
    return `
        <div class="${isMenuHeader ? "title" : "button"} ${isDisabled ? "disabled" : ""}" id="${id}" style="animation-delay:${Math.min(order * 30, 280)}ms">
            ${iconHtml(icon)}
            <div class="column">
                <div class="header">${header}</div>
                ${message ? `<div class="text">${message}</div>` : ""}
            </div>
            ${!isMenuHeader && !isDisabled && hotkey ? `<div class="hotkey">${hotkey}</div>` : ""}
            ${!isMenuHeader && !isDisabled ? `<i class="fas fa-chevron-right chevron"></i>` : ""}
        </div>
    `;
};

const openMenu = (data = null) => {
    let html = "";
    let order = 0;
    let hotkeyNum = 0;
    focusIndex = -1;
    images = [];
    buttonParams = [];
    data.forEach((item, index) => {
        if (!item.hidden) {
            images[index] = item;
            const selectable = !item.isMenuHeader && !item.disabled;
            const hotkey = selectable && hotkeyNum < 9 ? ++hotkeyNum : null;
            html += getButtonRender(item.header, item.txt || item.text, index, item.isMenuHeader, item.disabled, item.icon, order++, hotkey);
            if (item.params) buttonParams[index] = item.params;
        }
    });

    buttonsEl.innerHTML = html;

    buttonsEl.querySelectorAll(".button:not(.disabled)").forEach((el) => {
        el.addEventListener("click", () => postData(el.id));
    });
};

const closeMenu = () => {
    buttonsEl.innerHTML = "";
    imageHoverEl.style.display = "none";
    buttonParams = [];
    images = [];
    focusIndex = -1;
};

const postData = (id) => {
    fetch(`https://${GetParentResourceName()}/clickedButton`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(parseInt(id) + 1),
    });
    return closeMenu();
};

const cancelMenu = () => {
    fetch(`https://${GetParentResourceName()}/closeMenu`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: "{}",
    });
    return closeMenu();
};

window.addEventListener("message", (event) => {
    const { action, data } = event.data;
    switch (action) {
        case "OPEN_MENU":
        case "SHOW_HEADER":
            return openMenu(data);
        case "CLOSE_MENU":
            return closeMenu();
        default:
            return;
    }
});

// item image preview on hover
window.addEventListener("mousemove", (event) => {
    const target = event.target.closest(".button");
    if (target && images[target.id] && images[target.id].image) {
        imageEl.src = images[target.id].image;
        imageHoverEl.style.display = "block";
    } else {
        imageHoverEl.style.display = "none";
    }
});

// keyboard navigation: arrows + enter, escape to close
const getNavigable = () => Array.from(buttonsEl.querySelectorAll(".button:not(.disabled)"));

const setFocus = (list, idx) => {
    list.forEach((el) => el.classList.remove("kb-focus"));
    if (idx >= 0 && list[idx]) {
        list[idx].classList.add("kb-focus");
        list[idx].scrollIntoView({ block: "nearest" });
    }
};

document.onkeyup = (event) => {
    if (event.key === "Escape") return cancelMenu();
};

document.onkeydown = (event) => {
    const list = getNavigable();
    if (!list.length) return;
    if (event.key === "ArrowDown") {
        focusIndex = Math.min(focusIndex + 1, list.length - 1);
        setFocus(list, focusIndex);
    } else if (event.key === "ArrowUp") {
        focusIndex = Math.max(focusIndex - 1, 0);
        setFocus(list, focusIndex);
    } else if (event.key === "Enter" && focusIndex >= 0 && list[focusIndex]) {
        postData(list[focusIndex].id);
    } else if (/^[1-9]$/.test(event.key)) {
        const idx = parseInt(event.key, 10) - 1;
        if (list[idx]) postData(list[idx].id);
    }
};


/* PF global UI theme (broadcast by pf-hud) */
const pfHexToRgba = (h, a) => { const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || ""); return m ? `rgba(${parseInt(m[1],16)},${parseInt(m[2],16)},${parseInt(m[3],16)},${a})` : null; };
window.addEventListener("message", (e) => {
    if (!e.data || e.data.action !== "theme" || !e.data.theme) return;
    const t = e.data.theme, r = document.documentElement.style, op = t.opacity ?? 0.92;
    if (t.primary) r.setProperty("--menu-bg", pfHexToRgba(t.primary, op));
    if (t.secondary) r.setProperty("--menu-bg-header", pfHexToRgba(t.secondary, Math.min(1, op + 0.03)));
    if (t.accent) r.setProperty("--menu-accent", t.accent);
    if (t.text) { r.setProperty("--menu-fg", t.text); r.setProperty("--menu-fg-dim", pfHexToRgba(t.text, 0.6)); }
});