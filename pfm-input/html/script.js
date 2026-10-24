let formInputs = {};
let currentStyle = null;

const wrapper = () => document.querySelector(".main-wrapper");

const esc = (v) => String(v ?? "").replace(/"/g, "&quot;");

const OpenMenu = (data) => {
    if (data == null || data === "") {
        console.log("No data detected");
        return null;
    }

    formInputs = {};

    let form = [`<form id="qb-input-form">`, `<div class="heading">${data.header != null ? data.header : "Form Title"}</div>`];

    data.inputs.forEach((item) => {
        switch (item.type) {
            case "text":
                form.push(renderBasicInput(item, "text"));
                break;
            case "password":
                form.push(renderBasicInput(item, "password"));
                break;
            case "number":
                form.push(renderBasicInput(item, "number"));
                break;
            case "radio":
                form.push(renderRadioInput(item));
                break;
            case "select":
                form.push(renderSelectInput(item));
                break;
            case "checkbox":
                form.push(renderCheckboxInput(item));
                break;
            case "color":
                form.push(renderColorInput(item));
                break;
            default:
                form.push(`<div class="label">${item.text}</div>`);
        }
    });
    form.push(`<div class="footer"><button type="submit" class="btn btn-success" id="submit">${data.submitText ? data.submitText : "Submit"}</button></div>`);
    form.push("</form>");

    const w = wrapper();
    w.innerHTML = form.join(" ");
    w.style.display = "block";

    const formEl = document.getElementById("qb-input-form");

    formEl.addEventListener("change", (event) => {
        const t = event.target;
        if (t.getAttribute("type") === "checkbox") {
            formInputs[t.value] = t.checked ? "true" : "false";
        } else {
            formInputs[t.name] = t.value;
        }
    });

    formEl.addEventListener("submit", (event) => {
        event.preventDefault();
        fetch(`https://${GetParentResourceName()}/buttonSubmit`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify({ data: formInputs }),
        }).then(() => CloseMenu());
    });

    const firstField = formEl.querySelector("input, select");
    if (firstField) firstField.focus();
};

const renderBasicInput = (item, type) => {
    const { text, name } = item;
    formInputs[name] = item.default ? item.default : "";
    const isRequired = item.isRequired == "true" || item.isRequired ? "required" : "";
    const defaultValue = item.default != null ? `value="${esc(item.default)}"` : "";
    return `<input placeholder="${esc(text)}" type="${type}" class="form-control" name="${esc(name)}" ${defaultValue} ${isRequired}/>`;
};

const renderRadioInput = (item) => {
    const { options, name, text } = item;
    formInputs[name] = options[0].value;

    let div = `<div class="form-input-group"><div class="form-group-title">${text}</div><div class="input-group">`;
    options.forEach((option, index) => {
        const checked = (item.default ? item.default == option.value : index == 0);
        if (checked) formInputs[name] = option.value;
        div += `<label for="radio_${esc(name)}_${index}" class="choice"><input type="radio" id="radio_${esc(name)}_${index}" name="${esc(name)}" value="${esc(option.value)}" ${checked ? "checked" : ""}><span>${option.text}</span></label>`;
    });
    div += "</div></div>";
    return div;
};

const renderCheckboxInput = (item) => {
    const { options, name, text } = item;
    let div = `<div class="form-input-group"><div class="form-group-title">${text}</div><div class="input-group-chk">`;
    options.forEach((option, index) => {
        div += `<label for="chk_${esc(name)}_${index}" class="choice"><input type="checkbox" id="chk_${esc(name)}_${index}" name="${esc(name)}" value="${esc(option.value)}" ${option.checked ? "checked" : ""}><span>${option.text}</span></label>`;
        formInputs[option.value] = option.checked ? "true" : "false";
    });
    div += "</div></div>";
    return div;
};

const renderSelectInput = (item) => {
    const { options, name, text } = item;
    let div = `<div class="select-title">${text}</div>`;
    div += `<select class="form-select" name="${esc(name)}" title="${esc(text)}">`;
    formInputs[name] = options[0].value;
    options.forEach((option) => {
        const isDefaultValue = item.default == option.value;
        div += `<option value="${esc(option.value)}" ${isDefaultValue ? "selected" : ""}>${option.text}</option>`;
        if (isDefaultValue) formInputs[name] = option.value;
    });
    div += "</select>";
    return div;
};

const renderColorInput = (item) => {
    const { text, name } = item;
    formInputs[name] = item.default ? item.default : "#ffffff";
    const isRequired = item.isRequired == "true" || item.isRequired ? "required" : "";
    const defaultValue = `value="${esc(item.default ? item.default : "#ffffff")}"`;
    return `<div class="color-row"><span class="color-label">${esc(text)}</span><input type="color" class="form-control" name="${esc(name)}" ${defaultValue} ${isRequired}/></div>`;
};

const CloseMenu = () => {
    const w = wrapper();
    w.style.display = "none";
    const formEl = document.getElementById("qb-input-form");
    if (formEl) formEl.remove();
    formInputs = {};
};

const SetStyle = (style) => {
    if (currentStyle === style) return;
    currentStyle = style;
    let link = document.getElementById("qb-input-style");
    if (!link) {
        link = document.createElement("link");
        link.id = "qb-input-style";
        link.rel = "stylesheet";
        link.type = "text/css";
        document.head.appendChild(link);
    }
    link.href = `./styles/${style}.css`;
};

const CancelMenu = () => {
    fetch(`https://${GetParentResourceName()}/closeMenu`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: "{}",
    });
    return CloseMenu();
};

SetStyle("default");

window.addEventListener("message", (event) => {
    const { action, data } = event.data;
    switch (action) {
        case "SET_STYLE":
            return SetStyle(data);
        case "OPEN_MENU":
            return OpenMenu(data);
        case "CLOSE_MENU":
            return CloseMenu();
        default:
            return;
    }
});

document.onkeyup = (event) => {
    if (event.key === "Escape") {
        CancelMenu();
    }
    // Enter submits natively via the form's submit button
};

document.addEventListener("click", (event) => {
    const w = wrapper();
    if (w.style.display === "block" && !event.target.closest(".main-wrapper")) {
        CancelMenu();
    }
});


/* PF global UI theme (broadcast by pf-hud) */
const pfHexToRgba = (h, a) => { const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || ""); return m ? `rgba(${parseInt(m[1],16)},${parseInt(m[2],16)},${parseInt(m[3],16)},${a})` : null; };
window.addEventListener("message", (e) => {
    if (!e.data || e.data.action !== "theme" || !e.data.theme) return;
    const t = e.data.theme, r = document.documentElement.style, op = t.opacity ?? 0.92;
    if (t.primary) r.setProperty("--in-bg", pfHexToRgba(t.primary, op));
    if (t.secondary) r.setProperty("--in-bg-field", pfHexToRgba(t.secondary, 0.8));
    if (t.accent) r.setProperty("--in-accent", t.accent);
    if (t.text) { r.setProperty("--in-fg", t.text); r.setProperty("--in-fg-dim", pfHexToRgba(t.text, 0.6)); }
});