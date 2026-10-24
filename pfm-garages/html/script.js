let allVehicles = [];
let currentGarageLabel = "";
let currentGarageType = "";

const GARAGE_ICONS = { depot: "local_parking", job: "work", gang: "groups", house: "home", public: "garage" };

window.addEventListener("message", function (event) {
    const data = event.data;
    if (data.action === "VehicleList") {
        currentGarageLabel = data.garageLabel;
        currentGarageType = data.garageType || "";
        allVehicles = data.vehicles || [];
        document.getElementById("search").value = "";
        renderVehicleList();
        displayUI();
    } else if (data.action === "theme") {
        applyTheme(data.theme);
    }
});

function applyTheme(t) {
    if (!t) return;
    const r = document.documentElement.style;
    const hexToRgba = (hex, a) => {
        const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
        return m ? `rgba(${parseInt(m[1], 16)}, ${parseInt(m[2], 16)}, ${parseInt(m[3], 16)}, ${a})` : hex;
    };
    const op = typeof t.opacity === "number" ? Math.max(0.5, Math.min(1, t.opacity)) : 0.92;
    if (t.primary) {
        r.setProperty("--g-bg", hexToRgba(t.primary, op));
        r.setProperty("--g-bg-head", hexToRgba(t.primary, Math.min(1, op + 0.03)));
    }
    if (t.secondary) {
        r.setProperty("--g-card", hexToRgba(t.secondary, 0.55));
        r.setProperty("--g-card-hover", hexToRgba(t.secondary, 0.8));
    }
    if (t.accent) r.setProperty("--g-accent", t.accent);
    if (t.text) {
        r.setProperty("--g-fg", t.text);
        r.setProperty("--g-dim", hexToRgba(t.text, 0.55));
    }
}

document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeGarageMenu();
});

document.getElementById("close-btn").addEventListener("click", closeGarageMenu);
document.getElementById("search").addEventListener("input", renderVehicleList);

function post(cb, body) {
    return fetch(`https://pfm-garages/${cb}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(body),
    }).then((r) => r.json());
}

function closeGarageMenu() {
    document.getElementById("container").classList.remove("show");
    post("closeGarage", {});
}

function displayUI() {
    document.getElementById("container").classList.add("show");
}

// Mirrors the original state machine exactly:
// state 0 = out, state 1 = garaged, state 2 = impounded
function getVehicleAction(v) {
    const hasDepotFee = v.depotPrice && v.depotPrice > 0;
    if (v.state === 2) return { status: "Impounded", cls: "impound", button: null };
    if (v.state === 0) {
        if (hasDepotFee) {
            if (v.type === "public") return { status: "In depot", cls: "depot", button: null };
            if (v.type === "depot") return { status: "In depot", cls: "depot", button: { label: `Pay $${Math.floor(v.depotPrice).toLocaleString()}`, kind: "depot" } };
        }
        return { status: "Out", cls: "out", button: { label: "Track", kind: "track" } };
    }
    // state 1
    if (hasDepotFee) {
        if (v.type === "depot") return { status: "In depot", cls: "depot", button: { label: `Pay $${Math.floor(v.depotPrice).toLocaleString()}`, kind: "depot" } };
        if (v.type === "public") return { status: "In depot", cls: "depot", button: null };
    }
    return { status: "In garage", cls: "in", button: { label: "Drive", kind: "drive" } };
}

function statBar(label, icon, value, max) {
    const pct = Math.max(0, Math.min(100, (value / max) * 100));
    const cls = pct >= 75 ? "good" : pct >= 40 ? "warn" : "bad";
    return `
        <div class="stat" title="${label}: ${Math.round(pct)}%">
            <span class="material-icons-round">${icon}</span>
            <div class="bar"><div class="fill ${cls}" style="width:${pct}%"></div></div>
            <em>${Math.round(pct)}%</em>
        </div>`;
}

function renderVehicleList() {
    const container = document.getElementById("vehicle-container");
    const q = document.getElementById("search").value.trim().toLowerCase();

    document.getElementById("garage-header").textContent = currentGarageLabel;
    document.getElementById("garage-icon").textContent = GARAGE_ICONS[currentGarageType] || "garage";
    const typeEl = document.getElementById("garage-type");
    typeEl.textContent = currentGarageType ? currentGarageType : "";
    typeEl.style.display = currentGarageType ? "" : "none";

    const vehicles = allVehicles.filter((v) => {
        if (!q) return true;
        const name = `${v.brand || ""} ${v.vehicleLabel || ""}`.toLowerCase();
        return name.includes(q) || (v.plate || "").toLowerCase().includes(q);
    });

    document.getElementById("garage-count").textContent = `${allVehicles.length} vehicle${allVehicles.length === 1 ? "" : "s"}`;

    container.innerHTML = "";
    if (vehicles.length === 0) {
        container.innerHTML = `<div class="empty"><span class="material-icons-round">${q ? "search_off" : "garage"}</span>${q ? "No vehicles match your search" : "No vehicles here"}</div>`;
        return;
    }

    for (const v of vehicles) {
        const action = getVehicleAction(v);
        const card = document.createElement("div");
        card.className = "vehicle-item";

        const financed = v.balance && v.balance > 0;
        const name = v.brand ? `${v.brand} ${v.vehicleLabel}` : v.vehicleLabel;

        card.innerHTML = `
            <div class="v-row">
                <div class="v-main">
                    <div class="v-name">${name}${v.shared ? '<span class="chip shared" title="Owned by another member — only the owner can take it out">shared</span>' : ""}</div>
                    <div class="v-meta">
                        <span class="plate">${v.plate}</span>
                        <span class="meta"><span class="material-icons-round">route</span>${Number(v.distance || 0).toLocaleString()} mi</span>
                        ${financed ? `<span class="meta finance" title="Outstanding finance"><span class="material-icons-round">account_balance</span>$${Math.floor(v.balance).toLocaleString()}</span>` : ""}
                    </div>
                </div>
                <div class="v-side">
                    <span class="chip status ${action.cls}">${action.status}</span>
                    ${action.button && !v.shared ? `<button class="act ${action.button.kind}">${action.button.label}</button>` : ""}
                </div>
            </div>
            <div class="stats">
                ${statBar("Fuel", "local_gas_station", v.fuel, 100)}
                ${statBar("Engine", "settings", v.engine, 1000)}
                ${statBar("Body", "minor_crash", v.body, 1000)}
            </div>`;

        const btn = card.querySelector(".act");
        if (btn) {
            btn.onclick = () => {
                btn.disabled = true;
                const vehicleData = {
                    vehicle: v.vehicle,
                    garage: v.garage,
                    index: v.index,
                    plate: v.plate,
                    type: v.type,
                    depotPrice: v.depotPrice,
                    stats: { fuel: v.fuel, engine: v.engine, body: v.body },
                };
                if (action.button.kind === "track") {
                    post("trackVehicle", v.plate).then(() => closeGarageMenu());
                } else if (action.button.kind === "depot") {
                    post("takeOutDepo", vehicleData).then(() => closeGarageMenu());
                } else {
                    post("takeOutVehicle", vehicleData).then(() => closeGarageMenu());
                }
            };
        }

        container.appendChild(card);
    }
}
