window.addEventListener("message", (event) => {
    switch (event.data.action) {
        case "open":
            open(event.data);
            break;
        case "close":
            close();
            break;
        case "setup":
            setup(event.data);
            break;
    }
});

const open = (data) => {
    const scoreboard = document.querySelector(".scoreboard-block");
    scoreboard.style.display = "block";

    const pill = document.getElementById("players-pill");
    if (pill) pill.textContent = `${data.players} / ${data.maxPlayers}`;
    const fill = document.getElementById("players-bar-fill");
    if (fill) fill.style.width = `${Math.min(100, (data.players / Math.max(1, data.maxPlayers)) * 100)}%`;

    const totalPlayers = document.getElementById("total-players");
    if (totalPlayers) {
        totalPlayers.innerHTML = `<span class="status-pill count">${data.players} of ${data.maxPlayers}</span>`;
    }

    Object.entries(data.requiredCops).forEach(([category, info]) => {
        const beam = document.querySelector(`.scoreboard-info [data-type="${category}"]`);
        if (!beam) return;
        const status = beam.querySelector(".info-beam-status");
        if (!status) return;
        if (info.busy) {
            status.innerHTML = `<span class="status-pill busy">Busy</span>`;
        } else if (data.currentCops >= info.minimumPolice) {
            status.innerHTML = `<span class="status-pill available">Open</span>`;
        } else {
            status.innerHTML = `<span class="status-pill unavailable">${info.minimumPolice} cops</span>`;
        }
    });
};

const close = () => {
    const scoreboard = document.querySelector(".scoreboard-block");
    scoreboard.style.display = "none";
};

const setup = (data) => {
    const scoreboardInfo = document.querySelector(".scoreboard-info");
    if (!scoreboardInfo) return;
    scoreboardInfo.innerHTML = "";
    Object.entries(data.items).forEach(([index, value]) => {
        const beamElement = document.createElement("div");
        beamElement.className = "scoreboard-info-beam";
        beamElement.setAttribute("data-type", index);
        const titleElement = document.createElement("div");
        titleElement.className = "info-beam-title";
        titleElement.innerHTML = `<p>${value}</p>`;
        const statusElement = document.createElement("div");
        statusElement.className = "info-beam-status";
        beamElement.appendChild(titleElement);
        beamElement.appendChild(statusElement);
        scoreboardInfo.appendChild(beamElement);
    });
    const playersBeam = document.createElement("div");
    playersBeam.className = "scoreboard-info-beam";
    const playersTitle = document.createElement("div");
    playersTitle.className = "info-beam-title";
    playersTitle.innerHTML = "<p>Total Players</p>";
    const playersStatus = document.createElement("div");
    playersStatus.className = "info-beam-status";
    playersStatus.id = "total-players";
    playersBeam.appendChild(playersTitle);
    playersBeam.appendChild(playersStatus);
    scoreboardInfo.appendChild(playersBeam);
};


/* PF global UI theme (broadcast by pf-hud) */
const pfHexToRgba = (h, a) => { const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || ""); return m ? `rgba(${parseInt(m[1],16)},${parseInt(m[2],16)},${parseInt(m[3],16)},${a})` : null; };
window.addEventListener("message", (e) => {
    if (!e.data || e.data.action !== "theme" || !e.data.theme) return;
    const t = e.data.theme, r = document.documentElement.style, op = t.opacity ?? 0.92;
    if (t.primary) r.setProperty("--sb-bg", pfHexToRgba(t.primary, op));
    if (t.secondary) r.setProperty("--sb-bg-row", pfHexToRgba(t.secondary, 0.75));
    if (t.accent) r.setProperty("--sb-accent", t.accent);
    if (t.text) { r.setProperty("--sb-fg", t.text); r.setProperty("--sb-fg-dim", pfHexToRgba(t.text, 0.6)); }
});