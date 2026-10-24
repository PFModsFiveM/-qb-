const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const removeClass = (element, name) => element.classList.remove(name);
const addClass = (element, name) => element.classList.add(name);

const VALID_POSITIONS = ["left", "right", "top"];

// Renders "[E] Open Shop" / "E - Open Shop" with a styled keycap, anything else as-is.
// GTA color codes (~r~ etc.) are stripped since HTML can't render them.
const renderText = (element, rawText) => {
    const text = String(rawText ?? "").replace(/~[a-zA-Z]~/g, "");
    const match = text.match(/^\s*\[([^\]]{1,12})\]\s*-?\s*(.*)$/s) || text.match(/^\s*([A-Za-z0-9]{1})\s+-\s+(.*)$/s);
    if (match && match[2]) {
        element.innerHTML = "";
        const key = document.createElement("span");
        key.className = "dt-key";
        key.textContent = match[1];
        const label = document.createElement("span");
        label.innerHTML = match[2];
        element.appendChild(key);
        element.appendChild(label);
    } else {
        element.innerHTML = text;
    }
};

const applyPosition = (element, position) => {
    const pos = VALID_POSITIONS.includes(position) ? position : "left";
    addClass(element, pos);
};

const drawText = async (textData) => {
    const text = document.getElementById("text");
    applyPosition(text, textData.position);
    renderText(text, textData.text);
    document.getElementById("drawtext-container").style.display = "block";
    await sleep(100);
    addClass(text, "show");
};

const changeText = async (textData) => {
    const text = document.getElementById("text");

    removeClass(text, "show");
    addClass(text, "pressed");
    addClass(text, "hide");

    await sleep(350);
    for (const pos of VALID_POSITIONS) removeClass(text, pos);
    removeClass(text, "bottom");
    removeClass(text, "hide");
    removeClass(text, "pressed");

    applyPosition(text, textData.position);
    renderText(text, textData.text);

    await sleep(100);
    addClass(text, "show");
};

const hideText = async () => {
    const text = document.getElementById("text");
    removeClass(text, "show");
    addClass(text, "hide");

    setTimeout(() => {
        for (const pos of VALID_POSITIONS) removeClass(text, pos);
        removeClass(text, "bottom");
        removeClass(text, "hide");
        removeClass(text, "pressed");
        document.getElementById("drawtext-container").style.display = "none";
    }, 400);
};

const keyPressed = () => {
    addClass(document.getElementById("text"), "pressed");
};

window.addEventListener("message", (event) => {
    const { action, data } = event.data;
    switch (action) {
        case "DRAW_TEXT":
            return drawText(data);
        case "CHANGE_TEXT":
            return changeText(data);
        case "HIDE_TEXT":
            return hideText();
        case "KEY_PRESSED":
            return keyPressed();
        default:
            return;
    }
});


/* PF global UI theme (broadcast by pf-hud) */
const pfHexToRgba = (h, a) => { const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || ""); return m ? `rgba(${parseInt(m[1],16)},${parseInt(m[2],16)},${parseInt(m[3],16)},${a})` : null; };
window.addEventListener("message", (e) => {
    if (!e.data || e.data.action !== "theme" || !e.data.theme) return;
    const t = e.data.theme, r = document.documentElement.style, op = t.opacity ?? 0.92;
    if (t.primary) { r.setProperty("--notify-bg", pfHexToRgba(t.primary, op)); r.setProperty("--dt-bg", pfHexToRgba(t.primary, op)); }
    if (t.accent) r.setProperty("--dt-accent", t.accent);
    if (t.text) { r.setProperty("--notify-fg", t.text); r.setProperty("--notify-fg-dim", pfHexToRgba(t.text, 0.65)); r.setProperty("--dt-fg", t.text); }
});