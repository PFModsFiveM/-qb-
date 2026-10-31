local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')
local QBPhone = {}
local AppAlerts = {}
local MentionedTweets = {}
local Hashtags = {}
local Calls = {}
local Adverts = {}
local GeneratedPlates = {}
local WebHook = ''
local FivemerrApiToken = ''
local TWData = {}

-- Functions

local RateLimits = {}

-- Returns true (and records the attempt) when the source is still inside the cooldown for this action
local function IsRateLimited(src, action)
    local interval = Config.ContentIntervals and Config.ContentIntervals[action] or 1000
    local key = action .. ':' .. tostring(src)
    local now = GetGameTimer()
    if RateLimits[key] and (now - RateLimits[key]) < interval then
        return true
    end
    RateLimits[key] = now
    return false
end

-- Returns true once the source has done `action` more than `max` times inside `windowMs` (one tweet
-- sends several hashtag / mention events at once, so these allow a small burst).
local Bursts = {}
local function IsBurstLimited(src, action, max, windowMs)
    local key = action .. ':' .. tostring(src)
    local now = GetGameTimer()
    local b = Bursts[key]
    if not b or now - b.start >= windowMs then
        Bursts[key] = { start = now, count = 1 }
        return false
    end
    b.count = b.count + 1
    return b.count > max
end

-- Strips control characters and caps length; returns nil for invalid/empty input
local function SanitizeText(text, maxLen)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('%c', '')
    if #text < 1 then return nil end
    maxLen = maxLen or Config.MaxContentLength or 280
    if #text > maxLen then text = text:sub(1, maxLen) end
    return text
end

local function IsValidAmount(amount)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount <= 0 then return nil end
    return math.floor(amount)
end

local function Round(value, numDecimalPlaces)
    local mult = 10 ^ (numDecimalPlaces or 0)
    return math.floor(value * mult + 0.5) / mult
end

-- The MEOS app (person / vehicle / plate lookups) is a police app (Config.PhoneApplications.meos.job);
-- the server checks it, as any client could call these callbacks.
local function IsPolice(Player)
    local job = Player and Player.PlayerData.job
    return job ~= nil and (job.type == 'leo' or job.name == 'police')
end

-- Escapes LIKE wildcards so a search term only matches itself.
local function LikeEscape(text)
    return (text:gsub('[\\%%_]', '\\%0'))
end

local function IsPhoneNumber(number)
    number = tostring(number or '')
    return number ~= '' and #number <= 20 and number:match('^[%w%-]+$') ~= nil
end

--- The players row of the holder of exactly this phone number (the old lookups used
--- LIKE '%<number>%', which matched any player whose character data merely contained those digits).
local function FindPlayerRowByPhone(number)
    if not IsPhoneNumber(number) then return nil end
    local rows = MySQL.query.await('SELECT * FROM players WHERE charinfo LIKE ? LIMIT 2', { '%"phone":"' .. tostring(number) .. '"%' })
    if rows and rows[1] and not rows[2] then return rows[1] end
    return nil
end

local function ProfilePicture(row)
    local ok, meta = pcall(json.decode, row and row.metadata or '')
    local picture = ok and type(meta) == 'table' and type(meta.phone) == 'table' and meta.phone.profilepicture
    return picture or 'default'
end

local function EncodedSize(value)
    local ok, encoded = pcall(json.encode, value)
    return ok and type(encoded) == 'string' and #encoded or math.huge
end

-- Bank transfers between players go through the pfm-banking ledger (PFPayout, '@pfm-banking/payouts.lua'):
-- one Transfer debits the sender and credits the receiver (online or offline) under one key, and is
-- recovered if the server stops in between. RemoveMoney + AddMoney / a players.money rewrite could
-- lose or create money, and overwrote an offline receiver's balance with a stale copy.

--- Finds the player whose bank account number is exactly `iban` (letters and digits only; the old
--- lookup used LIKE '%<iban>%', so a partial number matched some other player's account).
local function FindAccountHolder(iban)
    iban = tostring(iban or '')
    if iban == '' or #iban > 32 or not iban:match('^%w+$') then return nil end
    local result = MySQL.query.await('SELECT citizenid FROM players WHERE charinfo LIKE ?', { '%"account":"' .. iban .. '"%' })
    if result and result[1] and not result[2] then return result[1].citizenid end
    return nil
end

--- Moves `amount` from the source player's bank to the holder of `iban`. Returns ok, error.
local function BankTransfer(src, iban, amount)
    local Player = exports['pfm-core']:GetPlayer(src)
    amount = IsValidAmount(amount)
    if not Player or not amount then return false, 'invalid' end
    local cid = Player.PlayerData.citizenid
    local receiver = FindAccountHolder(iban)
    if not receiver then return false, 'no_account' end
    if receiver == cid then return false, 'self' end
    local res = PFPayout.Transfer({
        from = ('player:%s:bank'):format(cid), to = ('player:%s:bank'):format(receiver), amount = amount,
        key = ('pfm-phone:transfer:%s:%s'):format(cid, PFPayout.NewId()), kind = 'transfer',
        reason = 'Phone bank transfer', actor = cid,
    })
    if not res.ok then return false, res.error end
    local Receiver = QBCore.Functions.GetPlayerByCitizenId(receiver)
    if Receiver and Receiver.Functions.GetItemByName('phone') then
        TriggerClientEvent('qb-phone:client:TransferMoney', Receiver.PlayerData.source, amount, Receiver.PlayerData.money.bank)
    end
    return true
end

local function GetOnlineStatus(number)
    local Target = QBCore.Functions.GetPlayerByPhone(number)
    local retval = false
    if Target ~= nil then
        retval = true
    end
    return retval
end

local function GenerateMailId()
    return math.random(111111, 999999)
end

function QBPhone.AddMentionedTweet(citizenid, TweetData)
    if MentionedTweets[citizenid] == nil then
        MentionedTweets[citizenid] = {}
    end
    MentionedTweets[citizenid][#MentionedTweets[citizenid] + 1] = TweetData
end

function QBPhone.SetPhoneAlerts(citizenid, app, alerts)
    if citizenid ~= nil and app ~= nil then
        if AppAlerts[citizenid] == nil then
            AppAlerts[citizenid] = {}
            if AppAlerts[citizenid][app] == nil then
                if alerts == nil then
                    AppAlerts[citizenid][app] = 1
                else
                    AppAlerts[citizenid][app] = alerts
                end
            end
        else
            if AppAlerts[citizenid][app] == nil then
                if alerts == nil then
                    AppAlerts[citizenid][app] = 1
                else
                    AppAlerts[citizenid][app] = 0
                end
            else
                if alerts == nil then
                    AppAlerts[citizenid][app] = AppAlerts[citizenid][app] + 1
                else
                    AppAlerts[citizenid][app] = AppAlerts[citizenid][app] + 0
                end
            end
        end
    end
end

local function SplitStringToArray(string)
    local retval = {}
    for i in string.gmatch(string, '%S+') do
        retval[#retval + 1] = i
    end
    return retval
end

local function GenerateOwnerName()
    local names = {
        [1] = { name = 'Bailey Sykes', citizenid = 'DSH091G93' },
        [2] = { name = 'Aroush Goodwin', citizenid = 'AVH09M193' },
        [3] = { name = 'Tom Warren', citizenid = 'DVH091T93' },
        [4] = { name = 'Abdallah Friedman', citizenid = 'GZP091G93' },
        [5] = { name = 'Lavinia Powell', citizenid = 'DRH09Z193' },
        [6] = { name = 'Andrew Delarosa', citizenid = 'KGV091J93' },
        [7] = { name = 'Skye Cardenas', citizenid = 'ODF09S193' },
        [8] = { name = 'Amelia-Mae Walter', citizenid = 'KSD0919H3' },
        [9] = { name = 'Elisha Cote', citizenid = 'NDX091D93' },
        [10] = { name = 'Janice Rhodes', citizenid = 'ZAL0919X3' },
        [11] = { name = 'Justin Harris', citizenid = 'ZAK09D193' },
        [12] = { name = 'Montel Graves', citizenid = 'POL09F193' },
        [13] = { name = 'Benjamin Zavala', citizenid = 'TEW0J9193' },
        [14] = { name = 'Mia Willis', citizenid = 'YOO09H193' },
        [15] = { name = 'Jacques Schmitt', citizenid = 'QBC091H93' },
        [16] = { name = 'Mert Simmonds', citizenid = 'YDN091H93' },
        [17] = { name = 'Rickie Browne', citizenid = 'PJD09D193' },
        [18] = { name = 'Deacon Stanley', citizenid = 'RND091D93' },
        [19] = { name = 'Daisy Fraser', citizenid = 'QWE091A93' },
        [20] = { name = 'Kitty Walters', citizenid = 'KJH0919M3' },
        [21] = { name = 'Jareth Fernandez', citizenid = 'ZXC09D193' },
        [22] = { name = 'Meredith Calhoun', citizenid = 'XYZ0919C3' },
        [23] = { name = 'Teagan Mckay', citizenid = 'ZYX0919F3' },
        [24] = { name = 'Kurt Bain', citizenid = 'IOP091O93' },
        [25] = { name = 'Burt Kain', citizenid = 'PIO091R93' },
        [26] = { name = 'Joanna Huff', citizenid = 'LEK091X93' },
        [27] = { name = 'Carrie-Ann Pineda', citizenid = 'ALG091Y93' },
        [28] = { name = 'Gracie-Mai Mcghee', citizenid = 'YUR09E193' },
        [29] = { name = 'Robyn Boone', citizenid = 'SOM091W93' },
        [30] = { name = 'Aliya William', citizenid = 'KAS009193' },
        [31] = { name = 'Rohit West', citizenid = 'SOK091093' },
        [32] = { name = 'Skylar Archer', citizenid = 'LOK091093' },
        [33] = { name = 'Jake Kumar', citizenid = 'AKA420609' },
    }
    return names[math.random(1, #names)]
end


-- One mailbox for the phone, the tablet and the computer: while pf-citizen runs, mail is stored and
-- announced by it (exports['pf-citizen']:SendMail) in this same player_mails table, and it calls
-- RefreshMails below to update the phone. Without pf-citizen the phone stores mail itself as before.

--- The phone's inbox: pf-citizen keeps sent mail, drafts and trash in the same table, the phone
--- shows only the inbox (rows from before pf-citizen have no folder).
local function PhoneMails(citizenid, newestFirst)
    local rows = MySQL.query.await('SELECT * FROM player_mails WHERE citizenid = ? ORDER BY `date` ' .. (newestFirst and 'DESC' or 'ASC'), { citizenid }) or {}
    local mails = {}
    for _, mail in ipairs(rows) do
        if mail.folder == nil or mail.folder == 'inbox' then
            if mail.button ~= nil and mail.button ~= '' then
                local ok, button = pcall(json.decode, mail.button)
                mail.button = ok and button or nil
            elseif mail.button == '' then
                mail.button = nil
            end
            mails[#mails + 1] = mail
        end
    end
    return mails
end

--- Sends the phone of an online citizen its inbox (and a new-mail notification when mailData is given).
local function RefreshMails(citizenid, mailData, newestFirst)
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if not Player then return false end
    local src = Player.PlayerData.source
    if type(mailData) == 'table' then TriggerClientEvent('qb-phone:client:NewMailNotify', src, mailData) end
    SetTimeout(200, function()
        TriggerClientEvent('qb-phone:client:UpdateMails', src, PhoneMails(citizenid, newestFirst))
    end)
    return true
end
exports('RefreshMails', function(citizenid, mailData) return RefreshMails(citizenid, mailData) end)

--- Stores a mail through pf-citizen. True when pf-citizen took it (stored or refused as invalid);
--- false when it is not running, so the caller stores it the old way.
local function CitizenMail(citizenid, mailData)
    if GetResourceState('pf-citizen') ~= 'started' then return false end
    local ok = pcall(function()
        return exports['pf-citizen']:SendMail(citizenid, {
            sender = mailData.sender, subject = mailData.subject, message = mailData.message or mailData.subject,
            button = mailData.button, senderType = 'system',
        })
    end)
    return ok
end

local function StoreMail(citizenid, mailData)
    if mailData.button == nil then
        MySQL.insert('INSERT INTO player_mails (`citizenid`, `sender`, `subject`, `message`, `mailid`, `read`) VALUES (?, ?, ?, ?, ?, ?)', { citizenid, mailData.sender, mailData.subject, mailData.message, GenerateMailId(), 0 })
    else
        MySQL.insert('INSERT INTO player_mails (`citizenid`, `sender`, `subject`, `message`, `mailid`, `read`, `button`) VALUES (?, ?, ?, ?, ?, ?, ?)', { citizenid, mailData.sender, mailData.subject, mailData.message, GenerateMailId(), 0, json.encode(mailData.button) })
    end
end

local function sendNewMailToOffline(citizenid, mailData)
    if type(citizenid) ~= 'string' or type(mailData) ~= 'table' then return end
    if CitizenMail(citizenid, mailData) then return end
    StoreMail(citizenid, mailData)
    RefreshMails(citizenid, mailData)
end
exports('sendNewMailToOffline', sendNewMailToOffline)

--- Tells the online members of the billing business that a bill was paid or declined, from the
--- server's own invoice data. (Clients used to send this through qb-phone:server:BillingEmail with a
--- business and amount of their choosing, so anyone could mail any job fake "invoice paid" notices.)
local function notifyBillingSociety(society, payer, amount, paid)
    if type(society) ~= 'string' or society == '' then return end
    local name = ('%s %s'):format(payer.PlayerData.charinfo.firstname or '', payer.PlayerData.charinfo.lastname or '')
    for _, src in pairs(QBCore.Functions.GetPlayers()) do
        local member = exports['pfm-core']:GetPlayer(src)
        if member and member.PlayerData.job and member.PlayerData.job.name == society then
            sendNewMailToOffline(member.PlayerData.citizenid, {
                sender = 'Billing Department',
                subject = paid and 'Invoice Paid' or 'Invoice Declined',
                message = ('Invoice Has Been %s From %s In The Amount Of $%s'):format(paid and 'Paid' or 'Declined', name, tostring(amount)),
            })
        end
    end
end
-- Callbacks

QBCore.Functions.CreateCallback('qb-phone:server:GetInvoices', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)

    if Player then
        local invoices = MySQL.query.await('SELECT * FROM phone_invoices WHERE citizenid = ?', { Player.PlayerData.citizenid })
        for _, v in pairs(invoices) do
            local Ply = QBCore.Functions.GetPlayerByCitizenId(v.sender)
            if Ply ~= nil then
                v.number = Ply.PlayerData.charinfo.phone
            else
                local res = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', { v.sender })
                if res[1] ~= nil then
                    res[1].charinfo = json.decode(res[1].charinfo)
                    v.number = res[1].charinfo.phone
                else
                    v.number = nil
                end
            end
        end
        cb(invoices)
        return
    end

    cb({})
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetCallState', function(_, cb, ContactData)
    if type(ContactData) ~= 'table' then return cb(false, false) end
    local Target = QBCore.Functions.GetPlayerByPhone(ContactData.number)
    if Target ~= nil then
        if Calls[Target.PlayerData.citizenid] ~= nil then
            if Calls[Target.PlayerData.citizenid].inCall then
                cb(false, true)
            else
                cb(true, true)
            end
        else
            cb(true, true)
        end
    else
        cb(false, false)
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetPhoneData', function(source, cb)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player ~= nil then
        local PhoneData = {
            Applications = {},
            PlayerContacts = {},
            MentionedTweets = {},
            Chats = {},
            Hashtags = {},
            Garage = {},
            Mails = {},
            Adverts = {},
            CryptoTransactions = {},
            Tweets = {},
            Images = {},
            InstalledApps = Player.PlayerData.metadata['phonedata'].InstalledApps
        }
        PhoneData.Adverts = Adverts

        local result = MySQL.query.await('SELECT * FROM player_contacts WHERE citizenid = ? ORDER BY name ASC', { Player.PlayerData.citizenid })
        if result[1] ~= nil then
            for _, v in pairs(result) do
                v.status = GetOnlineStatus(v.number)
            end

            PhoneData.PlayerContacts = result
        end

        local garageresult = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if garageresult[1] ~= nil then
            PhoneData.Garage = garageresult
        end

        local messages = MySQL.query.await('SELECT * FROM phone_messages WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if messages ~= nil and next(messages) ~= nil then
            PhoneData.Chats = messages
        end

        if AppAlerts[Player.PlayerData.citizenid] ~= nil then
            PhoneData.Applications = AppAlerts[Player.PlayerData.citizenid]
        end

        if MentionedTweets[Player.PlayerData.citizenid] ~= nil then
            PhoneData.MentionedTweets = MentionedTweets[Player.PlayerData.citizenid]
        end

        if Hashtags ~= nil and next(Hashtags) ~= nil then
            PhoneData.Hashtags = Hashtags
        end

        local Tweets = MySQL.query.await('SELECT * FROM phone_tweets WHERE `date` > NOW() - INTERVAL ? hour', { Config.TweetDuration })

        if Tweets ~= nil and next(Tweets) ~= nil then
            PhoneData.Tweets = Tweets
            TWData = Tweets
        end

        PhoneData.Mails = PhoneMails(Player.PlayerData.citizenid)

        local transactions = MySQL.query.await('SELECT * FROM crypto_transactions WHERE citizenid = ? ORDER BY `date` ASC', { Player.PlayerData.citizenid })
        if transactions[1] ~= nil then
            for _, v in pairs(transactions) do
                PhoneData.CryptoTransactions[#PhoneData.CryptoTransactions + 1] = {
                    TransactionTitle = v.title,
                    TransactionMessage = v.message
                }
            end
        end
        local images = MySQL.query.await('SELECT * FROM phone_gallery WHERE citizenid = ? ORDER BY `date` DESC', { Player.PlayerData.citizenid })
        if images ~= nil and next(images) ~= nil then
            PhoneData.Images = images
        end
        cb(PhoneData)
    end
end)

-- Paying a bill: the amount, the business and the biller come from the stored invoice. (They came
-- from the client, so a bill could be paid with $1, to any business, with the commission sent to
-- any player; the commission was also paid before the payment was checked.) Every step is keyed by
-- the invoice id, so paying the same bill twice moves money once. The phone, the tablet and the
-- computer (pf-citizen's Bills app, through the PayInvoice export) all pay through PayInvoice below.

--- Charges the invoice on the ledger. One key per invoice, so a replayed or doubled request is charged
--- once; a key whose attempt failed (not enough money) stays failed in the ledger, so a later attempt
--- moves on to the next key instead of failing forever. Returns true or false, error.
local function ChargeInvoice(src, invoiceId, amount, society)
    local base = 'pfm-phone:invoice:' .. invoiceId
    for attempt = 1, 20 do
        local key = attempt == 1 and base or (base .. ':retry' .. attempt)
        local account, res = PFPayout.Charge(src, 'bank', amount, { key = key, kind = 'purchase', reason = 'Invoice from ' .. society })
        if account then return true end
        if not (type(res) == 'table' and res.duplicate) then return false, type(res) == 'table' and res.error or 'payment_failed' end
    end
    return false, 'payment_failed'
end

--- Pays invoice `invoiceId` of the player `src`. Returns true, or false and an error code.
--- `elsewhere`: paid from another device, so the phone is told to reload its invoices.
local function PayInvoice(src, invoiceId, elsewhere)
    local Ply = exports['pfm-core']:GetPlayer(src)
    invoiceId = tonumber(invoiceId)
    if not Ply or not invoiceId or invoiceId ~= math.floor(invoiceId) then return false, 'bad_request' end
    local cid = Ply.PlayerData.citizenid
    local rows = MySQL.query.await('SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', { invoiceId, cid })
    local invoice = rows and rows[1]
    local amount = invoice and IsValidAmount(invoice.amount)
    local society = invoice and tostring(invoice.society or '')
    if not amount or society == '' then return false, 'not_found' end

    local charged, err = ChargeInvoice(src, invoiceId, amount, society)
    if not charged then return false, err == 'insufficient_funds' and 'insufficient_funds' or (err or 'payment_failed') end
    local deleted = MySQL.query.await('DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', { invoiceId, cid })
    -- a doubled request reaches this point too (its charge was the same ledger entry); only the one
    -- that removed the invoice sends the mails
    local first = not (type(deleted) == 'table' and tonumber(deleted.affectedRows) == 0)
    local key = 'pfm-phone:invoice:' .. invoiceId
    local ok = PFPayout.PaySociety(society, amount, { key = key .. ':society', reason = 'Phone invoice' })
    if not ok then print(('^1[pfm-phone]^7 invoice %d: payment to %s not credited yet (key %s:society)'):format(invoiceId, society, key)) end

    local rate = Config.BillingCommissions[society]
    if rate and invoice.sendercitizenid and invoice.sendercitizenid ~= '' then
        local commission = Round(amount * rate)
        if commission > 0 then
            PFPayout.Pay(invoice.sendercitizenid, 'bank', commission, { key = key .. ':commission', kind = 'wage', reason = 'Billing commission', quiet = true })
        end
        if first then
            exports['pfm-phone']:sendNewMailToOffline(invoice.sendercitizenid, {
                sender = 'Billing Department',
                subject = 'Commission Received',
                message = string.format('You received a commission check of $%s when %s %s paid a bill of $%s.', commission, Ply.PlayerData.charinfo.firstname, Ply.PlayerData.charinfo.lastname, amount)
            })
        end
    end
    if first then
        TriggerEvent('qb-phone:server:paidInvoice', src, invoiceId)
        TriggerEvent('pfm-phone:server:invoiceSettled', invoice, 'paid')
        notifyBillingSociety(society, Ply, amount, true)
        if elsewhere then TriggerClientEvent('qb-phone:RefreshPhone', src) end
    end
    return true
end
exports('PayInvoice', function(src, invoiceId) return PayInvoice(src, invoiceId, true) end)

QBCore.Functions.CreateCallback('qb-phone:server:PayInvoice', function(source, cb, _, _, invoiceId)
    cb(PayInvoice(source, invoiceId) == true)
end)

--- Declines a declinable invoice of the player `src`. Returns true, or false and an error code.
local function DeclineInvoice(src, invoiceId)
    local Ply = exports['pfm-core']:GetPlayer(src)
    invoiceId = tonumber(invoiceId)
    if not Ply or not invoiceId then return false, 'bad_request' end
    local cid = Ply.PlayerData.citizenid
    local rows = MySQL.query.await('SELECT amount, society FROM phone_invoices WHERE id = ? and citizenid = ? and candecline = ?', { invoiceId, cid, 1 })
    if not (rows and rows[1]) then return false, 'not_declinable' end
    TriggerEvent('qb-phone:server:declinedInvoice', src, invoiceId)
    notifyBillingSociety(rows[1].society, Ply, rows[1].amount, false)
    MySQL.query('DELETE FROM phone_invoices WHERE id = ? and citizenid = ? and candecline = ?', { invoiceId, cid, 1 })
    TriggerEvent('pfm-phone:server:invoiceSettled', { id = invoiceId, citizenid = cid, amount = rows[1].amount, society = rows[1].society }, 'declined')
    return true
end
exports('DeclineInvoice', function(src, invoiceId) return DeclineInvoice(src, invoiceId) end)

QBCore.Functions.CreateCallback('qb-phone:server:DeclineInvoice', function(source, cb, _, _, invoiceId)
    cb(DeclineInvoice(source, invoiceId) == true)
end)

-- Contact pictures: looked up by the exact phone number, at most MAX_PICTURE_LOOKUPS per request (the
-- list comes from the client and each entry is a database query).
local MAX_PICTURE_LOOKUPS = 50

QBCore.Functions.CreateCallback('qb-phone:server:GetContactPictures', function(_, cb, Chats)
    if type(Chats) ~= 'table' then return cb({}) end
    local looked = 0
    for _, v in pairs(Chats) do
        if type(v) == 'table' and looked < MAX_PICTURE_LOOKUPS then
            looked = looked + 1
            local row = FindPlayerRowByPhone(v.number)
            if row then v.picture = ProfilePicture(row) end
        end
    end
    SetTimeout(100, function()
        cb(Chats)
    end)
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetContactPicture', function(_, cb, Chat)
    if type(Chat) ~= 'table' then return cb(nil) end
    Chat.picture = ProfilePicture(FindPlayerRowByPhone(Chat.number))
    SetTimeout(100, function()
        cb(Chat)
    end)
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetPicture', function(_, cb, number)
    local row = FindPlayerRowByPhone(number)
    if row then
        cb(ProfilePicture(row))
    else
        cb(nil)
    end
end)

-- MEOS person search (police only). The search used to be pasted into the SQL text (a quote-escaping
-- helper that a backslash defeated), and any client could look up anyone's personal data.
QBCore.Functions.CreateCallback('qb-phone:server:FetchResult', function(source, cb, search)
    if not IsPolice(exports['pfm-core']:GetPlayer(source)) then return cb(nil) end
    search = SanitizeText(search, 64)
    if not search then return cb(nil) end
    local searchData = {}
    local ApaData = {}
    local query = 'SELECT * FROM `players` WHERE `citizenid` = ?'
    local params = { search }
    -- every word must appear in the character data
    local likes = {}
    for i, word in ipairs(SplitStringToArray(search)) do
        if i > 5 then break end
        likes[#likes + 1] = '`charinfo` LIKE ?'
        params[#params + 1] = '%' .. LikeEscape(word) .. '%'
    end
    if #likes > 0 then query = query .. ' OR (' .. table.concat(likes, ' AND ') .. ')' end
    query = query .. ' LIMIT 25'
    local ApartmentData = MySQL.query.await('SELECT * FROM apartments', {}) or {}
    for k, v in pairs(ApartmentData) do
        ApaData[v.citizenid] = ApartmentData[k]
    end
    local result = MySQL.query.await(query, params)
    if result and result[1] ~= nil then
        for _, v in pairs(result) do
            local charinfo = json.decode(v.charinfo) or {}
            local metadata = json.decode(v.metadata) or {}
            local appiepappie = {}
            if ApaData[v.citizenid] ~= nil and next(ApaData[v.citizenid]) ~= nil then
                appiepappie = ApaData[v.citizenid]
            end
            searchData[#searchData + 1] = {
                citizenid = v.citizenid,
                firstname = charinfo.firstname,
                lastname = charinfo.lastname,
                birthdate = charinfo.birthdate,
                phone = charinfo.phone,
                nationality = charinfo.nationality,
                gender = charinfo.gender,
                warrant = false,
                driverlicense = type(metadata.licences) == 'table' and metadata.licences.driver or false,
                appartmentdata = appiepappie
            }
        end
        cb(searchData)
    else
        cb(nil)
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetVehicleSearchResults', function(source, cb, search)
    if not IsPolice(exports['pfm-core']:GetPlayer(source)) then return cb(nil) end
    search = SanitizeText(search, 32)
    if not search then return cb(nil) end
    local searchData = {}
    local query = '%' .. LikeEscape(search) .. '%'
    local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate LIKE ? OR citizenid = ? LIMIT 25',
        { query, search }) or {}
    if result[1] ~= nil then
        for k, _ in pairs(result) do
            local player = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', { result[k].citizenid })
            if player[1] ~= nil then
                local charinfo = json.decode(player[1].charinfo)
                local vehicleInfo = sharedVehicles[result[k].vehicle]
                if vehicleInfo ~= nil then
                    searchData[#searchData + 1] = {
                        plate = result[k].plate,
                        status = true,
                        owner = charinfo.firstname .. ' ' .. charinfo.lastname,
                        citizenid = result[k].citizenid,
                        label = vehicleInfo['name']
                    }
                else
                    searchData[#searchData + 1] = {
                        plate = result[k].plate,
                        status = true,
                        owner = charinfo.firstname .. ' ' .. charinfo.lastname,
                        citizenid = result[k].citizenid,
                        label = 'Name not found..'
                    }
                end
            end
        end
    else
        if GeneratedPlates[search] ~= nil then
            searchData[#searchData + 1] = {
                plate = GeneratedPlates[search].plate,
                status = GeneratedPlates[search].status,
                owner = GeneratedPlates[search].owner,
                citizenid = GeneratedPlates[search].citizenid,
                label = 'Brand unknown..'
            }
        else
            local ownerInfo = GenerateOwnerName()
            GeneratedPlates[search] = {
                plate = search,
                status = true,
                owner = ownerInfo.name,
                citizenid = ownerInfo.citizenid
            }
            searchData[#searchData + 1] = {
                plate = search,
                status = true,
                owner = ownerInfo.name,
                citizenid = ownerInfo.citizenid,
                label = 'Brand unknown..'
            }
        end
    end
    cb(searchData)
end)

QBCore.Functions.CreateCallback('qb-phone:server:ScanPlate', function(source, cb, plate)
    local src = source
    if not IsPolice(exports['pfm-core']:GetPlayer(src)) then return cb(nil) end
    plate = type(plate) == 'string' and SanitizeText(plate, 16) or nil
    local vehicleData
    if plate ~= nil then
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate = ?', { plate }) or {}
        local player = result[1] and MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', { result[1].citizenid })
        if player and player[1] then
            local charinfo = json.decode(player[1].charinfo) or {}
            vehicleData = {
                plate = plate,
                status = true,
                owner = charinfo.firstname .. ' ' .. charinfo.lastname,
                citizenid = result[1].citizenid
            }
        elseif GeneratedPlates ~= nil and GeneratedPlates[plate] ~= nil then
            vehicleData = GeneratedPlates[plate]
        else
            local ownerInfo = GenerateOwnerName()
            GeneratedPlates[plate] = {
                plate = plate,
                status = true,
                owner = ownerInfo.name,
                citizenid = ownerInfo.citizenid
            }
            vehicleData = {
                plate = plate,
                status = true,
                owner = ownerInfo.name,
                citizenid = ownerInfo.citizenid
            }
        end
        cb(vehicleData)
    else
        TriggerClientEvent('QBCore:Notify', src, 'No Vehicle Nearby', 'error')
        cb(nil)
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:HasPhone', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if Player ~= nil then
        local HasPhone = Player.GetItemByName('phone')
        if HasPhone ~= nil then
            cb(true)
        else
            cb(false)
        end
    end
end)

-- The bank app's transfer (it does the transfer; the name is historical)
QBCore.Functions.CreateCallback('qb-phone:server:CanTransferMoney', function(source, cb, amount, iban)
    cb((BankTransfer(source, iban, amount)))
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetCurrentLawyers', function(_, cb)
    local Lawyers = {}
    for _, v in pairs(QBCore.Functions.GetPlayers()) do
        local Player = exports['pfm-core']:GetPlayer(v)
        if Player ~= nil then
            if (Player.PlayerData.job.name == 'lawyer' or Player.PlayerData.job.name == 'realestate' or
                    Player.PlayerData.job.name == 'mechanic' or Player.PlayerData.job.name == 'taxi' or
                    Player.PlayerData.job.name == 'police' or Player.PlayerData.job.name == 'ambulance') and
                Player.PlayerData.job.onduty then
                Lawyers[#Lawyers + 1] = {
                    name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
                    phone = Player.PlayerData.charinfo.phone,
                    typejob = Player.PlayerData.job.name
                }
            end
        end
    end
    cb(Lawyers)
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetWebhook', function(_, cb)
    if WebHook ~= '' then
        cb(WebHook)
    else
        print('Set your webhook to ensure that your camera will work!!!!!! Set this on line 9 of the server sided script!!!!!')
        cb(nil)
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:UploadToFivemerr', function(source, cb)
    local src = source

    if Config.Fivemerr == true and FivemerrApiToken == '' then
        print('^1--- Fivemerr is enabled but no API token has been specified. ---^7')
        return cb(nil)
    end

    exports['screenshot-basic']:requestClientScreenshot(src, {
        encoding = 'png'
    }, function(err, data)
        if err then return cb(nil) end
        PerformHttpRequest(WebHook, function(status, response)
            if status ~= 200 then
                print('^1--- ERROR UPLOADING IMAGE: ' .. status .. ' ---^7')
                cb(nil)
            end

            cb(response)
        end, 'POST', json.encode({ data = data }), {
            ['Authorization'] = FivemerrApiToken,
            ['Content-Type'] = 'application/json'
        })
    end)
end)

-- Events

RegisterNetEvent('qb-phone:server:AddAdvert', function(msg, url)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsRateLimited(src, 'advert') then return end
    msg = SanitizeText(msg)
    if not msg then return end
    url = url ~= nil and SanitizeText(tostring(url), 255) or nil
    local CitizenId = Player.PlayerData.citizenid
    if Adverts[CitizenId] ~= nil then
        Adverts[CitizenId].message = msg
        Adverts[CitizenId].name = '@' .. Player.PlayerData.charinfo.firstname .. '' .. Player.PlayerData.charinfo.lastname
        Adverts[CitizenId].number = Player.PlayerData.charinfo.phone
        Adverts[CitizenId].url = url
    else
        Adverts[CitizenId] = {
            message = msg,
            name = '@' .. Player.PlayerData.charinfo.firstname .. '' .. Player.PlayerData.charinfo.lastname,
            number = Player.PlayerData.charinfo.phone,
            url = url
        }
    end
    TriggerClientEvent('qb-phone:client:UpdateAdverts', -1, Adverts, '@' .. Player.PlayerData.charinfo.firstname .. '' .. Player.PlayerData.charinfo.lastname)
end)

RegisterNetEvent('qb-phone:server:DeleteAdvert', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    Adverts[citizenid] = nil
    TriggerClientEvent('qb-phone:client:UpdateAdvertsDel', -1, Adverts)
end)

RegisterNetEvent('qb-phone:server:SetCallState', function(bool)
    local src = source
    local Ply = exports['pfm-core']:GetPlayer(src)
    if not Ply then return end
    if Calls[Ply.PlayerData.citizenid] ~= nil then
        Calls[Ply.PlayerData.citizenid].inCall = bool
    else
        Calls[Ply.PlayerData.citizenid] = {}
        Calls[Ply.PlayerData.citizenid].inCall = bool
    end
end)

RegisterNetEvent('qb-phone:server:RemoveMail', function(MailId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(MailId) ~= 'number' and type(MailId) ~= 'string' then return end
    -- citizenid match in the query enforces that players can only delete their own mail. With
    -- pf-citizen it goes to the trash, as on the tablet and the computer (emptied after 30 days).
    if GetResourceState('pf-citizen') == 'started' then
        MySQL.update.await("UPDATE player_mails SET prev_folder = folder, folder = 'trash', moved_at = NOW() WHERE mailid = ? AND citizenid = ? AND folder = 'inbox'", { MailId, Player.PlayerData.citizenid })
    else
        MySQL.query.await('DELETE FROM player_mails WHERE mailid = ? AND citizenid = ?', { MailId, Player.PlayerData.citizenid })
    end
    RefreshMails(Player.PlayerData.citizenid)
end)

-- A mail to the sender's own phone (job and mission scripts send these from the client).
RegisterNetEvent('qb-phone:server:sendNewMail', function(mailData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(mailData) ~= 'table' then return end
    mailData.sender = SanitizeText(tostring(mailData.sender or ''), 64)
    mailData.subject = SanitizeText(tostring(mailData.subject or ''), 128)
    mailData.message = type(mailData.message) == 'string' and mailData.message ~= '' and mailData.message:sub(1, 4000) or nil
    if not mailData.sender or not mailData.subject or not mailData.message then return end
    if mailData.button ~= nil and (type(mailData.button) ~= 'table' or EncodedSize(mailData.button) > 2000) then return end
    -- only these four fields go on: the mail lands in the sender's own inbox, as a system mail
    local mail = { sender = mailData.sender, subject = mailData.subject, message = mailData.message, button = mailData.button }
    if CitizenMail(Player.PlayerData.citizenid, mail) then return end
    StoreMail(Player.PlayerData.citizenid, mail)
    RefreshMails(Player.PlayerData.citizenid, mail, true)
end)

-- Server-only: a mail to any citizen. It was a net event, so any client could put a mail (with a
-- button that runs an event of its choosing when clicked) into anyone's inbox. No client sends it.
AddEventHandler('qb-phone:server:sendNewEventMail', function(citizenid, mailData)
    if type(citizenid) ~= 'string' or type(mailData) ~= 'table' then return end
    if CitizenMail(citizenid, mailData) then return end
    StoreMail(citizenid, mailData)
    RefreshMails(citizenid)
end)

RegisterNetEvent('qb-phone:server:ClearButtonData', function(mailId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(mailId) ~= 'number' and type(mailId) ~= 'string' then return end
    MySQL.update.await('UPDATE player_mails SET button = ? WHERE mailid = ? AND citizenid = ?', { '', mailId, Player.PlayerData.citizenid })
    RefreshMails(Player.PlayerData.citizenid)
end)

--- A tweet as everyone else sees it, built by the server: the author is the sender, the text and links
--- are cleaned. (Tweets, mentions and hashtag posts used to be relayed as the client sent them, so a
--- client could post in someone else's name.) Returns nil for an empty message.
local function BuildTweet(Player, data)
    if type(data) ~= 'table' then return nil end
    local message = SanitizeText(tostring(data.message or ''))
    if not message then return nil end
    local time = type(data.time) == 'string' and SanitizeText(data.time, 64) or os.date('%Y-%m-%d %H:%M:%S')
    return {
        citizenid = Player.PlayerData.citizenid,
        firstName = Player.PlayerData.charinfo.firstname,
        lastName = Player.PlayerData.charinfo.lastname,
        message = message,
        time = time,
        date = time,
        url = (SanitizeText(tostring(data.url or ''), 255) or ''):gsub('[%<>\"()\' $]', ''),
        picture = (SanitizeText(tostring(data.picture or ''), 255) or 'default'):gsub('[%<>\"()\' $]', ''),
        tweetId = type(data.tweetId) == 'string' and data.tweetId:match('^TWEET%-%d+$') and data.tweetId or nil,
    }
end

RegisterNetEvent('qb-phone:server:MentionedPlayer', function(firstName, lastName, TweetMessage)
    local src = source
    local Sender = exports['pfm-core']:GetPlayer(src)
    if not Sender or IsBurstLimited(src, 'mention', 5, 3000) then return end
    firstName, lastName = SanitizeText(firstName, 64), SanitizeText(lastName, 64)
    local tweet = BuildTweet(Sender, TweetMessage)
    if not firstName or not lastName or not tweet then return end
    -- an online player with that name, else one database lookup (this used to run a query for
    -- every online player who did not match)
    for _, v in pairs(QBCore.Functions.GetPlayers()) do
        local Player = exports['pfm-core']:GetPlayer(v)
        if Player ~= nil and Player.PlayerData.charinfo.firstname == firstName and Player.PlayerData.charinfo.lastname == lastName then
            QBPhone.SetPhoneAlerts(Player.PlayerData.citizenid, 'twitter')
            QBPhone.AddMentionedTweet(Player.PlayerData.citizenid, tweet)
            TriggerClientEvent('qb-phone:client:GetMentioned', Player.PlayerData.source, tweet, AppAlerts[Player.PlayerData.citizenid]['twitter'])
            return
        end
    end
    local result = MySQL.query.await('SELECT citizenid FROM players WHERE charinfo LIKE ? AND charinfo LIKE ? LIMIT 1',
        { '%"firstname":"' .. LikeEscape(firstName) .. '"%', '%"lastname":"' .. LikeEscape(lastName) .. '"%' })
    if result and result[1] ~= nil then
        local MentionedTarget = result[1].citizenid
        QBPhone.SetPhoneAlerts(MentionedTarget, 'twitter')
        QBPhone.AddMentionedTweet(MentionedTarget, tweet)
    end
end)

RegisterNetEvent('qb-phone:server:CallContact', function(TargetData, CallId, AnonymousCall)
    local src = source
    local Ply = exports['pfm-core']:GetPlayer(src)
    if not Ply or type(TargetData) ~= 'table' then return end
    local Target = QBCore.Functions.GetPlayerByPhone(TargetData.number)
    if Target ~= nil then
        TriggerClientEvent('qb-phone:client:GetCalled', Target.PlayerData.source, Ply.PlayerData.charinfo.phone, CallId, AnonymousCall)
    end
end)

-- (qb-phone:server:BillingEmail removed: the server sends these mails itself, see notifyBillingSociety)

RegisterNetEvent('qb-phone:server:UpdateHashtags', function(Handle, messageData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or IsBurstLimited(src, 'hashtag', 3, 3000) then return end
    Handle = SanitizeText(Handle, 64)
    messageData = BuildTweet(Player, messageData)
    if not Handle or not messageData then return end
    if Hashtags[Handle] ~= nil and next(Hashtags[Handle]) ~= nil then
        Hashtags[Handle].messages[#Hashtags[Handle].messages + 1] = messageData
    else
        Hashtags[Handle] = {
            hashtag = Handle,
            messages = {}
        }
        Hashtags[Handle].messages[#Hashtags[Handle].messages + 1] = messageData
    end
    TriggerClientEvent('qb-phone:client:UpdateHashtags', -1, Handle, messageData)
end)

RegisterNetEvent('qb-phone:server:SetPhoneAlerts', function(app, alerts)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(app) ~= 'string' then return end
    QBPhone.SetPhoneAlerts(Player.PlayerData.citizenid, app, alerts)
end)

-- The tweet feed every phone shows is the server's own list (TWData, the recent rows of phone_tweets).
-- Posting used to broadcast the poster's whole client-side list to everyone, so a client could replace
-- every phone's feed with tweets in other people's names.
local MAX_FEED = 200

local function LoadTweets()
    if next(TWData) == nil then
        TWData = MySQL.query.await('SELECT * FROM phone_tweets WHERE `date` > NOW() - INTERVAL ? hour', { Config.TweetDuration }) or {}
    end
    return TWData
end

RegisterNetEvent('qb-phone:server:DeleteTweet', function(tweetId)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or type(tweetId) ~= 'string' then return end
    local Data = MySQL.scalar.await('SELECT citizenid FROM phone_tweets WHERE tweetId = ?', { tweetId })
    if Data ~= Player.PlayerData.citizenid then return end
    MySQL.query.await('DELETE FROM phone_tweets WHERE tweetId = ? AND citizenid = ?', { tweetId, Player.PlayerData.citizenid })
    local feed = LoadTweets()
    for i = #feed, 1, -1 do
        if feed[i].tweetId == tweetId then table.remove(feed, i) end
    end
    -- (this used to set the whole list to nil, and passed the arguments in the wrong order)
    TriggerClientEvent('qb-phone:client:UpdateTweets', -1, 0, feed, nil, true)
end)

RegisterNetEvent('qb-phone:server:UpdateTweets', function(_, TweetData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsRateLimited(src, 'tweet') then return end
    local tweet = BuildTweet(Player, TweetData)
    if not tweet then return end
    if not tweet.tweetId or MySQL.scalar.await('SELECT citizenid FROM phone_tweets WHERE tweetId = ?', { tweet.tweetId }) then
        tweet.tweetId = 'TWEET-' .. math.random(11111111, 99999999)
    end

    MySQL.insert('INSERT INTO phone_tweets (citizenid, firstName, lastName, message, date, url, picture, tweetid) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
        tweet.citizenid,
        tweet.firstName,
        tweet.lastName,
        tweet.message,
        tweet.time,
        tweet.url,
        tweet.picture,
        tweet.tweetId
    })
    local feed = LoadTweets()
    feed[#feed + 1] = tweet
    while #feed > MAX_FEED do table.remove(feed, 1) end
    TriggerClientEvent('qb-phone:client:UpdateTweets', -1, src, feed, tweet, false)
end)

RegisterNetEvent('qb-phone:server:TransferMoney', function(iban, amount)
    local src = source
    local ok, err = BankTransfer(src, iban, amount)
    if not ok then
        local text = err == 'no_account' and "This account number doesn't exist!"
            or err == 'insufficient_funds' and 'Not enough money in your bank account'
            or 'Invalid transfer!'
        TriggerClientEvent('QBCore:Notify', src, text, 'error')
    end
end)

RegisterNetEvent('qb-phone:server:EditContact', function(newName, newNumber, newIban, oldName, oldNumber, _)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    newName = SanitizeText(tostring(newName or ''), 64)
    newNumber = SanitizeText(tostring(newNumber or ''), 32)
    if not newName or not newNumber then return end
    newIban = newIban ~= nil and SanitizeText(tostring(newIban), 32) or nil
    -- citizenid match in the query enforces ownership
    MySQL.update(
        'UPDATE player_contacts SET name = ?, number = ?, iban = ? WHERE citizenid = ? AND name = ? AND number = ?',
        { newName, newNumber, newIban, Player.PlayerData.citizenid, oldName, oldNumber })
end)

RegisterNetEvent('qb-phone:server:RemoveContact', function(Name, Number)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- citizenid match in the query enforces ownership
    MySQL.query('DELETE FROM player_contacts WHERE name = ? AND number = ? AND citizenid = ?',
        { Name, Number, Player.PlayerData.citizenid })
end)

RegisterNetEvent('qb-phone:server:AddNewContact', function(name, number, iban)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsRateLimited(src, 'contact') then return end
    name = SanitizeText(tostring(name or ''), 64)
    number = SanitizeText(tostring(number or ''), 32)
    if not name or not number then return end
    iban = SanitizeText(tostring(iban or ''), 32) or ''
    MySQL.insert('INSERT INTO player_contacts (citizenid, name, number, iban) VALUES (?, ?, ?, ?)', { Player.PlayerData.citizenid, name, number, iban })
end)

RegisterNetEvent('qb-phone:server:UpdateMessages', function(ChatMessages, ChatNumber, _)
    local src = source
    local SenderData = exports['pfm-core']:GetPlayer(src)
    if not SenderData then return end
    if IsRateLimited(src, 'message') then return end
    if type(ChatMessages) ~= 'table' then return end
    if type(ChatNumber) ~= 'string' and type(ChatNumber) ~= 'number' then return end
    ChatNumber = tostring(ChatNumber)
    if ChatNumber == SenderData.PlayerData.charinfo.phone then return end
    -- the whole chat is stored for both people: keep it a sane size
    if EncodedSize(ChatMessages) > 60000 then return end
    -- sanitize every message body in the payload
    for _, day in pairs(ChatMessages) do
        if type(day) == 'table' and type(day.messages) == 'table' then
            for _, m in pairs(day.messages) do
                if type(m) == 'table' and type(m.message) == 'string' then
                    m.message = SanitizeText(m.message) or ''
                end
            end
        end
    end
    -- the holder of exactly that number (LIKE '%<number>%' wrote into the chats of whichever player's
    -- data happened to contain those digits)
    local row = FindPlayerRowByPhone(ChatNumber)
    local Player = { row }
    if Player[1] ~= nil then
        local TargetData = QBCore.Functions.GetPlayerByCitizenId(Player[1].citizenid)
        if TargetData ~= nil then
            local Chat = MySQL.query.await('SELECT * FROM phone_messages WHERE citizenid = ? AND number = ?', { SenderData.PlayerData.citizenid, ChatNumber })
            if Chat[1] ~= nil then
                -- Update for target
                MySQL.update('UPDATE phone_messages SET messages = ? WHERE citizenid = ? AND number = ?', { json.encode(ChatMessages), TargetData.PlayerData.citizenid, SenderData.PlayerData.charinfo.phone })
                -- Update for sender
                MySQL.update('UPDATE phone_messages SET messages = ? WHERE citizenid = ? AND number = ?', { json.encode(ChatMessages), SenderData.PlayerData.citizenid, TargetData.PlayerData.charinfo.phone })
                -- Send notification & Update messages for target
                TriggerClientEvent('qb-phone:client:UpdateMessages', TargetData.PlayerData.source, ChatMessages, SenderData.PlayerData.charinfo.phone, false)
            else
                -- Insert for target
                MySQL.insert('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { TargetData.PlayerData.citizenid, SenderData.PlayerData.charinfo.phone, json.encode(ChatMessages) })
                -- Insert for sender
                MySQL.insert('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { SenderData.PlayerData.citizenid, TargetData.PlayerData.charinfo.phone, json.encode(ChatMessages) })
                -- Send notification & Update messages for target
                TriggerClientEvent('qb-phone:client:UpdateMessages', TargetData.PlayerData.source, ChatMessages, SenderData.PlayerData.charinfo.phone, true)
            end
        else
            local Chat = MySQL.query.await('SELECT * FROM phone_messages WHERE citizenid = ? AND number = ?', { SenderData.PlayerData.citizenid, ChatNumber })
            if Chat[1] ~= nil then
                -- Update for target
                MySQL.update('UPDATE phone_messages SET messages = ? WHERE citizenid = ? AND number = ?', { json.encode(ChatMessages), Player[1].citizenid, SenderData.PlayerData.charinfo.phone })
                -- Update for sender
                Player[1].charinfo = json.decode(Player[1].charinfo)
                MySQL.update('UPDATE phone_messages SET messages = ? WHERE citizenid = ? AND number = ?', { json.encode(ChatMessages), SenderData.PlayerData.citizenid, Player[1].charinfo.phone })
            else
                -- Insert for target
                MySQL.insert('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { Player[1].citizenid, SenderData.PlayerData.charinfo.phone, json.encode(ChatMessages) })
                -- Insert for sender
                Player[1].charinfo = json.decode(Player[1].charinfo)
                MySQL.insert('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { SenderData.PlayerData.citizenid, Player[1].charinfo.phone, json.encode(ChatMessages) })
            end
        end
    end
end)

RegisterNetEvent('qb-phone:server:AddRecentCall', function(callType, data)
    local src = source
    local Ply = exports['pfm-core']:GetPlayer(src)
    -- (the first argument used to be named `type`, so type(data) below raised an error on every call)
    if not Ply or type(data) ~= 'table' or type(callType) ~= 'string' then return end
    local Hour = os.date('%H')
    local Minute = os.date('%M')
    local label = Hour .. ':' .. Minute
    TriggerClientEvent('qb-phone:client:AddRecentCall', src, data, label, callType)
    local Trgt = QBCore.Functions.GetPlayerByPhone(data.number)
    if Trgt ~= nil then
        TriggerClientEvent('qb-phone:client:AddRecentCall', Trgt.PlayerData.source, {
            name = Ply.PlayerData.charinfo.firstname .. ' ' .. Ply.PlayerData.charinfo.lastname,
            number = Ply.PlayerData.charinfo.phone,
            anonymous = data.anonymous
        }, label, 'outgoing')
    end
end)

RegisterNetEvent('qb-phone:server:CancelCall', function(ContactData)
    if type(ContactData) ~= 'table' or type(ContactData.TargetData) ~= 'table' then return end
    local Ply = QBCore.Functions.GetPlayerByPhone(ContactData.TargetData.number)
    if Ply ~= nil then
        TriggerClientEvent('qb-phone:client:CancelCall', Ply.PlayerData.source)
    end
end)

RegisterNetEvent('qb-phone:server:AnswerCall', function(CallData)
    if type(CallData) ~= 'table' or type(CallData.TargetData) ~= 'table' then return end
    local Ply = QBCore.Functions.GetPlayerByPhone(CallData.TargetData.number)
    if Ply ~= nil then
        TriggerClientEvent('qb-phone:client:AnswerCall', Ply.PlayerData.source)
    end
end)

RegisterNetEvent('qb-phone:server:SaveMetaData', function(MData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(MData) ~= 'table' then return end
    if #json.encode(MData) > 20000 then return end
    local result = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', { Player.PlayerData.citizenid })
    local MetaData = json.decode(result[1].metadata)
    MetaData.phone = MData
    MySQL.update('UPDATE players SET metadata = ? WHERE citizenid = ?',
        { json.encode(MetaData), Player.PlayerData.citizenid })
    Player.SetMetaData('phone', MData)
end)

RegisterNetEvent('qb-phone:server:GiveContactDetails', function(PlayerId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    PlayerId = tonumber(PlayerId)
    if not Player or not PlayerId or PlayerId == src or not exports['pfm-core']:GetPlayer(PlayerId) then return end
    -- handed to someone standing next to you (the client picks the closest player)
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(PlayerId))) > 5.0 then return end
    local SuggestionData = {
        name = {
            [1] = Player.PlayerData.charinfo.firstname,
            [2] = Player.PlayerData.charinfo.lastname
        },
        number = Player.PlayerData.charinfo.phone,
        bank = Player.PlayerData.charinfo.account
    }

    TriggerClientEvent('qb-phone:client:AddNewSuggestion', PlayerId, SuggestionData)
end)

RegisterNetEvent('qb-phone:server:AddTransaction', function(data)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(data) ~= 'table' then return end
    local title = SanitizeText(tostring(data.TransactionTitle or ''), 128)
    local message = SanitizeText(tostring(data.TransactionMessage or ''), 280)
    if not title or not message then return end
    MySQL.insert('INSERT INTO crypto_transactions (citizenid, title, message) VALUES (?, ?, ?)', {
        Player.PlayerData.citizenid,
        title,
        message
    })
end)

RegisterNetEvent('qb-phone:server:InstallApplication', function(ApplicationData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(ApplicationData) ~= 'table' or type(ApplicationData.app) ~= 'string' then return end
    -- only apps the store offers, stored as their name (the whole client table was saved in metadata)
    local app = ApplicationData.app
    if not (Config.StoreApps and Config.StoreApps[app]) then return end
    Player.PlayerData.metadata['phonedata'].InstalledApps[app] = { app = app }
    Player.SetMetaData('phonedata', Player.PlayerData.metadata['phonedata'])

    -- TriggerClientEvent('qb-phone:RefreshPhone', src)
end)

RegisterNetEvent('qb-phone:server:RemoveInstallation', function(App)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(App) ~= 'string' then return end
    Player.PlayerData.metadata['phonedata'].InstalledApps[App] = nil
    Player.SetMetaData('phonedata', Player.PlayerData.metadata['phonedata'])

    -- TriggerClientEvent('qb-phone:RefreshPhone', src)
end)

RegisterNetEvent('qb-phone:server:addImageToGallery', function(image)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsRateLimited(src, 'gallery') then return end
    image = SanitizeText(tostring(image or ''), 512)
    if not image then return end
    MySQL.insert('INSERT INTO phone_gallery (`citizenid`, `image`) VALUES (?, ?)', { Player.PlayerData.citizenid, image })
end)

RegisterNetEvent('qb-phone:server:getImageFromGallery', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local images = MySQL.query.await('SELECT * FROM phone_gallery WHERE citizenid = ? ORDER BY `date` DESC', { Player.PlayerData.citizenid })
    TriggerClientEvent('qb-phone:refreshImages', src, images)
end)

RegisterNetEvent('qb-phone:server:RemoveImageFromGallery', function(data)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(data) ~= 'table' then return end
    local image = data.image
    MySQL.query('DELETE FROM phone_gallery WHERE citizenid = ? AND image = ?', { Player.PlayerData.citizenid, image })
end)

RegisterNetEvent('qb-phone:server:sendPing', function(data)
    local src = source
    if src == data then
        TriggerClientEvent('QBCore:Notify', src, 'You cannot ping yourself', 'error')
    end
end)

-- Command

QBCore.Commands.Add('setmetadata', 'Set Player Metadata (God Only)', {}, false, function(source, args)
    local Player = exports['pfm-core']:GetPlayer(source)
    if args[1] then
        if args[1] == 'trucker' then
            if args[2] then
                local newrep = Player.PlayerData.metadata['jobrep']
                newrep.trucker = tonumber(args[2])
                Player.SetMetaData('jobrep', newrep)
            end
        end
    end
end, 'god')

QBCore.Commands.Add('bill', 'Bill A Player', { { name = 'id', help = 'Player ID' }, { name = 'amount', help = 'Fine Amount' } }, false, function(source, args)
    local biller = exports['pfm-core']:GetPlayer(source)
    local billed = exports['pfm-core']:GetPlayer(tonumber(args[1]))
    local amount = tonumber(args[2])
    if biller.PlayerData.job.name == 'police' or biller.PlayerData.job.name == 'ambulance' or biller.PlayerData.job.name == 'mechanic' then
        if billed ~= nil then
            if biller.PlayerData.citizenid ~= billed.PlayerData.citizenid then
                if amount and amount > 0 then
                    MySQL.insert(
                        'INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid) VALUES (?, ?, ?, ?, ?)',
                        { billed.PlayerData.citizenid, amount, biller.PlayerData.job.name,
                            biller.PlayerData.charinfo.firstname, biller.PlayerData.citizenid })
                    TriggerClientEvent('qb-phone:RefreshPhone', billed.PlayerData.source)
                    TriggerClientEvent('QBCore:Notify', source, 'Invoice Successfully Sent', 'success')
                    TriggerClientEvent('QBCore:Notify', billed.PlayerData.source, 'New Invoice Received')
                else
                    TriggerClientEvent('QBCore:Notify', source, 'Must Be A Valid Amount Above 0', 'error')
                end
            else
                TriggerClientEvent('QBCore:Notify', source, 'You Cannot Bill Yourself', 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', source, 'Player Not Online', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'No Access', 'error')
    end
end)
