/* qb-multicharacter UI — vanilla JS, same NUI protocol as the Vue version it replaces */

const state = {
    characters: [],
    characterAmount: 0,
    selectedCharacter: -1,
    allowDelete: false,
    customNationality: false,
    nationalities: [],
    dollar: Intl.NumberFormat("en-US"),
};

const el = (id) => document.getElementById(id);
const post = (event, data) =>
    fetch(`https://pfm-multicharacter/${event}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(data ?? {}),
    });

const t = (key, params) => (params ? translationManager.formatTranslation(key, params) : translationManager.translate(key));

const show = (id) => el(id).classList.remove("hidden");
const hide = (id) => el(id).classList.add("hidden");

/* ── toast ─────────────────────────────────── */
let toastTimer = null;
const showToast = (title, text) => {
    el("toast-title").textContent = title;
    el("toast-text").textContent = text;
    show("toast");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => hide("toast"), 5000);
};

/* ── character list ────────────────────────── */
const renderDetail = () => {
    const detail = el("char-detail");
    const char = state.characters[state.selectedCharacter];
    if (!char) {
        detail.classList.add("hidden");
        return;
    }
    detail.classList.remove("hidden");
    detail.classList.remove("detail-in");
    void detail.offsetWidth; // restart entrance animation
    detail.classList.add("detail-in");
    el("detail-name").textContent = `${char.charinfo.firstname} ${char.charinfo.lastname}`;
    el("detail-cid").textContent = char.citizenid || "";
    el("detail-job").textContent = char.job.label;
    el("detail-cash").textContent = "$" + state.dollar.format(char.money.cash);
    el("detail-bank").textContent = "$" + state.dollar.format(char.money.bank);
    el("detail-nat").textContent = (char.charinfo.nationality || "—");
    el("detail-play-label").textContent = t("play_button") !== "play_button" ? t("play_button") : "Play";
    el("detail-delete").classList.toggle("hidden", !state.allowDelete);
};

const renderCharacters = () => {
    const list = el("char-list");
    list.innerHTML = "";
    el("panel-title").textContent = t("characters_header") !== "characters_header" ? t("characters_header") : "Characters";

    for (let i = 1; i <= state.characterAmount; i++) {
        const char = state.characters[i];
        if (char) {
            const card = document.createElement("div");
            card.className = "char-card" + (state.selectedCharacter === i ? " selected" : "");
            card.style.animationDelay = `${Math.min(i * 60, 320)}ms`;
            card.innerHTML = `
                <div class="char-slot">${String(i).padStart(2, "0")}</div>
                <div class="char-main">
                    <div class="char-name">${char.charinfo.firstname} ${char.charinfo.lastname}</div>
                    <div class="char-sub">${char.job.label}</div>
                </div>
                <span class="material-icons char-chevron">chevron_right</span>
            `;
            card.addEventListener("click", () => selectCharacter(i));
            list.appendChild(card);
        } else {
            const empty = document.createElement("div");
            empty.className = "empty-card";
            empty.style.animationDelay = `${Math.min(i * 60, 320)}ms`;
            empty.innerHTML = `<span class="material-icons">person_add</span>${t("create_button") !== "create_button" ? t("create_button") : "Create Character"}`;
            empty.addEventListener("click", () => {
                state.selectedCharacter = i;
                post("cDataPed", {});
                openRegister();
            });
            list.appendChild(empty);
        }
    }
    renderDetail();
};

const selectCharacter = (i) => {
    state.selectedCharacter = i;
    if (state.characters[i] !== undefined) {
        post("cDataPed", { cData: state.characters[i] });
    } else {
        post("cDataPed", {});
    }
    renderCharacters();
};

el("detail-play").addEventListener("click", () => playCharacter());
el("detail-delete").addEventListener("click", () => prepareDelete());

const playCharacter = () => {
    if (state.selectedCharacter === -1) return;
    const data = state.characters[state.selectedCharacter];
    if (data !== undefined) {
        post("selectCharacter", { cData: data });
        setTimeout(() => { hide("char-panel"); hide("char-detail"); }, 500);
    } else {
        openRegister();
    }
};

/* ── delete flow ───────────────────────────── */
const prepareDelete = () => {
    el("delete-text").textContent = t("deletechar_description");
    el("delete-confirm").textContent = t("confirm");
    el("delete-cancel").textContent = t("cancel");
    hide("char-panel"); hide("char-detail");
    show("delete-modal");
};

el("delete-confirm").addEventListener("click", () => {
    hide("delete-modal");
    post("removeCharacter", { citizenid: state.characters[state.selectedCharacter].citizenid });
    setTimeout(() => { show("char-panel"); renderDetail(); }, 500);
});

el("delete-cancel").addEventListener("click", () => {
    hide("delete-modal");
    show("char-panel"); renderDetail();
});

/* ── register flow ─────────────────────────── */
const todayISO = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().substr(0, 10);

const openRegister = () => {
    hide("char-panel"); hide("char-detail");
    el("register-title").textContent = t("chardel_header");
    el("reg-firstname").placeholder = t("firstname");
    el("reg-lastname").placeholder = t("lastname");
    el("reg-firstname").value = "";
    el("reg-lastname").value = "";
    el("reg-date-label").textContent = t("birthdate");
    el("reg-date").value = todayISO();
    el("reg-date").max = todayISO();
    el("register-submit").textContent = t("create_button");

    const genderSel = el("reg-gender");
    genderSel.innerHTML = `<option value="" disabled selected>${t("gender")}</option><option>${t("male")}</option><option>${t("female")}</option>`;

    if (state.customNationality) {
        show("reg-nationality");
        hide("reg-nationality-select");
        el("reg-nationality").placeholder = t("nationality");
        el("reg-nationality").value = "";
    } else {
        hide("reg-nationality");
        show("reg-nationality-select");
        const sel = el("reg-nationality-select");
        sel.innerHTML = `<option value="" disabled selected>${t("nationality")}</option>` + state.nationalities.map((n) => `<option>${n}</option>`).join("");
    }

    show("register-modal");
    el("reg-firstname").focus();
};

const closeRegister = () => {
    hide("register-modal");
    show("char-panel"); renderDetail();
};

el("register-close").addEventListener("click", closeRegister);

el("register-submit").addEventListener("click", () => {
    const registerData = {
        firstname: el("reg-firstname").value.trim() || undefined,
        lastname: el("reg-lastname").value.trim() || undefined,
        nationality: (state.customNationality ? el("reg-nationality").value.trim() : el("reg-nationality-select").value) || undefined,
        gender: el("reg-gender").value || undefined,
        date: el("reg-date").value || undefined,
    };

    const validationResult = characterValidator.validateCharacter(registerData);
    if (validationResult.isValid) {
        hide("register-modal");
        post("createNewCharacter", {
            firstname: registerData.firstname,
            lastname: registerData.lastname,
            nationality: registerData.nationality,
            birthdate: registerData.date,
            gender: registerData.gender,
            cid: state.selectedCharacter,
        });
        setTimeout(() => { hide("char-panel"); hide("char-detail"); }, 500);
    } else {
        showToast(t("ran_into_issue"), t(validationResult.message, { field: t(validationResult.field) }));
    }
});

/* ── NUI message handling ──────────────────── */
initializeValidator();

window.addEventListener("message", (event) => {
    const data = event.data;
    switch (data.action) {
        case "ui": {
            state.customNationality = data.customNationality;
            translationManager.setTranslations(data.translations);
            state.nationalities = data.countries || [];
            state.characterAmount = data.nChar;
            state.selectedCharacter = -1;
            state.allowDelete = data.enableDeleteButton;
            hide("register-modal");
            hide("delete-modal");
            hide("char-panel"); hide("char-detail");

            if (data.toggle) {
                show("loading-screen");
                el("loading-text").textContent = t("retrieving_playerdata");
                let progress = 0;
                const interval = setInterval(() => {
                    progress++;
                    if (progress === 3) el("loading-text").textContent = t("validating_playerdata");
                    if (progress === 4) el("loading-text").textContent = t("retrieving_characters");
                    if (progress === 6) el("loading-text").textContent = t("validating_characters");
                }, 500);

                setTimeout(() => {
                    post("setupCharacters");
                    setTimeout(() => {
                        clearInterval(interval);
                        hide("loading-screen");
                        renderCharacters();
                        show("char-panel"); renderDetail();
                        post("removeBlur");
                    }, 2000);
                }, 2000);
            }
            break;
        }
        case "setupCharacters": {
            const newChars = [];
            for (let i = 0; i < data.characters.length; i++) {
                newChars[data.characters[i].cid] = data.characters[i];
            }
            state.characters = newChars;
            break;
        }
        case "setupCharInfo":
            break;
    }
});


/* PF global UI theme (broadcast by pf-hud) */
const pfHexToRgba = (h, a) => { const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || ""); return m ? `rgba(${parseInt(m[1],16)},${parseInt(m[2],16)},${parseInt(m[3],16)},${a})` : null; };
window.addEventListener("message", (e) => {
    if (!e.data || e.data.action !== "theme" || !e.data.theme) return;
    const t = e.data.theme, r = document.documentElement.style, op = t.opacity ?? 0.92;
    if (t.primary) { r.setProperty("--mc-bg", pfHexToRgba(t.primary, op)); r.setProperty("--mc-bg-card", pfHexToRgba(t.primary, Math.max(0.5, op - 0.04))); }
    if (t.secondary) r.setProperty("--mc-bg-field", pfHexToRgba(t.secondary, 0.8));
    if (t.accent) r.setProperty("--mc-accent", t.accent);
    if (t.text) { r.setProperty("--mc-fg", t.text); r.setProperty("--mc-fg-dim", pfHexToRgba(t.text, 0.6)); }
});