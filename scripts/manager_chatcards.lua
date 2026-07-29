--
-- ChatCards: core card manager.
-- Turns incoming chat messages into card windows, and receives structured
-- card payloads (broadcast as OOB messages by the ruleset hooks) that carry
-- data the flattened chat text no longer has.
--

OOB_MSGTYPE_CHATCARD = "chatcards_card";

-- Card accent palette, in FG's AARRGGBB form. The advantage/disadvantage die
-- tints use these, and the positive/negative tag pill art is drawn in the same
-- two colours — keep them in step if either changes.
COLOR_POSITIVE = "FF55A000";
COLOR_NEGATIVE = "FFB22E2E";

local MAX_CARDS = 150;
local _cList = nil;
local _tPending = {};

function onInit()
	OOBManager.registerOOBMsgHandler(OOB_MSGTYPE_CHATCARD, handleCardOOB);
	ChatManager.registerReceiveMessageCallback(onReceiveMessage);
	-- /clear is handled inside the engine, which clears the (hidden) chat
	-- control it owns and knows nothing about the card list beside it. A
	-- handler of our own covers the card list; the card list's radial menu
	-- offers the same thing, in case the engine consumes the command first.
	Comm.registerSlashHandler("clear", processClear);
end

function processClear()
	clearCards();
end

function clearCards()
	_tPending = {};
	if _cList then
		_cList.closeAll();
	end
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

function addSystemCard(sText)
	return addCard("chatcard_system", { sText = sText });
end

function addStoryCard(sText)
	return addCard("chatcard_story", { sText = sText });
end

-- ===== Structured cards via OOB =====

-- Rolls hidden from players: flagged secret by the engine (a CT-hidden
-- actor, or the dice tower) or the GM running with "reveal rolls" off.
-- Mirrors what ActionsManager.createActionMessage does to rMessage.secret.
function isRollSecret(rRoll)
	if rRoll and rRoll.bSecret then
		return true;
	end
	return Session.IsHost and OptionsManager.isOption("REVL", "off");
end

-- Secret cards go to the GM only (target ""); everything else is broadcast
-- to every client, the sender included (no target).
function sendCardOOB(tFields, bSecret)
	local msgOOB = { type = OOB_MSGTYPE_CHATCARD };
	for k, v in pairs(tFields) do
		msgOOB[k] = tostring(v);
	end
	if bSecret then
		Comm.deliverOOBMessage(msgOOB, "");
	else
		Comm.deliverOOBMessage(msgOOB);
	end
end

function handleCardOOB(msgOOB)
	addCard("chatcard_action", msgOOB);
end

-- ===== Tags (the pills on action cards) =====
-- Which tags exist is a ruleset concern: each supported system registers
-- providers per card type and this manager stays ignorant of their content.
-- A provider receives the card context and returns a list of
-- { sText = "Advantage", sStyle = "positive" }; sStyle names a pill style
-- defined in the cc_chip template (positive, negative, neutral) — named for
-- meaning, not colour — and defaults to neutral when omitted or unknown.
local _tTagProviders = {};

function registerTagProvider(sCardType, fn)
	if (sCardType or "") == "" or type(fn) ~= "function" then
		return;
	end
	_tTagProviders[sCardType] = _tTagProviders[sCardType] or {};
	table.insert(_tTagProviders[sCardType], fn);
end

-- Runs every provider registered for the card type, in registration order,
-- and returns the encoded string for the card payload.
function buildTags(sCardType, tContext)
	local tTags = {};
	for _, fn in ipairs(_tTagProviders[sCardType or ""] or {}) do
		for _, tTag in ipairs(fn(tContext) or {}) do
			if (type(tTag) == "table") and ((tTag.sText or "") ~= "") then
				table.insert(tTags, tTag);
			end
		end
	end
	return encodeTags(tTags);
end

-- "Attack:red;Advantage:green;Finesse" — the suffix is the style name, and
-- no suffix means neutral. ';' and ':' are separators, so they are stripped
-- from labels.
function encodeTags(tTags)
	local t = {};
	for _, tTag in ipairs(tTags or {}) do
		local sText = tostring(tTag.sText or ""):gsub("[;:]", " ");
		if sText ~= "" then
			local sStyle = tostring(tTag.sStyle or ""):gsub("[^%a]", "");
			if sStyle ~= "" then
				sText = sText .. ":" .. sStyle;
			end
			table.insert(t, sText);
		end
	end
	return table.concat(t, ";");
end

function decodeTags(sTags)
	local tTags = {};
	for sEntry in string.gmatch(sTags or "", "[^;]+") do
		local sText, sStyle = sEntry:match("^([^:]*):?(%a*)$");
		if (sText or "") ~= "" then
			table.insert(tTags, { sText = sText, sStyle = sStyle });
		end
	end
	return tTags;
end

-- ===== Generic roll cards =====

-- Card display name with fallbacks: actor display name, then the
-- sourcelinked record name (CT entries can carry an empty name field),
-- then the rolling user, then the local identity/GM label.
function getActorName(rActor, sUser)
	if rActor then
		local s = ActorManager.getDisplayName(rActor);
		if (s or "") ~= "" then
			return s;
		end
		s = ActorManager.getBaseName(rActor);
		if (s or "") ~= "" then
			return s;
		end
		-- Non-CT NPC records can resolve as "unidentified" (FG's record
		-- ID system returns their empty nonid_name); read the record's
		-- real name directly. NOTE: this reveals true names of
		-- unidentified NPCs on cards — swap the order of these two reads
		-- if a campaign relies on the identification mechanic.
		local nodeActor = ActorManager.getCreatureNode(rActor);
		if nodeActor then
			s = DB.getValue(nodeActor, "name", "");
			if s ~= "" then
				return s;
			end
			s = DB.getValue(nodeActor, "nonid_name", "");
			if s ~= "" then
				return s;
			end
		end
	end
	if (sUser or "") ~= "" then
		return sUser;
	end
	if Session.IsHost then
		return ChatIdentityManager.getGMIdentity();
	end
	local s = User.getIdentityLabel();
	if (s or "") ~= "" then
		return s;
	end
	return User.getUsername();
end

-- Build and broadcast a roll card. tExtra lets a ruleset's dedicated hook add
-- the pieces only it knows about — a target-DC line, an itemized modifier row,
-- a pass/fail outcome, a title of its own — while the common parts (actor,
-- portrait, dice, total, tags, secrecy) stay here.
function sendRollCard(rSource, rRoll, tExtra)
	local rActor = rSource;
	if not rActor and not Session.IsHost then
		rActor = ActorManager.getActiveActor();
	end

	local sName = getActorName(rActor, rRoll.sUser);

	tExtra = tExtra or {};
	local sTitle = tExtra.sTitle or cleanRollText(rRoll.sDesc or "");
	if sTitle == "" then
		sTitle = "Dice Roll";
	end

	-- Without an itemized breakdown from the hook, fall back to a single
	-- modifier line named after the roll source ("Dexterity +3") — the dice
	-- row no longer carries the bonus.
	local sLine1 = tExtra.sLine1 or "";
	local sMods = tExtra.sMods or "";
	if (sMods == "") and (sLine1 == "") then
		local sMod = formatMod(rRoll.nMod);
		if sMod ~= "" then
			sLine1 = (sTitle:match(":%s*(.+)$") or "Modifier") .. " " .. sMod;
		end
	end

	local tPortrait = getActorPortrait(rActor);
	sendCardOOB({
		sCardType = "roll",
		sName = sName or "",
		sSub = rRoll.sUser or (Session.IsHost and "Gamemaster" or User.getUsername()),
		sTitle = sTitle,
		sFormula = buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = encodeDiceResults(rRoll.aDice),
		sLine1 = sLine1,
		sMods = sMods,
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = tExtra.sOutcome or "",
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rActor and Session.IsHost) and "1" or "",
		sTags = buildTags("roll", { rSource = rSource, rRoll = rRoll, sTitle = sTitle }),
	}, isRollSecret(rRoll));
end

-- Types without a dedicated hook (basic tray dice, initiative, ...).
function sendGenericRollCard(rSource, rRoll)
	sendRollCard(rSource, rRoll, nil);
end

-- Player label for a speech card. Chat messages carry no username, so the
-- speaker is resolved from the engine's identity list: the sender label is
-- an identity label, and identities know their owning user (the same
-- mapping ChatManager.searchForIdentity uses for whisper autocomplete).
-- This is what catches a player speaking as an NPC they have been given.
-- Falls back to record ownership (the CT entry first, since control of a
-- combatant is granted there rather than on the creature record), then to
-- "Gamemaster" for the GM's own voices.
function getSpeakerUser(msg)
	local sSender = msg.sender or "";
	if sSender ~= "" then
		for _, sIdentity in ipairs(User.getAllActiveIdentities() or {}) do
			if User.getIdentityLabel(sIdentity) == sSender then
				local sOwner = User.getIdentityOwner(sIdentity);
				if (sOwner or "") ~= "" then
					return sOwner;
				end
				break;
			end
		end
	end

	local rActor = ActorManager.resolveActor(msg.sActorNode);
	if rActor then
		local nodeCT = ActorManager.getCTNode(rActor);
		if nodeCT then
			local sOwner = DB.getOwner(nodeCT);
			if (sOwner or "") ~= "" then
				return sOwner;
			end
		end
		local sOwner = ActorManager.getOwner(rActor);
		if (sOwner or "") ~= "" then
			return sOwner;
		end
	end
	return "Gamemaster";
end

-- ===== Generic messages =====

-- Speech-like modes get a speech card; everything else without dice gets a
-- full-width text card. Story is handled separately: it is narration rather
-- than someone speaking, so it gets no portrait and an italic font.
local _tSpeechModes = { chat = true, emote = true, ooc = true, whisper = true };

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

-- Apply-result labels whose outcome a card already reports, so their chat
-- message would only repeat it.
local _tRedundantApplies = {
	Attack = true, Save = true, Concentration = true, ["System Shock"] = true,
};

-- Applies that report a change to an actor instead: what a card shows is the
-- roll, while these carry the amount that actually landed after resistances,
-- caps and the like, so they become a banner in plain words.
local _tApplyBanners = {
	Damage = { sVerb = "takes", sUnit = "damage" },
	Heal = { sVerb = "recovers", sUnit = "hit points" },
	["Temporary hit points"] = { sVerb = "gains", sUnit = "temporary hit points" },
	["Fast healing"] = { sVerb = "recovers", sUnit = "hit points" },
	Regeneration = { sVerb = "recovers", sUnit = "hit points" },
	Recovery = { sVerb = "recovers", sUnit = "hit points" },
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

	-- Apply-result messages from ActionCore.applyMessage use mixed-case labels
	-- ("[Attack (M)] Rapier [22] -> [Ireena] [HIT]", "[Save] [16] [vs DC 12]
	-- [SUCCESS]"). Where a card already shows that roll's result, the message
	-- is redundant, so it is dropped; damage applications instead become a
	-- "takes N damage" banner, since no card reports the applied total.
	-- Capture up to the closing bracket, an order "#2" or a "(M)" range, so
	-- two-word labels ("System Shock") are not cut at the space.
	local sApplyLabel = sText:match("^%[(%a[^%]#%(]*)");
	if sApplyLabel then
		sApplyLabel = StringManager.trim(sApplyLabel);
	end
	if sApplyLabel and _tRedundantApplies[sApplyLabel] then
		return;
	end
	if sApplyLabel and _tApplyBanners[sApplyLabel] then
		addApplyBanner(sText, _tApplyBanners[sApplyLabel]);
		return;
	end

	if (msg.mode or "") == "story" then
		if sText ~= "" then
			addStoryCard(sText);
		end
		return;
	end

	if _tSpeechModes[msg.mode or ""] and (msg.sender or "") ~= "" then
		local tPortrait = getMessagePortrait(msg);
		local bGM = tPortrait.bGM or (msg.sender == ChatIdentityManager.getGMIdentity());
		addCard("chatcard_speech", {
			sName = msg.sender,
			sSub = getSpeakerUser(msg),
			sText = sText,
			sIconAsset = tPortrait.sIconAsset,
			sTokenAsset = tPortrait.sTokenAsset,
			sIsGM = bGM and "1" or "",
		});
		return;
	end

	if sText ~= "" then
		addSystemCard(sText);
	end
end

-- "[Damage (M)] Rapier [7] -> [Ireena Kolyana] [WOUNDED]" ->
-- "Ireena Kolyana takes 7 damage". The GM's copy carries the amount; the
-- players' short form does not, so it is optional.
function addApplyBanner(sText, tPhrase)
	local sTarget = sText:match("%->%s*%[([^%]]+)%]");
	if not sTarget then
		addSystemCard(sText);
		return;
	end
	local nValue = tonumber(sText:match("%[(%-?%d+)%]"));
	if nValue then
		addSystemCard(string.format("%s %s %d %s", sTarget, tPhrase.sVerb, nValue, tPhrase.sUnit));
	else
		addSystemCard(string.format("%s %s %s", sTarget, tPhrase.sVerb, tPhrase.sUnit));
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

-- "+4" / "-2" for the trailing modifier slot; empty when zero
function formatMod(nMod)
	if (nMod or 0) == 0 then
		return "";
	end
	return string.format("%+d", nMod);
end

-- Serialize per-die results for OOB transport: "d20:15;gd20:15;d6:3:x"
-- (":x" marks a die dropped by advantage/disadvantage).
function encodeDiceResults(aDice)
	local t = {};
	for _, d in ipairs(aDice or {}) do
		if type(d) == "table" then
			table.insert(t, string.format("%s:%d%s",
				d.type or "d6", d.result or 0, d.dropped and ":x" or ""));
		end
	end
	return table.concat(t, ";");
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

-- Find the actor a chat message came from. msg.sActorNode does not survive
-- network delivery (same as msg.dice), so on the receive side the sender
-- label is matched against the combat tracker first, then the NPC and
-- character records — the strategy ChatIdentityManager.getAssetByName uses.
function findActorBySenderName(sName)
	if (sName or "") == "" then
		return nil;
	end
	for _, nodeCT in pairs(CombatManager.getCombatantNodes()) do
		if DB.getValue(nodeCT, "name", "") == sName then
			return ActorManager.resolveActor(nodeCT);
		end
	end
	for _, sRecordType in ipairs({ "npc", "charsheet" }) do
		local nodeRecord = RecordManager.findRecordByString(sRecordType, "name", sName);
		if nodeRecord then
			return ActorManager.resolveActor(nodeRecord);
		end
	end
	return nil;
end

-- Resolve portrait fields from a received chat message. Resolving from the
-- speaking actor first keeps speech cards on the same priority as roll
-- cards (picture -> token -> "?"); the message's own asset uses the
-- engine's chat order (token first), so it is only a fallback.
function getMessagePortrait(msg)
	local rActor = ActorManager.resolveActor(msg.sActorNode)
		or findActorBySenderName(msg.sender);
	if rActor then
		local tActorPortrait = getActorPortrait(rActor);
		if (tActorPortrait.sIconAsset ~= "") or (tActorPortrait.sTokenAsset ~= "") then
			return tActorPortrait;
		end
	end

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
-- Avatar layer size (the frame's square inner area). Portrait icons and
-- badges are authored at 3x this and drawn through a bitmap widget with
-- an explicit size, so FG downsamples a detailed source rather than
-- stretching a 40px one — sharper under UI scaling / high-DPI displays.
local PORTRAIT_SIZE = 40;

function setCardPortrait(cIcon, cToken, cFrame, t)
	local sIcon = t.sIconAsset or "";
	local sToken = t.sTokenAsset or "";

	-- Corner cover, drawn on the frame control so it sits above both avatar
	-- layers: rounds the avatar's corners for every portrait type (token
	-- controls cannot be masked). The frame is 4px larger than the avatar,
	-- hence the centred placement.
	if cFrame then
		cFrame.addBitmapWidget({
			icon = "cc_portrait_cover",
			position = "topleft",
			x = (PORTRAIT_SIZE + 4) / 2, y = (PORTRAIT_SIZE + 4) / 2,
			w = PORTRAIT_SIZE, h = PORTRAIT_SIZE,
		});
	end

	-- Token art is rendered by the engine's token control, which already
	-- scales its (high-resolution) source into the control.
	if sIcon == "" and sToken ~= "" then
		cToken.setPrototype(sToken);
		cToken.setVisible(true);
		return;
	end
	cToken.setVisible(false);

	if sIcon == "" then
		sIcon = (t.sIsGM == "1") and "cc_portrait_gm" or "cc_portrait_unknown";
	end
	cIcon.addBitmapWidget({
		icon = sIcon,
		position = "topleft",
		x = PORTRAIT_SIZE / 2, y = PORTRAIT_SIZE / 2,
		w = PORTRAIT_SIZE, h = PORTRAIT_SIZE,
	});
end
