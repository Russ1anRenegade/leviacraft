-- LeviaCraft.lua
-- Guild-internal crafting marketplace for Levia on OctoWoW (vanilla 1.12)
-- Profession registry + buy orders + craft listings via addon messaging

LEVIA_CRAFT_PREFIX = "LeviaCraft"
LEVIA_CRAFT_VERSION = "2.0"

-- Message type tokens (kept short to save message space)
LC_MSG = {
    HELLO      = "HI",   -- broadcast professions on login
    REQUEST    = "RQ",   -- request someone re-broadcast their professions
    PROF_DATA  = "PD",   -- profession data packet
    POST_LIST  = "PL",   -- "I can craft this" listing
    POST_BUY   = "PB",   -- buy order
    DEL_LIST   = "DL",   -- delete my listing
    DEL_BUY    = "DB",   -- delete my buy order
    FILL_BUY   = "FB",   -- mark buy order as filled/in-progress
    PING       = "PI",   -- request full registry rebroadcast from everyone
    CLR_LIST   = "CL",   -- clear all my listings before re-broadcast
    CLR_BUY    = "CB",   -- clear all my orders before re-broadcast
    BYE        = "BY",   -- player logging out
    BEAT       = "BT",   -- heartbeat ping (sent every 15s)
}

-- Max bytes per SendAddonMessage payload (vanilla safe limit)
LC_MAX_MSG = 250

-- Skill level thresholds for display
LC_RANK = {
    [1]   = "Apprentice",
    [75]  = "Journeyman",
    [150] = "Expert",
    [225] = "Artisan",
    [300] = "Master",
}

-- ============================================================
-- Saved variable defaults
-- ============================================================
function LC_InitDB()
    if not LeviaCraftDB then
        LeviaCraftDB = {}
    end
    if not LeviaCraftDB.orders then
        LeviaCraftDB.orders = {}
    end
    if not LeviaCraftDB.listings then
        LeviaCraftDB.listings = {}
    end
    if not LeviaCraftDB.registry then
        LeviaCraftDB.registry = {}    -- persisted profession data keyed by player name
    end
    if not LeviaCraftDB.deleted then
        LeviaCraftDB.deleted = {}     -- tombstones: id -> { owner, time } for deleted listings/orders
    end
    if not LeviaCraftDB.prefs then
        LeviaCraftDB.prefs = { minimap_angle = 200, minimap_show = true }
    end
end

-- ============================================================
-- Runtime state (not saved)
-- ============================================================
-- LC_Registry points at LeviaCraftDB.registry after ADDON_LOADED.
-- This makes profession data persist across sessions so offline players
-- remain visible until their data is replaced by a live broadcast.
LC_Registry = {}
LC_MyListings  = {}   -- listings I have posted this session
LC_MyBuys      = {}   -- buy orders I have posted this session
LC_OrderSeq    = 0    -- incrementing id for orders (combined with timestamp for uniqueness)

-- Rate limiter: don't broadcast professions more than once every 8 seconds.
-- The ticker fires every 10s but HELLO/PING responses also trigger broadcasts.
LC_LastBroadcast   = 0
LC_BROADCAST_COOLDOWN = 20  -- seconds

-- ============================================================
-- Profession scanning
-- ============================================================
local PROF_SLOTS = { 7, 8 }   -- character sheet trade skill slots 7 and 8

function LC_ScanMyProfessions()
    local profs = {}

    -- Try ATSW2 API first (it exposes GetATSWSkillLine if loaded)
    if GetATSWNumSkills then
        for i = 1, GetATSWNumSkills() do
            local name, hdr, isHeader, _, rank, maxRank = GetATSWSkillLine(i)
            if not isHeader and rank and rank > 0 then
                profs[table.getn(profs) + 1] = { name = name, skill = rank, max = maxRank }
            end
        end
    end

    -- Native fallback: check both trade skill slots via GetProfessions equivalent
    -- Vanilla 1.12 doesn't have GetProfessions() so we iterate GetSkillLineInfo
    if table.getn(profs) == 0 then
        local numSkills = GetNumSkillLines()
        for i = 1, numSkills do
            local skillName, isHeader, _, rankNum, numTempPoints, skillModifier,
                  skillRank, maxRank = GetSkillLineInfo(i)
            if not isHeader and skillName then
                -- Only capture primary trade skills and secondaries we care about
                if LC_IsTradeProfession(skillName) then
                    profs[table.getn(profs) + 1] = {
                        name  = skillName,
                        skill = rankNum or 0,
                        max   = maxRank or 300,
                    }
                end
            end
        end
    end

    return profs
end

function LC_IsTradeProfession(name)
    local trades = {
        ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true,
        ["Engineering"] = true, ["Herbalism"] = true, ["Inscription"] = true,
        ["Jewelcrafting"] = true, ["Leatherworking"] = true, ["Mining"] = true,
        ["Skinning"] = true, ["Tailoring"] = true, ["Fishing"] = true,
        ["Cooking"] = true, ["First Aid"] = true,
        -- OctoWoW custom
        ["Survival"] = true,
    }
    return trades[name] == true
end

function LC_GetRankLabel(skill)
    local label = "Apprentice"
    for threshold, name in pairs(LC_RANK) do
        if skill >= threshold then
            label = name
        end
    end
    return label
end

-- ============================================================
-- Messaging helpers
-- ============================================================

-- ============================================================
-- ============================================================
-- Comms - PallyPower style: plain SendAddonMessage, no encoding,
-- no CTL, no chunking. Colon-delimited. Accept from any channel.
-- ============================================================

-- Lua 5.0 has no string.match; emulate with string.find
function LC_Match(s, pattern)
    local results = { string.find(s, pattern) }
    if not results[1] then return nil end
    if table.getn(results) < 3 then return nil end
    local caps = {}
    for i = 3, table.getn(results) do
        caps[table.getn(caps) + 1] = results[i]
    end
    return unpack(caps)
end

LC_DELIM     = ":"    -- colon, safe in addon messages
LC_SendQueue = {}

-- ============================================================
-- Encryption: XOR cipher with base-85 output
-- Shared key known only to LeviaCraft clients.
-- XOR each byte of the message against a rotating key byte,
-- then encode to printable ASCII (offset 33-117) so the result
-- is safe in WoW channel messages and won't trigger chat filters.
-- ============================================================
LC_CRYPT_KEY = "L3v1aCr4ft_0ct0W0W_K3y_2024_S3cur3!"



-- Queue one send; drains one-per-frame via lcThrottle
-- ============================================================
-- Channel comms: join a custom "LeviaCraft" world channel and
-- use SendChatMessage to broadcast addon data through it.
-- Custom channels work on all private servers with no guild/party
-- requirement. Messages are prefixed with LEVIA_CRAFT_PREFIX so
-- we can filter them in CHAT_MSG_CHANNEL. Rate limited to one
-- message per 2 seconds to stay well under anti-spam detection.
-- ============================================================

LC_CHANNEL_NAME = "LeviaCraft"
LC_CHANNEL_ID   = nil    -- set once we confirm the channel number
LC_SendQueue    = {}
LC_SEND_RATE    = 5.0    -- seconds between bulk sends (increased to avoid timeout)
LC_SendAcc      = 0

-- Join our custom channel on load; retry if not yet available
function LC_JoinChannel()
    JoinChannelByName(LC_CHANNEL_NAME)
    -- Find channel ID and hide it from all chat frames
    for i = 1, 10 do
        local id, name = GetChannelName(i)
        if name and string.find(string.lower(name), string.lower(LC_CHANNEL_NAME)) then
            LC_CHANNEL_ID = id
            LC_HideChannel(id)
            return
        end
    end
end

function LC_HideChannel(channelId)
    if not channelId then return end
    -- DO NOT use ChatFrame_RemoveChannel - on some private server builds this
    -- suppresses CHAT_MSG_CHANNEL events entirely, breaking addon message receipt.
    -- Instead just make the channel text invisible by zeroing its color.
    local key = "CHANNEL" .. tostring(channelId)
    if ChatTypeInfo and ChatTypeInfo[key] then
        ChatTypeInfo[key].r = 0
        ChatTypeInfo[key].g = 0
        ChatTypeInfo[key].b = 0
    end
end

-- Re-check channel ID if it got assigned after join
function LC_FindChannel()
    for i = 1, 10 do
        local id, name = GetChannelName(i)
        if name and string.find(string.lower(name), string.lower(LC_CHANNEL_NAME)) then
            LC_CHANNEL_ID = id
            LC_HideChannel(id)
            return true
        end
    end
    return false
end

-- Priority send: post/delete/fill go immediately, bypassing the queue.
-- Bulk sends (professions, CLR, full re-broadcast) use the slow queue.
LC_PRIORITY_MSGS = {
    [LC_MSG.POST_LIST] = true,
    [LC_MSG.POST_BUY]  = true,
    [LC_MSG.DEL_LIST]  = true,
    [LC_MSG.DEL_BUY]   = true,
    [LC_MSG.FILL_BUY]  = true,
    [LC_MSG.HELLO]     = true,
    [LC_MSG.BYE]       = true,
    [LC_MSG.PING]      = true,
}
LC_LastPrioritySend  = 0
LC_PRIORITY_RATE     = 4.0   -- minimum gap between priority sends
-- Inter-player gap removed - was blocking sends in busy channels
-- Per-message rate limit alone is sufficient anti-spam protection

function LC_GetChannelID()
    -- Always look up fresh - never trust cached ID
    for i = 1, 20 do
        local id, name = GetChannelName(i)
        if name and string.find(string.lower(name), string.lower(LC_CHANNEL_NAME)) then
            LC_CHANNEL_ID = id
            return id
        end
    end
    return nil
end

function LC_RawSend(msg)
    local chanID = LC_GetChannelID()
    if not chanID then
        -- Not in channel yet, try joining
        JoinChannelByName(LC_CHANNEL_NAME)
        chanID = LC_GetChannelID()
        if not chanID then return false end
    end
    SendChatMessage(msg, "CHANNEL", nil, chanID)
    return true
end

function LC_Send(msgType, payload)
    local msg = LEVIA_CRAFT_PREFIX .. ":" .. msgType .. ":" .. (payload or "")
    if string.len(msg) > 240 then msg = string.sub(msg, 1, 240) end

    if LC_PRIORITY_MSGS[msgType] then
        -- Send immediately if enough time has passed, else front of queue
        local now = GetTime()
        local sinceSent = now - LC_LastPrioritySend
        if sinceSent >= LC_PRIORITY_RATE then
            if LC_RawSend(msg) then
                LC_LastPrioritySend = now
                return
            end
        end
        -- Not ready yet: insert at front of queue so it goes next
        table.insert(LC_SendQueue, 1, msg)
    else
        -- Bulk: append to back of queue
        LC_SendQueue[table.getn(LC_SendQueue) + 1] = msg
    end
end

-- Drain one bulk message per LC_SEND_RATE seconds
local lcThrottle = CreateFrame("Frame")
lcThrottle:SetScript("OnUpdate", function()
    if table.getn(LC_SendQueue) == 0 then return end
    LC_SendAcc = LC_SendAcc + arg1
    if LC_SendAcc < LC_SEND_RATE then return end
    LC_SendAcc = 0
    local msg = table.remove(LC_SendQueue, 1)
    LC_RawSend(msg)
end)

-- ============================================================
-- Broadcast my professions
-- ============================================================
function LC_BroadcastProfessions(force)
    local now = GetTime()
    if not force and (now - LC_LastBroadcast) < LC_BROADCAST_COOLDOWN then
        return  -- silently skip; we broadcast recently
    end
    LC_LastBroadcast = now

    local profs = LC_ScanMyProfessions()
    local me = UnitName("player")
    local class = UnitClass("player")

    -- Update local registry immediately (persists to SavedVariables)
    LC_Registry[me] = {
        profs   = profs,
        class   = class,
        updated = GetTime(),
        online  = true,
    }

    -- Build compact payload: PD|Name|Class|Prof1:skill:max;Prof2:skill:max
    local parts = {}
    for _, p in ipairs(profs) do
        parts[table.getn(parts) + 1] = p.name .. ":" .. p.skill .. ":" .. p.max
    end
    local payload = me .. "~" .. (class or "?") .. "~" .. table.concat(parts, ";")
    if LC_DEBUG_RECV then
        LC_Print("SENDING PD: " .. string.sub(payload, 1, 80))
    end
    LC_Send(LC_MSG.PROF_DATA, payload)
end

-- Re-broadcast all my active listings and buy orders
-- Called on HELLO/PING so latecomers catch up
-- Full broadcast: wipe remote stale data then re-send everything.
-- Used on HELLO/PING response so latecomers get clean state.
function LC_BroadcastMyListings()
    local me = UnitName("player")
    LC_Send(LC_MSG.CLR_LIST, me)
    LC_Send(LC_MSG.CLR_BUY, me)
    for id, l in pairs(LeviaCraftDB.listings) do
        if l.crafter == me then
            local payload = id .. "~" .. me .. "~" .. (l.item or "") .. "~" .. (l.price or "Tips/Mats") .. "~" .. (l.note or "")
            LC_Send(LC_MSG.POST_LIST, payload)
        end
    end
    for id, o in pairs(LeviaCraftDB.orders) do
        if o.buyer == me then
            local payload = id .. "~" .. me .. "~" .. (o.item or "") .. "~" .. (o.payment or "Negotiable") .. "~" .. (o.note or "")
            LC_Send(LC_MSG.POST_BUY, payload)
        end
    end
end

-- Ticker broadcast: re-send listings WITHOUT wiping first.
-- Avoids race where CLR arrives but POST hasn't yet, causing items to vanish.
function LC_TickerBroadcastListings()
    local me = UnitName("player")
    -- Re-broadcast active listings
    for id, l in pairs(LeviaCraftDB.listings) do
        if l.crafter == me then
            local payload = id .. "~" .. me .. "~" .. (l.item or "") .. "~" .. (l.price or "Tips/Mats") .. "~" .. (l.note or "")
            LC_Send(LC_MSG.POST_LIST, payload)
        end
    end
    for id, o in pairs(LeviaCraftDB.orders) do
        if o.buyer == me then
            local payload = id .. "~" .. me .. "~" .. (o.item or "") .. "~" .. (o.payment or "Negotiable") .. "~" .. (o.note or "")
            LC_Send(LC_MSG.POST_BUY, payload)
        end
    end
    -- Re-broadcast our tombstones so late joiners apply our deletes
    if not LeviaCraftDB.deleted then LeviaCraftDB.deleted = {} end
    for id, tomb in pairs(LeviaCraftDB.deleted) do
        if tomb.owner == me then
            if tomb.kind == "L" then
                LC_Send(LC_MSG.DEL_LIST, id)
            else
                LC_Send(LC_MSG.DEL_BUY, id)
            end
        end
    end
    -- Prune old tombstones periodically
    LC_PruneTombstones()
end

-- ============================================================
-- Post a craft listing  ("I can make X")
-- ============================================================
function LC_PostListing(itemName, note, price)
    LC_OrderSeq = LC_OrderSeq + 1
    local me = UnitName("player")
    -- Timestamp + seq + player ensures globally unique IDs across all players
    local id = me .. "_" .. math.floor(GetTime()) .. "_" .. LC_OrderSeq

    local listing = {
        id       = id,
        crafter  = me,
        item     = itemName,
        note     = note or "",
        price    = price or "Tips/Mats",
        posted   = GetTime(),
    }

    LC_MyListings[id] = listing

    -- Persist across reloads
    LeviaCraftDB.listings[id] = listing

    -- Broadcast: PL|id|crafter|item|price|note
    local payload = id .. "~" .. me .. "~" .. itemName .. "~" .. listing.price .. "~" .. listing.note
    LC_Send(LC_MSG.POST_LIST, payload)
    LC_UIDirty = true
    LC_Print("Listed: |cffffd700" .. itemName .. "|r  [" .. listing.price .. "]")
end

-- ============================================================
-- Post a buy order ("WTB craft of X")
-- ============================================================
function LC_PostBuyOrder(itemName, payment, note)
    LC_OrderSeq = LC_OrderSeq + 1
    local me = UnitName("player")
    local id = me .. "_" .. math.floor(GetTime()) .. "_" .. LC_OrderSeq

    local order = {
        id      = id,
        buyer   = me,
        item    = itemName,
        payment = payment or "Negotiable",
        note    = note or "",
        posted  = GetTime(),
    }

    LC_MyBuys[id] = order
    LeviaCraftDB.orders[id] = order

    -- Broadcast: PB|id|buyer|item|payment|note
    local payload = id .. "~" .. me .. "~" .. itemName .. "~" .. order.payment .. "~" .. order.note
    LC_Send(LC_MSG.POST_BUY, payload)
    LC_UIDirty = true
    LC_Print("Buy order posted: |cffffd700" .. itemName .. "|r  [" .. order.payment .. "]")
end

-- ============================================================
-- Delete helpers
-- ============================================================
function LC_DeleteListing(id)
    LC_MyListings[id] = nil
    LeviaCraftDB.listings[id] = nil
    -- Store tombstone so ticker can re-broadcast the delete to late joiners
    if not LeviaCraftDB.deleted then LeviaCraftDB.deleted = {} end
    LeviaCraftDB.deleted[id] = { owner = UnitName("player"), t = GetTime(), kind = "L" }
    LC_Send(LC_MSG.DEL_LIST, id)
    LC_UIDirty = true
end

function LC_DeleteBuyOrder(id)
    LC_MyBuys[id] = nil
    LeviaCraftDB.orders[id] = nil
    if not LeviaCraftDB.deleted then LeviaCraftDB.deleted = {} end
    LeviaCraftDB.deleted[id] = { owner = UnitName("player"), t = GetTime(), kind = "B" }
    LC_Send(LC_MSG.DEL_BUY, id)
    LC_UIDirty = true
end

-- Prune tombstones older than 24 hours (86400s) to keep SavedVariables tidy
function LC_PruneTombstones()
    if not LeviaCraftDB or not LeviaCraftDB.deleted then return end
    local now = GetTime()
    for id, tomb in pairs(LeviaCraftDB.deleted) do
        if (now - tomb.t) > 86400 then
            LeviaCraftDB.deleted[id] = nil
        end
    end
end

-- Cycle status: open -> mats_sent -> in_progress -> filled -> open
LC_ORDER_STATUS = {
    ["open"]        = { label = "Open",        next = "mats_sent",   color = "ff888888" },
    ["mats_sent"]   = { label = "Mats Sent",   next = "in_progress", color = "ffffd700" },
    ["in_progress"] = { label = "In Progress", next = "filled",      color = "ff00aaff" },
    ["filled"]      = { label = "Filled!",     next = "open",        color = "ff00ff7f" },
}

function LC_CycleBuyOrderStatus(id)
    local order = LeviaCraftDB.orders[id]
    if not order then return end
    local cur = order.status or "open"
    local info = LC_ORDER_STATUS[cur]
    order.status = info and info.next or "open"
    LeviaCraftDB.orders[id] = order
    -- Broadcast the status change
    LC_Send(LC_MSG.FILL_BUY, id .. "~" .. order.status)
    LC_UIDirty = true
end

-- Schedule a profession broadcast after `delay` seconds
LC_BroadcastPending = false
function LC_ScheduleBroadcast(delay)
    if LC_BroadcastPending then return end
    LC_BroadcastPending = true
    local t = CreateFrame("Frame")
    local elapsed = 0
    t:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed >= delay then
            LC_BroadcastPending = false
            LC_BroadcastProfessions()
            t:SetScript("OnUpdate", nil)
        end
    end)
end

-- Schedule a listing/order re-broadcast after `delay` seconds
LC_ListingBroadcastPending = false
function LC_ScheduleListingBroadcast(delay)
    if LC_ListingBroadcastPending then return end
    LC_ListingBroadcastPending = true
    local t = CreateFrame("Frame")
    local elapsed = 0
    t:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed >= delay then
            LC_ListingBroadcastPending = false
            LC_TickerBroadcastListings()
            t:SetScript("OnUpdate", nil)
        end
    end)
end

-- ============================================================
-- Incoming message handler
-- ============================================================
LC_ChunkBuffer = {}   -- [sender][msgType] = { total, parts = {} }

-- LC_ChunkBuffer kept for safety but no longer used
LC_ChunkBuffer = {}

-- Heartbeat tracking
-- LC_HeartbeatMissed[player] = number of consecutive missed beats
LC_HeartbeatMissed  = {}
LC_BEAT_INTERVAL    = 45    -- seconds between heartbeats (proportional to send rate)
LC_BEAT_MISS_LIMIT  = 3     -- missed beats before marking offline
LC_BeatAcc          = 0

-- UI dirty flag - set true whenever data changes, polled every 0.2s
-- Matches PallyPower uiDirty pattern for real-time updates
LC_UIDirty   = false
LC_UIPollAcc = 0
LC_UI_POLL   = 0.2   -- seconds between UI refresh checks

-- UI is "busy" when the dropdown is open, an editbox has focus,
-- or the user is on the Post tab filling in a form.
-- Never refresh while busy - it destroys dropdowns and kicks editbox focus.
function LC_UIIsBusy()
    -- Dropdown open
    if LC_DropdownOpen then return true end
    -- Post tab active (user may be typing)
    if LC_ActiveTab == "post" then return true end
    -- Recipe panel open
    if LC_RecipePanel and LC_RecipePanel:IsShown() then return true end
    return false
end

local lcUIPoll = CreateFrame("Frame")
lcUIPoll:SetScript("OnUpdate", function()
    LC_UIPollAcc = LC_UIPollAcc + arg1
    if LC_UIPollAcc >= LC_UI_POLL then
        LC_UIPollAcc = 0
        if LC_UIDirty and LC_Window and LC_Window:IsShown() then
            if not LC_UIIsBusy() then
                LC_UIDirty = false
                LC_RefreshUI()
            end
            -- If busy, leave dirty=true and retry next poll
        end
    end
end)

-- Receive from CHAT_MSG_CHANNEL
-- Format: "LeviaCraft:MSGTYPE:payload"
-- arg1=message, arg2=sender, arg3=language, arg4=channelString, arg5=?, arg6=?, arg7=channelNum, arg8=channelName
-- Raw debug frame - catches ALL channel events with zero filtering
-- This tells us if CHAT_MSG_CHANNEL fires at all for other players
local lcRawDebug = CreateFrame("Frame")
lcRawDebug:RegisterEvent("CHAT_MSG_CHANNEL")
lcRawDebug:SetScript("OnEvent", function()
    if LC_DEBUG_RECV then
        LC_Print("RAW_CHAN: from=" .. tostring(arg2) .. " msg=" .. string.sub(tostring(arg1), 1, 50))
    end
end)

function LC_OnChannelMessage(msg, sender)
    if sender == UnitName("player") then return end
    -- Strip "LeviaCraft:" prefix, then split msgType:payload
    local withoutPrefix = string.sub(msg, string.len(LEVIA_CRAFT_PREFIX) + 2)
    local msgType, rest = LC_Match(withoutPrefix, "^([^:]+):(.*)$")
    if not msgType then return end
    LC_DispatchMessage(msgType, rest, sender)
end

function LC_DispatchMessage(msgType, payload, sender)
    -- Any message from a sender means they're online - update their status
    if sender and sender ~= "" and sender ~= UnitName("player") then
        LC_HeartbeatMissed[sender] = 0
        if LC_Registry[sender] then
            if not LC_Registry[sender].online then
                LC_Registry[sender].online = true
                LC_UIDirty = true
            end
        else
            -- Create stub entry for unknown senders
            LC_Registry[sender] = { profs = {}, online = true, updated = GetTime() }
            LC_UIDirty = true
        end
    end

    if msgType == LC_MSG.PROF_DATA then
        LC_HandleProfData(payload, sender)

    elseif msgType == LC_MSG.HELLO then
        -- Someone logged in: mark them online immediately
        if not LC_Registry[sender] then
            LC_Registry[sender] = { profs = {}, online = true, updated = GetTime() }
        else
            LC_Registry[sender].online = true
        end
        LC_HeartbeatMissed[sender] = 0
        LC_UIDirty = true
        -- Respond immediately with beat + profession data (staggered to avoid collision)
        LC_Send(LC_MSG.BEAT, UnitName("player"))
        LC_ScheduleBroadcast(math.random(1, 3))
        LC_ScheduleListingBroadcast(math.random(2, 5))

    elseif msgType == LC_MSG.REQUEST then
        -- Someone wants our data - send beat first so they see us online fast
        LC_Send(LC_MSG.BEAT, UnitName("player"))
        LC_ScheduleBroadcast(math.random(0, 2))
        LC_ScheduleListingBroadcast(math.random(1, 4))

    elseif msgType == LC_MSG.PING then
        -- Refresh requested: send beat immediately + full data with jitter
        LC_Send(LC_MSG.BEAT, UnitName("player"))
        LC_ScheduleBroadcast(math.random(1, 5))
        LC_ScheduleListingBroadcast(math.random(2, 7))

    elseif msgType == LC_MSG.POST_LIST then
        LC_HandleListing(payload)

    elseif msgType == LC_MSG.POST_BUY then
        LC_HandleBuyOrder(payload)

    elseif msgType == LC_MSG.DEL_LIST then
        LeviaCraftDB.listings[payload] = nil
        -- Store tombstone so re-broadcast of old POST doesn't resurrect it
        if not LeviaCraftDB.deleted then LeviaCraftDB.deleted = {} end
        LeviaCraftDB.deleted[payload] = { owner = sender, t = GetTime(), kind = "L" }
        LC_UIDirty = true

    elseif msgType == LC_MSG.DEL_BUY then
        LeviaCraftDB.orders[payload] = nil
        if not LeviaCraftDB.deleted then LeviaCraftDB.deleted = {} end
        LeviaCraftDB.deleted[payload] = { owner = sender, t = GetTime(), kind = "B" }
        LC_UIDirty = true

    elseif msgType == LC_MSG.FILL_BUY then
        local oid, status = LC_Match(payload, "^([^~]+)~(.+)$")
        if oid and LeviaCraftDB.orders[oid] then
            LeviaCraftDB.orders[oid].status = status
        end
        LC_UIDirty = true

    elseif msgType == LC_MSG.CLR_LIST then
        local crafter = payload
        for id, l in pairs(LeviaCraftDB.listings) do
            if l.crafter == crafter then
                LeviaCraftDB.listings[id] = nil
                LeviaCraftDB.deleted[id] = { owner = crafter, t = GetTime(), kind = "L" }
            end
        end
        LC_UIDirty = true

    elseif msgType == LC_MSG.CLR_BUY then
        local buyer = payload
        for id, o in pairs(LeviaCraftDB.orders) do
            if o.buyer == buyer then
                LeviaCraftDB.orders[id] = nil
                LeviaCraftDB.deleted[id] = { owner = buyer, t = GetTime(), kind = "B" }
            end
        end
        LC_UIDirty = true

    elseif msgType == LC_MSG.BYE then
        if LC_Registry[sender] then
            LC_Registry[sender].online = false
            LC_UIDirty = true
        end
        LC_HeartbeatMissed[sender] = 0

    elseif msgType == LC_MSG.BEAT then
        LC_HeartbeatMissed[sender] = 0
        if LC_Registry[sender] then
            if not LC_Registry[sender].online then
                LC_Registry[sender].online = true
                LC_UIDirty = true
            end
        else
            -- New player - create stub entry so they appear online immediately
            -- then request their full data
            LC_Registry[sender] = { profs = {}, online = true, updated = GetTime() }
            LC_UIDirty = true
            LC_Send(LC_MSG.REQUEST, sender)
        end
    end
end

function LC_HandleProfData(payload, sender)
    -- Format: name~class~Prof1:skill:max;Prof2:skill:max
    if LC_DEBUG_RECV then
        LC_Print("ProfData from " .. tostring(sender) .. ": [" .. string.sub(tostring(payload),1,80) .. "]")
    end
    local name, class, profStr = LC_Match(payload, "^([^~]+)~([^~]+)~(.*)$")
    if not name then
        if LC_DEBUG_RECV then LC_Print("  -> PARSE FAILED on: " .. tostring(payload)) end
        return
    end
    if LC_DEBUG_RECV then
        LC_Print("  -> name=" .. tostring(name) .. " class=" .. tostring(class) .. " profs=" .. tostring(profStr))
    end

    local profs = {}
    if profStr and profStr ~= "" then
        for entry in string.gmatch(profStr .. ";", "([^;]+);") do
            local pname, skill, max = LC_Match(entry, "^([^:]+):(%d+):(%d+)$")
            if pname then
                profs[table.getn(profs) + 1] = { name = pname, skill = tonumber(skill), max = tonumber(max) }
            end
        end
    end

    LC_Registry[name] = {
        profs   = profs,
        class   = class,
        updated = GetTime(),
        online  = true,
    }
    LC_HeartbeatMissed[name] = 0

    LC_UIDirty = true
end

function LC_HandleListing(payload)
    local id, crafter, item, price, note = LC_Match(payload, "^([^~]+)~([^~]+)~([^~]+)~([^~]+)~(.*)$")
    if not id then return end
    -- Ignore if we have a tombstone for this ID (it was deleted)
    if LeviaCraftDB.deleted and LeviaCraftDB.deleted[id] then return end
    LeviaCraftDB.listings[id] = {
        id = id, crafter = crafter, item = item,
        price = price, note = note, posted = GetTime(),
    }
    LC_UIDirty = true
end

function LC_HandleBuyOrder(payload)
    local id, buyer, item, payment, note = LC_Match(payload, "^([^~]+)~([^~]+)~([^~]+)~([^~]+)~(.*)$")
    if not id then return end
    -- Ignore if tombstoned
    if LeviaCraftDB.deleted and LeviaCraftDB.deleted[id] then return end
    LeviaCraftDB.orders[id] = {
        id = id, buyer = buyer, item = item,
        payment = payment, note = note, posted = GetTime(),
    }
    LC_UIDirty = true
end

-- ============================================================
-- Slash commands
-- ============================================================
function LC_SlashHandler(msg)
    local cmd, args = LC_Match(msg, "^(%S*)%s*(.*)$")
    cmd = string.lower(cmd or "")

    if cmd == "" or cmd == "show" then
        LC_ToggleWindow()

    elseif cmd == "scan" then
        LC_BroadcastProfessions()
        LC_Print("Professions scanned and broadcast to guild.")

    elseif cmd == "ping" then
        LC_Send(LC_MSG.PING, "")
        LC_Print("Requested profession data from all online guild members.")

    elseif cmd == "sell" then
        -- /lcraft sell <item>;<price>;<note>
        local item, price, note = LC_Match(args, "^([^;]+);?([^;]*);?(.*)$")
        if item and item ~= "" then
            LC_PostListing(LC_Trim(item), LC_Trim(note), LC_Trim(price) ~= "" and LC_Trim(price) or nil)
        else
            LC_Print("Usage: /lcraft sell <item>;<price>;<note>")
        end

    elseif cmd == "buy" then
        -- /lcraft buy <item>;<payment>;<note>
        local item, payment, note = LC_Match(args, "^([^;]+);?([^;]*);?(.*)$")
        if item and item ~= "" then
            LC_PostBuyOrder(LC_Trim(item), LC_Trim(payment) ~= "" and LC_Trim(payment) or nil, LC_Trim(note))
        else
            LC_Print("Usage: /lcraft buy <item>;<payment>;<note>")
        end

    elseif cmd == "debug" then
        LC_DEBUG_RECV = not LC_DEBUG_RECV
        LC_Print("Receive debug: " .. (LC_DEBUG_RECV and "|cff00ff00ON|r" or "|cffff4444OFF|r"))

    elseif cmd == "test" then
        local me = UnitName("player")
        local profs = LC_ScanMyProfessions()
        LC_Print("Scanning " .. table.getn(profs) .. " professions for " .. me)
        for _, p in ipairs(profs) do
            LC_Print("  " .. p.name .. " " .. p.skill .. "/" .. p.max)
        end
        -- Show fresh channel lookup
        local freshID = LC_GetChannelID and LC_GetChannelID() or LC_CHANNEL_ID
        LC_Print("LC_CHANNEL_ID (cached)=" .. tostring(LC_CHANNEL_ID))
        LC_Print("Channel (fresh lookup)=" .. tostring(freshID))
        -- Force send directly to test
        if freshID then
            local testMsg = LEVIA_CRAFT_PREFIX .. ":TEST:" .. me
            SendChatMessage(testMsg, "CHANNEL", nil, freshID)
            LC_Print("Direct test message sent to channel " .. tostring(freshID))
        else
            LC_Print("|cffff0000ERROR: Not in LeviaCraft channel!|r")
            LC_Print("Attempting to join...")
            JoinChannelByName(LC_CHANNEL_NAME)
        end
        LC_BroadcastProfessions(true)
        LC_Print("Broadcast queued.")

    elseif cmd == "chan" then
        -- Print channel info
        for i = 1, 10 do
            local id, name = GetChannelName(i)
            if id and id > 0 then
                LC_Print("Channel " .. i .. ": id=" .. tostring(id) .. " name=" .. tostring(name))
            end
        end
        LC_Print("LC_CHANNEL_ID=" .. tostring(LC_CHANNEL_ID))

    elseif cmd == "cleardata" then
        LeviaCraftDB.registry = {}
        LC_Registry = LeviaCraftDB.registry
        LC_Print("Registry cleared. Run /lcraft ping to repopulate from online members.")

    elseif cmd == "help" then
        LC_Print("|cff00d1ffLeviaCraft commands:|r")
        LC_Print("  /lcraft            - Open the marketplace window")
        LC_Print("  /lcraft scan       - Re-scan and broadcast your professions")
        LC_Print("  /lcraft ping       - Request all guildies rebroadcast their profs")
        LC_Print("  /lcraft sell <item>;<price>;<note>  - Post a craft listing")
        LC_Print("  /lcraft buy <item>;<payment>;<note> - Post a buy order")
        LC_Print("  /lcraft cleardata  - Wipe saved registry (use if data looks stale)")
    else
        LC_Print("Unknown command. Type |cff00d1ff/lcraft help|r for usage.")
    end
end

-- ============================================================
-- Utility
-- ============================================================
function LC_Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00d1ff[LeviaCraft]|r " .. msg)
end

function LC_Trim(s)
    if not s then return "" end
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function LC_FormatAge(t)
    local age = GetTime() - (t or 0)
    if age < 60 then return "just now"
    elseif age < 3600 then return math.floor(age/60) .. "m ago"
    else return math.floor(age/3600) .. "h ago"
    end
end

-- ============================================================
-- Class colour helper
-- ============================================================
LC_CLASS_COLOR = {
    ["Warrior"]     = "ffc79c6e",
    ["Paladin"]     = "fff58cba",
    ["Hunter"]      = "ffabd473",
    ["Rogue"]       = "fffff569",
    ["Priest"]      = "ffffffff",
    ["Shaman"]      = "ff0070de",
    ["Mage"]        = "ff69ccf0",
    ["Warlock"]     = "ff9482c9",
    ["Druid"]       = "ffff7d0a",
    ["Death Knight"]= "ffc41f3b",
}

function LC_ClassColor(class)
    return LC_CLASS_COLOR[class] or "ffaaaaaa"
end

-- ============================================================
-- Repeating 10s scan ticker
-- Scans professions and re-broadcasts everything every 10 seconds.
-- Staggers broadcasts randomly within the window so a full guild
-- doesn't all send at the same instant.
-- ============================================================
LC_ScanTicker = nil
LC_ScanElapsed = 0
LC_SCAN_INTERVAL = 60   -- seconds between full re-broadcasts

function LC_StartScanTicker()
    if LC_ScanTicker then return end  -- already running

    -- Fire immediately on first tick
    LC_BroadcastProfessions(true)
    LC_BroadcastMyListings()

    LC_ScanTicker = CreateFrame("Frame")
    LC_ScanTicker:SetScript("OnUpdate", function()
        local dt = arg1

        -- Data broadcast ticker
        LC_ScanElapsed = LC_ScanElapsed + dt
        if LC_ScanElapsed >= LC_SCAN_INTERVAL then
            LC_ScanElapsed = 0
            if not LC_UIIsBusy() then
                LC_BroadcastProfessions(true)
                LC_TickerBroadcastListings()
            else
                LC_ScanElapsed = LC_SCAN_INTERVAL - 3
            end
        end

        -- Heartbeat ticker
        LC_BeatAcc = LC_BeatAcc + dt
        if LC_BeatAcc >= LC_BEAT_INTERVAL then
            LC_BeatAcc = 0
            -- Send our heartbeat
            LC_Send(LC_MSG.BEAT, UnitName("player"))
            -- Increment missed count for everyone in registry
            -- (will be cleared when we receive their beat)
            local dirty = false
            for name, data in pairs(LC_Registry) do
                if name ~= UnitName("player") and data.online then
                    LC_HeartbeatMissed[name] = (LC_HeartbeatMissed[name] or 0) + 1
                    if LC_HeartbeatMissed[name] >= LC_BEAT_MISS_LIMIT then
                        data.online = false
                        LC_HeartbeatMissed[name] = 0
                        dirty = true
                    end
                end
            end
            if dirty then LC_UIDirty = true end
        end
    end)
end

-- ============================================================
-- Event frame
-- ============================================================
local frame = CreateFrame("Frame", "LeviaCraftEventFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("CHAT_MSG_CHANNEL_JOIN")
frame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")

frame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "LeviaCraft" then
        LC_InitDB()

        -- Point LC_Registry at the persisted table so offline members stay visible
        LC_Registry = LeviaCraftDB.registry

        -- Mark all existing entries as offline until they broadcast this session
        for _, entry in pairs(LC_Registry) do
            entry.online = false
        end

        -- Restore saved listings/orders into active tables
        for id, l in pairs(LeviaCraftDB.listings) do
            if l.crafter == UnitName("player") then
                LC_MyListings[id] = l
            end
        end
        for id, o in pairs(LeviaCraftDB.orders) do
            if o.buyer == UnitName("player") then
                LC_MyBuys[id] = o
            end
        end

        SLASH_LEVIA_CRAFT1 = "/lcraft"
        SLASH_LEVIA_CRAFT2 = "/levicraft"
        SlashCmdList["LEVIA_CRAFT"] = LC_SlashHandler

        LC_Print("Loaded v" .. LEVIA_CRAFT_VERSION .. "  |cff888888/lcraft help|r")

    elseif event == "PLAYER_LOGIN" then
        -- Wait for channel to be fully available before broadcasting
        -- Poll every 0.5s until LC_CHANNEL_ID is set, then start
        LC_CreateMinimapButton()
        local t = CreateFrame("Frame")
        local elapsed = 0
        t:SetScript("OnUpdate", function()
            elapsed = elapsed + arg1
            -- Try joining channel after 2s
            if elapsed >= 2 and not LC_CHANNEL_ID then
                LC_JoinChannel()
            end
            -- Once channel is confirmed, start everything
            if elapsed >= 2 and LC_CHANNEL_ID then
                t:SetScript("OnUpdate", nil)
                LC_Send(LC_MSG.BEAT, UnitName("player"))
                LC_Send(LC_MSG.HELLO, UnitName("player"))
                LC_StartScanTicker()
            end
            -- Hard timeout: start anyway after 8s even without channel ID
            if elapsed >= 8 then
                t:SetScript("OnUpdate", nil)
                LC_StartScanTicker()
            end
        end)

    elseif event == "PLAYER_LOGOUT" then
        -- Send BYE immediately (no queue - we're logging out now)
        if LC_CHANNEL_ID then
            local msg = LEVIA_CRAFT_PREFIX .. ":BY:" .. UnitName("player")
            SendChatMessage(msg, "CHANNEL", nil, LC_CHANNEL_ID)
        end

    elseif event == "CHAT_MSG_CHANNEL_JOIN" or event == "CHAT_MSG_CHANNEL_NOTICE" then
        -- Suppress join/leave notices for our channel and re-hide it
        if arg9 and string.find(string.lower(arg9), string.lower(LC_CHANNEL_NAME)) then
            LC_HideChannel(LC_CHANNEL_ID)
        end

    elseif event == "CHAT_MSG_CHANNEL" then
        -- Dump raw args in debug mode so we can see exactly what arrives
        if LC_DEBUG_RECV then
            LC_Print("CHAN_EVENT: arg1=" .. string.sub(tostring(arg1),1,40) ..
                     " arg2=" .. tostring(arg2) ..
                     " arg4=" .. tostring(arg4) ..
                     " arg8=" .. tostring(arg8) ..
                     " arg9=" .. tostring(arg9))
        end
        -- Accept any message that starts with our prefix - simplest possible filter
        if arg1 and string.find(arg1, "^" .. LEVIA_CRAFT_PREFIX .. ":") then
            LC_OnChannelMessage(arg1, arg2)
        end
    end
end)

-- ============================================================
-- Craftable items by profession (common/useful vanilla items)
-- Used to populate the Post panel dropdown
-- ============================================================
LC_CRAFT_ITEMS = {
    ["Alchemy"] = {
        "Flask of Supreme Power", "Flask of Distilled Wisdom", "Flask of the Titans",
        "Flask of Chromatic Resistance", "Elixir of Brute Force", "Elixir of the Mongoose",
        "Elixir of Giants", "Elixir of Fortitude", "Greater Arcane Elixir",
        "Elixir of Shadow Power", "Elixir of Demonslaying", "Ony Flask (Elixir of Ancient Wisdom)",
        "Major Healing Potion", "Major Mana Potion", "Limited Invulnerability Potion",
        "Free Action Potion", "Greater Fire Protection Potion", "Greater Nature Protection Potion",
        "Greater Shadow Protection Potion", "Greater Arcane Protection Potion",
        "Transmute: Arcanite", "Transmute: Iron to Gold", "Transmute: Mithril to Truesilver",
    },
    ["Blacksmithing"] = {
        "Arcanite Champion", "Arcanite Reaper", "Dark Iron Sword", "Dark Iron Boots",
        "Dark Iron Helm", "Dark Iron Plate", "Fiery Chain Girdle",
        "Titanic Leggings", "Lionheart Helm", "Helm of the Great Chief",
        "Stronghold Gauntlets", "Enchanted Thorium Breastplate", "Ornate Thorium Handaxe",
        "Thorium Shield Spike", "Arcanite Rod",
    },
    ["Enchanting"] = {
        "Enchant Weapon - Crusader", "Enchant Weapon - Lifestealing", "Enchant Weapon - Mighty Intellect",
        "Enchant Weapon - Spell Power", "Enchant Weapon - Mongoose",
        "Enchant Weapon - Fiery Weapon", "Enchant Weapon - Unholy",
        "Enchant Chest - Greater Stats", "Enchant Chest - Major Mana",
        "Enchant Boots - Greater Agility", "Enchant Boots - Greater Stamina",
        "Enchant Cloak - Greater Resistance", "Enchant Gloves - Greater Agility",
        "Enchant Gloves - Healing Power", "Enchant Gloves - Shadow Power",
        "Enchant Bracers - Superior Strength", "Enchant Bracers - Healing Power",
        "Enchant Shield - Greater Stamina",
    },
    ["Engineering"] = {
        "Arcanite Dragonling", "Core Marksman Rifle", "Bloodvine Goggles",
        "Hyper-Radiant Flame Reflector", "Ultrasafe Transporter: Gadgetzan",
        "Goblin Jumper Cables XL", "Masterwork Target Dummy",
        "Dense Dynamite", "Thorium Grenade", "Iron Grenade",
        "Goblin Sapper Charge", "Gnomish Battle Chicken",
        "Force Reactive Disk", "Biznicks 247x128 Accurascope",
    },
    ["Leatherworking"] = {
        "Chromatic Mantle of the Dawn", "Corehound Belt", "Molten Helm",
        "Black Dragonscale Breastplate", "Blue Dragonscale Breastplate",
        "Warbear Woolies", "Shifting Cloak", "Heavy Scorpid Belt",
        "Devilsaur Gauntlets", "Devilsaur Leggings", "Runic Leather Headband",
        "Shadowcraft Set Pieces", "Sandstalker Ankleguards",
    },
    ["Tailoring"] = {
        "Bloodvine Vest", "Bloodvine Leggings", "Bloodvine Boots",
        "Robe of the Archmage", "Robe of Arcana", "Truefaith Vestments",
        "Truefaith Gloves", "Flarecore Robe", "Flarecore Gloves",
        "Mooncloth Robe", "Mooncloth Bag", "Bottomless Bag",
        "Core Felcloth Bag", "Felcloth Bag", "Runecloth Bag",
    },
    ["Jewelcrafting"] = {
        "Bold Living Ruby", "Delicate Living Ruby", "Brilliant Dawnstone",
        "Smooth Dawnstone", "Solid Star of Elune", "Stormy Star of Elune",
        "Runed Living Ruby", "Teardrop Living Ruby", "Lustrous Star of Elune",
    },
    ["Cooking"] = {
        "Dirge's Kickin' Chimaerok Chops", "Smoked Desert Dumplings",
        "Dragonbreath Chili", "Runn Tum Tuber Surprise",
        "Tender Wolf Steak", "Grilled Squid", "Hot Wolf Ribs",
        "Nightfin Soup", "Poached Sunscale Salmon", "Blessed Sunfruit",
    },
    ["First Aid"] = {
        "Heavy Runecloth Bandage", "Runecloth Bandage",
        "Heavy Mageweave Bandage", "Mageweave Bandage",
    },
    ["Fishing"] = {
        "Stonescale Oil (Stonescale Eel)", "Nightfin Snapper", "Sunscale Salmon",
        "Firefin Snapper", "Spotted Yellowtail", "Winter Squid",
    },
    ["Survival"] = {
        "Survival Kit", "Field Ration", "Emergency Bandage",
        "Trap: Fire", "Trap: Frost", "Survival Elixir",
    },
}

-- Get craftable items for a player based on their known professions
function LC_GetCraftableItems(playerName)
    local items = {}
    local data = LC_Registry[playerName]
    if not data or not data.profs then return items end
    for _, prof in ipairs(data.profs) do
        local list = LC_CRAFT_ITEMS[prof.name]
        if list then
            for _, item in ipairs(list) do
                items[table.getn(items) + 1] = { item = item, prof = prof.name }
            end
        end
    end
    return items
end

-- ============================================================
-- Raw materials / reagents by category
-- Used in the Post panel "I Want This" dropdown for mats requests
-- ============================================================
LC_MAT_ITEMS = {
    ["Herbs"] = {
        "Dreamfoil", "Golden Sansam", "Mountain Silversage", "Plaguebloom",
        "Icecap", "Black Lotus", "Gromsblood", "Bloodvine",
        "Ghost Mushroom", "Blindweed", "Sungrass", "Khadgar's Whisker",
        "Fadeleaf", "Goldenseal", "Wild Steelbloom", "Briarthorn",
        "Mageroyal", "Peacebloom", "Silverleaf", "Earthroot",
        "Swiftthistle", "Stranglekelp", "Bruiseweed",
    },
    ["Ore & Metal"] = {
        "Arcanite Bar", "Dark Iron Bar", "Thorium Bar", "Mithril Bar",
        "Truesilver Bar", "Gold Bar", "Iron Bar", "Steel Bar",
        "Bronze Bar", "Tin Bar", "Copper Bar",
        "Thorium Ore", "Mithril Ore", "Iron Ore", "Tin Ore", "Copper Ore",
        "Dark Iron Ore", "Small Thorium Vein", "Rich Thorium Vein",
    },
    ["Leather & Hide"] = {
        "Rugged Leather", "Thick Leather", "Heavy Leather", "Medium Leather",
        "Light Leather", "Rugged Hide", "Thick Hide", "Heavy Hide",
        "Worn Dragonscale", "Red Dragonscale", "Blue Dragonscale",
        "Black Dragonscale", "Devilsaur Leather", "Warbear Leather",
        "Scorpid Scale", "Core Leather",
    },
    ["Cloth"] = {
        "Runecloth", "Mageweave Cloth", "Silk Cloth",
        "Wool Cloth", "Linen Cloth", "Felcloth", "Mooncloth",
    },
    ["Enchanting Mats"] = {
        "Nexus Crystal", "Large Brilliant Shard", "Small Brilliant Shard",
        "Greater Eternal Essence", "Lesser Eternal Essence",
        "Illusion Dust", "Large Radiant Shard", "Small Radiant Shard",
        "Greater Nether Essence", "Lesser Nether Essence",
        "Dream Dust", "Large Glowing Shard", "Small Glowing Shard",
        "Greater Astral Essence", "Lesser Astral Essence",
        "Soul Dust", "Strange Dust", "Vision Dust",
    },
    ["Gems & Stones"] = {
        "Azerothian Diamond", "Huge Emerald", "Large Opal",
        "Blue Sapphire", "Star Ruby", "Citrine", "Aquamarine",
        "Solid Stone", "Heavy Stone", "Coarse Stone", "Rough Stone",
        "Elemental Earth", "Elemental Fire", "Elemental Water", "Elemental Air",
        "Core of Earth", "Heart of Fire", "Globe of Water", "Breath of Wind",
    },
    ["Potions & Flasks"] = {
        "Flask of Supreme Power", "Flask of Distilled Wisdom",
        "Flask of the Titans", "Flask of Chromatic Resistance",
        "Elixir of the Mongoose", "Elixir of Brute Force",
        "Greater Arcane Elixir", "Elixir of Shadow Power",
        "Major Healing Potion", "Major Mana Potion",
        "Free Action Potion", "Limited Invulnerability Potion",
        "Greater Fire Protection Potion", "Greater Nature Protection Potion",
        "Greater Shadow Protection Potion", "Greater Arcane Protection Potion",
    },
    ["Trade Goods"] = {
        "Essence of Fire", "Essence of Water", "Essence of Air",
        "Essence of Earth", "Essence of Undeath", "Essence of Magic",
        "Living Essence", "Corrupted Essence",
        "Ichor of Undeath", "Glob of Ectoplasm",
        "Righteous Orb", "Pristine Black Diamond",
        "Blood of the Mountain", "Lava Core", "Fiery Core",
        "Ironweb Spider Silk", "Bolt of Runecloth", "Bolt of Mageweave",
    },
    ["Food & Drink"] = {
        "Dirge's Kickin' Chimaerok Chops", "Smoked Desert Dumplings",
        "Grilled Squid", "Hot Wolf Ribs", "Tender Wolf Steak",
        "Nightfin Soup", "Poached Sunscale Salmon",
        "Blessed Sunfruit", "Runn Tum Tuber Surprise",
        "Dragonbreath Chili", "Alterac Swiss",
    },
}

-- Merged lookup for the Post panel dropdown: returns craft items + mat items
function LC_GetAllBuyItems()
    local items = {}
    local seen  = {}
    -- Crafted items from all known crafters
    for crafter, data in pairs(LC_Registry) do
        if crafter ~= UnitName("player") and data.profs then
            for _, prof in ipairs(data.profs) do
                local list = LC_CRAFT_ITEMS[prof.name]
                if list then
                    for _, item in ipairs(list) do
                        if not seen[item] then
                            seen[item] = true
                            items[table.getn(items) + 1] = {
                                item = item, prof = prof.name,
                                crafter = crafter, isMat = false
                            }
                        end
                    end
                end
            end
        end
    end
    -- Raw materials (always shown regardless of who's online)
    for cat, list in pairs(LC_MAT_ITEMS) do
        for _, item in ipairs(list) do
            if not seen[item] then
                seen[item] = true
                items[table.getn(items) + 1] = {
                    item = item, prof = cat,
                    crafter = nil, isMat = true
                }
            end
        end
    end
    return items
end
