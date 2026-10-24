/* qb-loading — FiveM loadscreen */

const TIPS = [
    "Press I at any time to open the HUD settings and pick your own style and accent color.",
    "Buckle up — driving unbuckled over 50 builds stress fast.",
    "Keep your hunger and thirst up or your health will start to drain.",
    "Stressed out? Food, drinks and downtime at a restaurant bring it back down.",
    "Your vehicle keeps its damage — visit a mechanic instead of hopping cars.",
    "Use /cash and /bank to quickly check your balances.",
];

const LOAD_STEPS = {
    INIT_BEFORE_MAP_LOADED: "Preparing the city…",
    MAP: "Loading the map…",
    INIT_AFTER_MAP_LOADED: "Placing the furniture…",
    INIT_SESSION: "Finding you a spot…",
};

let count = 0;
let thisCount = 0;

const fill = document.getElementById("progress-fill");
const pct = document.getElementById("pct");
const status = document.getElementById("status");

const setProgress = (fraction) => {
    const p = Math.max(0, Math.min(100, Math.round(fraction * 100)));
    fill.style.width = p + "%";
    pct.textContent = p + "%";
};

window.addEventListener("message", (e) => {
    const d = e.data;
    if (d.eventName === "loadProgress") {
        setProgress(d.loadFraction);
    } else if (d.eventName === "startInitFunctionOrder") {
        count = d.count;
        thisCount = 0;
        if (LOAD_STEPS[d.type]) status.textContent = LOAD_STEPS[d.type];
    } else if (d.eventName === "initFunctionInvoking") {
        thisCount = d.idx;
    } else if (d.eventName === "startDataFileEntries") {
        status.textContent = "Streaming assets…";
    } else if (d.eventName === "onLogLine") {
        // keep the generic step label; log lines are too noisy
    }
});

/* rotating tips */
const tipEl = document.getElementById("tip");
let tipIndex = Math.floor(Math.random() * TIPS.length);
tipEl.textContent = TIPS[tipIndex];
setInterval(() => {
    tipEl.classList.add("swap");
    setTimeout(() => {
        tipIndex = (tipIndex + 1) % TIPS.length;
        tipEl.textContent = TIPS[tipIndex];
        tipEl.classList.remove("swap");
    }, 400);
}, 7000);

/* music (off until toggled — browsers/CEF block autoplay with sound anyway) */
const music = document.getElementById("music");
const soundBtn = document.getElementById("sound-btn");
music.volume = 0.25;
let playing = false;
soundBtn.classList.add("muted");
soundBtn.addEventListener("click", () => {
    playing = !playing;
    if (playing) {
        music.play().catch(() => {});
        soundBtn.classList.remove("muted");
    } else {
        music.pause();
        soundBtn.classList.add("muted");
    }
});

/* explore panel */
const explore = document.getElementById("explore");
document.getElementById("explore-btn").addEventListener("click", () => explore.classList.remove("hidden"));
document.getElementById("explore-close").addEventListener("click", () => explore.classList.add("hidden"));
document.getElementById("explore-tabs").addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-tab]");
    if (!btn) return;
    document.querySelectorAll("#explore-tabs button").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    for (const page of ["keys", "start", "features"]) {
        document.getElementById("page-" + page).classList.toggle("hidden", page !== btn.dataset.tab);
    }
});