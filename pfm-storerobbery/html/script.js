// Store robbery NUI: the keypad of keypad safes. The guess goes to the client script, which has the
// server check it (the code never reaches the client). Register lockpicks and padlock dials are
// pfm-minigames challenges the server judges, so they have no UI here.
var Keypad = {};
var MAX_DIGITS = 4;

function post(name, data) {
    return fetch("https://" + GetParentResourceName() + "/" + name, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data || {}),
    }).catch(function () {});
}

function pinBox() {
    return document.getElementById("PINbox");
}

function addKeyPadNumber(digit) {
    var box = pinBox();
    if (box && box.value.length < MAX_DIGITS) box.value += digit;
}

function clearForm() {
    var box = pinBox();
    if (box) box.value = "";
}

function submitForm() {
    var box = pinBox();
    var guess = box ? box.value : "";
    document.getElementById("keypad").style.display = "none";
    post("TryCombination", { combination: guess });
}

// Builds the keypad with DOM calls (no HTML strings).
function buildKeypad(root) {
    root.textContent = "";
    var form = document.createElement("form");
    form.id = "PINform";
    form.setAttribute("autocomplete", "off");
    form.addEventListener("submit", function (e) { e.preventDefault(); });
    var box = document.createElement("input");
    box.id = "PINbox";
    box.type = "password";
    box.disabled = true;
    form.appendChild(box);
    var rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["clear", "0", "enter"]];
    rows.forEach(function (row) {
        form.appendChild(document.createElement("br"));
        row.forEach(function (label) {
            var btn = document.createElement("input");
            btn.type = "button";
            btn.value = label;
            btn.className = "PINbutton" + (label === "clear" ? " clear" : label === "enter" ? " enter" : "");
            btn.addEventListener("click", function () {
                if (label === "clear") clearForm();
                else if (label === "enter") submitForm();
                else addKeyPadNumber(label);
            });
            form.appendChild(btn);
        });
    });
    root.appendChild(form);
}

Keypad.Open = function () {
    var root = document.getElementById("keypad");
    buildKeypad(root);
    root.style.display = "block";
};

Keypad.Close = function (data) {
    document.getElementById("keypad").style.display = "none";
    post("PadLockClose");
    if (data && data.error) post("CombinationFail");
};

window.addEventListener("message", function (event) {
    var data = event.data || {};
    if (data.action === "openKeypad") Keypad.Open(data);
    if (data.action === "closeKeypad") Keypad.Close(data);
});

document.addEventListener("keyup", function (e) {
    if (e.key === "Escape" && document.getElementById("keypad").style.display === "block") Keypad.Close();
});
