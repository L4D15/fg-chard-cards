--
-- ChatCards: core card manager.
-- Turns incoming chat messages into card windows, and receives structured
-- card payloads (broadcast as OOB messages by the ruleset hooks) that carry
-- data the flattened chat text no longer has.
--

OOB_MSGTYPE_CHATCARD = "chatcards_card";

local MAX_CARDS = 150;
local _cList = nil;
local _tPending = {};

function onInit()
	OOBManager.registerOOBMsgHandler(OOB_MSGTYPE_CHATCARD, handleCardOOB);
	ChatManager.registerReceiveMessageCallback(onReceiveMessage);
end

function setCardList(cList)
	_cList = cList;
	if _cList then
		local tQueued = _tPending;
		_tPending = {};
		for _, tEntry in ipairs(tQueued) do
			addCard(tEntry.sClass, tEntry.tData);
		end
	end
end

-- ===== Card creation =====

function addCard(sClass, tData)
	-- Messages delivered before the chat window exists (e.g. ruleset
	-- announcements at load) are queued and flushed by setCardList.
	if not _cList then
		table.insert(_tPending, { sClass = sClass, tData = tData });
		return;
	end
	local w = _cList.createWindowWithClass(sClass);
	if not w then
		return;
	end
	w.setData(tData);

	local tWindows = _cList.getWindows();
	if #tWindows > MAX_CARDS then
		tWindows[1].close();
	end
	_cList.scrollToWindow(w, nil, true);
	return w;
end

function addBanner(sText)
	return addCard("chatcard_banner", { sText = sText });
end

-- ===== Structured cards via OOB =====

function sendCardOOB(tFields)
	local msgOOB = { type = OOB_MSGTYPE_CHATCARD };
	for k, v in pairs(tFields) do
		msgOOB[k] = tostring(v);
	end
	Comm.deliverOOBMessage(msgOOB, "");
end

function handleCardOOB(msgOOB)
	addCard("chatcard_action", msgOOB);
end

-- ===== Generic roll cards =====

-- Every roll type resolves through ActionsManager.resolveAction; the ruleset
-- hook script wraps it and calls this for types without a dedicated card.
function sendGenericRollCard(rSource, rRoll)
	local rActor = rSource;
	if not rActor and not Session.IsHost then
		rActor = ActorManager.getActiveActor();
	end

	local sName;
	if rActor then
		sName = ActorManager.getDisplayName(rActor);
	elseif Session.IsHost then
		sName = ChatIdentityManager.getGMIdentity();
	else
		sName = User.getUsername();
	end

	local sTitle = cleanRollText(rRoll.sDesc or "");
	if sTitle == "" then
		sTitle = "Dice Roll";
	end

	local tPortrait = getActorPortrait(rActor);
	sendCardOOB({
		sCardType = "roll",
		sName = sName or "",
		sSub = rRoll.sUser or (Session.IsHost and "Gamemaster" or User.getUsername()),
		sTitle = sTitle,
		sFormula = buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = "",
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rActor and Session.IsHost) and "1" or "",
	});
end

-- ===== Generic messages =====

-- Speech-like modes get a speech card; everything else without dice gets a banner.
local _tSpeechModes = { chat = true, emote = true, ooc = true, whisper = true, story = true };

-- Uppercase tags that identify roll messages (built by encodeActionText from
-- the action strings, e.g. "[ATTACK (M)] Mace"). All rolls become structured
-- cards via the resolveAction hook, so their text messages are skipped.
-- NOTE: dice data is NOT available on received messages (msg.dice arrives
-- empty), so classification is text-based.
local _tRollTags = {
	ATTACK = true, DAMAGE = true, SAVE = true, CHECK = true, SKILL = true,
	INIT = true, DEATH = true, CAST = true, CONCENTRATION = true,
	TABLE = true, HEAL = true, RECHARGE = true, RECOVERY = true,
	POWERSAVE = true,
};

function onReceiveMessage(msg)
	if not msg then
		return;
	end
	-- NOTE: secret messages are NOT skipped here. The engine only delivers
	-- them to clients allowed to see them (e.g. the GM's apply-result
	-- messages when NPCs are involved arrive with secret=true). Roll
	-- secrecy for cards is enforced at the OOB source via rRoll.bSecret.

	local sText = msg.text or "";

	-- Defensive: if dice ever do arrive, the roll is already carded via OOB.
	if msg.dice and #msg.dice > 0 then
		return;
	end

	local sTag = sText:match("^%[(%u+)");
	if sTag and _tRollTags[sTag] then
		return;
	end

	-- Apply-result messages from ActionCore.applyMessage use mixed case
	-- ("[Attack (M)] Rapier [22] -> [Ireena] [HIT]"). The attack card already
	-- shows the outcome, so drop those; damage applications become a
	-- "takes N damage" banner. Other applies (Save, Heal, ...) stay as
	-- banners with their original text.
	if sText:match("^%[Attack[%s#%(%]]") then
		return;
	end
	if sText:match("^%[Damage[%s#%(%]]") then
		addDamageApplyBanner(sText);
		return;
	end

	if _tSpeechModes[msg.mode or ""] and (msg.sender or "") ~= "" then
		local tPortrait = getMessagePortrait(msg);
		local bGM = tPortrait.bGM or (msg.sender == ChatIdentityManager.getGMIdentity());
		addCard("chatcard_speech", {
			sName = msg.sender,
			sSub = "",
			sText = sText,
			sIconAsset = tPortrait.sIconAsset,
			sTokenAsset = tPortrait.sTokenAsset,
			sIsGM = bGM and "1" or "",
		});
		return;
	end

	if sText ~= "" then
		addBanner(sText);
	end
end

-- "[Damage (M)] Rapier [7] -> [Ireena Kolyana] [WOUNDED]" ->
-- "Ireena Kolyana takes 7 damage". GM sees the total; players receive the
-- short form without it, so the amount is optional.
function addDamageApplyBanner(sText)
	local sTarget = sText:match("%->%s*%[([^%]]+)%]");
	if not sTarget then
		addBanner(sText);
		return;
	end
	local nValue = tonumber(sText:match("%[(%-?%d+)%]"));
	if nValue then
		addBanner(string.format("%s takes %d damage", sTarget, nValue));
	else
		addBanner(string.format("%s takes damage", sTarget));
	end
end

-- "[SAVE] Dexterity save [EFFECTS +1]" -> "Save: Dexterity save"
function cleanRollText(s)
	local sTag, sRest = s:match("^%[([^%]]+)%]%s*(.*)$");
	if sTag then
		sTag = StringManager.capitalize(sTag:lower():gsub("%s*%(.-%)", ""));
		s = sTag .. ": " .. sRest;
	end
	s = s:gsub("%s*%[[^%]]*%]", "");
	return s;
end

function buildDiceFormula(aDice, nMod)
	local tCount = {};
	local tOrder = {};
	for _, d in ipairs(aDice or {}) do
		local sType = (type(d) == "table") and (d.type or "") or tostring(d);
		local sDie = sType:match("(d%d+)") or sType;
		if sDie ~= "" then
			if not tCount[sDie] then
				table.insert(tOrder, sDie);
			end
			tCount[sDie] = (tCount[sDie] or 0) + 1;
		end
	end
	local tParts = {};
	for _, sDie in ipairs(tOrder) do
		if tCount[sDie] > 1 then
			table.insert(tParts, tCount[sDie] .. sDie);
		else
			table.insert(tParts, sDie);
		end
	end
	local s = table.concat(tParts, "+");
	if (nMod or 0) ~= 0 then
		s = s .. string.format("%+d", nMod);
	end
	return s;
end

-- ===== Portraits =====
-- Cards show, in priority order: character portrait -> token/picture ->
-- GM badge (for the GM) -> "?" fallback.

-- Resolve portrait fields for an actor (used on the rolling client before
-- broadcasting a card OOB; all fields are plain strings).
function getActorPortrait(rActor)
	local t = { sIconAsset = "", sTokenAsset = "" };
	if not rActor then
		return t;
	end
	local nodeActor = ActorManager.getCreatureNode(rActor);
	if not nodeActor then
		return t;
	end
	if ActorManager.isPC(rActor) then
		-- Engine-generated per-identity portrait icons from our own
		-- portrait set (transparent base, full-size mask)
		t.sIconAsset = "portrait_" .. DB.getName(nodeActor) .. "_ccard";
	else
		local sToken = DB.getValue(nodeActor, "picture", "");
		if (sToken or "") == "" then
			sToken = DB.getValue(nodeActor, "token", "");
		end
		if (sToken or "") == "" then
			sToken = DB.getValue(nodeActor, "token3Dflat", "");
		end
		t.sTokenAsset = UtilityManager.resolveDisplayToken(sToken, ActorManager.getDisplayName(rActor)) or "";
	end
	return t;
end

-- Resolve portrait fields from a received chat message: prefer the message's
-- own asset (what native chat would draw), fall back to a CT/NPC-record
-- lookup by sender name.
function getMessagePortrait(msg)
	local tAsset = msg.assets and msg.assets[1];
	if type(tAsset) ~= "table" or ((tAsset.name or "") == "") then
		tAsset = ChatIdentityManager.getAssetByName(msg.sender or "");
	end

	local t = { sIconAsset = "", sTokenAsset = "", bGM = false };
	if type(tAsset) == "table" and (tAsset.name or "") ~= "" then
		if tAsset.type == "icon" then
			if tAsset.name == "portrait_gm_token" then
				t.bGM = true;
			else
				-- Identity portrait icons from other sets carry their own
				-- baked-in ring/mask; reroute them to our clean set.
				local sIdentity = tAsset.name:match("^portrait_(.+)_%w+$");
				if sIdentity then
					t.sIconAsset = "portrait_" .. sIdentity .. "_ccard";
				else
					t.sIconAsset = tAsset.name;
				end
			end
		else
			t.sTokenAsset = tAsset.name;
		end
	end
	return t;
end

-- Apply portrait data to a card's icon + token controls (card side; the
-- data table carries stringified OOB fields).
function setCardPortrait(cIcon, cToken, t)
	local sIcon = t.sIconAsset or "";
	local sToken = t.sTokenAsset or "";
	if sIcon ~= "" then
		cIcon.setIcon(sIcon);
		cToken.setVisible(false);
	elseif sToken ~= "" then
		cIcon.setIcon("");
		cToken.setPrototype(sToken);
		cToken.setVisible(true);
	elseif t.sIsGM == "1" then
		cIcon.setIcon("cc_portrait_gm");
		cToken.setVisible(false);
	else
		cIcon.setIcon("cc_portrait_unknown");
		cToken.setVisible(false);
	end
end
