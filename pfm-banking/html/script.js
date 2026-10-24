/* inline brand marks (parody banks — simple geometric logos) */
const BRAND_LOGOS = {
    fleeca: `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="2" width="44" height="44" rx="12" fill="#0e3b25"/><path d="M33.5 10c-8.8.6-15.8 4.5-18.9 11.3-2.4 5.2-2 11.2.8 16.7l3.5-1.9c-2.2-4.4-2.5-9-.7-12.9 2.4-5.2 7.9-8.4 15.3-9.1-.4 6.4-2.5 11.4-6.1 14.4-2 1.7-4.4 2.7-7.1 3l.5 3.9c3.5-.4 6.6-1.7 9.2-3.9 4.9-4.1 7.5-10.9 7.7-19.5l.1-2.2-2.2.1-2.1.1z" fill="#2fbf71"/></svg>`,
    maze: `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="2" width="44" height="44" rx="8" fill="#b4232a"/><path d="M10 38V15h7.5l6.5 9 6.5-9H38v23h-7V25.5L24 34l-7-8.5V38z" fill="#ffffff"/></svg>`,
    pacific: `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg"><circle cx="24" cy="24" r="22" fill="#12284c"/><circle cx="24" cy="24" r="21" fill="none" stroke="#d8b45a" stroke-width="2"/><path d="M24 10l3.4 8.2 8.9.7-6.8 5.8 2.1 8.7L24 28.7l-7.6 4.7 2.1-8.7-6.8-5.8 8.9-.7z" fill="#d8b45a"/></svg>`,
    blaine: `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg"><path d="M24 2l18 7v13c0 11-7.5 19.5-18 24C13.5 41.5 6 33 6 22V9z" fill="#4c3812"/><path d="M24 5l15 5.8V22c0 9.3-6.3 16.6-15 20.7C15.3 38.6 9 31.3 9 22V10.8z" fill="#d8a33c"/><path d="M13 29l7-10 4 5 4.5-7L35 29z" fill="#4c3812"/></svg>`,
    pf: `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg"><path d="M24 2l19 11v22L24 46 5 35V13z" fill="#15253f"/><path d="M26.5 10L15 27h7l-2.5 11L33 21h-7.5z" fill="#5b9dff"/></svg>`,
};
const CARD_BRAND = { fleeca_green: "fleeca", maze_platinum: "maze", pacific_black: "pacific" };

/* debit card color variants (design → gradient) */
const CARD_DESIGNS = {
    classic: ["#15253f", "#5b9dff"],
    midnight: ["#0a0a0e", "#2c2c38"],
    gold: ["#4c3812", "#d8a33c"],
    ruby: ["#5c1010", "#e03a3a"],
    ocean: ["#0f3a42", "#2fb3bf"],
};

const bankingApp = Vue.createApp({
    data() {
        return {
            isBankOpen: false,
            isATMOpen: false,
            showPinPrompt: false,
            notification: null,
            view: "dashboard",
            viewTitles: {
                dashboard: "Dashboard",
                transactions: "Transactions",
                transfer: "Move money",
                loans: "Loans & credit",
                cards: "Cards",
                options: "Account options",
            },
            brand: "pf",
            brandStyle: { label: "PF Credit Union", short: "PFCU", accent: "#5b9dff", gradient: ["#15253f", "#5b9dff"] },
            accounts: [],
            statements: {},
            selectedAccountStatement: "checking",
            playerName: "",
            accountNumber: "",
            playerCash: 0,
            // finance
            finance: { score: 650, scoreMin: 300, scoreMax: 850, loans: [], cards: [], tiers: [], cardProducts: [], maxActiveLoans: 2, advanceFeePct: 0.02 },
            loanAmounts: {},
            cardAmounts: {},
            // money
            selectedMoneyAccount: null,
            selectedMoneyAmount: 0,
            moneyReason: "",
            // transfer
            transferType: "internal",
            internalFromAccount: null,
            internalToAccount: null,
            externalAccountNumber: "",
            externalFromAccount: null,
            transferAmount: 0,
            transferReason: "",
            // cards / options
            debitPin: "",
            enteredPin: "",
            acceptablePins: [],
            tempBankData: null,
            createAccountName: "",
            createAccountAmount: 0,
            editAccount: null,
            editAccountName: "",
            manageAccountName: null,
            manageUserName: "",
            // multi-account banking
            accountsData: { personal: { balance: 0, iban: "", transactions: [] }, accounts: [], myCards: [], myName: "", myCitizenid: "" },
            selectedAccRef: "personal",
            hideBalances: false,
            showCreateAccount: false,
            newAccountLabel: "",
            newAccountType: "shared",
            acctAmount: null,
            acctTransferIban: "",
            acctTransferAmount: null,
            acctTransferNote: "",
            memberCitizenId: "",
            acctRenameLabel: "",
            acctColorValue: "#5b9dff",
            accentSwatches: ["#5b9dff", "#2fbf71", "#d8a33c", "#e03a3a", "#a86bff", "#2fb3bf", "#ff7ab0", "#9fa6b8"],
            cardDesigns: CARD_DESIGNS,
            newCardTarget: "personal",
            newCardDesign: "classic",
            cardIdx: 0,
            cardRevealed: false,
            // dashboard
            dashAmount: null,
            fastIban: "",
            fastAmount: null,
        };
    },
    computed: {
        currentStatements() {
            return this.statements[this.selectedAccountStatement] || [];
        },
        checkingBalance() {
            const checking = this.accounts.find((a) => a.name === "checking");
            return checking ? checking.balance : 0;
        },
        sharedAccounts() {
            return this.accounts.filter((a) => a.type === "shared");
        },
        totalDebt() {
            const loans = this.finance.loans.reduce((sum, l) => sum + l.balance, 0);
            const cards = this.finance.cards.reduce((sum, c) => sum + c.balance, 0);
            return loans + cards;
        },
        scorePct() {
            const { score, scoreMin, scoreMax } = this.finance;
            return Math.round(((score - scoreMin) / (scoreMax - scoreMin)) * 100);
        },
        scoreColor() {
            const s = this.finance.score;
            if (s >= 740) return "#34d17b";
            if (s >= 660) return "#9bd34c";
            if (s >= 580) return "#ffb547";
            return "#ff5d5d";
        },
        scoreLabel() {
            const s = this.finance.score;
            if (s >= 790) return "Excellent";
            if (s >= 740) return "Very good";
            if (s >= 660) return "Good";
            if (s >= 580) return "Fair";
            return "Poor";
        },
        brandGradient() {
            const g = this.brandStyle.gradient || ["#15253f", "#5b9dff"];
            return { background: `linear-gradient(120deg, ${g[0]}, ${g[1]})` };
        },
        availableCardProducts() {
            const owned = new Set(this.finance.cards.map((c) => c.card_id));
            return this.finance.cardProducts.filter((p) => !owned.has(p.id));
        },
        brandLogo() {
            return BRAND_LOGOS[this.brand] || BRAND_LOGOS.pf;
        },
        /* ── multi-account banking ──────────────── */
        selectedAccount() {
            if (this.selectedAccRef === "personal") return null;
            return this.accountsData.accounts.find((a) => a.id === this.selectedAccRef) || null;
        },
        selectedAccLabel() {
            return this.selectedAccount ? this.selectedAccount.label : "Personal";
        },
        selectedTransactions() {
            if (this.selectedAccount) return this.selectedAccount.transactions || [];
            return this.accountsData.personal.transactions || [];
        },
        cardEligibleAccounts() {
            return this.accountsData.accounts.filter((a) => a.isOwner || (a.myPerms && a.myPerms.can_cards == 1));
        },
        allWalletCards() {
            const out = [];
            (this.accountsData.myCards || []).forEach((card) => out.push({ card, accountLabel: "Personal" }));
            (this.accountsData.accounts || []).forEach((acc) => {
                (acc.cards || []).forEach((card) => out.push({ card, accountLabel: acc.label }));
            });
            return out.filter((e) => e.card.cancelled != 1);
        },
        currentWalletCard() {
            const cards = this.allWalletCards;
            if (!cards.length) return null;
            return cards[Math.min(this.cardIdx, cards.length - 1)];
        },
        personalCard() {
            const cards = this.accountsData.myCards || [];
            return cards.length ? cards[0] : null;
        },
        /* ── dashboard analytics ─────────────────── */
        dashAllTx() {
            const legacy = (this.statements["checking"] || []).map((s) => ({
                id: "s" + s.id,
                note: s.reason,
                actor_name: s.user,
                amount: Number(s.amount) || 0,
                type: s.type === "deposit" ? "deposit" : "withdraw",
                created_at: Number(s.date) || 0,
            }));
            const mine = (this.accountsData.personal.transactions || []).map((t) => ({ ...t, amount: Number(t.amount) || 0, created_at: Number(t.created_at) || 0 }));
            return mine.concat(legacy).sort((a, b) => b.created_at - a.created_at);
        },
        dashTransactions() {
            return this.dashAllTx.slice(0, 10);
        },
        stats7d() {
            const cutoff = Date.now() - 7 * 86400000;
            const out = { income: 0, expenses: 0, transfers: 0 };
            this.dashAllTx.forEach((t) => {
                if (t.created_at < cutoff) return;
                if (t.type === "deposit" || t.type === "transfer_in") out.income += t.amount;
                else out.expenses += t.amount;
                if (t.type === "transfer_in" || t.type === "transfer_out") out.transfers += t.amount;
            });
            return out;
        },
        weekdayBars() {
            const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
            const days = [];
            const today = new Date();
            today.setHours(0, 0, 0, 0);
            for (let i = 6; i >= 0; i--) {
                const start = today.getTime() - i * 86400000;
                days.push({ key: start, label: names[new Date(start).getDay()], start, end: start + 86400000, income: 0, expense: 0 });
            }
            this.dashAllTx.forEach((t) => {
                const day = days.find((d) => t.created_at >= d.start && t.created_at < d.end);
                if (!day) return;
                if (t.type === "deposit" || t.type === "transfer_in") day.income += t.amount;
                else day.expense += t.amount;
            });
            const max = Math.max(1, ...days.map((d) => Math.max(d.income, d.expense)));
            days.forEach((d) => {
                d.incomePct = Math.max(d.income > 0 ? 4 : 2, Math.round((d.income / max) * 100));
                d.expensePct = Math.max(d.expense > 0 ? 4 : 2, Math.round((d.expense / max) * 100));
            });
            return days;
        },
    },
    methods: {
        /* ── helpers ─────────────────────────────── */
        post(endpoint, data) {
            return axios.post(`https://pfm-banking/${endpoint}`, data || {});
        },
        formatCurrency(amount) {
            return new Intl.NumberFormat().format(Math.round(amount || 0));
        },
        formatDate(timestamp) {
            const date = new Date(isNaN(timestamp) ? timestamp : parseInt(timestamp));
            if (isNaN(date.getTime())) return "";
            return `${(date.getMonth() + 1).toString().padStart(2, "0")}/${date.getDate().toString().padStart(2, "0")}/${date.getFullYear()}`;
        },
        formatDateTime(timestamp) {
            const date = new Date(isNaN(timestamp) ? timestamp : parseInt(timestamp));
            if (isNaN(date.getTime())) return "";
            return `${this.formatDate(timestamp)} ${date.getHours().toString().padStart(2, "0")}:${date.getMinutes().toString().padStart(2, "0")}`;
        },
        addNotification(message, type) {
            this.notification = { message, type };
            clearTimeout(this._noteTimer);
            this._noteTimer = setTimeout(() => (this.notification = null), 3500);
        },
        addStatement(accountNumber, accountName, reason, amount, type) {
            if (!this.statements[accountName]) this.statements[accountName] = [];
            this.statements[accountName].unshift({ id: Date.now() + Math.random(), date: Date.now(), user: accountNumber, reason: reason || type, amount, type });
        },
        selectAccount(account) {
            this.selectedAccountStatement = account.name;
        },
        applyBrandAccent() {
            const r = document.documentElement.style;
            r.setProperty("--bk-accent", this.brandStyle.accent || "#5b9dff");
        },
        refreshFinance() {
            this.post("getFinance").then((res) => {
                if (res.data) this.finance = { ...this.finance, ...res.data };
            });
        },
        loanProgress(loan) {
            const total = loan.principal * (1 + loan.apr / 100);
            return Math.max(2, Math.min(100, Math.round(((total - loan.balance) / total) * 100)));
        },
        estimatePayment(tier, amount) {
            if (!amount) return 0;
            return Math.ceil((amount * (1 + tier.apr / 100)) / tier.payments);
        },
        cardLabel(card) {
            const p = this.finance.cardProducts.find((x) => x.id === card.card_id);
            return p ? p.label : card.card_id;
        },
        cardGradient(card) {
            const p = this.finance.cardProducts.find((x) => x.id === card.card_id);
            const g = (p && p.gradient) || ["#15253f", "#5b9dff"];
            return { background: `linear-gradient(120deg, ${g[0]}, ${g[1]})` };
        },
        cardLogo(cardId) {
            return BRAND_LOGOS[CARD_BRAND[cardId]] || BRAND_LOGOS.pf;
        },

        /* ── multi-account banking ───────────────── */
        applyAccountsData(data) {
            if (!data) return;
            this.accountsData = { ...this.accountsData, ...data };
            if (this.selectedAccRef !== "personal" && !this.accountsData.accounts.some((a) => a.id === this.selectedAccRef)) {
                this.selectedAccRef = "personal";
            }
            // keep the legacy checking row in sync with the personal balance
            const checking = this.accounts.find((a) => a.name === "checking");
            if (checking && this.accountsData.personal) checking.balance = this.accountsData.personal.balance;
            if (this.cardIdx >= this.allWalletCards.length) this.cardIdx = 0;
        },
        refreshAccounts() {
            this.post("getAccountsData").then((res) => this.applyAccountsData(res.data));
        },
        selectAccRef(ref) {
            this.selectedAccRef = ref;
            this.acctRenameLabel = "";
            this.memberCitizenId = "";
            const acc = ref === "personal" ? null : this.accountsData.accounts.find((a) => a.id === ref);
            if (acc && acc.color) this.acctColorValue = acc.color;
        },
        acctAccent(acc) {
            const color = acc ? acc.color || "var(--bk-accent)" : "var(--bk-accent)";
            return { "--acct-accent": color };
        },
        canDo(permKey) {
            const acc = this.selectedAccount;
            if (!acc) return false;
            return acc.isOwner || (acc.myPerms && acc.myPerms[permKey] == 1);
        },
        maskIban(iban) {
            if (!iban) return "••••";
            return iban.slice(0, 2) + "•••• " + iban.slice(-4);
        },
        copyText(text) {
            if (!text) return;
            try {
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text);
                } else {
                    const el = document.createElement("textarea");
                    el.value = text;
                    document.body.appendChild(el);
                    el.select();
                    document.execCommand("copy");
                    document.body.removeChild(el);
                }
                this.addNotification("Copied to clipboard", "success");
            } catch (e) {
                this.addNotification("Could not copy", "error");
            }
        },
        txClass(type) {
            return type === "deposit" || type === "transfer_in" ? "deposit" : "withdraw";
        },
        txIcon(type) {
            if (type === "deposit") return "south_west";
            if (type === "withdraw") return "north_east";
            if (type === "transfer_in") return "call_received";
            if (type === "transfer_out") return "call_made";
            return "receipt";
        },
        txSign(type) {
            return type === "deposit" || type === "transfer_in" ? "+" : "-";
        },
        txTitle(type) {
            return { deposit: "Deposit", withdraw: "Withdrawal", transfer_in: "Incoming transfer", transfer_out: "Outgoing transfer", fee: "Fee" }[type] || type;
        },
        createNewAccount() {
            const label = (this.newAccountLabel || "").trim();
            if (!label) return this.addNotification("Enter an account name first", "error");
            this.post("createAccount", { label, type: this.newAccountType }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.newAccountLabel = "";
                    this.showCreateAccount = false;
                    if (res.data.accountId) this.selectedAccRef = res.data.accountId;
                    this.refreshAccounts();
                }
            });
        },
        doAcctDeposit() {
            const acc = this.selectedAccount;
            const amount = Number(this.acctAmount);
            if (!acc || !(amount > 0)) return this.addNotification("Enter an amount first", "error");
            this.post("accountDeposit", { accountId: acc.id, amount }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.acctAmount = null;
                    this.refreshAccounts();
                }
            });
        },
        doAcctWithdraw() {
            const acc = this.selectedAccount;
            const amount = Number(this.acctAmount);
            if (!acc || !(amount > 0)) return this.addNotification("Enter an amount first", "error");
            this.post("accountWithdraw", { accountId: acc.id, amount }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.acctAmount = null;
                    this.refreshAccounts();
                }
            });
        },
        doAcctTransfer() {
            const amount = Number(this.acctTransferAmount);
            const toIban = (this.acctTransferIban || "").trim();
            if (!toIban) return this.addNotification("Enter a destination IBAN", "error");
            if (!(amount > 0)) return this.addNotification("Enter an amount first", "error");
            const fromRef = this.selectedAccount ? this.selectedAccount.id : "personal";
            this.post("accountTransfer", { fromRef, toIban, amount, note: this.acctTransferNote }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.acctTransferAmount = null;
                    this.acctTransferIban = "";
                    this.acctTransferNote = "";
                    this.refreshAccounts();
                }
            });
        },
        togglePerm(member, key) {
            const newVal = member[key] == 1 ? 0 : 1;
            member[key] = newVal;
            const acc = this.selectedAccount;
            if (!acc) return;
            this.post("updateMember", {
                accountId: acc.id,
                citizenid: member.citizenid,
                perms: {
                    can_withdraw: member.can_withdraw == 1,
                    can_deposit: member.can_deposit == 1,
                    can_cards: member.can_cards == 1,
                    can_manage: member.can_manage == 1,
                },
            }).then((res) => {
                if (!res.data.success) {
                    member[key] = newVal == 1 ? 0 : 1; // revert
                    this.addNotification(res.data.message, "error");
                }
            });
        },
        addMemberRow() {
            const acc = this.selectedAccount;
            const cid = (this.memberCitizenId || "").trim();
            if (!acc || !cid) return this.addNotification("Enter a citizen ID first", "error");
            this.post("addMember", { accountId: acc.id, citizenid: cid, perms: { can_deposit: true } }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.memberCitizenId = "";
                    this.refreshAccounts();
                }
            });
        },
        removeMemberRow(member) {
            const acc = this.selectedAccount;
            if (!acc) return;
            this.post("removeMember", { accountId: acc.id, citizenid: member.citizenid }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) this.refreshAccounts();
            });
        },
        renameSelected() {
            const acc = this.selectedAccount;
            const label = (this.acctRenameLabel || "").trim();
            if (!acc || !label) return this.addNotification("Enter a new name first", "error");
            this.post("accountRename", { accountId: acc.id, label }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.acctRenameLabel = "";
                    this.refreshAccounts();
                }
            });
        },
        colorSelected() {
            const acc = this.selectedAccount;
            if (!acc) return;
            this.post("accountColor", { accountId: acc.id, color: this.acctColorValue }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) this.refreshAccounts();
            });
        },
        deleteSelected() {
            const acc = this.selectedAccount;
            if (!acc) return;
            this.post("accountDelete", { accountId: acc.id }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    this.selectedAccRef = "personal";
                    this.refreshAccounts();
                }
            });
        },
        /* ── wallet cards ────────────────────────── */
        formatCardNumber(number) {
            return (number || "").replace(/(.{4})/g, "$1 ").trim();
        },
        maskCardNumber(number) {
            return "•••• •••• •••• " + (number || "").slice(-4);
        },
        cardDesignStyle(design) {
            const g = CARD_DESIGNS[design] || CARD_DESIGNS.classic;
            return { background: `linear-gradient(120deg, ${g[0]}, ${g[1]})` };
        },
        stepCard(dir) {
            const len = this.allWalletCards.length;
            if (len < 2) return;
            this.cardIdx = (Math.min(this.cardIdx, len - 1) + dir + len) % len;
            this.cardRevealed = false;
        },
        relativeDate(timestamp) {
            const ts = Number(timestamp) || 0;
            const diff = Date.now() - ts;
            if (diff < 60000) return "Just now";
            if (diff < 3600000) return Math.floor(diff / 60000) + "m ago";
            if (diff < 86400000) return Math.floor(diff / 3600000) + "h ago";
            if (diff < 172800000) return "Yesterday";
            if (diff < 7 * 86400000) return Math.floor(diff / 86400000) + "d ago";
            return this.formatDate(ts);
        },
        dashMoney(kind) {
            const amount = Number(this.dashAmount);
            if (!(amount > 0)) return this.addNotification("Enter an amount first", "error");
            this.post(kind, { accountName: "checking", amount, reason: "" }).then((response) => {
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance += kind === "deposit" ? amount : -amount;
                    this.accountsData.personal.balance += kind === "deposit" ? amount : -amount;
                    this.playerCash += kind === "deposit" ? -amount : amount;
                    this.addStatement(this.accountNumber, "checking", "", amount, kind);
                    this.dashAmount = null;
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        fastTransfer() {
            const amount = Number(this.fastAmount);
            const toIban = (this.fastIban || "").trim();
            if (!toIban) return this.addNotification("Enter a destination IBAN", "error");
            if (!(amount > 0)) return this.addNotification("Enter an amount first", "error");
            this.post("accountTransfer", { fromRef: "personal", toIban, amount, note: "Fast transfer" }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance -= amount;
                    this.fastAmount = null;
                    this.fastIban = "";
                    this.refreshAccounts();
                }
            });
        },
        createNewCard() {
            this.post("createCard", { accountRef: this.newCardTarget, design: this.newCardDesign }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) this.refreshAccounts();
            });
        },
        toggleLockCard(card) {
            this.post("toggleCardLock", { cardId: card.id }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) card.locked = res.data.locked;
            });
        },
        cancelWalletCard(card) {
            this.post("cancelCard", { cardId: card.id }).then((res) => {
                this.addNotification(res.data.message, res.data.success ? "success" : "error");
                if (res.data.success) this.refreshAccounts();
            });
        },

        /* ── open / close ────────────────────────── */
        openBank(bankData) {
            const playerData = bankData.playerData;
            this.playerName = playerData.charinfo.firstname + " " + playerData.charinfo.lastname;
            this.accountNumber = playerData.citizenid;
            this.playerCash = playerData.money.cash;
            if (bankData.brand) this.brand = bankData.brand;
            if (bankData.brandStyle) this.brandStyle = bankData.brandStyle;
            if (bankData.finance) this.finance = { ...this.finance, ...bankData.finance };
            if (bankData.accountsData) this.applyAccountsData(bankData.accountsData);
            this.applyBrandAccent();
            this.accounts = [];
            bankData.accounts.forEach((account) => {
                this.accounts.push({
                    name: account.account_name,
                    type: account.account_type,
                    balance: account.account_balance,
                    users: account.users,
                    id: account.id,
                });
            });
            this.statements = {};
            Object.keys(bankData.statements || {}).forEach((key) => {
                this.statements[key] = bankData.statements[key]
                    .map((s) => ({ id: s.id, date: s.date, reason: s.reason, amount: s.amount, type: s.statement_type, user: s.citizenid }))
                    .sort((a, b) => b.date - a.date);
            });
            this.view = "dashboard";
            this.selectedAccountStatement = "checking";
            this.isBankOpen = true;
        },
        openATM(bankData) {
            const playerData = bankData.playerData;
            this.playerName = playerData.charinfo.firstname + " " + playerData.charinfo.lastname;
            this.accountNumber = playerData.citizenid;
            this.playerCash = playerData.money.cash;
            this.accounts = [];
            bankData.accounts.forEach((account) => {
                this.accounts.push({ name: account.account_name, type: account.account_type, balance: account.account_balance, users: account.users, id: account.id });
            });
            this.isATMOpen = true;
        },
        pinPrompt(enteredPin) {
            const bankData = this.tempBankData;
            this.acceptablePins = Array.from(bankData.pinNumbers || []);
            if (this.acceptablePins.includes(parseInt(enteredPin))) {
                this.showPinPrompt = false;
                this.enteredPin = "";
                this.openATM(bankData);
            } else {
                this.enteredPin = "";
            }
        },
        appendNumber(number) {
            if (this.enteredPin.length < 8) this.enteredPin += number.toString();
        },
        closeApplication() {
            this.isBankOpen = false;
            this.isATMOpen = false;
            this.showPinPrompt = false;
            this.enteredPin = "";
            this.post("closeApp");
        },

        /* ── money ───────────────────────────────── */
        withdrawMoney() {
            if (!this.selectedMoneyAccount || this.selectedMoneyAmount <= 0) return;
            const amount = Number(this.selectedMoneyAmount);
            this.post("withdraw", { accountName: this.selectedMoneyAccount.name, amount, reason: this.moneyReason }).then((response) => {
                if (response.data.success) {
                    const account = this.accounts.find((a) => a.name === this.selectedMoneyAccount.name);
                    if (account) {
                        account.balance -= amount;
                        this.playerCash += amount;
                        this.addStatement(this.accountNumber, this.selectedMoneyAccount.name, this.moneyReason, amount, "withdraw");
                    }
                    this.selectedMoneyAmount = 0;
                    this.moneyReason = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        depositMoney() {
            if (!this.selectedMoneyAccount || this.selectedMoneyAmount <= 0) return;
            const amount = Number(this.selectedMoneyAmount);
            this.post("deposit", { accountName: this.selectedMoneyAccount.name, amount, reason: this.moneyReason }).then((response) => {
                if (response.data.success) {
                    const account = this.accounts.find((a) => a.name === this.selectedMoneyAccount.name);
                    if (account) {
                        account.balance += amount;
                        this.playerCash -= amount;
                        this.addStatement(this.accountNumber, this.selectedMoneyAccount.name, this.moneyReason, amount, "deposit");
                    }
                    this.selectedMoneyAmount = 0;
                    this.moneyReason = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        internalTransfer() {
            if (!this.internalFromAccount || !this.internalToAccount || this.transferAmount <= 0) return;
            const amount = Number(this.transferAmount);
            this.post("internalTransfer", { fromAccountName: this.internalFromAccount.name, toAccountName: this.internalToAccount.name, amount, reason: this.transferReason }).then((response) => {
                if (response.data.success) {
                    const fromAccount = this.accounts.find((a) => a.name === this.internalFromAccount.name);
                    if (fromAccount) fromAccount.balance -= amount;
                    const toAccount = this.accounts.find((a) => a.name === this.internalToAccount.name);
                    if (toAccount) toAccount.balance += amount;
                    this.addStatement(this.accountNumber, this.internalFromAccount.name, this.transferReason, amount, "withdraw");
                    this.addStatement(this.accountNumber, this.internalToAccount.name, this.transferReason, amount, "deposit");
                    this.transferAmount = 0;
                    this.transferReason = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        externalTransfer() {
            if (!this.externalFromAccount || !this.externalAccountNumber || this.transferAmount <= 0) return;
            const amount = Number(this.transferAmount);
            this.post("externalTransfer", { fromAccountName: this.externalFromAccount.name, toAccountNumber: this.externalAccountNumber, amount, reason: this.transferReason }).then((response) => {
                if (response.data.success) {
                    const fromAccount = this.accounts.find((a) => a.name === this.externalFromAccount.name);
                    if (fromAccount) fromAccount.balance -= amount;
                    this.addStatement(this.accountNumber, this.externalFromAccount.name, this.transferReason, amount, "withdraw");
                    this.transferAmount = 0;
                    this.transferReason = "";
                    this.externalAccountNumber = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },

        /* ── loans ───────────────────────────────── */
        applyLoan(tierIndex, amount) {
            if (!amount || amount <= 0) return this.addNotification("Enter a loan amount first", "error");
            this.post("applyLoan", { tierIndex, amount }).then((response) => {
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance += Number(amount);
                    this.loanAmounts = {};
                    this.refreshFinance();
                }
            });
        },
        payLoan(loan) {
            this.post("payLoan", { loanId: loan.id }).then((response) => {
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance -= Math.min(loan.payment_amount, loan.balance);
                    this.refreshFinance();
                }
            });
        },
        payoffLoan(loan) {
            this.post("payoffLoan", { loanId: loan.id }).then((response) => {
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance -= loan.balance;
                    this.refreshFinance();
                }
            });
        },

        /* ── cards ───────────────────────────────── */
        orderCreditCard(product) {
            this.post("orderCreditCard", { cardId: product.id }).then((response) => {
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
                if (response.data.success) this.refreshFinance();
            });
        },
        cardAdvance(card) {
            const amount = Number(this.cardAmounts[card.id] || 0);
            if (amount <= 0) return this.addNotification("Enter an amount first", "error");
            this.post("cardAdvance", { cardId: card.id, amount }).then((response) => {
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance += amount;
                    this.cardAmounts[card.id] = null;
                    this.refreshFinance();
                }
            });
        },
        payCard(card) {
            const amount = Number(this.cardAmounts[card.id] || 0);
            if (amount <= 0) return this.addNotification("Enter an amount first", "error");
            this.post("payCard", { cardId: card.id, amount }).then((response) => {
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance -= Math.min(amount, card.balance);
                    this.cardAmounts[card.id] = null;
                    this.refreshFinance();
                }
            });
        },
        orderDebitCard() {
            if (!this.debitPin) return;
            this.post("orderCard", { pin: this.debitPin }).then((response) => {
                if (response.data.success) this.debitPin = "";
                this.addNotification(response.data.message, response.data.success ? "success" : "error");
            });
        },

        /* ── account options ─────────────────────── */
        openAccount() {
            if (!this.createAccountName || this.createAccountAmount < 0) return;
            const amount = Number(this.createAccountAmount);
            this.post("openAccount", { accountName: this.createAccountName, amount }).then((response) => {
                if (response.data.success) {
                    const checking = this.accounts.find((a) => a.name === "checking");
                    if (checking) checking.balance -= amount;
                    this.accounts.push({ name: this.createAccountName, type: "shared", balance: amount, users: JSON.stringify([this.accountNumber]) });
                    this.createAccountName = "";
                    this.createAccountAmount = 0;
                    this.addNotification(response.data.message, "success");
                } else {
                    this.createAccountName = "";
                    this.createAccountAmount = 0;
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        renameAccount() {
            if (!this.editAccount || !this.editAccountName) return;
            this.post("renameAccount", { oldName: this.editAccount.name, newName: this.editAccountName }).then((response) => {
                if (response.data.success) {
                    const account = this.accounts.find((a) => a.name === this.editAccount.name);
                    if (account) account.name = this.editAccountName;
                    this.editAccount = null;
                    this.editAccountName = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        deleteAccount() {
            if (!this.editAccount) return;
            this.post("deleteAccount", { accountName: this.editAccount.name }).then((response) => {
                if (response.data.success) {
                    this.accounts = this.accounts.filter((a) => a.name !== this.editAccount.name);
                    this.editAccount = null;
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        addUserToAccount() {
            if (!this.manageAccountName || !this.manageUserName) return;
            this.post("addUser", { accountName: this.manageAccountName.name, userName: this.manageUserName }).then((response) => {
                if (response.data.success) {
                    try {
                        const users = JSON.parse(this.manageAccountName.users || "[]");
                        users.push(this.manageUserName);
                        this.manageAccountName.users = JSON.stringify(users);
                    } catch (e) {}
                    this.manageUserName = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },
        removeUserFromAccount() {
            if (!this.manageAccountName || !this.manageUserName) return;
            this.post("removeUser", { accountName: this.manageAccountName.name, userName: this.manageUserName }).then((response) => {
                if (response.data.success) {
                    try {
                        let users = JSON.parse(this.manageAccountName.users || "[]");
                        users = users.filter((u) => u !== this.manageUserName);
                        this.manageAccountName.users = JSON.stringify(users);
                    } catch (e) {}
                    this.manageUserName = "";
                    this.addNotification(response.data.message, "success");
                } else {
                    this.addNotification(response.data.message, "error");
                }
            });
        },

        /* ── message handling ────────────────────── */
        handleMessage(event) {
            const action = event.data.action;
            if (action === "openBank") {
                this.openBank(event.data);
            } else if (action === "openATM") {
                this.tempBankData = event.data;
                this.showPinPrompt = true;
            } else if (action === "theme" && event.data.theme) {
                const t = event.data.theme;
                const r = document.documentElement.style;
                const hexToRgba = (h, a) => {
                    const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h || "");
                    return m ? `rgba(${parseInt(m[1], 16)},${parseInt(m[2], 16)},${parseInt(m[3], 16)},${a})` : null;
                };
                const op = t.opacity ?? 0.94;
                if (t.primary) r.setProperty("--bk-bg", hexToRgba(t.primary, Math.min(1, op + 0.02)));
                if (t.secondary) { r.setProperty("--bk-bg-panel", hexToRgba(t.secondary, 0.65)); r.setProperty("--bk-bg-field", hexToRgba(t.secondary, 0.55)); }
                if (t.text) { r.setProperty("--bk-fg", t.text); r.setProperty("--bk-fg-dim", hexToRgba(t.text, 0.55)); }
                // the bank brand keeps its own accent
            }
        },
    },
    mounted() {
        window.addEventListener("message", this.handleMessage);
        document.addEventListener("keyup", (e) => {
            if (e.key === "Escape" && (this.isBankOpen || this.isATMOpen || this.showPinPrompt)) this.closeApplication();
        });
    },
});

bankingApp.mount("#app");
