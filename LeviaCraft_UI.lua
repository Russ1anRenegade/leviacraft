-- LeviaCraft_UI.lua
-- Tabbed marketplace window: Professions | Craft Listings | Buy Orders | Post

LC_Window      = nil
LC_CONTENT_WIDTH = 462   -- fixed content area width (avoids nil from GetWidth before shown)
LC_ActiveTab   = "profs"
LC_ScrollFrame = nil
LC_Rows        = {}
LC_PostMode    = nil   -- "sell" or "buy" when post panel is open

-- ============================================================
-- Colours
-- ============================================================
local CLR = {
    gold    = "|cffffd700",
    teal    = "|cff00d1ff",
    green   = "|cff00ff7f",
    red     = "|cffff4444",
    grey    = "|cff888888",
    white   = "|cffffffff",
    reset   = "|r",
}

-- ============================================================
-- Main window
-- ============================================================
function LC_CreateWindow()
    if LC_Window then return end

    local f = CreateFrame("Frame", "LeviaCraftWindow", UIParent)
    f:SetWidth(520)
    f:SetHeight(460)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=11, right=12, top=12, bottom=11 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")
    f:Hide()

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText(CLR.teal .. "Levia" .. CLR.reset .. "Craft " .. CLR.grey .. "v" .. LEVIA_CRAFT_VERSION .. "  Guild Marketplace" .. CLR.reset)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Divider line under title
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")
    div:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
    div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -36)
    div:SetHeight(1)

    -- ---- Tabs ----
    local tabs = {
        { id = "profs",    label = "Professions",   width = 120 },
        { id = "listings", label = "Craft Listings", width = 120 },
        { id = "orders",   label = "Buy Orders",    width = 110 },
        { id = "post",     label = "+ Post",         width = 90  },
    }
    f.tabs = {}
    local tabX = 14
    for _, t in ipairs(tabs) do
        local btn = CreateFrame("Button", nil, f)
        btn:SetHeight(26)
        btn:SetWidth(t.width)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", tabX, -38)
        tabX = tabX + t.width + 4

        -- Inactive background
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(btn)
        bg:SetTexture(0.08, 0.08, 0.12, 1)
        btn.bg = bg

        -- Active highlight overlay (hidden by default)
        local hl = btn:CreateTexture(nil, "ARTWORK")
        hl:SetAllPoints(btn)
        hl:SetTexture(0.1, 0.35, 0.6, 1)
        hl:Hide()
        btn.hl = hl

        -- Bottom accent bar (shows on active tab)
        local bar = btn:CreateTexture(nil, "OVERLAY")
        bar:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT",  2, 0)
        bar:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 0)
        bar:SetHeight(2)
        bar:SetTexture(0, 0.8, 1, 1)
        bar:Hide()
        btn.bar = bar

        -- Hover tint
        local hov = btn:CreateTexture(nil, "ARTWORK")
        hov:SetAllPoints(btn)
        hov:SetTexture(1, 1, 1, 0.07)
        hov:Hide()
        btn.hov = hov

        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetAllPoints(btn)
        lbl:SetText(t.label)
        lbl:SetTextColor(0.65, 0.65, 0.65)
        btn.lbl = lbl

        local tabId = t.id
        btn:SetScript("OnClick", function() LC_SetTab(tabId) end)
        btn:SetScript("OnEnter", function()
            if LC_ActiveTab ~= tabId then btn.hov:Show() end
        end)
        btn:SetScript("OnLeave", function() btn.hov:Hide() end)

        f.tabs[t.id] = btn
    end

    -- ---- Scroll area ----
    local scrollBG = CreateFrame("Frame", nil, f)
    scrollBG:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, -72)
    scrollBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 50)
    scrollBG:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left=4, right=4, top=4, bottom=4 },
    })
    scrollBG:SetBackdropColor(0.04, 0.05, 0.08, 0.97)

    local sf = CreateFrame("ScrollFrame", "LCScrollFrame", scrollBG, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",    scrollBG, "TOPLEFT",    4, -4)
    sf:SetPoint("BOTTOMRIGHT",scrollBG, "BOTTOMRIGHT",-28, 4)
    LC_ScrollFrame = sf

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(LC_CONTENT_WIDTH)
    content:SetHeight(1)
    sf:SetScrollChild(content)
    f.content = content

    -- ---- Status bar at bottom ----
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 18)
    status:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -40, 18)
    status:SetJustifyH("LEFT")
    status:SetText("")
    f.status = status

    -- Refresh button
    local refBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    refBtn:SetWidth(70)
    refBtn:SetHeight(22)
    refBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 14)
    refBtn:SetText("Ping")
    refBtn:SetScript("OnClick", function()
        LC_RefreshUI()
        LC_Send(LC_MSG.PING, "")
        f.status:SetText(CLR.teal .. "Pinged channel — waiting for responses..." .. CLR.reset)
    end)

    LC_Window = f
    LC_SetTab("profs")
end

-- ============================================================
-- Tab switching
-- ============================================================
function LC_SetTab(id)
    LC_ActiveTab = id

    if LC_Window and LC_Window.tabs then
        for tid, btn in pairs(LC_Window.tabs) do
            if tid == id then
                btn.bg:SetTexture(0.06, 0.18, 0.32, 1)
                btn.hl:Show()
                btn.bar:Show()
                btn.hov:Hide()
                btn.lbl:SetTextColor(0, 0.85, 1)   -- bright teal for active
            else
                btn.bg:SetTexture(0.08, 0.08, 0.12, 1)
                btn.hl:Hide()
                btn.bar:Hide()
                btn.lbl:SetTextColor(0.6, 0.6, 0.6)
            end
        end
    end

    LC_RefreshUI()
end

-- ============================================================
-- Main refresh dispatcher
-- ============================================================
function LC_RefreshUI()
    if not LC_Window then return end
    LC_ClearRows()

    if LC_ActiveTab == "profs" then
        LC_DrawProfessions()
    elseif LC_ActiveTab == "listings" then
        LC_DrawListings()
    elseif LC_ActiveTab == "orders" then
        LC_DrawBuyOrders()
    elseif LC_ActiveTab == "post" then
        LC_DrawPostPanel()
    end
end

-- ============================================================
-- Clear content area
-- ============================================================
function LC_ClearRows()
    -- Close any open dropdown first
    if LC_DropdownFrame then
        LC_DropdownFrame:Hide()
        LC_DropdownFrame = nil
        LC_DropdownOpen = false
    end
    -- Destroy tracked rows by hiding AND re-parenting to a hidden graveyard frame
    -- SetParent(nil) is unreliable in vanilla; reparent to hidden frame instead
    if not LC_Graveyard then
        LC_Graveyard = CreateFrame("Frame", "LCGraveyard", UIParent)
        LC_Graveyard:Hide()
        LC_Graveyard:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -9000, -9000)
    end
    for _, r in ipairs(LC_Rows) do
        r:Hide()
        r:ClearAllPoints()
        r:SetParent(LC_Graveyard)
    end
    LC_Rows = {}
    LC_PostInputs = {}
    if LC_Window then
        LC_Window.content:SetHeight(1)
        LCScrollFrame:SetVerticalScroll(0)
    end
end

-- ============================================================
-- Add a row frame to content
-- ============================================================
local ROW_HEIGHT = 28
local ROW_PAD    = 4

function LC_AddRow(yOffset)
    local r = CreateFrame("Frame", nil, LC_Window.content)
    r:SetWidth(LC_CONTENT_WIDTH)
    r:SetHeight(ROW_HEIGHT)
    r:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, yOffset)
    LC_Rows[table.getn(LC_Rows) + 1] = r

    -- Alternating row tint
    if mod(table.getn(LC_Rows), 2) == 0 then
        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(1, 1, 1, 0.03)
    end

    LC_Window.content:SetHeight(math.abs(yOffset) + ROW_HEIGHT + ROW_PAD)
    return r
end

function LC_AddSectionHeader(text, yOffset)
    local r = CreateFrame("Frame", nil, LC_Window.content)
    r:SetWidth(LC_CONTENT_WIDTH)
    r:SetHeight(20)
    r:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, yOffset)
    LC_Rows[table.getn(LC_Rows) + 1] = r

    local bg = r:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0.1, 0.3, 0.5, 0.5)

    local lbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", r, "LEFT", 8, 0)
    lbl:SetText(CLR.teal .. text .. CLR.reset)

    LC_Window.content:SetHeight(math.abs(yOffset) + 20 + ROW_PAD)
    return r
end

-- ============================================================
-- TAB: Professions
-- ============================================================
function LC_DrawProfessions()
    local y = -ROW_PAD
    local me = UnitName("player")
    local onlineCount = 0
    local offlineCount = 0

    LC_AddSectionHeader("  Player                Class            Professions & Skill", y)
    y = y - 22

    local sorted = {}
    for name, data in pairs(LC_Registry) do
        sorted[table.getn(sorted) + 1] = { name = name, data = data }
    end

    -- Online first, then offline, each group alphabetical
    table.sort(sorted, function(a, b)
        local ao = a.data.online == true
        local bo = b.data.online == true
        if ao ~= bo then return ao end
        return a.name < b.name
    end)

    -- Ensure self is present even before first broadcast
    local selfFound = false
    for _, e in ipairs(sorted) do
        if e.name == me then selfFound = true break end
    end
    if not selfFound then
        local myProfs = LC_ScanMyProfessions()
        if table.getn(myProfs) > 0 then
            table.insert(sorted, 1, { name = me, data = {
                profs = myProfs, class = UnitClass("player"),
                updated = GetTime(), online = true
            }})
        end
    end

    if table.getn(sorted) == 0 then
        local r = LC_AddRow(y)
        local t = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("LEFT", r, "LEFT", 12, 0)
        t:SetText(CLR.grey .. "No data yet. Type /lcraft ping to request from guildmates." .. CLR.reset)
        return
    end

    local shownOfflineHeader = false

    for _, entry in ipairs(sorted) do
        local name = entry.name
        local data = entry.data
        local isOnline = data.online == true

        -- Offline section divider
        if not isOnline and not shownOfflineHeader then
            shownOfflineHeader = true
            LC_AddSectionHeader("  Offline Members  (cached data)", y)
            y = y - 22
        end

        local r = LC_AddRow(y)
        y = y - ROW_HEIGHT - ROW_PAD

        -- Make entire row a button so it's clickable
        r:EnableMouse(true)

        -- Dim overlay for offline rows
        if not isOnline then
            local dimTex = r:CreateTexture(nil, "BACKGROUND")
            dimTex:SetAllPoints(r)
            dimTex:SetTexture(0, 0, 0, 0.4)
            offlineCount = offlineCount + 1
        else
            onlineCount = onlineCount + 1
        end

        -- Hover highlight
        local hov = r:CreateTexture(nil, "ARTWORK")
        hov:SetAllPoints(r)
        hov:SetTexture(0.2, 0.5, 0.8, 0.15)
        hov:Hide()

        -- Click hint on right side
        local hint = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        hint:SetText(CLR.grey .. "view recipes ›" .. CLR.reset)
        hint:Hide()

        r:SetScript("OnEnter", function()
            hov:Show()
            hint:Show()
        end)
        r:SetScript("OnLeave", function()
            hov:Hide()
            hint:Hide()
        end)

        local pName = name
        local pData = data
        r:SetScript("OnMouseDown", function()
            LC_OpenRecipePanel(pName, pData)
        end)

        -- Online indicator dot
        local dot = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dot:SetPoint("LEFT", r, "LEFT", 2, 0)
        dot:SetWidth(6)
        if isOnline then
            dot:SetText("|cff00ff00•|r")
        else
            dot:SetText("|cff555555•|r")
        end

        -- Player name
        local cc = isOnline and LC_ClassColor(data.class) or "ff555555"
        local nameLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameLbl:SetPoint("LEFT", r, "LEFT", 10, 0)
        nameLbl:SetWidth(108)
        nameLbl:SetText("|c" .. cc .. name .. CLR.reset)

        -- Class
        local classLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLbl:SetPoint("LEFT", r, "LEFT", 122, 0)
        classLbl:SetWidth(88)
        classLbl:SetText(CLR.grey .. (data.class or "?") .. CLR.reset)

        -- Professions summary
        if data.profs and table.getn(data.profs) > 0 then
            local profParts = {}
            for _, p in ipairs(data.profs) do
                local col
                if not isOnline then
                    col = "|cff555555"
                elseif p.skill >= 300 then col = CLR.gold
                elseif p.skill >= 225 then col = CLR.green
                else col = CLR.white
                end
                profParts[table.getn(profParts) + 1] = col .. p.name .. " " .. p.skill .. CLR.reset
            end
            local profLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            profLbl:SetPoint("LEFT", r, "LEFT", 213, 0)
            profLbl:SetWidth(200)
            profLbl:SetText(table.concat(profParts, "  "))
        else
            local noProfLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noProfLbl:SetPoint("LEFT", r, "LEFT", 213, 0)
            noProfLbl:SetText(CLR.grey .. "No professions" .. CLR.reset)
        end
    end

    if LC_Window.status then
        LC_Window.status:SetText(
            CLR.grey .. onlineCount .. " online  |cff555555" .. offlineCount .. " offline (cached)|r" .. CLR.reset
        )
    end
end

-- ============================================================
-- TAB: Craft Listings
-- ============================================================
function LC_DrawListings()
    local y = -ROW_PAD
    local me = UnitName("player")
    local count = 0

    LC_AddSectionHeader("  Crafter             Item                             Price / Note", y)
    y = y - 22

    -- Sort: own listings first, then alphabetical by item
    local sorted = {}
    for id, l in pairs(LeviaCraftDB.listings) do
        sorted[table.getn(sorted) + 1] = l
    end
    table.sort(sorted, function(a, b)
        if a.crafter == me and b.crafter ~= me then return true end
        if b.crafter == me and a.crafter ~= me then return false end
        return (a.item or "") < (b.item or "")
    end)

    if table.getn(sorted) == 0 then
        local r = LC_AddRow(y)
        local t = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("LEFT", r, "LEFT", 12, 0)
        t:SetText(CLR.grey .. "No craft listings posted. Use the Post tab to offer your services." .. CLR.reset)
        return
    end

    for _, l in ipairs(sorted) do
        local r = LC_AddRow(y)
        y = y - ROW_HEIGHT - ROW_PAD
        count = count + 1

        local isMe = (l.crafter == me)

        -- Crafter
        local crafterData = LC_Registry[l.crafter]
        local cc = LC_ClassColor(crafterData and crafterData.class or nil)
        local cLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cLbl:SetPoint("LEFT", r, "LEFT", 8, 0)
        cLbl:SetWidth(110)
        cLbl:SetText("|c" .. cc .. l.crafter .. CLR.reset)

        -- Item
        local iLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        iLbl:SetPoint("LEFT", r, "LEFT", 120, 0)
        iLbl:SetWidth(165)
        iLbl:SetText(CLR.gold .. (l.item or "?") .. CLR.reset)

        -- Price
        local pLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pLbl:SetPoint("LEFT", r, "LEFT", 288, 0)
        pLbl:SetWidth(130)
        local priceStr = (l.price or "Tips/Mats")
        if l.note and l.note ~= "" then
            priceStr = priceStr .. CLR.grey .. "  " .. l.note .. CLR.reset
        end
        pLbl:SetText(CLR.green .. priceStr .. CLR.reset)

        -- Delete button (own listings only)
        if isMe then
            local del = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            del:SetWidth(24)
            del:SetHeight(18)
            del:SetPoint("RIGHT", r, "RIGHT", -6, 0)
            del:SetText("X")
            local lid = l.id
            del:SetScript("OnClick", function()
                LC_DeleteListing(lid)
                LC_RefreshUI()
            end)
        end

        -- Whisper button (others' listings)
        if not isMe then
            local wb = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            wb:SetWidth(52)
            wb:SetHeight(18)
            wb:SetPoint("RIGHT", r, "RIGHT", -6, 0)
            wb:SetText("Whisper")
            local crafter = l.crafter
            local item    = l.item
            wb:SetScript("OnClick", function()
                ChatFrame_OpenChat("/w " .. crafter .. " Hi! I'd like you to craft: " .. item)
            end)
        end
    end

    if LC_Window.status then
        LC_Window.status:SetText(CLR.grey .. count .. " craft listing(s)" .. CLR.reset)
    end
end

-- ============================================================
-- TAB: Buy Orders
-- ============================================================
function LC_DrawBuyOrders()
    local y = -ROW_PAD
    local me = UnitName("player")
    local count = 0

    -- Two-line header: cols + legend
    LC_AddSectionHeader("  Buyer           Item                    Payment          Status", y)
    y = y - 22

    -- Status legend row
    local legRow = CreateFrame("Frame", nil, LC_Window.content)
    legRow:SetWidth(LC_CONTENT_WIDTH)
    legRow:SetHeight(16)
    legRow:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, y)
    LC_Rows[table.getn(LC_Rows) + 1] = legRow
    LC_Window.content:SetHeight(math.abs(y) + 18)
    local leg = legRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leg:SetPoint("LEFT", legRow, "LEFT", 8, 0)
    leg:SetText(
        CLR.grey .. "Open" .. CLR.reset .. "  ▶  " ..
        "|cffffd700Mats Sent|r" .. "  ▶  " ..
        "|cff00aaffIn Progress|r" .. "  ▶  " ..
        "|cff00ff7fFilled!|r" ..
        CLR.grey .. "   (click status button to advance)" .. CLR.reset
    )
    y = y - 20

    -- Sort: my orders first (open ones on top), then by item name
    -- Filled orders sink to the bottom
    local sorted = {}
    for id, o in pairs(LeviaCraftDB.orders) do
        sorted[table.getn(sorted) + 1] = o
    end
    table.sort(sorted, function(a, b)
        local aFilled = (a.status == "filled")
        local bFilled = (b.status == "filled")
        if aFilled ~= bFilled then return bFilled end  -- filled sinks
        if a.buyer == me and b.buyer ~= me then return true end
        if b.buyer == me and a.buyer ~= me then return false end
        return (a.item or "") < (b.item or "")
    end)

    if table.getn(sorted) == 0 then
        local r = LC_AddRow(y)
        local t = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("LEFT", r, "LEFT", 12, 0)
        t:SetText(CLR.grey .. "No buy orders. Use the Post tab to request a craft." .. CLR.reset)
        return
    end

    for _, o in ipairs(sorted) do
        local r = LC_AddRow(y)
        y = y - ROW_HEIGHT - ROW_PAD
        count = count + 1

        local isMe = (o.buyer == me)
        local status = o.status or "open"
        local statusInfo = LC_ORDER_STATUS and LC_ORDER_STATUS[status]
        local statusLabel = statusInfo and statusInfo.label or "Open"
        local statusColor = statusInfo and statusInfo.color or "ff888888"

        -- Dim filled rows slightly
        if status == "filled" then
            local dimBg = r:CreateTexture(nil, "BACKGROUND")
            dimBg:SetAllPoints(r)
            dimBg:SetTexture(0, 0.3, 0, 0.15)
        end

        -- Buyer name (class coloured)
        local buyerData = LC_Registry[o.buyer]
        local cc = LC_ClassColor(buyerData and buyerData.class or nil)
        local bLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bLbl:SetPoint("LEFT", r, "LEFT", 8, 0)
        bLbl:SetWidth(95)
        bLbl:SetText("|c" .. cc .. o.buyer .. CLR.reset)

        -- Item - orange tint for mat requests
        local iLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        iLbl:SetPoint("LEFT", r, "LEFT", 105, 0)
        iLbl:SetWidth(140)
        local iMatRequest = o.note and string.find(o.note, "^%[Mat Request%]") ~= nil
        local iItemCol = iMatRequest and "|cffffaa00" or CLR.gold
        local iPrefix  = iMatRequest and "⛏ " or ""
        iLbl:SetText(iItemCol .. iPrefix .. (o.item or "?") .. CLR.reset)

        -- Payment + note
        local pStr = (o.payment or "Negotiable")
        if o.note and o.note ~= "" then
            pStr = pStr .. CLR.grey .. " " .. o.note .. CLR.reset
        end
        local pLbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pLbl:SetPoint("LEFT", r, "LEFT", 248, 0)
        pLbl:SetWidth(100)
        pLbl:SetText(CLR.teal .. pStr .. CLR.reset)

        -- Status button (anyone can advance status to coordinate)
        local sb = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        sb:SetWidth(78)
        sb:SetHeight(18)
        sb:SetPoint("RIGHT", r, "RIGHT", -34, 0)
        sb:SetText("|c" .. statusColor .. statusLabel .. CLR.reset)
        local oid = o.id
        sb:SetScript("OnClick", function()
            LC_CycleBuyOrderStatus(oid)
        end)
        sb:SetScript("OnEnter", function()
            GameTooltip:SetOwner(sb, "ANCHOR_RIGHT")
            GameTooltip:SetText("Order Status")
            local nextInfo = statusInfo and LC_ORDER_STATUS[statusInfo.next]
            GameTooltip:AddLine("Click to advance to: " .. (nextInfo and nextInfo.label or "Open"), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Open: waiting for crafter", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Mats Sent: buyer sent materials", 1, 0.84, 0)
            GameTooltip:AddLine("In Progress: crafter is working", 0, 0.67, 1)
            GameTooltip:AddLine("Filled!: craft delivered", 0, 1, 0.5)
            GameTooltip:Show()
        end)
        sb:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Delete X (own orders only)
        if isMe then
            local del = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            del:SetWidth(24)
            del:SetHeight(18)
            del:SetPoint("RIGHT", r, "RIGHT", -6, 0)
            del:SetText("X")
            del:SetScript("OnClick", function()
                LC_DeleteBuyOrder(oid)
                LC_RefreshUI()
            end)
        end

        -- Whisper button (others' orders)
        if not isMe then
            local wb = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            wb:SetWidth(24)
            wb:SetHeight(18)
            wb:SetPoint("RIGHT", r, "RIGHT", -6, 0)
            wb:SetText("W")
            wb:SetScript("OnEnter", function()
                GameTooltip:SetOwner(wb, "ANCHOR_RIGHT")
                GameTooltip:SetText("Whisper " .. o.buyer)
                GameTooltip:Show()
            end)
            wb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            local buyer = o.buyer
            local item  = o.item
            wb:SetScript("OnClick", function()
                ChatFrame_OpenChat("/w " .. buyer .. " Hi! I can craft " .. item .. " for you.")
            end)
        end
    end

    if LC_Window.status then
        LC_Window.status:SetText(CLR.grey .. count .. " buy order(s)  —  click status button to track progress" .. CLR.reset)
    end
end

-- ============================================================
-- TAB: Post panel
-- ============================================================
LC_PostInputs   = {}
LC_DropdownOpen  = false
LC_DropdownFrame = nil
LC_DropdownSeq   = 0

function LC_DrawPostPanel()
    local me = UnitName("player")
    LC_PostMode = LC_PostMode or "sell"

    -- ---- Section header ----
    local y = -ROW_PAD
    LC_AddSectionHeader("  Post a new listing or buy order", y)
    y = y - 30

    -- ---- Mode toggle buttons ----
    local modeRow = CreateFrame("Frame", nil, LC_Window.content)
    modeRow:SetWidth(LC_CONTENT_WIDTH)
    modeRow:SetHeight(28)
    modeRow:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, y)
    LC_Rows[table.getn(LC_Rows) + 1] = modeRow
    LC_Window.content:SetHeight(math.abs(y) + 28 + ROW_PAD)
    y = y - 34

    local function MakeModeBtn(label, xOff, width, modeId)
        local btn = CreateFrame("Button", nil, modeRow, "UIPanelButtonTemplate")
        btn:SetWidth(width)
        btn:SetHeight(24)
        btn:SetPoint("LEFT", modeRow, "LEFT", xOff, 0)
        btn:SetText(label)
        btn:SetScript("OnClick", function()
            if LC_PostMode ~= modeId then
                LC_PostMode = modeId
                LC_RefreshUI()
            end
        end)
        return btn
    end

    MakeModeBtn(CLR.green  .. "I Can Craft This"    .. CLR.reset,  8,   138, "sell")
    MakeModeBtn(CLR.teal   .. "I Want This Crafted" .. CLR.reset,  150, 138, "buy")
    MakeModeBtn("|cffffaa00Raw Materials|r",                        292, 138, "mats")

    -- ---- Helper: label row ----
    local function MakeLabel(text, yy)
        local r = CreateFrame("Frame", nil, LC_Window.content)
        r:SetWidth(LC_CONTENT_WIDTH)
        r:SetHeight(20)
        r:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, yy)
        LC_Rows[table.getn(LC_Rows) + 1] = r
        LC_Window.content:SetHeight(math.abs(yy) + 22)
        local lbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", r, "LEFT", 12, 0)
        lbl:SetText(text)
        return r, yy - 22
    end

    -- ---- Helper: plain editbox with manual border ----
    local function MakeInput(yy, width)
        width = width or 300
        local r = CreateFrame("Frame", nil, LC_Window.content)
        r:SetWidth(LC_CONTENT_WIDTH)
        r:SetHeight(26)
        r:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, yy)
        LC_Rows[table.getn(LC_Rows) + 1] = r
        LC_Window.content:SetHeight(math.abs(yy) + 28)

        local border = r:CreateTexture(nil, "BACKGROUND")
        border:SetPoint("TOPLEFT",     r, "TOPLEFT",  12, -1)
        border:SetWidth(width + 4)
        border:SetHeight(24)
        border:SetTexture(0.2, 0.5, 0.8, 1)

        local fill = r:CreateTexture(nil, "BACKGROUND")
        fill:SetPoint("TOPLEFT",     r, "TOPLEFT",  13, -2)
        fill:SetWidth(width + 2)
        fill:SetHeight(22)
        fill:SetTexture(0.0, 0.0, 0.0, 1)

        local eb = CreateFrame("EditBox", nil, r)
        eb:SetWidth(width - 4)
        eb:SetHeight(20)
        eb:SetPoint("LEFT", r, "LEFT", 16, 0)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetTextColor(1, 1, 1)
        eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
        eb:SetScript("OnEditFocusGained", function()
            fill:SetTexture(0.04, 0.1, 0.2, 1)
            border:SetTexture(0, 0.8, 1, 1)
        end)
        eb:SetScript("OnEditFocusLost", function()
            fill:SetTexture(0.0, 0.0, 0.0, 1)
            border:SetTexture(0.2, 0.5, 0.8, 1)
        end)
        return r, eb, yy - 30
    end

    -- ---- Item row with dropdown button ----
    local itemLabel
    if LC_PostMode == "sell" then
        itemLabel = CLR.gold .. "Item you can craft:" .. CLR.reset
    elseif LC_PostMode == "buy" then
        itemLabel = CLR.gold .. "Item you want crafted:" .. CLR.reset
    else
        itemLabel = "|cffffaa00Material you need:" .. CLR.reset
    end
    MakeLabel(itemLabel, y)
    y = y - 22

    local itemRow = CreateFrame("Frame", nil, LC_Window.content)
    itemRow:SetWidth(LC_CONTENT_WIDTH)
    itemRow:SetHeight(26)
    itemRow:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, y)
    LC_Rows[table.getn(LC_Rows) + 1] = itemRow
    LC_Window.content:SetHeight(math.abs(y) + 28)
    y = y - 30

    local itemBorder = itemRow:CreateTexture(nil, "BACKGROUND")
    itemBorder:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 12, -1)
    itemBorder:SetWidth(274)
    itemBorder:SetHeight(24)
    itemBorder:SetTexture(0.2, 0.5, 0.8, 1)

    local itemFill = itemRow:CreateTexture(nil, "BACKGROUND")
    itemFill:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 13, -2)
    itemFill:SetWidth(272)
    itemFill:SetHeight(22)
    itemFill:SetTexture(0, 0, 0, 1)

    local itemEB = CreateFrame("EditBox", nil, itemRow)
    itemEB:SetWidth(264)
    itemEB:SetHeight(20)
    itemEB:SetPoint("LEFT", itemRow, "LEFT", 16, 0)
    itemEB:SetAutoFocus(false)
    itemEB:SetFontObject(ChatFontNormal)
    itemEB:SetTextColor(1, 1, 1)
    itemEB:SetScript("OnEscapePressed", function() itemEB:ClearFocus() end)
    itemEB:SetScript("OnEditFocusGained", function()
        itemFill:SetTexture(0.04, 0.1, 0.2, 1)
        itemBorder:SetTexture(0, 0.8, 1, 1)
    end)
    itemEB:SetScript("OnEditFocusLost", function()
        itemFill:SetTexture(0, 0, 0, 1)
        itemBorder:SetTexture(0.2, 0.5, 0.8, 1)
    end)
    LC_PostInputs.item = itemEB

    -- Dropdown button
    local ddBtn = CreateFrame("Button", nil, itemRow, "UIPanelButtonTemplate")
    ddBtn:SetWidth(90)
    ddBtn:SetHeight(22)
    ddBtn:SetPoint("LEFT", itemRow, "LEFT", 292, 0)
    local ddLabel
    if LC_PostMode == "sell" then ddLabel = "My Crafts v"
    elseif LC_PostMode == "buy" then ddLabel = "All Crafts v"
    else ddLabel = "Materials v" end
    ddBtn:SetText(ddLabel)

    -- ---- Price/Payment ----
    local priceLabel
    if LC_PostMode == "sell" then
        priceLabel = CLR.gold .. "Price / Terms:" .. CLR.reset
    elseif LC_PostMode == "buy" then
        priceLabel = CLR.gold .. "Offering / Payment:" .. CLR.reset
    else
        priceLabel = "|cffffaa00Offering / How many needed:" .. CLR.reset
    end
    MakeLabel(priceLabel, y)
    y = y - 22
    local _, payEB
    _, payEB, y = MakeInput(y, 200)
    if LC_PostMode == "sell" then payEB:SetText("Tips + Mats")
    elseif LC_PostMode == "buy" then payEB:SetText("5g + Mats")
    else payEB:SetText("Negotiable / qty needed") end
    LC_PostInputs.pay = payEB

    -- ---- Note ----
    MakeLabel(CLR.grey .. "Note (optional):" .. CLR.reset, y)
    y = y - 22
    local _, noteEB
    _, noteEB, y = MakeInput(y, 380)
    LC_PostInputs.note = noteEB

    -- ---- Submit ----
    local subRow = CreateFrame("Frame", nil, LC_Window.content)
    subRow:SetWidth(LC_CONTENT_WIDTH)
    subRow:SetHeight(32)
    subRow:SetPoint("TOPLEFT", LC_Window.content, "TOPLEFT", 0, y)
    LC_Rows[table.getn(LC_Rows) + 1] = subRow
    LC_Window.content:SetHeight(math.abs(y) + 34)

    local subBtn = CreateFrame("Button", nil, subRow, "GameMenuButtonTemplate")
    subBtn:SetWidth(160)
    subBtn:SetHeight(26)
    subBtn:SetPoint("LEFT", subRow, "LEFT", 14, 0)

    if LC_PostMode == "sell" then
        subBtn:SetText("Post Craft Listing")
        subBtn:SetScript("OnClick", function()
            local item = LC_Trim(itemEB:GetText() or "")
            local pay  = LC_Trim(payEB:GetText() or "")
            local note = LC_Trim(noteEB:GetText() or "")
            if item == "" then LC_Print("Please enter an item name.") return end
            LC_PostListing(item, note, pay ~= "" and pay or nil)
            LC_SetTab("listings")
        end)
    elseif LC_PostMode == "buy" then
        subBtn:SetText("Post Buy Order")
        subBtn:SetScript("OnClick", function()
            local item = LC_Trim(itemEB:GetText() or "")
            local pay  = LC_Trim(payEB:GetText() or "")
            local note = LC_Trim(noteEB:GetText() or "")
            if item == "" then LC_Print("Please enter an item name.") return end
            LC_PostBuyOrder(item, pay ~= "" and pay or nil, note)
            LC_SetTab("orders")
        end)
    else
        -- mats mode: posts as a buy order but tagged as material request
        subBtn:SetText("Post Mat Request")
        subBtn:SetScript("OnClick", function()
            local item = LC_Trim(itemEB:GetText() or "")
            local pay  = LC_Trim(payEB:GetText() or "")
            local note = LC_Trim(noteEB:GetText() or "")
            if item == "" then LC_Print("Please enter a material name.") return end
            -- Prefix note to distinguish mat requests in the buy orders tab
            local matNote = "[Mat Request] " .. (note ~= "" and note or "")
            LC_PostBuyOrder(item, pay ~= "" and pay or nil, matNote)
            LC_SetTab("orders")
        end)
    end

    -- ---- Dropdown logic ----
    local function CloseDropdown()
        if LC_DropdownFrame then
            LC_DropdownFrame:Hide()
            LC_DropdownFrame = nil
        end
        LC_DropdownOpen = false
    end

    local function OpenDropdown()
        if LC_DropdownOpen then CloseDropdown() return end

        local items = {}
        local crafterMap = {}

        if LC_PostMode == "sell" then
            items = LC_GetCraftableItems(me)
        elseif LC_PostMode == "mats" then
            -- Raw materials only
            for cat, list in pairs(LC_MAT_ITEMS) do
                for _, item in ipairs(list) do
                    items[table.getn(items) + 1] = { item = item, prof = cat, crafter = nil, isMat = true }
                end
            end
        else
            -- Buy mode: crafted items from known crafters + all raw materials
            items = LC_GetAllBuyItems()
            for _, entry in ipairs(items) do
                if entry.crafter then
                    crafterMap[entry.item] = crafterMap[entry.item] or {}
                    local cm = crafterMap[entry.item]
                    cm[table.getn(cm) + 1] = entry.crafter
                end
            end
        end

        if table.getn(items) == 0 then
            LC_Print("No profession data yet. Try /lcraft ping.")
            return
        end

        table.sort(items, function(a, b)
            if a.prof ~= b.prof then return a.prof < b.prof end
            return a.item < b.item
        end)

        local dd = CreateFrame("Frame", "LCDropdownFrame", UIParent)
        dd:SetFrameStrata("FULLSCREEN_DIALOG")
        dd:SetFrameLevel(100)
        dd:SetWidth(320)
        dd:SetMovable(true)
        dd:EnableMouse(true)
        dd:RegisterForDrag("LeftButton")
        dd:SetScript("OnDragStart", function() dd:StartMoving() end)
        dd:SetScript("OnDragStop",  function() dd:StopMovingOrSizing() end)
        dd:SetBackdrop({
            bgFile   = "Interface\DialogFrame\UI-DialogBox-Background",
            edgeFile = "Interface\DialogFrame\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left=11, right=12, top=12, bottom=11 },
        })
        dd:SetBackdropColor(0, 0, 0, 1)

        local ddFill = dd:CreateTexture(nil, "BACKGROUND")
        ddFill:SetPoint("TOPLEFT",     dd, "TOPLEFT",     12, -12)
        ddFill:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -13,  12)
        ddFill:SetTexture(0.04, 0.05, 0.09, 1)

        local titleBG = dd:CreateTexture(nil, "ARTWORK")
        titleBG:SetPoint("TOPLEFT",  dd, "TOPLEFT",  12, -12)
        titleBG:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -13, -12)
        titleBG:SetHeight(22)
        titleBG:SetTexture(0.08, 0.25, 0.45, 1)

        local ddTitle = dd:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ddTitle:SetPoint("TOPLEFT", dd, "TOPLEFT", 16, -16)
        ddTitle:SetText(CLR.teal .. "Select Item" .. CLR.reset)

        local ddHint = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ddHint:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -36, -18)
        ddHint:SetText(CLR.grey .. "drag to move" .. CLR.reset)

        local ddClose = CreateFrame("Button", nil, dd, "UIPanelCloseButton")
        ddClose:SetWidth(24)
        ddClose:SetHeight(24)
        ddClose:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -2, -2)
        ddClose:SetScript("OnClick", CloseDropdown)

        dd:SetPoint("TOPLEFT", LC_Window, "TOPRIGHT", 4, 0)

        local rowH = 20
        local maxVisible = 16
        local lastP = ""
        local headerCount = 0
        for _, e in ipairs(items) do
            if e.prof ~= lastP then headerCount = headerCount + 1 lastP = e.prof end
        end
        local totalRows = table.getn(items) + headerCount
        local clampedRows = totalRows
        if clampedRows > maxVisible then clampedRows = maxVisible end
        dd:SetHeight(clampedRows * rowH + 44)

        LC_DropdownSeq = (LC_DropdownSeq or 0) + 1
        local sf2 = CreateFrame("ScrollFrame", "LCDropdownScroll" .. LC_DropdownSeq, dd, "UIPanelScrollFrameTemplate")
        sf2:SetPoint("TOPLEFT",     dd, "TOPLEFT",     14, -38)
        sf2:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -28, 14)

        local sc = CreateFrame("Frame", nil, sf2)
        sc:SetWidth(290)
        sc:SetHeight(totalRows * rowH + 4)
        sf2:SetScrollChild(sc)

        local lastProf = ""
        local ry = 0
        for _, entry in ipairs(items) do
            if entry.prof ~= lastProf then
                local hf = CreateFrame("Frame", nil, sc)
                hf:SetWidth(290)
                hf:SetHeight(rowH)
                hf:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -ry)
                local hbg = hf:CreateTexture(nil, "BACKGROUND")
                hbg:SetAllPoints(hf)
                if entry.isMat then
                    hbg:SetTexture(0.05, 0.28, 0.10, 1)
                else
                    hbg:SetTexture(0.08, 0.25, 0.45, 1)
                end
                local hl = hf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                hl:SetPoint("LEFT", hf, "LEFT", 6, 0)
                if entry.isMat then
                    hl:SetText("|cff44cc44" .. entry.prof .. CLR.reset)
                else
                    hl:SetText(CLR.teal .. entry.prof .. CLR.reset)
                end
                ry = ry + rowH
                lastProf = entry.prof
            end

            local rf = CreateFrame("Button", nil, sc)
            rf:SetWidth(290)
            rf:SetHeight(rowH)
            rf:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -ry)

            local rbase = rf:CreateTexture(nil, "BACKGROUND")
            rbase:SetAllPoints(rf)
            rbase:SetTexture(0.04, 0.05, 0.09, 1)

            local rbg = rf:CreateTexture(nil, "ARTWORK")
            rbg:SetAllPoints(rf)
            rbg:SetTexture(1, 1, 1, 0)

            local rl = rf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rl:SetPoint("LEFT", rf, "LEFT", 14, 0)
            rl:SetWidth(180)
            local iCol = entry.isMat and CLR.white or CLR.gold
            rl:SetText(iCol .. entry.item .. CLR.reset)

            if capturedCrafter then
                local cd = LC_Registry[capturedCrafter]
                local cc = LC_ClassColor(cd and cd.class or nil)
                local cl = rf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                cl:SetPoint("RIGHT", rf, "RIGHT", -4, 0)
                cl:SetWidth(90)
                cl:SetJustifyH("RIGHT")
                cl:SetText(CLR.grey .. "by |c" .. cc .. capturedCrafter .. CLR.reset)
            end

            -- Capture per-iteration values to avoid Lua 5.0 closure upvalue issue
            local capturedItem    = entry.item
            local capturedIsMat   = entry.isMat
            local capturedCrafter = entry.crafter

            rf:SetScript("OnEnter", function()
                rbg:SetTexture(0.15, 0.45, 0.75, 0.4)
                if crafterMap and not capturedIsMat then
                    local crafters = crafterMap[capturedItem]
                    if crafters and table.getn(crafters) > 0 then
                        GameTooltip:SetOwner(rf, "ANCHOR_LEFT")
                        GameTooltip:SetText(capturedItem)
                        GameTooltip:AddLine("Can be crafted by:", 0.5, 0.8, 1)
                        for _, c in ipairs(crafters) do
                            local cd = LC_Registry[c]
                            local cc2 = LC_ClassColor(cd and cd.class or nil)
                            GameTooltip:AddLine("  |c" .. cc2 .. c .. "|r", 1, 1, 1)
                        end
                        GameTooltip:Show()
                    end
                end
            end)
            rf:SetScript("OnLeave", function()
                rbg:SetTexture(1, 1, 1, 0)
                GameTooltip:Hide()
            end)

            rf:SetScript("OnClick", function()
                itemEB:SetText(capturedItem)
                CloseDropdown()
            end)

            ry = ry + rowH
        end

        dd:SetScript("OnHide", function() LC_DropdownOpen = false end)
        LC_DropdownFrame = dd
        LC_DropdownOpen  = true
        dd:Show()
    end

    ddBtn:SetScript("OnClick", OpenDropdown)
end


-- ============================================================
-- Recipe panel: floating window showing all craftable items
-- for a specific player, grouped by profession
-- ============================================================
LC_RecipePanel = nil
LC_RecipePanelSeq = 0

function LC_OpenRecipePanel(playerName, data)
    -- Close any existing recipe panel
    if LC_RecipePanel then
        LC_RecipePanel:Hide()
        LC_RecipePanel = nil
    end

    if not data or not data.profs or table.getn(data.profs) == 0 then
        LC_Print(playerName .. " has no profession data.")
        return
    end

    -- Build item list grouped by profession
    local groups = {}
    for _, prof in ipairs(data.profs) do
        local items = LC_CRAFT_ITEMS[prof.name]
        if items then
            groups[table.getn(groups) + 1] = { prof = prof, items = items }
        end
    end

    if table.getn(groups) == 0 then
        LC_Print("No known recipes for " .. playerName .. "'s professions.")
        return
    end

    local panelW = 340
    local rowH   = 20

    -- Count total rows
    local totalRows = 0
    for _, g in ipairs(groups) do
        totalRows = totalRows + 1  -- header
        totalRows = totalRows + table.getn(g.items)
    end
    local maxH   = 460
    local contentH = totalRows * rowH + 10
    local panelH = contentH + 60
    if panelH > maxH then panelH = maxH end

    local f = CreateFrame("Frame", "LCRecipePanel", UIParent)
    f:SetWidth(panelW)
    f:SetHeight(panelH)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(200)
    f:SetPoint("LEFT", LC_Window, "RIGHT", 6, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile   = "Interface\DialogFrame\UI-DialogBox-Background",
        edgeFile = "Interface\DialogFrame\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=11, right=12, top=12, bottom=11 },
    })
    f:SetBackdropColor(0, 0, 0, 1)

    -- Solid fill
    local fill = f:CreateTexture(nil, "BACKGROUND")
    fill:SetPoint("TOPLEFT",     f, "TOPLEFT",     12, -12)
    fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -13,  12)
    fill:SetTexture(0.04, 0.05, 0.09, 1)

    -- Title bar
    local titleBG = f:CreateTexture(nil, "ARTWORK")
    titleBG:SetPoint("TOPLEFT",  f, "TOPLEFT",  12, -12)
    titleBG:SetPoint("TOPRIGHT", f, "TOPRIGHT", -13, -12)
    titleBG:SetHeight(24)
    titleBG:SetTexture(0.08, 0.25, 0.45, 1)

    local cc = LC_ClassColor(data.class)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -16)
    title:SetText("|c" .. cc .. playerName .. "|r  " .. CLR.grey .. "Recipes" .. CLR.reset)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(24)
    closeBtn:SetHeight(24)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        LC_RecipePanel = nil
    end)

    -- Whisper button
    local wBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    wBtn:SetWidth(60)
    wBtn:SetHeight(18)
    wBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -15)
    wBtn:SetText("Whisper")
    wBtn:SetScript("OnClick", function()
        ChatFrame_OpenChat("/w " .. playerName .. " ")
    end)

    -- Scroll frame
    LC_RecipePanelSeq = LC_RecipePanelSeq + 1
    local sf = CreateFrame("ScrollFrame", "LCRecipeScroll" .. LC_RecipePanelSeq, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     14, -42)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 14)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(panelW - 44)
    sc:SetHeight(contentH)
    sf:SetScrollChild(sc)

    local ry = 0
    for _, g in ipairs(groups) do
        local prof = g.prof
        -- Profession header
        local hf = CreateFrame("Frame", nil, sc)
        hf:SetWidth(panelW - 44)
        hf:SetHeight(rowH)
        hf:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -ry)

        local hbg = hf:CreateTexture(nil, "BACKGROUND")
        hbg:SetAllPoints(hf)
        hbg:SetTexture(0.08, 0.25, 0.45, 1)

        local skillCol = prof.skill >= 300 and CLR.gold or (prof.skill >= 225 and CLR.green or CLR.white)
        local hLbl = hf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hLbl:SetPoint("LEFT", hf, "LEFT", 6, 0)
        hLbl:SetText(CLR.teal .. prof.name .. CLR.reset .. "  " .. skillCol .. prof.skill .. "/" .. prof.max .. CLR.reset)
        ry = ry + rowH

        -- Items
        for idx, itemName in ipairs(g.items) do
            local rf = CreateFrame("Button", nil, sc)
            rf:SetWidth(panelW - 44)
            rf:SetHeight(rowH)
            rf:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -ry)

            -- Alternating bg
            local rbg = rf:CreateTexture(nil, "BACKGROUND")
            rbg:SetAllPoints(rf)
            if mod(idx, 2) == 0 then
                rbg:SetTexture(1, 1, 1, 0.03)
            else
                rbg:SetTexture(0, 0, 0, 0)
            end

            local hov2 = rf:CreateTexture(nil, "ARTWORK")
            hov2:SetAllPoints(rf)
            hov2:SetTexture(0.2, 0.5, 0.8, 0.3)
            hov2:Hide()

            local iLbl = rf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            iLbl:SetPoint("LEFT", rf, "LEFT", 12, 0)
            iLbl:SetWidth(200)
            iLbl:SetText(CLR.gold .. itemName .. CLR.reset)

            -- "Request" button - opens post panel with this item pre-filled as buy order
            local reqBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
            reqBtn:SetWidth(56)
            reqBtn:SetHeight(16)
            reqBtn:SetPoint("RIGHT", rf, "RIGHT", -4, 0)
            reqBtn:SetText("Request")
            local capturedItem = itemName
            local capturedPlayer = playerName
            reqBtn:SetScript("OnClick", function()
                -- Switch to Post tab in buy mode with item pre-filled
                LC_PostMode = "buy"
                LC_SetTab("post")
                -- Pre-fill item after the tab draws
                local t = CreateFrame("Frame")
                local acc = 0
                t:SetScript("OnUpdate", function()
                    acc = acc + arg1
                    if acc > 0.1 then
                        t:SetScript("OnUpdate", nil)
                        if LC_PostInputs and LC_PostInputs.item then
                            LC_PostInputs.item:SetText(capturedItem)
                        end
                        if LC_PostInputs and LC_PostInputs.note then
                            LC_PostInputs.note:SetText("For " .. capturedPlayer)
                        end
                    end
                end)
                f:Hide()
                LC_RecipePanel = nil
            end)

            rf:SetScript("OnEnter", function() hov2:Show() end)
            rf:SetScript("OnLeave", function() hov2:Hide() end)

            ry = ry + rowH
        end
    end

    LC_RecipePanel = f
    f:Show()
end

-- ============================================================
-- Toggle window
-- ============================================================
function LC_ToggleWindow()
    if not LC_Window then
        LC_CreateWindow()
    end
    if LC_Window:IsShown() then
        LC_Window:Hide()
    else
        LC_Window:Show()
        LC_RefreshUI()
    end
end

-- ============================================================
-- Minimap button
-- ============================================================
function LC_CreateMinimapButton()
    if LC_MinimapBtn then return end
    if not LeviaCraftDB or not LeviaCraftDB.prefs then return end

    -- Create button parented to Minimap
    local btn = CreateFrame("Button", "LCMinimapBtn", Minimap)
    btn:SetWidth(28)
    btn:SetHeight(28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    -- Place it now so we never call SetPoint with a nil frame
    btn:SetPoint("CENTER", Minimap, "CENTER", -80, 0)

    -- Icon texture - must use explicit parent reference for SetPoint in 1.12
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(22)
    icon:SetHeight(22)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")

    -- Border texture
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(28)
    border:SetHeight(28)
    border:SetPoint("CENTER", btn, "CENTER", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Drag to reposition around minimap
    local dragging = false
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function()
        dragging = true
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetScale()
            cx = cx / s
            cy = cy / s
            local angle = math.atan2(cy - my, cx - mx)
            local x = math.cos(angle) * 80
            local y = math.sin(angle) * 80
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
            if LeviaCraftDB and LeviaCraftDB.prefs then
                LeviaCraftDB.prefs.minimap_angle = angle
            end
        end)
    end)
    btn:SetScript("OnDragStop", function()
        dragging = false
        btn:SetScript("OnUpdate", nil)
    end)
    btn:SetScript("OnClick", function()
        if not dragging then
            LC_ToggleWindow()
        end
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:SetText("LeviaCraft")
        GameTooltip:AddLine("Guild crafting marketplace", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Restore saved position if we have one
    if LeviaCraftDB.prefs.minimap_angle then
        local angle = LeviaCraftDB.prefs.minimap_angle
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    LC_MinimapBtn = btn
end
