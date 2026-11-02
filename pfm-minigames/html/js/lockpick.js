const lockpickContainer = document.querySelector("#lockpick-container"),
    pin = document.querySelector("#pin"),
    cyl = document.querySelector("#cylinder"),
    driver = document.querySelector("#driver");

const minRot = -90,
    maxRot = 90,
    solvePadding = 4,
    maxDistFromSolve = 45,
    mouseSmoothing = 2,
    keyRepeatRate = 25,
    cylRotSpeed = 3,
    pinDamage = 20,
    pinDamageInterval = 150;

let solveDeg = Math.random() * (maxRot - minRot + 1) + minRot,
    pinRot = 0,
    cylRot = 0,
    lastMousePos = 0,
    pinHealth = 100,
    numPins = 1,
    userPushingCyl = false,
    gameOver = false,
    gamePaused = false,
    cylRotationInterval,
    pinLastDamaged;
// For a server challenge: the pin angle of the push that opened the lock, when, and pins broken.
let pushAngle = 0,
    startedAt = 0,
    pinsBroken = 0;

const clamp = (val, min, max) => Math.min(Math.max(val, min), max);
const convertRanges = (value, oldMin, oldMax, newMin, newMax) => ((value - oldMin) * (newMax - newMin)) / (oldMax - oldMin) + newMin;

const closeLockpick = () => {
    solveDeg = Math.random() * (maxRot - minRot + 1) + minRot;
    pinRot = 0;
    cylRot = 0;
    lastMousePos = 0;
    pinHealth = 100;
    numPins = 1;
    userPushingCyl = false;
    gameOver = true;
    gamePaused = true;
    lockpickContainer.style.display = "none";
    if (cylRotationInterval) {
        cancelAnimationFrame(cylRotationInterval);
        cylRotationInterval = null;
    }
};

const unlock = () => {
    const answer = { success: true, a: pushAngle, ms: Date.now() - startedAt, broken: pinsBroken };
    closeLockpick();
    fetch(`https://${GetParentResourceName()}/lockpickFinish`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(answer),
    });
};

const pushCyl = () => {
    cancelAnimationFrame(cylRotationInterval);
    userPushingCyl = true;
    pushAngle = pinRot;

    let distFromSolve = Math.abs(pinRot - solveDeg) - solvePadding;
    distFromSolve = clamp(distFromSolve, 0, maxDistFromSolve);

    let cylRotationAllowance = convertRanges(distFromSolve, 0, maxDistFromSolve, maxRot, maxRot * 0.02);

    function updateCylinderRotation() {
        if (!userPushingCyl || cylRot >= maxRot || gameOver) {
            cancelAnimationFrame(cylRotationInterval);
            if (cylRot >= maxRot) {
                unlock();
            }
            return;
        }

        cylRot += cylRotSpeed;
        cylRot = Math.min(cylRot, cylRotationAllowance);

        if (cylRot >= cylRotationAllowance) {
            damagePin();
        }

        cyl.style.transform = `translate(-50%, -50%) rotateZ(${cylRot}deg)`;
        driver.style.transform = `rotateZ(${cylRot}deg)`;

        cylRotationInterval = requestAnimationFrame(updateCylinderRotation);
    }

    cylRotationInterval = requestAnimationFrame(updateCylinderRotation);
};

const unpushCyl = () => {
    userPushingCyl = false;
    cancelAnimationFrame(cylRotationInterval);

    function updateCylinderRotationBackward() {
        if (cylRot <= 0 || gameOver) {
            cylRot = 0;
            cancelAnimationFrame(cylRotationInterval);
            return;
        }

        cylRot -= cylRotSpeed;
        cylRot = Math.max(cylRot, 0);

        cyl.style.transform = `translate(-50%, -50%) rotateZ(${cylRot}deg)`;
        driver.style.transform = `rotateZ(${cylRot}deg)`;

        cylRotationInterval = requestAnimationFrame(updateCylinderRotationBackward);
    }

    cylRotationInterval = requestAnimationFrame(updateCylinderRotationBackward);
};

const damagePin = () => {
    if (!pinLastDamaged || Date.now() - pinLastDamaged > pinDamageInterval) {
        pinHealth -= pinDamage;
        pinLastDamaged = Date.now();

        const keyframes = [{ transform: `rotateZ(${pinRot}deg)` }, { transform: `rotateZ(${pinRot - 2}deg)` }, { transform: `rotateZ(${pinRot}deg)` }];

        const options = {
            duration: pinDamageInterval / 2,
            easing: "ease-out",
        };

        pin.animate(keyframes, options);

        if (pinHealth <= 0) {
            breakPin();
        }
    }
};

const reset = () => {
    cylRot = 0;
    pinHealth = 100;
    pinRot = 0;

    pin.style.transform = `rotateZ(${pinRot}deg)`;
    cyl.style.transform = `translate(-50%, -50%) rotateZ(${cylRot}deg)`;
    driver.style.transform = `rotateZ(${cylRot}deg)`;

    const pinTop = pin.querySelector(".top");
    const pinBott = pin.querySelector(".bott");

    [pinTop, pinBott].forEach((el) => {
        if (el) {
            el.style.transform = "rotateZ(0deg) translateX(0) translateY(0)";
            el.style.opacity = "1";
        }
    });

    if (cylRotationInterval) {
        cancelAnimationFrame(cylRotationInterval);
        cylRotationInterval = null;
    }
};

const outOfPins = () => {
    const answer = { success: false, ms: Date.now() - startedAt, broken: pinsBroken };
    closeLockpick();
    fetch(`https://${GetParentResourceName()}/lockpickFinish`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(answer),
    });
};

const breakPin = () => {
    gamePaused = true;
    cancelAnimationFrame(cylRotationInterval);

    numPins--;
    pinsBroken++;

    const pinTop = pin.querySelector(".top");
    const pinBott = pin.querySelector(".bott");

    const animateOptions = {
        duration: 700,
    };

    pinTop.animate(
        [
            { transform: "rotateZ(0deg) translateX(0) translateY(0)", opacity: 1 },
            { transform: "rotateZ(-400deg) translateX(-200px) translateY(-100px)", opacity: 0 },
        ],
        animateOptions
    );

    const bottomAnimation = pinBott.animate(
        [
            { transform: "rotateZ(0deg) translateX(0) translateY(0)", opacity: 1 },
            { transform: "rotateZ(400deg) translateX(200px) translateY(100px)", opacity: 0 },
        ],
        animateOptions
    );

    bottomAnimation.onfinish = () => {
        if (numPins > 0) {
            gamePaused = false;
            reset();
        } else {
            outOfPins();
        }
    };
};

document.addEventListener("mousemove", (e) => {
    if (!gameOver && !gamePaused) {
        let pinRotChange = (e.clientX - lastMousePos) / mouseSmoothing;
        pinRot += pinRotChange;
        pinRot = clamp(pinRot, minRot, maxRot);
        pin.style.transform = `rotateZ(${pinRot}deg)`;
    }
    lastMousePos = e.clientX;
});

document.addEventListener("mouseleave", () => (lastMousePos = 0));

const keyActionMap = {
    w: pushCyl,
    a: pushCyl,
    s: pushCyl,
    d: pushCyl,
    escape: () => {
        const broken = pinsBroken;
        closeLockpick();
        fetch(`https://${GetParentResourceName()}/lockpickExit`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ broken: broken }),
        }).catch(console.error);
    },
};

document.addEventListener("keydown", (e) => {
    let action = keyActionMap[e.key.toLowerCase()];
    if (action && !userPushingCyl && !gameOver && !gamePaused) {
        action();
    }
});

document.addEventListener("keyup", (e) => {
    let action = keyActionMap[e.key.toLowerCase()];
    if (action && !gameOver) {
        unpushCyl();
    }
});

window.addEventListener("message", (event) => {
    const eventData = event.data;
    if (eventData.action === "startLockpick") {
        lockpickContainer.style.display = "block";
        numPins = eventData.pins;
        // a server challenge fixes the angle (closeLockpick picks a random one for the next game)
        const challenge = eventData.challenge;
        if (challenge && typeof challenge.solve === "number") {
            solveDeg = challenge.solve;
            numPins = Number(challenge.pins) || numPins;
        }
        pinsBroken = 0;
        pushAngle = 0;
        startedAt = Date.now();
        gameOver = false;
        gamePaused = false;
        reset();
    }
});
