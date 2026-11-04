local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')
local QBPhone = {}
local AppAlerts = {}
local MentionedTweets = {}
local Hashtags = {}
local Adverts = {}
local GeneratedPlates = {}
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

--- True when `host` is one of Config.ImageHosts or a subdomain of one.
local function AllowedImageHost(host)
    for _, allowed in ipairs(Config.ImageHosts or {}) do
        allowed = tostring(allowed):lower()
        if host == allowed or (#host > #allowed and host:sub(-#allowed - 1) == '.' .. allowed) then return true end
    end
    return false
end

--- A picture link the phone may show, or nil: https, on an allowed host, at most 512 characters and
--- without quotes, spaces, brackets, parentheses or backslashes, so it cannot leave an HTML attribute
--- or a CSS url() even where a page forgets to escape it.
local function SafeImageUrl(url)
    if type(url) ~= 'string' or #url > 512 then return nil end
    if url:find('[%c%s"\'<>()\\`{}]') then return nil end
    local host = url:match('^https://([%w%.%-]+)[/?#]') or url:match('^https://([%w%.%-]+)$')
    if not host or not AllowedImageHost(host:lower()) then return nil end
    return url
end
PFPhoneSafeImageUrl = SafeImageUrl

--- Does this player carry a phone? (The Functions table of a pfm-core player, called through pcall:
--- a method from another resource is a function reference.)
local function HasPhoneItem(Player)
    local fns = Player and Player.Functions
    if type(fns) ~= 'table' or fns.GetItemByName == nil then return false end
    local ok, item = pcall(function() return fns.GetItemByName('phone') end)
    return ok and item ~= nil
end

--- A stored profile picture as the phone may show it (rows saved before the check may hold anything).
local function CleanProfilePicture(picture)
    if picture == 'default' then return 'default' end
    return SafeImageUrl(picture) or 'default'
end

local function ProfilePicture(row)
    local ok, meta = pcall(json.decode, row and row.metadata or '')
    local picture = ok and type(meta) == 'table' and type(meta.phone) == 'table' and meta.phone.profilepicture
    return CleanProfilePicture(picture)
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
local function notifyBillingSociety(society, name, amount, paid)
    if type(society) ~= 'string' or society == '' then return end
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

-- ── calls ────────────────────────────────────────────────────────────
-- The server owns every call: who called whom, whether it rings or was answered, and its voice
-- channel, a random id the server picks and hands to pma-voice itself (pma-voice's
-- voice_serverCallsOnly keeps clients from joining a call channel on their own). Only the person
-- called can answer a ringing call, and only the two people in a call can end it. The clients used
-- to send the call id (worked out from both phone numbers), the number to answer or hang up and
-- their own "in a call" flag, so anyone could hang up anyone's call, make a ringing phone answer by
-- itself and listen in, or join any call's voice channel.
-- ActiveCalls[id] = { id, caller, target (sources), callerNumber, targetNumber, anonymous,
--                     state = 'ringing' | 'ongoing' }; CallOf[source] = id
local ActiveCalls = {}
local CallOf = {}
-- a call nobody answers is ended a little after both phones stopped ringing
local CALL_RING_MS = ((tonumber(Config.CallRepeats) or 10) + 2) * (tonumber(Config.RepeatTimeout) or 2000)

PFPhoneCalls = PFPhoneCalls or {}
function PFPhoneCalls.Get(id) return ActiveCalls[id] end
function PFPhoneCalls.Of(src) return CallOf[src] end

local function NewCallId()
    for _ = 1, 50 do
        local id = math.random(100000, 2147483646)
        if not ActiveCalls[id] then return id end
    end
end

--- Puts the player in the voice channel of a call (0: out of any call), through pma-voice's server export.
local function SetVoiceCall(src, channel)
    if GetResourceState('pma-voice') ~= 'started' then return false end
    local ok, err = pcall(function() exports['pma-voice']:setPlayerCall(src, channel) end)
    if not ok then print(('^1[pfm-phone]^7 pma-voice setPlayerCall(%s, %s) failed: %s'):format(tostring(src), tostring(channel), tostring(err))) end
    return ok
end

--- The call `src` is in, when callId is that call or not given (a stale id from an older call is
--- ignored, so it cannot end a newer one).
local function CallFor(src, callId)
    local id = CallOf[src]
    local call = id and ActiveCalls[id]
    if not call then return nil end
    local wanted = type(callId) == 'number' and math.tointeger(callId) or nil
    if type(callId) == 'number' and wanted ~= id then return nil end
    return call
end

--- Ends a call for both people. endedBy: the source that ended it (it is not sent its own hang-up);
--- gone: that source has left the server (nothing is sent to it).
local function EndCall(id, endedBy, gone)
    local call = ActiveCalls[id]
    if not call then return false end
    ActiveCalls[id] = nil
    local answered = call.state == 'ongoing'
    for _, src in ipairs({ call.caller, call.target }) do
        if CallOf[src] == id then CallOf[src] = nil end
        if not (gone and src == endedBy) then
            if answered then SetVoiceCall(src, 0) end
            if src ~= endedBy then TriggerClientEvent('qb-phone:client:CancelCall', src) end
        end
    end
    -- the recent-call lists, from the server's record (clients used to report these for any number)
    local at = os.date('%H:%M', os.time())
    if not (gone and endedBy == call.caller) then
        TriggerClientEvent('qb-phone:client:AddRecentCall', call.caller, { number = call.targetNumber, anonymous = false }, at, 'outgoing')
    end
    if not (gone and endedBy == call.target) then
        TriggerClientEvent('qb-phone:client:AddRecentCall', call.target,
            { number = (not call.anonymous) and call.callerNumber or nil, anonymous = call.anonymous }, at, answered and 'incoming' or 'missed')
    end
    return true
end
PFPhoneCalls.End = EndCall

--- Starts a call from `src` to the holder of `number`. Returns the call id, or nil and a reason.
local function StartCall(src, number, anonymous)
    local Caller = exports['pfm-core']:GetPlayer(src)
    if not Caller or not IsPhoneNumber(number) then return nil, 'invalid' end
    number = tostring(number)
    local callerNumber = tostring(Caller.PlayerData.charinfo and Caller.PlayerData.charinfo.phone or '')
    if CallOf[src] then return nil, 'in_call' end
    if not HasPhoneItem(Caller) then return nil, 'no_phone' end
    if number == callerNumber then return nil, 'self' end
    local Target = QBCore.Functions.GetPlayerByPhone(number)
    local tgt = Target and tonumber(Target.PlayerData.source)
    if not tgt or tgt == src or not HasPhoneItem(Target) then return nil, 'unavailable' end
    if CallOf[tgt] then return nil, 'busy' end
    local id = NewCallId()
    if not id then return nil, 'unavailable' end
    anonymous = anonymous == true
    ActiveCalls[id] = { id = id, caller = src, target = tgt, callerNumber = callerNumber, targetNumber = number, anonymous = anonymous, state = 'ringing' }
    CallOf[src], CallOf[tgt] = id, id
    TriggerClientEvent('qb-phone:client:CallStarted', src, id)
    -- an anonymous caller's number never reaches the phone being called
    TriggerClientEvent('qb-phone:client:GetCalled', tgt, (not anonymous) and callerNumber or nil, id, anonymous)
    SetTimeout(CALL_RING_MS, function()
        local call = ActiveCalls[id]
        if call and call.state == 'ringing' then EndCall(id, nil) end
    end)
    return id
end
PFPhoneCalls.Start = StartCall

--- The person called answers: both are put in the call's voice channel by the server.
local function AnswerCall(src, callId)
    local call = CallFor(src, callId)
    if not call or call.target ~= src or call.state ~= 'ringing' then return false end
    if not HasPhoneItem(exports['pfm-core']:GetPlayer(src)) then return false end
    call.state = 'ongoing'
    SetVoiceCall(call.caller, call.id)
    SetVoiceCall(call.target, call.id)
    TriggerClientEvent('qb-phone:client:AnswerCall', call.caller)
    return true
end
PFPhoneCalls.Answer = AnswerCall

local function EndCallOf(src, gone)
    local id = CallOf[src]
    if id then EndCall(id, src, gone) end
end

AddEventHandler('playerDropped', function()
    EndCallOf(tonumber(source), true)
end)

-- a logout (character switch) ends the call too: the next character must not be in it
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = tonumber(src)
    if src then EndCallOf(src, false) end
end)

-- ── chats ────────────────────────────────────────────────────────────
-- Each person's copy of a chat is a row of phone_messages: a list of days { date = 'D-M-YYYY' (month
-- from 0, as the phone writes it), messages = { { sender, type, message, time, data } } }. Every
-- message is built here (sender, time, location and text from the server) and appended to both
-- rows. The client used to send the whole chat, which overwrote both people's rows: a sender could
-- rewrite or delete the other person's messages, add messages in their name, and put HTML into
-- fields the phone showed unescaped (a message that moved the reader's money when opened).
local CHAT_TYPES = { message = true, location = true, picture = true }
local MAX_CHAT_DAYS = 30
local MAX_CHAT_MESSAGES = 200
local MAX_CHAT_BYTES = 60000 -- phone_messages.messages is a TEXT column (64 KB)
local ChatLocks = {} -- ['<number>|<number>'] = true while a message between the two is written

local function ChatDateKey()
    local d = os.date('*t', os.time())
    return ('%d-%d-%d'):format(d.day, d.month - 1, d.year)
end

--- A stored message as the phone may show it, or nil (rows written before this check may hold anything).
local function CleanChatMessage(m)
    if type(m) ~= 'table' or not CHAT_TYPES[m.type] then return nil end
    local sender = m.sender
    if type(sender) ~= 'string' or #sender > 50 or not sender:match('^[%w]+$') then return nil end
    local time = type(m.time) == 'string' and m.time:match('^%d%d?:%d%d$') and m.time or ''
    local data = type(m.data) == 'table' and m.data or {}
    local out = { sender = sender, type = m.type, time = time, data = {} }
    if m.type == 'message' then
        out.message = SanitizeText(m.message, 1000)
        if not out.message then return nil end
    elseif m.type == 'location' then
        local x, y = tonumber(data.x), tonumber(data.y)
        if not x or not y or x ~= x or y ~= y or math.abs(x) > 100000 or math.abs(y) > 100000 then return nil end
        out.message, out.data = 'Shared Location', { x = Round(x, 2), y = Round(y, 2) }
    else
        local url = SafeImageUrl(data.url)
        if not url then return nil end
        out.message, out.data = 'Photo', { url = url }
    end
    return out
end

local function CleanChat(days)
    local out = {}
    if type(days) ~= 'table' then return out end
    for _, day in ipairs(days) do
        if type(day) == 'table' and type(day.date) == 'string' and day.date:match('^%d%d?%-%d%d?%-%d%d%d%d$') and type(day.messages) == 'table' then
            local msgs = {}
            for _, m in ipairs(day.messages) do
                local clean = CleanChatMessage(m)
                if clean then msgs[#msgs + 1] = clean end
            end
            if #msgs > 0 then out[#out + 1] = { date = day.date, messages = msgs } end
        end
    end
    return out
end
PFPhoneCleanChat = CleanChat

--- Drops the oldest messages until the chat fits (days, messages, bytes). Returns the JSON to store.
local function CapChat(days)
    while #days > MAX_CHAT_DAYS do table.remove(days, 1) end
    local function dropOldest(n)
        while n > 0 and #days > 0 do
            table.remove(days[1].messages, 1)
            if #days[1].messages == 0 then table.remove(days, 1) end
            n = n - 1
        end
    end
    local total = 0
    for _, d in ipairs(days) do total = total + #d.messages end
    if total > MAX_CHAT_MESSAGES then dropOldest(total - MAX_CHAT_MESSAGES) end
    local encoded = json.encode(days)
    while #encoded > MAX_CHAT_BYTES and #days > 0 do
        dropOldest(math.ceil((#encoded - MAX_CHAT_BYTES) / 300) + 1)
        encoded = json.encode(days)
    end
    return encoded
end

local function AppendChatMessage(days, dateKey, msg)
    for i = #days, 1, -1 do
        if days[i].date == dateKey then
            days[i].messages[#days[i].messages + 1] = msg
            return
        end
    end
    days[#days + 1] = { date = dateKey, messages = { msg } }
end

--- One person's copy of a chat: its row id (nil: none yet) and its cleaned days. The newest row wins
--- when an older version of the phone left two.
local function ReadChat(cid, number)
    local rows = MySQL.query.await('SELECT id, messages FROM phone_messages WHERE citizenid = ? AND number = ? ORDER BY id DESC LIMIT 1', { cid, number })
    local row = type(rows) == 'table' and rows[1] or nil
    if not row then return nil, {} end
    local ok, decoded = pcall(json.decode, row.messages or '')
    return row.id, CleanChat(ok and decoded or nil)
end

local function WriteChat(rowId, cid, number, encoded)
    if rowId then
        MySQL.update.await('UPDATE phone_messages SET messages = ? WHERE id = ?', { encoded, rowId })
    else
        MySQL.insert.await('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { cid, number, encoded })
    end
end

--- The message the server stores for a chat payload { type, message, url }, or nil.
local function BuildChatMessage(src, Sender, payload)
    if type(payload) ~= 'table' or not CHAT_TYPES[payload.type] then return nil end
    local msg = { sender = Sender.PlayerData.citizenid, type = payload.type, time = os.date('%H:%M', os.time()), data = {} }
    if payload.type == 'message' then
        msg.message = SanitizeText(payload.message, Config.MaxContentLength or 280)
        if not msg.message then return nil end
    elseif payload.type == 'location' then
        -- where the sender stands, from the server
        local c = GetEntityCoords(GetPlayerPed(src))
        msg.message, msg.data = 'Shared Location', { x = Round(c.x, 2), y = Round(c.y, 2) }
    else
        local url = SafeImageUrl(payload.url)
        if not url then return nil, 'bad_picture' end
        msg.message, msg.data = 'Photo', { url = url }
    end
    return msg
end

local function PhoneNotify(src, text)
    TriggerClientEvent('qb-phone:client:CustomNotification', src, 'Whatsapp', text, 'fab fa-whatsapp', '#25D366', 2500)
end

--- Appends one message to both copies of the chat between `src` and `number` and sends it to both
--- phones. Returns true, or false and a reason.
local function SendChatMessage(src, number, payload)
    local Sender = exports['pfm-core']:GetPlayer(src)
    if not Sender or not IsPhoneNumber(number) then return false, 'invalid' end
    number = tostring(number)
    local cid = Sender.PlayerData.citizenid
    local myNumber = tostring(Sender.PlayerData.charinfo and Sender.PlayerData.charinfo.phone or '')
    if myNumber == '' or number == myNumber then return false, 'invalid' end
    if not HasPhoneItem(Sender) then return false, 'no_phone' end
    local msg, why = BuildChatMessage(src, Sender, payload)
    if not msg then return false, why or 'invalid' end
    -- one write per pair at a time, taken before the first database wait: both rows are read,
    -- appended to and written back, and a second message meanwhile would overwrite the first
    local lockKey = number < myNumber and (number .. '|' .. myNumber) or (myNumber .. '|' .. number)
    local locked = false
    for _ = 1, 100 do
        if not ChatLocks[lockKey] then
            ChatLocks[lockKey] = true
            locked = true
            break
        end
        Wait(20)
    end
    if not locked then return false, 'busy' end
    local ok, sent, err = pcall(function()
        local Target = QBCore.Functions.GetPlayerByPhone(number)
        local targetCid = Target and Target.PlayerData.citizenid
        if not targetCid then
            local row = FindPlayerRowByPhone(number)
            targetCid = row and row.citizenid
        end
        if type(targetCid) ~= 'string' or targetCid == cid then return false, 'no_number' end
        local dateKey = ChatDateKey()
        local myRow, myDays = ReadChat(cid, number)
        local theirRow, theirDays = ReadChat(targetCid, myNumber)
        AppendChatMessage(myDays, dateKey, msg)
        AppendChatMessage(theirDays, dateKey, msg)
        WriteChat(myRow, cid, number, CapChat(myDays))
        WriteChat(theirRow, targetCid, myNumber, CapChat(theirDays))
        TriggerClientEvent('qb-phone:client:ChatMessage', src, number, dateKey, msg, true)
        -- the receiver's online phone, found again after the database waits (they may have left)
        local Now = QBCore.Functions.GetPlayerByCitizenId(targetCid)
        if Now and tostring(Now.PlayerData.charinfo and Now.PlayerData.charinfo.phone or '') == number then
            TriggerClientEvent('qb-phone:client:ChatMessage', Now.PlayerData.source, myNumber, dateKey, msg, false)
        end
        return true
    end)
    ChatLocks[lockKey] = nil
    if not ok then
        print(('^1[pfm-phone]^7 sending a chat message failed: %s'):format(tostring(sent)))
        return false, 'server_error'
    end
    return sent, err
end
PFPhoneChats = { Send = SendChatMessage, Clean = CleanChat }

-- ── phone settings ───────────────────────────────────────────────────
--- The phone settings a client may store (metadata.phone): a built-in background name or a picture
--- link, and 'default' or a picture link as the avatar. A field the client sends that is not valid
--- keeps its stored value. (The whole client table used to be stored and the avatar was shown to
--- other players inside an unescaped style attribute.)
local function CleanPhoneMeta(MData, current)
    current = type(current) == 'table' and current or {}
    -- rejected: the player asked for a new value that is not allowed (an old stored value the
    -- phone sends back with every save is kept quietly, as its cleaned form)
    local out, rejected = {}, false
    local bg = MData.background
    if bg ~= nil then
        if type(bg) == 'string' and ((#bg <= 64 and bg:match('^[%w_%-]+$')) or SafeImageUrl(bg)) then out.background = bg
        elseif bg ~= current.background then rejected = true end
    end
    local pic = MData.profilepicture
    if pic ~= nil then
        if pic == 'default' or SafeImageUrl(pic) then out.profilepicture = pic
        elseif pic ~= current.profilepicture then rejected = true end
    end
    if out.background == nil and type(current.background) == 'string' and ((#current.background <= 64 and current.background:match('^[%w_%-]+$')) or SafeImageUrl(current.background)) then
        out.background = current.background
    end
    if out.profilepicture == nil and current.profilepicture ~= nil then out.profilepicture = CleanProfilePicture(current.profilepicture) end
    return out, rejected
end
-- Callbacks

QBCore.Functions.CreateCallback('qb-phone:server:GetInvoices', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)

    if Player then
        -- a 'paying' invoice was paid (or is being charged) and is only waiting to be settled: not listed
        local invoices = {}
        for _, v in ipairs(MySQL.query.await('SELECT * FROM phone_invoices WHERE citizenid = ?', { Player.PlayerData.citizenid }) or {}) do
            if v.pay_state ~= 'paying' then invoices[#invoices + 1] = v end
        end
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
        for _, v in pairs(invoices) do v.ledger_token, v.pay_state, v.ref = nil, nil, nil end -- server-side bookkeeping only
        cb(invoices)
        return
    end

    cb({})
end)

-- CanCall, IsOnline for the number the phone wants to call, from the server's own call table (see
-- the calls section below; it used to read an "in a call" flag each client set for itself).
QBCore.Functions.CreateCallback('qb-phone:server:GetCallState', function(_, cb, ContactData)
    if type(ContactData) ~= 'table' or not IsPhoneNumber(ContactData.number) then return cb(false, false) end
    local Target = QBCore.Functions.GetPlayerByPhone(tostring(ContactData.number))
    if not Target or not HasPhoneItem(Target) then return cb(false, false) end
    if CallOf[Target.PlayerData.source] then return cb(false, true) end
    cb(true, true)
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

        -- chats are cleaned as they are read (rows written before the server built every message may
        -- hold forged senders or HTML); one chat per number, the newest row when there are two
        local messages = MySQL.query.await('SELECT id, number, messages FROM phone_messages WHERE citizenid = ? ORDER BY id', { Player.PlayerData.citizenid })
        local byNumber, order = {}, {}
        for _, row in ipairs(type(messages) == 'table' and messages or {}) do
            if IsPhoneNumber(row.number) then
                local number = tostring(row.number)
                local ok, decoded = pcall(json.decode, row.messages or '')
                if not byNumber[number] then order[#order + 1] = number end
                byNumber[number] = { number = number, messages = json.encode(CleanChat(ok and decoded or nil)) }
            end
        end
        for _, number in ipairs(order) do PhoneData.Chats[#PhoneData.Chats + 1] = byNumber[number] end

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
-- any player; the commission was also paid before the payment was checked.) The phone, the tablet
-- and the computer (pf-citizen's Bills app, through the PayInvoice export) all pay through
-- PayInvoice below.
--
-- How an invoice is paid exactly once. Each step is a ledger transfer on numbered keys of its own:
--   1. the charge, payer bank -> system:pfm-phone:  <base>:bank, <base>:retry<n>:bank
--   2. the business, system:pfm-phone -> society:   <base>:society, <base>:society:retry<n>
--   3. the biller's commission (Config.BillingCommissions): <base>:commission, <base>:commission:retry<n>
--   4. the row is deleted; the request that deleted it sends the paid events and mails.
-- A transfer that ended without moving money (failed, or compensated: refunded) stays spent in the
-- ledger, so the next attempt of that step uses the next number; there is no attempt limit. A
-- transfer the ledger has not settled (pending, debited, or failed with 'interrupted_unverified':
-- recovery could not tell whether an online payer's money left before a crash) is never repeated
-- under a new key: that step waits until the ledger, or an admin reconciling it, settles it. (An
-- admin who finds the money never left gives that transfer another error, e.g. 'checked_not_taken',
-- and the next payment uses the next key; one who finds it left sets it 'debited', and the ledger's
-- recovery completes it, which counts as the payment.)
--
-- Half-paid invoices. Before the charge the row is marked pay_state = 'paying'. A 'paying' invoice
-- is hidden from the phone, cannot be declined, and is finished by PFPhoneInvoices.Sweep (on start
-- and every two minutes) or by the next payment request: once its charge is completed the missing
-- payouts are made and the row is deleted; once no attempt can have moved money it is open again.
-- So a crash at any point leaves an open invoice (nothing charged) or a 'paying' one that is
-- finished later: the money taken from the payer waits in system:pfm-phone until the business is
-- credited, and nothing is paid twice. Without the pay_state column (it could not be added) the
-- row stays listed instead, and paying it again finishes it the same way. The sweep goes through
-- the 'paying' rows page by page and goes on where it stopped, so rows that wait for good (an
-- unverified charge nobody has settled yet; it prints one console warning per invoice) never keep
-- it from later ones. A payer is never charged for a business the bank says cannot hold money
-- (unknown_society); one whose account goes after the charge stays 'paying' until it is back.
-- All of it runs under the invoice's lock (citizenid:id, the id as an integer), taken before the
-- first database wait, so a payment, a decline and the sweep of one invoice never overlap.
--
-- <base> comes from the invoice's ledger_token, a unique token stored with it
-- (pfm-phone:invoice:tok:<token>). Invoice ids can come back (a truncated table, or MySQL before
-- 8.0 resetting AUTO_INCREMENT on a restart), and a new invoice under an old id would otherwise
-- find the old invoice's charge and count as paid. A row without a token (from before the column,
-- or inserted directly by another resource on a database without the UUID() default) is first
-- checked against its id keys pfm-phone:invoice:<id>: a charge of the same payer and amount there
-- (completed, or not settled) keeps the row on those keys, so it is never charged twice; otherwise
-- it gets a token before it is charged. On id keys the payouts of a charge are the transfers the
-- ledger stored on the payout keys after that charge (pf_transactions.id): an older invoice's
-- payouts under the same id came before it and are skipped, so this invoice's are made on the next
-- numbers, and none is ever made twice. (A reused id whose older invoice had the same payer and
-- amount cannot be told apart from this one being paid already: it counts as paid, with no money
-- moved. That needs a row without a token, a reused id, and the same payer and amount.)

local SWEEP_INTERVAL_MS = 120000
local SWEEP_BATCH = 50
local SWEEP_MAX_BACKOFF_MS = 1800000

-- [step|base] = { n = first attempt not known to be spent, lastErr = error of the attempt before it }.
-- A hint only: after a restart the walk starts at 1 again and skips the spent keys it finds.
local AttemptHints = {}
local SweepBackoff = {} -- [invoice id] = { at = game timer, delay = ms, warned = true }: see the sweep

-- ledger errors returned before anything is written: the key is still unused
local REFUSED_BEFORE_WRITE = {
    insufficient_funds = true, invalid_request = true, invalid_account = true, same_account = true,
    invalid_amount = true, invalid_key = true, ledger_unavailable = true,
}

local function TokenOk(token)
    return type(token) == 'string' and token ~= '' and #token <= 40 and token:match('^[%w%-_.]+$') ~= nil
end

--- An invoice id as a positive integer, or nil. 5 and 5.0 are the same invoice: they must build the
--- same lock key, or a decline sent as 5.0 could run while a payment of 5 holds the lock.
local function InvoiceIdOf(v)
    local n = tonumber(v)
    n = n and math.tointeger(n)
    if not n or n < 1 then return nil end
    return n
end

--- The ledger key base of an invoice row and whether it is keyed by id (no usable token).
local function InvoiceKeyBase(invoice)
    if TokenOk(invoice.ledger_token) then return 'pfm-phone:invoice:tok:' .. invoice.ledger_token, false end
    return 'pfm-phone:invoice:' .. tostring(invoice.id), true
end

local function AttemptKey(first, n) return n == 1 and first or (first .. ':retry' .. n) end
local function ChargeKeys(base) return function(n) return AttemptKey(base, n) .. ':bank' end end

local function Affected(res)
    return type(res) == 'table' and (tonumber(res.affectedRows) or 0) or (tonumber(res) or 0)
end

local function SameAmount(a, b) return math.abs((tonumber(a) or -1) - (tonumber(b) or -2)) < 0.005 end

--- For a row keyed by id: whether a stored transfer is this invoice's (an older invoice under the
--- same id may have used the key; it went from or to other accounts, or was for another amount).
--- afterId (payouts): the ledger row id of the charge they pay out. A payout stored after it is this
--- charge's, whatever its account or amount (so it is never made twice); one stored before it is an
--- older invoice's. Without row ids the account and amount decide.
local function IdKeyMatch(byId, field, account, amount, afterId)
    if not byId then return nil end
    return function(tx)
        local rowId = tonumber(tx.id)
        if afterId and rowId then return rowId > afterId end
        return tx[field] == account and SameAmount(tx.amount, amount)
    end
end

local function PayerAccount(invoice) return ('player:%s:bank'):format(invoice.citizenid) end

--- False only when the bank says the society cannot hold money (not a job, gang or existing account).
--- A bank that cannot answer is not a refusal: the charge then decides.
local function SocietyKnown(society)
    local ok, known = pcall(function() return exports['pfm-banking']:EnsureSocietyAccount(society) end)
    return not (ok and known == false)
end

--- What a stored transfer means for its step: 'done', 'spent' (ended without moving money: the next
--- attempt key may be used) or 'wait' (not settled; see the header).
local function TxOutcome(state, err)
    if state == 'completed' then return 'done' end
    if state == 'compensated' then return 'spent' end
    if state == 'failed' then return err == 'interrupted_unverified' and 'wait' or 'spent' end
    return 'wait' -- pending, debited
end

--- Where one step of an invoice stands: 'free' plus the attempt number to use and the error of the
--- spent attempt before it; 'done' or 'wait' plus the attempt number, its error and the stored
--- transfer; or 'error' when the ledger cannot be read.
local function WalkStep(hint, keyOf, isOurs)
    local h = AttemptHints[hint]
    local n, lastErr = h and h.n or 1, h and h.lastErr or nil
    for _ = 1, 100000 do -- only a broken ledger lookup gets this far
        local ok, tx = pcall(function() return exports['pfm-banking']:GetTransaction(keyOf(n)) end)
        if not ok then return 'error' end
        if type(tx) ~= 'table' then
            AttemptHints[hint] = { n = n, lastErr = lastErr }
            return 'free', n, lastErr
        end
        local outcome = 'spent'
        if not isOurs or isOurs(tx) then
            outcome = TxOutcome(tx.state, tx.error)
            lastErr = tx.error
        end
        if outcome ~= 'spent' then return outcome, n, tx.error, tx end
        n = n + 1
    end
    return 'error'
end

local function ForgetHints(base)
    AttemptHints['charge|' .. base], AttemptHints['society|' .. base], AttemptHints['commission|' .. base] = nil, nil, nil
end

-- phone_invoices.ledger_token and pay_state on servers that imported qb-phone.sql before the columns
-- existed. Each step runs only when information_schema shows it is missing, so a restart repeats
-- nothing:
--   1. ledger_token, NULL on the rows already there (they are checked against their id keys);
--   2. pay_state, NULL (open) on every row;
--   3. ledger_token's default UUID(), so invoices other resources insert without a token get a
--      unique one as well. Best effort: a database without expression defaults (MySQL before
--      8.0.13) keeps NULL there, and such rows get a token when they are first paid.
-- Without ledger_token new invoices use id keys (as before); without pay_state a half-paid invoice
-- stays listed and is finished when it is paid again, not by the sweep. A failed check is retried
-- at most once a minute, not on every invoice.
--   4. ref (batch 15H), NULL on every row, and its unique index uq_phone_invoices_ref: the caller's
--      idempotency reference (CreateInvoice data.ref). Without both, an invoice asked for with a
--      ref is refused (it could not be kept from being created twice); invoices without one work.
local COLUMNS_SQL = [[SELECT COLUMN_NAME AS name, COLUMN_DEFAULT AS def FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_invoices' AND COLUMN_NAME IN ('ledger_token', 'pay_state', 'ref')]]
local REF_INDEX_SQL = [[SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_invoices' AND INDEX_NAME = 'uq_phone_invoices_ref' AND NON_UNIQUE = 0]]
local COLUMN_RETRY_MS = 60000
local Columns = { token = false, payState = false, ref = false, checking = false, failedAt = nil }

--- hasToken, tokenHasUuidDefault, hasPayState, hasRef, hasRefIndex
local function ReadColumns()
    local found = {}
    for _, r in ipairs(MySQL.query.await(COLUMNS_SQL) or {}) do found[tostring(r.name)] = r end
    local tok = found.ledger_token
    local refIndex = found.ref ~= nil and (tonumber(MySQL.scalar.await(REF_INDEX_SQL)) or 0) > 0
    return tok ~= nil, tok ~= nil and tostring(tok.def or ''):lower():find('uuid', 1, true) ~= nil, found.pay_state ~= nil,
        found.ref ~= nil, refIndex
end

local function EnsureInvoiceColumns()
    if Columns.token and Columns.payState and Columns.ref then return end
    for _ = 1, 100 do -- another caller is checking: wait for its answer (at most ~5 s)
        if not Columns.checking then break end
        Wait(50)
    end
    if (Columns.token and Columns.payState and Columns.ref) or Columns.checking then return end
    if Columns.failedAt and GetGameTimer() - Columns.failedAt < COLUMN_RETRY_MS then return end
    Columns.checking = true
    local problem
    local okRead, token, uuidDefault, payState, ref, refIndex = pcall(ReadColumns)
    if okRead and not (token and payState and ref and refIndex) then
        if not token then
            local ok, err = pcall(MySQL.query.await, 'ALTER TABLE `phone_invoices` ADD COLUMN `ledger_token` VARCHAR(40) NULL DEFAULT NULL')
            if not ok then problem = tostring(err) end
        end
        if not payState then
            local ok, err = pcall(MySQL.query.await, 'ALTER TABLE `phone_invoices` ADD COLUMN `pay_state` VARCHAR(16) NULL DEFAULT NULL')
            if not ok then problem = tostring(err) end
        end
        if not ref then
            local ok, err = pcall(MySQL.query.await, 'ALTER TABLE phone_invoices ADD COLUMN ref VARCHAR(128) NULL DEFAULT NULL')
            if not ok then problem = tostring(err) end
        end
        if not refIndex then
            -- NULLs never collide, so the rows already there (all NULL) cannot block the index
            local ok, err = pcall(MySQL.query.await, 'CREATE UNIQUE INDEX uq_phone_invoices_ref ON phone_invoices (ref)')
            if not ok then problem = tostring(err) end
        end
        -- read again either way: another server sharing the database may have added them meanwhile
        okRead, token, uuidDefault, payState, ref, refIndex = pcall(ReadColumns)
    end
    if not okRead then
        problem = tostring(token)
        token, uuidDefault, payState, ref, refIndex = false, false, false, false, false
    end
    if token and not uuidDefault then
        local ok, err = pcall(MySQL.query.await, 'ALTER TABLE `phone_invoices` ALTER COLUMN `ledger_token` SET DEFAULT (UUID())')
        if not ok then
            print(('^3[pfm-phone]^7 phone_invoices.ledger_token has no UUID() default (%s): invoices other resources insert directly get their token when they are paid'):format(tostring(err)))
        end
    end
    Columns.token, Columns.payState, Columns.checking = token == true, payState == true, false
    Columns.ref = ref == true and refIndex == true
    Columns.failedAt = not (Columns.token and Columns.payState and Columns.ref) and GetGameTimer() or nil
    if not Columns.token then
        print(('^1[pfm-phone]^7 phone_invoices.ledger_token is missing and could not be added (%s): invoices use id-based ledger keys; add the column from qb-phone.sql')
            :format(problem or 'not listed after ALTER'))
    end
    if not Columns.payState then
        print(('^1[pfm-phone]^7 phone_invoices.pay_state is missing and could not be added (%s): half-paid invoices are finished only when paid again; add the column from qb-phone.sql')
            :format(problem or 'not listed after ALTER'))
    end
    if not Columns.ref then
        print(('^1[pfm-phone]^7 phone_invoices.ref or its unique index uq_phone_invoices_ref is missing and could not be added (%s): invoices asked for with a ref are refused; add them from qb-phone.sql')
            :format(problem or 'not listed after ALTER'))
    end
end
CreateThread(EnsureInvoiceColumns)

local function LoadInvoice(invoiceId, cid)
    local rows = MySQL.query.await('SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', { invoiceId, cid })
    return rows and rows[1] or nil
end

--- The invoice as other resources see it (the ledger token and pay state are bookkeeping).
local function PublicInvoice(invoice)
    local out = {}
    for k, v in pairs(invoice) do
        if k ~= 'ledger_token' and k ~= 'pay_state' then out[k] = v end
    end
    return out
end

--- Marks the invoice 'paying' (see the header). True when it is marked, or when the column is missing.
local function MarkPaying(invoice)
    if not Columns.payState or invoice.pay_state == 'paying' then return true end
    local ok, res = pcall(MySQL.update.await, "UPDATE phone_invoices SET pay_state = 'paying' WHERE id = ? AND citizenid = ? AND pay_state IS NULL",
        { invoice.id, invoice.citizenid })
    if not ok or Affected(res) ~= 1 then return false end
    invoice.pay_state = 'paying'
    return true
end

--- Opens a 'paying' invoice again: no attempt of its charge moved money.
local function Reopen(invoice)
    if not Columns.payState or invoice.pay_state ~= 'paying' then return end
    local ok = pcall(MySQL.update.await, "UPDATE phone_invoices SET pay_state = NULL WHERE id = ? AND citizenid = ? AND pay_state = 'paying'",
        { invoice.id, invoice.citizenid })
    if ok then invoice.pay_state = nil end
end

--- The payer's source (when online) and name, for the events and mails of a settled invoice.
--- (A deleted character's 'paying' invoice is kept by pfm-core and settled by the sweep: paying the
--- business does not need the payer. Its mails then name 'a former resident'.)
local function PayerOf(cid, Ply)
    Ply = Ply or exports['pfm-core']:GetPlayerByCitizenId(cid)
    local info = Ply and Ply.PlayerData.charinfo
    if not info then
        local ok, raw = pcall(MySQL.scalar.await, 'SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1', { cid })
        local okDecode, decoded = pcall(json.decode, ok and raw or '')
        info = okDecode and type(decoded) == 'table' and decoded or {}
    end
    local name = ('%s %s'):format(tostring(info.firstname or ''), tostring(info.lastname or '')):match('^%s*(.-)%s*$')
    return { src = Ply and Ply.PlayerData.source or nil, name = name ~= '' and name or 'a former resident' }
end

--- False only when the database answers that the character no longer exists.
local function CharacterExists(cid)
    local ok, n = pcall(MySQL.scalar.await, 'SELECT COUNT(*) FROM players WHERE citizenid = ?', { cid })
    if not ok or n == nil then return true end
    return (tonumber(n) or 1) > 0
end

--- Stores a new invoice with its own ledger token. Every invoice pfm-phone creates goes through here.
--- data: { citizenid, amount, society, sender, sendercitizenid, candecline (optional, default 1), reason (optional),
---        ref (optional, 1..128 of [A-Za-z0-9-_:.]) }
--- Returns the invoice id, or nil and an error code. A society the bank says cannot hold money
--- (not a job, gang or existing account) is refused: its invoices could be charged but never settled.
---
--- ref is the caller's idempotency reference (e.g. 'pf-justice:order:12'): while an invoice with that
--- ref exists, a second call returns its id and 'duplicate' instead of creating another (also when
--- two calls race: the unique index uq_phone_invoices_ref lets one insert win). The same ref with a
--- different citizen, society or amount returns nil, 'key_reused'. A paid or declined invoice is
--- deleted as before, so its ref is free again afterwards: the caller learns the outcome from
--- pfm-phone:server:invoiceSettled (the invoice it carries includes the ref) and must not ask again.
local REF_COLUMNS = 'id, citizenid, amount, society'

local function ValidRef(ref)
    return type(ref) == 'string' and #ref >= 1 and #ref <= 128 and not ref:find('[^%w%-_:%.]')
end

local function InvoiceByRef(ref)
    local ok, rows = pcall(MySQL.query.await, 'SELECT ' .. REF_COLUMNS .. ' FROM phone_invoices WHERE ref = ? LIMIT 1', { ref })
    if not ok then return nil, false end
    return type(rows) == 'table' and rows[1] or nil, true
end

--- The answer for an invoice found under the ref: its id and 'duplicate', or nil, 'key_reused'.
local function SameRefAnswer(found, cid, amount, society)
    if found.citizenid == cid and tostring(found.society) == society and tonumber(found.amount) == amount then
        return InvoiceIdOf(found.id), 'duplicate'
    end
    return nil, 'key_reused'
end

local function CreateInvoice(data)
    if type(data) ~= 'table' then return nil, 'bad_request' end
    local cid, amount, society = data.citizenid, IsValidAmount(data.amount), data.society
    if type(cid) ~= 'string' or cid == '' or #cid > 50 or not amount or amount < 1 or amount > 2147483647
        or type(society) ~= 'string' or society == '' or #society > 50 then
        return nil, 'bad_request'
    end
    local ref = data.ref
    if ref ~= nil and not ValidRef(ref) then return nil, 'bad_request' end
    EnsureInvoiceColumns()
    if ref then
        -- without the column and its unique index a ref cannot be honoured: refused, not ignored
        if not Columns.ref then return nil, 'db_unavailable' end
        local found, okRead = InvoiceByRef(ref)
        if not okRead then return nil, 'db_error' end
        if found then return SameRefAnswer(found, cid, amount, society) end
    end
    if not SocietyKnown(society) then return nil, 'unknown_society' end
    local candecline = (data.candecline == 0 or data.candecline == false) and 0 or 1
    local reason = data.reason ~= nil and tostring(data.reason):sub(1, 256) or nil
    local sender = data.sender ~= nil and tostring(data.sender):sub(1, 50) or nil
    local senderCid = data.sendercitizenid ~= nil and tostring(data.sendercitizenid):sub(1, 50) or nil
    -- values may hold nils (sender, reason): positions are counted from cols, never with #values
    local cols = { 'citizenid', 'amount', 'society', 'sender', 'sendercitizenid', 'candecline', 'reason' }
    local values = { cid, amount, society, sender, senderCid, candecline, reason }
    if Columns.token then cols[8], values[8] = 'ledger_token', PFPayout.NewId() end
    if ref then
        local n = #cols + 1
        cols[n], values[n] = 'ref', ref
    end
    local sql = ('INSERT INTO phone_invoices (%s) VALUES (%s)'):format(table.concat(cols, ', '), ('?, '):rep(#cols):sub(1, -3))
    local okInsert, res = pcall(MySQL.insert.await, sql, values)
    local id = okInsert and InvoiceIdOf(res) or nil
    if not id and ref then
        -- another call with this ref inserted first (unique index): answer with its invoice
        local found = InvoiceByRef(ref)
        if found then return SameRefAnswer(found, cid, amount, society) end
    end
    if not okInsert then print(('^1[pfm-phone]^7 creating an invoice failed: %s'):format(tostring(res))) end
    if not id then return nil, 'db_error' end
    return id
end
exports('CreateInvoice', CreateInvoice)

--- The key base to charge a row on (see the header): its token; for a row without one, its id keys
--- when they hold a charge of this payer and amount, otherwise a token given to it now.
--- Returns base, byId, or nil and an error code.
local function ResolveKeyBase(invoice, amount)
    local base, byId = InvoiceKeyBase(invoice)
    if not byId then return base, false end
    local step = WalkStep('charge|' .. base, ChargeKeys(base), IdKeyMatch(true, 'from_account', PayerAccount(invoice), amount))
    if step == 'error' then return nil, nil, 'bank_unavailable' end
    if step ~= 'free' or not Columns.token then return base, true end -- charged (or settling) there; or no column: id keys as before
    local token = PFPayout.NewId()
    local ok, res = pcall(MySQL.update.await, 'UPDATE phone_invoices SET ledger_token = ? WHERE id = ? AND citizenid = ? AND (ledger_token IS NULL OR ledger_token = ?)',
        { token, invoice.id, invoice.citizenid, tostring(invoice.ledger_token or '') })
    if not ok or Affected(res) ~= 1 then return nil, nil, 'in_progress' end
    invoice.ledger_token = token
    return 'pfm-phone:invoice:tok:' .. token, false
end

--- Charges the payer for the invoice unless an attempt already did. Returns
---   'paid', replayed       a completed charge (replayed: made before this call)
---   'wait'                 an attempt the ledger has not settled; never charged again meanwhile
---   'failed', error        nothing was taken (e.g. insufficient_funds; unknown_society: the
---                          business cannot take the money, so the payer is not charged for it)
---   'error', error         the ledger could not be read, or the invoice could not be marked
local function ChargeInvoice(src, invoice, base, byId, amount)
    local hint, keyOf = 'charge|' .. base, ChargeKeys(base)
    local isOurs = IdKeyMatch(byId, 'from_account', PayerAccount(invoice), amount)
    while true do
        local step, n = WalkStep(hint, keyOf, isOurs)
        if step == 'error' then return 'error', 'bank_unavailable' end
        if step == 'done' then return 'paid', true end
        if step == 'wait' then return 'wait' end
        if not SocietyKnown(invoice.society) then return 'failed', 'unknown_society' end
        if not MarkPaying(invoice) then return 'error', 'in_progress' end
        local account, res = PFPayout.Charge(src, 'bank', amount, { key = AttemptKey(base, n), kind = 'purchase', reason = 'Invoice from ' .. tostring(invoice.society) })
        res = type(res) == 'table' and res or {}
        if account then return 'paid', res.duplicate == true end
        if res.state then
            local outcome = TxOutcome(res.state, res.error)
            if outcome ~= 'spent' then return 'wait' end
            AttemptHints[hint] = { n = n + 1, lastErr = res.error }
            if not res.duplicate then return 'failed', res.error or 'payment_failed' end
            -- a failure stored under this key meanwhile (another server): walk on to the next key
        elseif res.txId == nil and REFUSED_BEFORE_WRITE[res.error] then
            return 'failed', res.error
        else
            return 'wait' -- the call broke off (bank_unavailable, internal_error, a key in use): the ledger tells later
        end
    end
end

--- One payout of a charged invoice on its numbered keys. Returns done, madeNow, voided. With
--- voidIfUnknown, a recipient the ledger reports as unknown_account (a deleted character) ends the
--- step unpaid (voided).
local function PayStep(hint, first, isOurs, pay, voidIfUnknown)
    local keyOf = function(n) return AttemptKey(first, n) end
    local step, n, lastErr = WalkStep(hint, keyOf, isOurs)
    if step == 'done' then return true, false, false end
    if step ~= 'free' then return false, false, false end
    if voidIfUnknown and lastErr == 'unknown_account' then return true, false, true end
    local key = keyOf(n)
    local ok, res = pay(key)
    res = type(res) == 'table' and res or {}
    if ok then return true, res.duplicate ~= true, false end
    if res.state and TxOutcome(res.state, res.error) == 'spent' then
        AttemptHints[hint] = { n = n + 1, lastErr = res.error }
        if voidIfUnknown and res.error == 'unknown_account' then
            print(('^3[pfm-phone]^7 %s: the recipient no longer exists, nothing paid'):format(key))
            return true, false, true
        end
    end
    print(('^1[pfm-phone]^7 %s not paid yet (%s): the invoice stays open for settlement'):format(key, tostring(res.error or res.state)))
    return false, false
end

--- For a row keyed by id: true and the ledger row id of its completed charge, or false when the
--- charge cannot be read now. Its payouts are the ones the ledger stored after that charge.
local function ChargeRowId(invoice, base, amount)
    local step, _, _, tx = WalkStep('charge|' .. base, ChargeKeys(base), IdKeyMatch(true, 'from_account', PayerAccount(invoice), amount))
    if step ~= 'done' then return false end
    return true, type(tx) == 'table' and tonumber(tx.id) or nil
end

--- Pays the business and the commission of a charged invoice, then deletes the row and reports it
--- paid. Returns true once all of it is done; false while a payout waits (the invoice stays
--- 'paying' and a later payment request or the sweep finishes it).
local function SettleInvoice(invoice, base, byId, replayed, payer)
    local amount, society = IsValidAmount(invoice.amount), tostring(invoice.society)
    local afterId
    if byId then
        local found, rowId = ChargeRowId(invoice, base, amount)
        if not found then return false end
        afterId = rowId
    end
    local socDone, socNow = PayStep('society|' .. base, base .. ':society', IdKeyMatch(byId, 'to_account', 'society:' .. society, amount, afterId), function(key)
        return PFPayout.PaySociety(society, amount, { key = key, reason = 'Phone invoice' })
    end)
    local biller, commission = invoice.sendercitizenid, 0
    local rate = Config.BillingCommissions and Config.BillingCommissions[society]
    local comDone, comNow, comVoid = true, false, false
    if rate and type(biller) == 'string' and biller ~= '' then
        commission = Round(amount * rate)
        if commission > 0 then
            comDone, comNow, comVoid = PayStep('commission|' .. base, base .. ':commission', IdKeyMatch(byId, 'to_account', ('player:%s:bank'):format(biller), commission, afterId), function(key)
                return PFPayout.Pay(biller, 'bank', commission, { key = key, kind = 'wage', reason = 'Billing commission', quiet = true })
            end, true)
        end
    end
    if not (socDone and comDone) then return false end

    local removed = Affected(MySQL.update.await('DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', { invoice.id, invoice.citizenid }))
    ForgetHints(base)
    SweepBackoff[invoice.id] = nil
    -- Reported once per paid invoice: by the request that removed the row (also after a crash
    -- between the payouts and the delete). A row keyed by id whose payouts were all made before
    -- (a reused id of an invoice that was paid in full) reports nothing again.
    if removed < 1 or (byId and replayed and not socNow and not comNow) then return true end
    if commission > 0 and not comVoid then -- no mail for a commission dropped for a deleted character
        exports['pfm-phone']:sendNewMailToOffline(biller, {
            sender = 'Billing Department',
            subject = 'Commission Received',
            message = string.format('You received a commission check of $%s when %s paid a bill of $%s.', commission, payer.name, amount)
        })
    end
    TriggerEvent('qb-phone:server:paidInvoice', payer.src, invoice.id)
    TriggerEvent('pfm-phone:server:invoiceSettled', PublicInvoice(invoice), 'paid')
    notifyBillingSociety(society, payer.name, amount, true)
    return true
end

--- Finishes an invoice marked 'paying'. Returns 'paid' (settled and removed), 'wait' (a step is not
--- settled by the ledger yet, or a payout was refused: tried again later) or 'open' (no attempt of
--- the charge moved money: the invoice is open again). With 'wait' for the charge itself, also the
--- error and key of the attempt it waits for (the sweep tells the admin about unverified ones).
local function FinishPaying(invoice, payer)
    local amount = IsValidAmount(invoice.amount)
    if not amount then return 'wait' end
    local base, byId = InvoiceKeyBase(invoice)
    local step, n, err = WalkStep('charge|' .. base, ChargeKeys(base), IdKeyMatch(byId, 'from_account', PayerAccount(invoice), amount))
    if step == 'done' then return SettleInvoice(invoice, base, byId, true, payer) and 'paid' or 'wait' end
    if step == 'free' then
        Reopen(invoice)
        return invoice.pay_state == nil and 'open' or 'wait'
    end
    if step == 'wait' then return 'wait', err, ChargeKeys(base)(n) end
    return 'wait'
end

local InvoiceLocks = {} -- ['<citizenid>:<invoiceId>'] = true while a payment, decline or sweep of it runs (they yield on the database)

--- Pays invoice `invoiceId` of the player `src`. Returns true once it is paid and settled, or false
--- and an error code ('in_progress' while the ledger settles it, or after the charge while the
--- business is credited).
--- `elsewhere`: paid from another device, so the phone is told to reload its invoices.
local PayInvoiceLocked

local function PayInvoice(src, invoiceId, elsewhere)
    local Ply = exports['pfm-core']:GetPlayer(src)
    invoiceId = InvoiceIdOf(invoiceId)
    if not Ply or not invoiceId then return false, 'bad_request' end
    -- one payment of an invoice at a time (phone, tablet and computer can ask at once); the lock is
    -- taken before the first database yield and released however the payment ends. It is keyed by
    -- the payer too: only the owner's own devices share it, so another player asking for this
    -- invoice id (a request that ends in not_found) cannot keep the owner from paying.
    local lockKey = tostring(Ply.PlayerData.citizenid) .. ':' .. invoiceId
    if InvoiceLocks[lockKey] then return false, 'in_progress' end
    InvoiceLocks[lockKey] = true
    local ok, paid, err = pcall(PayInvoiceLocked, src, Ply, invoiceId, elsewhere)
    InvoiceLocks[lockKey] = nil
    if not ok then
        print(('^1[pfm-phone]^7 paying invoice %d failed: %s'):format(invoiceId, tostring(paid)))
        return false, 'server_error'
    end
    return paid, err
end

PayInvoiceLocked = function(src, Ply, invoiceId, elsewhere)
    if GetResourceState('pfm-banking') ~= 'started' then return false, 'bank_unavailable' end
    local cid = Ply.PlayerData.citizenid
    local invoice = LoadInvoice(invoiceId, cid)
    local amount = invoice and IsValidAmount(invoice.amount)
    if not amount or tostring(invoice.society or '') == '' then return false, 'not_found' end
    EnsureInvoiceColumns()
    local payer = PayerOf(cid, Ply)

    if invoice.pay_state == 'paying' then
        local result = FinishPaying(invoice, payer)
        if result == 'paid' then
            if elsewhere then TriggerClientEvent('qb-phone:RefreshPhone', src) end
            return true
        end
        if result == 'wait' then return false, 'in_progress' end
    end

    local base, byId, err = ResolveKeyBase(invoice, amount)
    if not base then return false, err end
    local charged, info = ChargeInvoice(src, invoice, base, byId, amount)
    if charged == 'failed' then
        Reopen(invoice)
        return false, info
    elseif charged == 'error' then
        return false, info
    elseif charged == 'wait' then
        MarkPaying(invoice) -- followed by the sweep until the ledger settles the attempt
        return false, 'in_progress'
    end
    MarkPaying(invoice) -- a charge found made before (a crash after it): finish it below or in the sweep
    if SettleInvoice(invoice, base, byId, info == true, payer) then
        if elsewhere then TriggerClientEvent('qb-phone:RefreshPhone', src) end
        return true
    end
    TriggerClientEvent('QBCore:Notify', src, 'Your payment was received. The invoice is settled with the business shortly.', 'primary')
    TriggerClientEvent('qb-phone:RefreshPhone', src)
    return false, 'in_progress'
end
exports('PayInvoice', function(src, invoiceId) return PayInvoice(src, invoiceId, true) end)

-- true when paid; 'in_progress' while the bank settles it, 'unknown_society' when the business cannot
-- take payments (the phone says so instead of "not enough balance"); false otherwise
QBCore.Functions.CreateCallback('qb-phone:server:PayInvoice', function(source, cb, _, _, invoiceId)
    local ok, err = PayInvoice(source, invoiceId)
    if ok == true then return cb(true) end
    cb((err == 'in_progress' or err == 'unknown_society') and err or false)
end)

--- Declines a declinable invoice of the player `src`. Returns true, or false and an error code.
--- It takes the invoice's payment lock, so a decline and a payment of one invoice cannot run at once.
--- An invoice whose payer was charged under any attempt key is not declined: the payment is finished
--- instead (the business gets its money) and the answer is 'not_open'; one with a charge the ledger
--- has not settled answers 'in_progress'. The events go out from the request that removed the row.
local function DeclineInvoice(src, invoiceId)
    local Ply = exports['pfm-core']:GetPlayer(src)
    invoiceId = InvoiceIdOf(invoiceId)
    if not Ply or not invoiceId then return false, 'bad_request' end
    local cid = Ply.PlayerData.citizenid
    local lockKey = tostring(cid) .. ':' .. invoiceId
    if InvoiceLocks[lockKey] then return false, 'in_progress' end
    InvoiceLocks[lockKey] = true
    local ok, done, err = pcall(function()
        local invoice = LoadInvoice(invoiceId, cid)
        if not invoice or tonumber(invoice.candecline) ~= 1 then return false, 'not_declinable' end
        EnsureInvoiceColumns()
        local payer = PayerOf(cid, Ply)
        if invoice.pay_state == 'paying' then
            local result = FinishPaying(invoice, payer)
            if result == 'paid' then return false, 'not_open' end
            if result == 'wait' then return false, 'in_progress' end
        end
        local amount = IsValidAmount(invoice.amount)
        if amount then
            local base, byId = InvoiceKeyBase(invoice)
            local step = WalkStep('charge|' .. base, ChargeKeys(base), IdKeyMatch(byId, 'from_account', PayerAccount(invoice), amount))
            if step == 'error' then return false, 'bank_unavailable' end
            if step == 'wait' then
                MarkPaying(invoice)
                return false, 'in_progress'
            end
            if step == 'done' then
                MarkPaying(invoice)
                SettleInvoice(invoice, base, byId, true, payer)
                TriggerClientEvent('qb-phone:RefreshPhone', src)
                return false, 'not_open'
            end
        end
        local sql = 'DELETE FROM phone_invoices WHERE id = ? and citizenid = ? and candecline = ?'
        if Columns.payState then sql = sql .. ' AND pay_state IS NULL' end
        if Affected(MySQL.update.await(sql, { invoiceId, cid, 1 })) < 1 then return false, 'not_declinable' end
        TriggerEvent('qb-phone:server:declinedInvoice', src, invoiceId)
        notifyBillingSociety(invoice.society, payer.name, invoice.amount, false)
        TriggerEvent('pfm-phone:server:invoiceSettled', PublicInvoice(invoice), 'declined')
        return true
    end)
    InvoiceLocks[lockKey] = nil
    if not ok then
        print(('^1[pfm-phone]^7 declining invoice %d failed: %s'):format(invoiceId, tostring(done)))
        return false, 'server_error'
    end
    return done, err
end
exports('DeclineInvoice', function(src, invoiceId) return DeclineInvoice(src, invoiceId) end)

QBCore.Functions.CreateCallback('qb-phone:server:DeclineInvoice', function(source, cb, _, _, invoiceId)
    cb(DeclineInvoice(source, invoiceId) == true)
end)

-- The sweep: finishes 'paying' invoices left by a crash, a payout the ledger had not settled, or a
-- business account that could not take the money (see the header). An invoice that has to wait is
-- tried again later, sooner first (2, 4, 8 ... up to 30 minutes). It takes each invoice's lock, so
-- it never runs alongside a payment or decline of the same invoice. It goes through the 'paying'
-- rows in id order, page by page, and goes on next time where it stopped: rows that wait (an
-- unverified charge an admin has to settle can wait for good) never keep it from later ones.
PFPhoneInvoices = PFPhoneInvoices or {}
local SWEEP_PAGES = 20 -- pages of SWEEP_BATCH rows looked at per sweep
local SWEEP_SQL = ("SELECT id, citizenid FROM phone_invoices WHERE pay_state = 'paying' AND id > ? ORDER BY id LIMIT %d"):format(SWEEP_BATCH)
local SweepCursor = 0 -- the id the next sweep goes on after

--- Tries one 'paying' invoice that is due. Returns 'paid', 'open', 'wait' or 'gone'.
local function SweepOne(id, cid)
    local lockKey = cid .. ':' .. id
    InvoiceLocks[lockKey] = true
    local ok, result, err, key = pcall(function()
        local invoice = LoadInvoice(id, cid)
        if not invoice or invoice.pay_state ~= 'paying' then return 'gone' end
        local payer = PayerOf(cid)
        local res, waitErr, waitKey = FinishPaying(invoice, payer)
        if res == 'open' and not payer.src and not CharacterExists(cid) then
            -- no attempt took money and the payer was deleted meanwhile: nobody can pay it any more
            pcall(MySQL.update.await, 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ? AND pay_state IS NULL', { id, cid })
            return 'open'
        end
        if res == 'open' and payer.src then TriggerClientEvent('qb-phone:RefreshPhone', payer.src) end
        return res, waitErr, waitKey
    end)
    InvoiceLocks[lockKey] = nil
    if not ok then print(('^1[pfm-phone]^7 finishing invoice %d failed: %s'):format(id, tostring(result))) end
    local backoff = SweepBackoff[id]
    if not ok or result == 'wait' then
        local delay = backoff and math.min(backoff.delay * 2, SWEEP_MAX_BACKOFF_MS) or SWEEP_INTERVAL_MS
        SweepBackoff[id] = { at = GetGameTimer() + delay, delay = delay, warned = backoff and backoff.warned }
        if ok and err == 'interrupted_unverified' and not SweepBackoff[id].warned then
            -- nothing else tells anyone: the invoice stays hidden from the payer until this is settled
            SweepBackoff[id].warned = true
            print(('^3[pfm-phone]^7 invoice %d waits for an admin: its charge %s was interrupted and the ledger could not verify whether the money left (pf_transactions; see the invoice notes in pfm-phone/server/main.lua)')
                :format(id, tostring(key)))
        end
        return 'wait'
    end
    SweepBackoff[id] = nil
    return result
end

--- Returns how many invoices it settled or opened again.
function PFPhoneInvoices.Sweep()
    EnsureInvoiceColumns()
    if not Columns.payState or GetResourceState('pfm-banking') ~= 'started' then return 0 end
    local start = SweepCursor
    local after, wrapped, tried, finished = start, false, 0, 0
    for _ = 1, SWEEP_PAGES do
        local okList, rows = pcall(MySQL.query.await, SWEEP_SQL, { after })
        if not okList or type(rows) ~= 'table' then
            SweepCursor = after
            return finished
        end
        for _, r in ipairs(rows) do
            local id, cid = InvoiceIdOf(r.id), r.citizenid
            if id and wrapped and id > start then -- back where this sweep began: every row was looked at
                SweepCursor = 0
                return finished
            end
            if id then
                after = id
                local backoff = SweepBackoff[id]
                if type(cid) == 'string' and not InvoiceLocks[cid .. ':' .. id] and not (backoff and GetGameTimer() < backoff.at) then
                    tried = tried + 1
                    local result = SweepOne(id, cid)
                    if result == 'paid' or result == 'open' then finished = finished + 1 end
                    if tried >= SWEEP_BATCH then
                        SweepCursor = after
                        return finished
                    end
                end
            end
        end
        if #rows < SWEEP_BATCH then -- the end of the table
            if wrapped or start == 0 then
                SweepCursor = 0
                return finished
            end
            wrapped, after = true, 0
        end
    end
    SweepCursor = after
    return finished
end

CreateThread(function()
    -- the ledger recovers interrupted transfers when it starts: wait for it (at most ~5 minutes)
    for _ = 1, 60 do
        local ok, ready = pcall(function() return exports['pfm-banking']:IsLedgerReady() end)
        if ok and ready == true then break end
        Wait(5000)
    end
    while true do
        local ok, err = pcall(PFPhoneInvoices.Sweep)
        if not ok then print(('^1[pfm-phone]^7 invoice sweep failed: %s'):format(tostring(err))) end
        Wait(SWEEP_INTERVAL_MS)
    end
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

-- ── camera uploads ───────────────────────────────────────────────────
-- The phone's camera is uploaded by the server: screenshot-basic takes the picture from the player's
-- screen, the server sends it to the upload target and gives the phone only the picture's link (and
-- puts it in the gallery). The target comes from server-only convars (config.lua): a Discord
-- webhook (pfm_phone_webhook) or Fivemerr (Config.Fivemerr, pfm_phone_fivemerr_token). The phone
-- used to fetch the webhook URL from the server and upload itself, so every client could read it and
-- post as the webhook, or delete its messages, outside the game.
local FIVEMERR_DEFAULT_URL = 'https://api.fivemerr.com/v1/media/images'
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64Index = {}
for i = 1, #B64 do B64Index[B64:sub(i, i)] = i - 1 end

local function Base64Decode(text)
    text = text:gsub('[^%w%+/=]', '')
    local out, bits, nbits = {}, 0, 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == '=' then break end
        local v = B64Index[ch]
        if v then
            bits = (bits << 6) | v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                out[#out + 1] = string.char((bits >> nbits) & 0xFF)
            end
        end
    end
    return table.concat(out)
end

--- The bytes and type of a data: URI from screenshot-basic, or nil.
local function DataUriBytes(uri)
    if type(uri) ~= 'string' then return nil end
    local mime, b64 = uri:match('^data:(image/[%w%+%-%.]+);base64,(.+)$')
    if not mime then return nil end
    return Base64Decode(b64), mime
end

local function Webhook()
    local url = GetConvar('pfm_phone_webhook', '')
    if type(url) ~= 'string' or not url:match('^https://') then return nil end
    -- Discord answers with the message (and its attachment links) only with wait=true
    if not url:find('[?&]wait=') then url = url .. (url:find('?', 1, true) and '&' or '?') .. 'wait=true' end
    return url
end

--- Uploads the screenshot to the Discord webhook. done(url or nil).
local function UploadToWebhook(url, dataUri, done)
    local bytes, mime = DataUriBytes(dataUri)
    if not bytes or bytes == '' then return done(nil) end
    local ext = mime == 'image/png' and 'png' or (mime == 'image/webp' and 'webp' or 'jpg')
    local boundary = ('----pfmphone%08x%08x'):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
    local body = table.concat({
        '--', boundary, '\r\n',
        'Content-Disposition: form-data; name="files[0]"; filename="photo.', ext, '"\r\n',
        'Content-Type: ', mime, '\r\n\r\n',
        bytes, '\r\n',
        '--', boundary, '--\r\n',
    })
    PerformHttpRequest(url, function(status, response)
        status = tonumber(status) or 0
        if status < 200 or status > 299 then
            print(('^1[pfm-phone]^7 photo upload failed (HTTP %d)'):format(status))
            return done(nil)
        end
        local ok, data = pcall(json.decode, response or '')
        local att = ok and type(data) == 'table' and type(data.attachments) == 'table' and data.attachments[1] or nil
        done(type(att) == 'table' and (att.proxy_url or att.url) or nil)
    end, 'POST', body, { ['Content-Type'] = 'multipart/form-data; boundary=' .. boundary })
end

--- Uploads the screenshot to Fivemerr. done(url or nil).
local function UploadToFivemerr(token, dataUri, done)
    PerformHttpRequest(GetConvar('pfm_phone_fivemerr_url', FIVEMERR_DEFAULT_URL), function(status, response)
        status = tonumber(status) or 0
        if status < 200 or status > 299 then
            print(('^1[pfm-phone]^7 Fivemerr upload failed (HTTP %d)'):format(status))
            return done(nil)
        end
        local ok, data = pcall(json.decode, response or '')
        done(ok and type(data) == 'table' and data.url or nil)
    end, 'POST', json.encode({ data = dataUri }), { ['Authorization'] = token, ['Content-Type'] = 'application/json' })
end

local warnedNoTarget = false
--- encoding, upload(dataUri, done) for the configured target, or nil.
local function UploadTarget()
    if Config.Fivemerr == true then
        local token = GetConvar('pfm_phone_fivemerr_token', '')
        if token == '' then return nil, 'Config.Fivemerr is on but the convar pfm_phone_fivemerr_token is not set' end
        return 'png', function(data, done) UploadToFivemerr(token, data, done) end
    end
    local url = Webhook()
    if not url then return nil, 'set the server-only convar pfm_phone_webhook (`set`, not `setr`) to a Discord webhook URL' end
    return 'jpg', function(data, done) UploadToWebhook(url, data, done) end
end

--- Takes a photo from the player's screen and uploads it. Calls reply(url or nil) exactly once.
local function UploadPhoto(src, reply)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not HasPhoneItem(Player) then return reply(nil) end
    if IsRateLimited(src, 'photo') then return reply(nil, 'too_fast') end
    local encoding, upload = UploadTarget()
    if not encoding then
        if not warnedNoTarget then
            warnedNoTarget = true
            print(('^3[pfm-phone]^7 the camera cannot upload: %s'):format(tostring(upload)))
        end
        return reply(nil, 'not_setup')
    end
    if GetResourceState('screenshot-basic') ~= 'started' then return reply(nil, 'not_setup') end
    local cid = Player.PlayerData.citizenid
    local ok, err = pcall(function()
        exports['screenshot-basic']:requestClientScreenshot(src, { encoding = encoding, quality = 0.85 }, function(shotErr, data)
            if shotErr or type(data) ~= 'string' then return reply(nil) end
            upload(data, function(url)
                url = SafeImageUrl(url)
                if not url then return reply(nil) end
                MySQL.insert.await('INSERT INTO phone_gallery (`citizenid`, `image`) VALUES (?, ?)', { cid, url })
                local images = MySQL.query.await('SELECT * FROM phone_gallery WHERE citizenid = ? ORDER BY `date` DESC', { cid })
                TriggerClientEvent('qb-phone:refreshImages', src, images)
                reply(url)
            end)
        end)
    end)
    if not ok then
        print(('^1[pfm-phone]^7 photo upload failed: %s'):format(tostring(err)))
        reply(nil)
    end
end

QBCore.Functions.CreateCallback('qb-phone:server:UploadPhoto', function(source, cb)
    local answered = false
    UploadPhoto(source, function(url, why)
        if answered then return end
        answered = true
        cb(url, why)
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
    -- the picture goes to every phone: only an allowed https link (it was put into the page
    -- unquoted, so a link with spaces ran script on every phone that showed the adverts)
    if url ~= nil and url ~= '' then
        url = SafeImageUrl(url)
        if not url then TriggerClientEvent('QBCore:Notify', src, 'That picture link is not allowed', 'error') end
    else
        url = nil
    end
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
--- (The time is the server's, and the avatar is the author's stored one: both came from the client.
--- The image link must be an allowed picture link; anything else is dropped.)
local function BuildTweet(Player, data)
    if type(data) ~= 'table' then return nil end
    local message = SanitizeText(tostring(data.message or ''))
    if not message then return nil end
    local time = os.date('%Y-%m-%d %H:%M:%S', os.time())
    local meta = Player.PlayerData.metadata and Player.PlayerData.metadata.phone
    return {
        citizenid = Player.PlayerData.citizenid,
        firstName = Player.PlayerData.charinfo.firstname,
        lastName = Player.PlayerData.charinfo.lastname,
        message = message,
        time = time,
        date = time,
        url = SafeImageUrl(data.url) or '',
        picture = CleanProfilePicture(type(meta) == 'table' and meta.profilepicture or nil),
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

-- A call to TargetData.number (the second argument, the old client-chosen call id, is ignored: the
-- server picks it). A call that cannot start ends the caller's ringing at once.
RegisterNetEvent('qb-phone:server:CallContact', function(TargetData, _, AnonymousCall)
    local src = source
    if type(TargetData) ~= 'table' then return end
    if IsRateLimited(src, 'call') then return TriggerClientEvent('qb-phone:client:CancelCall', src) end
    local id = StartCall(src, TargetData.number, AnonymousCall == true)
    if not id then TriggerClientEvent('qb-phone:client:CancelCall', src) end
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
    -- only the phone's own apps (any string used to become a key of a table kept for the session)
    if not Player or type(app) ~= 'string' then return end
    if not ((Config.PhoneApplications and Config.PhoneApplications[app]) or (Config.StoreApps and Config.StoreApps[app])) then return end
    if alerts ~= nil then
        alerts = math.tointeger(tonumber(alerts))
        if not alerts or alerts < 0 or alerts > 999 then return end
    end
    QBPhone.SetPhoneAlerts(Player.PlayerData.citizenid, app, alerts)
end)

-- Drops the cached tweet feed so the next read reloads it (server/characters.lua after a deleted
-- character's tweets were removed).
function PFPhoneForgetTweets() TWData = {} end

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

-- One chat message: { type = 'message' | 'location' | 'picture', message, url }. The server builds
-- the message itself and appends it to both people's copies of the chat (see the chats section).
RegisterNetEvent('qb-phone:server:SendMessage', function(number, payload)
    local src = source
    if IsRateLimited(src, 'message') then return end
    if type(number) ~= 'string' and type(number) ~= 'number' then return end
    local ok, why = SendChatMessage(src, number, payload)
    if ok then return end
    if why == 'no_number' then PhoneNotify(src, 'This number does not exist')
    elseif why == 'bad_picture' then PhoneNotify(src, 'That picture cannot be sent')
    elseif why == 'busy' or why == 'server_error' then PhoneNotify(src, 'The message was not sent, try again') end
end)

-- (qb-phone:server:UpdateMessages removed: it stored the whole chat the client sent, for both people.
-- qb-phone:server:AddRecentCall removed: the server adds the recent calls when a call ends.)

-- Hang up (or deny) the sender's own call; callId is the id the server gave the phone.
RegisterNetEvent('qb-phone:server:CancelCall', function(callId)
    local src = source
    local call = CallFor(src, callId)
    if call then EndCall(call.id, src) end
end)

-- Answer the call ringing on the sender's own phone.
RegisterNetEvent('qb-phone:server:AnswerCall', function(callId)
    local src = source
    if not AnswerCall(src, callId) then
        -- nothing (any more) to answer: the phone that thinks it answered goes back to idle
        if not CallOf[src] then TriggerClientEvent('qb-phone:client:CancelCall', src) end
    end
end)

RegisterNetEvent('qb-phone:server:SaveMetaData', function(MData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(MData) ~= 'table' then return end
    local clean, rejected = CleanPhoneMeta(MData, Player.PlayerData.metadata and Player.PlayerData.metadata.phone)
    -- through pfm-core only (a direct UPDATE of players.metadata raced with its own save)
    Player.Functions.SetMetaData('phone', clean)
    if rejected then TriggerClientEvent('QBCore:Notify', src, 'That picture link is not allowed', 'error') end
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
    -- the camera's uploads are added by the server itself; this only takes an allowed picture link
    image = SafeImageUrl(image)
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

--- Server-only: a character's newest gallery photos for other resources (pf-computer shows them as
--- wallpapers): { { image = url, date = 'YYYY-MM-DD HH:MM:SS' } }, newest first, at most `limit` (1-100).
exports('GetGallery', function(citizenid, limit)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 64 then return {} end
    limit = math.floor(tonumber(limit) or 50)
    if limit < 1 then limit = 1 elseif limit > 100 then limit = 100 end
    local rows = MySQL.query.await('SELECT image, `date` FROM phone_gallery WHERE citizenid = ? ORDER BY `date` DESC LIMIT ?', { citizenid, limit }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        if type(r.image) == 'string' and r.image ~= '' then
            out[#out + 1] = { image = r.image, date = r.date ~= nil and tostring(r.date) or nil }
        end
    end
    return out
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
                    local ok, id = pcall(CreateInvoice, { citizenid = billed.PlayerData.citizenid, amount = amount, society = biller.PlayerData.job.name,
                        sender = biller.PlayerData.charinfo.firstname, sendercitizenid = biller.PlayerData.citizenid })
                    if not ok or not id then
                        TriggerClientEvent('QBCore:Notify', source, 'The invoice could not be sent', 'error')
                        return
                    end
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
