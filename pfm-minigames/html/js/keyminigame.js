const Keys = {
    ArrowUp: "arrowup",
    ArrowLeft: "arrowleft",
    ArrowDown: "arrowdown",
    ArrowRight: "arrowright",
};

let WrongKeyCount = 0;
let CurrentKey = -1; // step being played (0-based), -1 before the first key lights
let Key = 0;
let KeyPressed = false;
let CanPress = false;
let Running = false;
let GameToken = 0; // a game quit with Escape stops even if a new one has started meanwhile
let StepStart = 0;
// first press of each step, sent back as the answer to a server challenge (server/challenge.lua)
let Presses = [];

const generateRandomPattern = (length) => {
    const keys = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"];
    const pattern = [];

    for (let i = 0; i < length; i++) {
        const randomIndex = Math.floor(Math.random() * keys.length);
        pattern.push(keys[randomIndex]);
    }

    return pattern;
};

const showMinigame = () => {
    const container = document.querySelector(".keys-container");
    if (container) {
        container.style.transition = "opacity 300ms";
        container.style.opacity = 1;
        container.style.display = "flex";
    }
};

const hideMinigame = () => {
    const container = document.querySelector(".keys-container");
    if (container) {
        container.style.transition = "opacity 300ms";
        container.style.opacity = 0;
        setTimeout(() => {
            container.style.display = "none";
        }, 300);
    }
};

const keysTimer = (ms) => {
    return new Promise((resolve) => setTimeout(resolve, ms));
};

const keyElementFor = (name) => document.querySelector(`.keys-container .key[data-key="${Keys[name]}"]`);

const resetKeygame = () => {
    WrongKeyCount = 0;
    CurrentKey = -1;
    Key = 0;
    KeyPressed = false;
    CanPress = false;
    Running = false;
};

// A challenge brings the server's pattern and timings; without one the pattern is random.
async function startKeygame(amount, challenge) {
    const pattern = challenge && Array.isArray(challenge.pattern) ? challenge.pattern.map(String) : generateRandomPattern(amount);
    const lead = challenge ? Number(challenge.lead) : 1000;
    const step = challenge ? Number(challenge.step) : 1500;
    const windowMs = challenge ? Number(challenge.window) : 500;
    resetKeygame();
    Presses = [];
    Running = true;
    const token = ++GameToken;
    const live = () => Running && token === GameToken;
    showMinigame();
    await keysTimer(lead);

    for (let i = 0; i < pattern.length; i++) {
        if (!live()) return; // quit with Escape
        Key = pattern[i];
        CurrentKey = i;
        KeyPressed = false;
        StepStart = performance.now();

        const keyElement = keyElementFor(Key);
        if (keyElement) keyElement.style.backgroundColor = "orange";
        CanPress = true;

        (function (k) {
            setTimeout(function () {
                const el = keyElementFor(k);
                if (el) el.style.backgroundColor = "white";
                CanPress = false;
            }, windowMs);
        })(Key);

        // the last key is judged too, once its window has closed
        await keysTimer(i === pattern.length - 1 ? windowMs + 50 : step);
        if (!live()) return;
        if (!KeyPressed) WrongKeyCount += 1;
    }

    hideMinigame();
    fetch(`https://${GetParentResourceName()}/keyminigameFinish`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ faults: WrongKeyCount, presses: Presses }),
    }).catch((err) => console.error("Error with fetch:", err));
    resetKeygame();
}

document.addEventListener("keydown", function (event) {
    if (!Running) return;
    const keyName = event.key;

    if (keyName === "Escape") {
        hideMinigame();
        fetch(`https://${GetParentResourceName()}/keyminigameExit`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify({ presses: Presses }),
        }).catch((err) => console.error("Error with fetch:", err));
        resetKeygame();
        return;
    }

    const keyDiv = keyElementFor(keyName);
    if (!keyDiv || CurrentKey < 0) return;
    if (!KeyPressed) Presses.push({ s: CurrentKey + 1, k: keyName, ms: Math.round(performance.now() - StepStart) });

    if (keyName === Key) {
        if (CanPress) {
            keyDiv.style.backgroundColor = "green";
            KeyPressed = true;
            CanPress = false;
        } else {
            if (!KeyPressed) {
                WrongKeyCount++;
                keyDiv.style.backgroundColor = "red";
                KeyPressed = true;
                CanPress = false;
                setTimeout(() => (keyDiv.style.backgroundColor = "white"), 300);
            }
        }
    } else {
        if (!KeyPressed) {
            WrongKeyCount++;
            keyDiv.style.backgroundColor = "red";
            KeyPressed = true;
            CanPress = false;
            setTimeout(() => (keyDiv.style.backgroundColor = "white"), 300);
        }
    }
});

window.addEventListener("message", (event) => {
    let data = event.data;
    if (data.action === "startKeygame" && !Running) {
        startKeygame(data.amount, data.challenge);
    }
});
