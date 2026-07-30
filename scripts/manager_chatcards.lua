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
	-- The receive event fires for every message: delivered ones AND local
	-- injects via Comm.addChatMessage (SystemMessage, the GM copies of
	-- turn/effect notices), secret or not — verified in-app on FGU v5.1.13.
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

-- Frameless notice with an optional leading icon: system messages,
-- announcements, and the rest of the engine's chatter.
function addNoticeCard(sText, sIcon)
	return addCard("chatcard_notice", { sText = sText, sIcon = sIcon or "" });
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

-- Card classes by OOB card type; rolls of every kind share the action card.
local _tCardClasses = {
	power = "chatcard_power",
};

function handleCardOOB(msgOOB)
	addCard(_tCardClasses[msgOOB.sCardType or ""] or "chatcard_action", msgOOB);
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
		sActorNode = rActor and ActorManager.getCreatureNodeName(rActor) or "",
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
		-- For the name link. msg.sActorNode does not survive delivery, so
		-- received messages fall back to the sender-name lookup.
		local rSpeaker = ActorManager.resolveActor(msg.sActorNode)
			or findActorBySenderName(msg.sender);
		addCard("chatcard_speech", {
			sName = msg.sender,
			sSub = getSpeakerUser(msg),
			sText = sText,
			sActorNode = rSpeaker and ActorManager.getCreatureNodeName(rSpeaker) or "",
			sIconAsset = tPortrait.sIconAsset,
			sTokenAsset = tPortrait.sTokenAsset,
			sIsGM = bGM and "1" or "",
		});
		return;
	end

	-- Turn, round and effect notices are rewritten into plain sentences on a
	-- system card (background, no icon); everything else keeps the raw text.
	local sNoticeClass, tNotice = formatSystemNotice(sText);
	if sNoticeClass then
		addCard(sNoticeClass, tNotice);
		return;
	end

	-- Everything left is engine/ruleset chatter (unrecognized system
	-- messages, module loads, ...): a frameless notice, keeping whatever
	-- icon the message carries.
	if sText ~= "" then
		addNoticeCard(sText, getMessageIcon(msg));
	end
end

-- ===== Recognized system notices =====
-- Engine chatter arrives as bracketed text built for the native chat log
-- ("[TURN] Wololo", "Effect ['LIGHT: 20 light']\r-> [to Elara]"). The ones
-- whose pieces can be pulled apart reliably become sentences on a system
-- card; the rest fall through to a frameless notice unchanged. The bracketed
-- tags themselves are localized (CoreRPG strings), so they are compared
-- against Interface.getString rather than hardcoded in the patterns.

-- Returns the card class to show the notice on plus its card data, or nil
-- when the message is none of the recognized notices.
function formatSystemNotice(sText)
	local sRound = formatRoundNotice(sText);
	if sRound then
		return "chatcard_round", { sText = sRound };
	end
	local sTurn = formatTurnNotice(sText);
	if sTurn then
		return "chatcard_system", { sText = sTurn };
	end
	-- The effect card composes its own sentence: it needs the pieces apart to
	-- render the names in bold.
	local tEffect = parseEffectNotice(sText);
	if tEffect then
		return "chatcard_effect", tEffect;
	end
	return nil;
end

-- "[ROUND 3]" -> "Round 3", on the centred card.
function formatRoundNotice(sText)
	local sTag, sNumber = sText:match("^%[(%a[%a%s]-)%s+(%d+)%]%s*$");
	if sTag ~= Interface.getString("combat_tag_round") then
		return nil;
	end
	return StringManager.capitalize(sTag:lower()) .. " " .. sNumber;
end

-- "[TURN] Wololo" -> "Turn advanced. Is Wololo turn". With the "show effects
-- on turn" option (RSHE) the engine appends the actor's effects as further
-- indented lines, so only the first line is rewritten and the rest is kept.
function formatTurnNotice(sText)
	local sFirstLine, sRest = sText:match("^([^\r\n]*)([\r\n].*)$");
	if not sFirstLine then
		sFirstLine = sText;
		sRest = "";
	end
	local sTag, sName = sFirstLine:match("^%[([^%]]+)%]%s*(.-)%s*$");
	if (sTag ~= Interface.getString("combat_tag_turn")) or (sName == "") then
		return nil;
	end
	return string.format("Turn advanced. Is %s turn", sName) .. sRest;
end

-- The effect-applied notice, from EffectManager.onEffectAddNotify:
-- "Effect ['LIGHT: 20 light; [D: 1 hour]']\r-> [to Elara Brightwood]\r[by Wololo]"
-- ("[by ...]" only when the effect has a source). The same "Effect ['...']"
-- shape is also used for expiry/immunity/duplicate notices, which carry a
-- status instead of a "[to ...]" target and are left as notices.
-- Returns the card's pieces: name, rules logic, source (may be empty) and
-- target. The wording is the card's business, not this one's.
function parseEffectNotice(sText)
	local sLabel, sEffect = sText:match("^([^%[]+)%s*%['(.-)'%]");
	if not sLabel or (StringManager.trim(sLabel) ~= Interface.getString("effect_label")) then
		return nil;
	end
	local sTarget = sText:match("%[to ([^%]]+)%]");
	if not sTarget then
		return nil;
	end

	local sName, sLogic = splitEffectName(sEffect);
	-- "[from X]" names the power the effect came from. The 5E hooks add it
	-- (as the notice's last line) exactly when the effect string carries no
	-- name of its own, so it wins the name slot and the whole effect string
	-- is rules text.
	local sPower = sText:match("%[from ([^%]]+)%]%s*$");
	if sPower then
		sName = sPower;
		sLogic = sEffect;
	elseif sName == "" then
		sName = "Unknown effect";
	end
	return {
		sName = sName,
		sLogic = sLogic,
		-- Empty for effects applied without a source actor (the GM typing one
		-- straight onto a combatant, most character-sheet effects).
		sSource = sText:match("%[by ([^%]]+)%]") or "",
		sTarget = sTarget,
	};
end

-- An effect string is a list of ';'-separated clauses, optionally led by a
-- display name: "LIGHT: 20 light; [D: 1 hour]" -> "LIGHT" + "20 light;
-- [D: 1 hour]", "Celestial Resistance; RESIST: necrotic,radiant" ->
-- "Celestial Resistance" + "RESIST: necrotic,radiant". The name ends at the
-- first ';' or ':' outside brackets — a duration clause ("[D: 1 hour]") or a
-- concentration marker carries separators of its own.
-- NOTE: an effect written as bare rules text ("IMMUNE: poison") has no name
-- to find, so its first tag becomes the name (unless a "[from ...]" marker
-- supplied the originating power, see parseEffectNotice).
-- Also returns the separator the name ended at, for hasEffectName.
function splitEffectName(sEffect)
	local nDepth = 0;
	for i = 1, #sEffect do
		local sChar = sEffect:sub(i, i);
		if (sChar == "[") or (sChar == "(") then
			nDepth = nDepth + 1;
		elseif (sChar == "]") or (sChar == ")") then
			nDepth = math.max(nDepth - 1, 0);
		elseif (nDepth == 0) and ((sChar == ";") or (sChar == ":")) then
			return StringManager.trim(sEffect:sub(1, i - 1)), StringManager.trim(sEffect:sub(i + 1)), sChar;
		end
	end
	return StringManager.trim(sEffect), "", "";
end

-- Whether an effect string leads with a display name of its own: a first
-- clause with no ':' inside it ("Bless; ...", plain "Prone"), as opposed to
-- opening straight with a rules tag ("AC: 3", "LIGHT: 20 light").
function hasEffectName(sEffect)
	local sName, _, sSep = splitEffectName(sEffect or "");
	return (sName ~= "") and (sSep ~= ":");
end

-- The received copy of a message carries its icon in msg.assets, as
-- { type = "icon", name = "turn_flag", w = 0, h = 0 } — msg.icon does not
-- survive the trip (both verified in-app). msg.icon is still read first for
-- robustness (a string or a list of names depending on the sender). Portrait
-- assets (identity icons on speech-like messages, at their real size rather
-- than 0x0) are not message icons, so they are skipped.
function getMessageIcon(msg)
	local vIcon = msg.icon;
	if type(vIcon) == "table" then
		vIcon = vIcon[1];
	end
	if (type(vIcon) == "string") and (vIcon ~= "") then
		return vIcon;
	end
	local tAsset = msg.assets and msg.assets[1];
	if (type(tAsset) == "table") and (tAsset.type == "icon")
			and ((tAsset.name or "") ~= "") and not tAsset.name:match("^portrait_") then
		return tAsset.name;
	end
	return "";
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

-- ===== Rich text (mixed-font sentences) =====
-- A text widget carries a single font, so a sentence with bold parts in it
-- cannot be one string control: it is drawn as one widget per word, measured
-- and positioned by hand. Segments arrive as
-- { sText = "Elara Brightwood", sFont = "cc_bodybold" } and every word of a
-- segment keeps that font.
--
-- The words do NOT reflow by themselves, so the caller has to render again
-- when its width changes (see chatcard_effect.lua's onLayoutSizeChanged).

-- Stands in for the space between words: a measured widget reports the width
-- of its glyphs, and trailing spaces cannot be relied on to survive that
-- measurement, so the pen advances by a fixed gap instead.
local RICH_WORD_GAP = 4;
local RICH_WIDGET_NAME = "richword";

-- ===== Links =====
-- A rich-text segment with sLinkClass/sLinkPath (or a whole control given to
-- setControlLink) becomes clickable: hand cursor and a colour shift on hover,
-- Interface.openWindow on click. State is keyed by control; FG's sandbox has
-- no setmetatable (so no weak tables), so every card whose controls register
-- state MUST release it from onClose via releaseControlState, or closed
-- cards (the card cap, /clear) accumulate entries.

-- Hover tint: the theme gold of cc_subtitle / cc_effectlogic.
local LINK_HOVER_COLOR = "FF8A7340";
-- What linked rich-text words return to when the pointer leaves: a widget's
-- setColor cannot be reset to "whatever the font had", so this must match
-- cc_body / cc_bodybold in graphics_chatcards.xml.
local RICH_TEXT_COLOR = "FF1A1A1A";

local _tRichState = {};
local _tControlLinks = {};

function releaseControlState(...)
	for _, cControl in ipairs({ ... }) do
		_tRichState[cControl] = nil;
		_tControlLinks[cControl] = nil;
	end
end

-- Widgets are named consecutively so a re-render can drop the previous pass
-- (there is no "destroy every widget" call).
function clearRichText(cControl)
	local nIndex = 1;
	while true do
		local wgt = cControl.findWidget(RICH_WIDGET_NAME .. nIndex);
		if not wgt then
			return;
		end
		wgt.destroy();
		nIndex = nIndex + 1;
	end
end

-- Returns the height used (including the optional nTopPad rendered above
-- the first line), so the caller can size its control. Segments may carry
-- sLinkClass/sLinkPath to make their words clickable — the link events are
-- handled here (see the cc_rich_sentence template), so the caller only
-- marks the segments.
function setRichText(cControl, tSegments, nWidth, nLineHeight, nTopPad)
	clearRichText(cControl);

	nTopPad = nTopPad or 0;
	local tWords = {};
	local nX = 0;
	local nY = nTopPad;
	local nLines = 1;
	local nIndex = 0;
	for nSegment, tSegment in ipairs(tSegments or {}) do
		-- Line breaks inside a segment's text are honoured (the power
		-- description's paragraphs); segment boundaries still flow inline.
		local bFirstLine = true;
		for sLine in tostring(tSegment.sText or ""):gmatch("[^\r\n]+") do
			if not bFirstLine and (nX > 0) then
				nX = 0;
				nY = nY + nLineHeight;
				nLines = nLines + 1;
			end
			bFirstLine = false;
			for sWord in sLine:gmatch("%S+") do
				nIndex = nIndex + 1;
				local wWord = cControl.addTextWidget({
					name = RICH_WIDGET_NAME .. nIndex,
					font = tSegment.sFont or "cc_body",
					text = sWord,
					position = "topleft", x = 0, y = 0,
				});
				if wWord then
					local nWordWidth = wWord.getSize() or 0;
					-- Wrap before a word that would overrun, unless it is the
					-- first on its line: a word wider than the card has
					-- nowhere better to go.
					if (nX > 0) and ((nX + nWordWidth) > nWidth) then
						nX = 0;
						nY = nY + nLineHeight;
						nLines = nLines + 1;
					end
					-- Widgets are positioned by their centre.
					wWord.setPosition("topleft",
						nX + math.floor(nWordWidth / 2),
						nY + math.floor(nLineHeight / 2));
					table.insert(tWords, {
						nSegment = nSegment,
						sWidget = RICH_WIDGET_NAME .. nIndex,
						x = nX, y = nY,
						w = nWordWidth, h = nLineHeight,
					});
					nX = nX + nWordWidth + RICH_WORD_GAP;
				end
			end
		end
	end
	-- Kept for the link event handlers (onRichTextClick/Hover); a re-render
	-- replaces it, so any hover tint from the old layout is gone with it.
	_tRichState[cControl] = { tWords = tWords, tSegments = tSegments or {} };
	return nTopPad + (nLines * nLineHeight), tWords;
end

-- Which segment a control-local point is over, from setRichText's word
-- boxes; nil between words and outside the text.
function getRichTextSegmentAt(tWords, x, y)
	for _, tWord in ipairs(tWords or {}) do
		if (x >= tWord.x) and (x <= (tWord.x + tWord.w))
				and (y >= tWord.y) and (y <= (tWord.y + tWord.h)) then
			return tWord.nSegment;
		end
	end
	return nil;
end

-- The linked segment under a control-local point, or nil.
local function getRichLinkAt(cControl, x, y)
	local tState = _tRichState[cControl];
	if not tState then
		return nil;
	end
	local nSegment = getRichTextSegmentAt(tState.tWords, x, y);
	local tSegment = nSegment and tState.tSegments[nSegment];
	if tSegment and tSegment.sLinkClass and tSegment.sLinkPath then
		return nSegment, tSegment;
	end
	return nil;
end

-- Whether a rich-text control has any linked segment (the template's
-- onClickDown claims the press only then, so linkless sentences stay
-- transparent to clicks).
function hasRichTextLink(cControl)
	local tState = _tRichState[cControl];
	for _, tSegment in ipairs(tState and tState.tSegments or {}) do
		if tSegment.sLinkClass and tSegment.sLinkPath then
			return true;
		end
	end
	return false;
end

-- Event forwarders for controls rendered with setRichText (wired up by the
-- cc_rich_sentence template).
function onRichTextClick(cControl, nButton, x, y)
	if nButton ~= 1 then
		return;
	end
	local _, tSegment = getRichLinkAt(cControl, x, y);
	if not tSegment then
		return;
	end
	Interface.openWindow(tSegment.sLinkClass, tSegment.sLinkPath);
	return true;
end

function onRichTextHover(cControl, x, y)
	local tState = _tRichState[cControl];
	if not tState then
		return;
	end
	local nSegment = getRichLinkAt(cControl, x, y);
	if nSegment == tState.nHoverSegment then
		return;
	end

	local function tintSegment(nTarget, sColor)
		for _, tWord in ipairs(tState.tWords) do
			if tWord.nSegment == nTarget then
				local wWord = cControl.findWidget(tWord.sWidget);
				if wWord then
					wWord.setColor(sColor);
				end
			end
		end
	end
	if tState.nHoverSegment then
		tintSegment(tState.nHoverSegment, RICH_TEXT_COLOR);
	end
	if nSegment then
		tintSegment(nSegment, LINK_HOVER_COLOR);
	end
	tState.nHoverSegment = nSegment;

	if cControl.setHoverCursor then
		cControl.setHoverCursor(nSegment and "hand" or "arrow");
	end
end

-- Whole-control links (the header name on action and speech cards).
-- sNormalColor is the control font's colour, restored on hover end.
function setControlLink(cControl, sClass, sPath, sNormalColor)
	if sClass and sPath then
		_tControlLinks[cControl] = { sClass = sClass, sPath = sPath, sNormal = sNormalColor };
	else
		_tControlLinks[cControl] = nil;
	end
end

function hasControlLink(cControl)
	return _tControlLinks[cControl] ~= nil;
end

function onLinkControlClick(cControl, nButton)
	local tLink = _tControlLinks[cControl];
	if not tLink or (nButton ~= 1) then
		return;
	end
	Interface.openWindow(tLink.sClass, tLink.sPath);
	return true;
end

function onLinkControlHover(cControl, bOver)
	local tLink = _tControlLinks[cControl];
	if not tLink then
		return;
	end
	if cControl.setHoverCursor then
		cControl.setHoverCursor(bOver and "hand" or "arrow");
	end
	cControl.setColor(bOver and LINK_HOVER_COLOR or tLink.sNormal);
end

-- ===== Actor links =====
-- Where a character name can open the sheet behind it. Class comes from the
-- node: charsheet nodes open the character sheet for anyone who can resolve
-- them (the engine only syncs what a client may see); anything else is an
-- NPC record or CT entry, whose stat block stays GM-only.
function resolveActorLink(sActorNode)
	sActorNode = sActorNode or "";
	if (sActorNode == "") or not DB.findNode(sActorNode) then
		return nil;
	end
	if sActorNode:match("^charsheet%.") then
		return "charsheet", sActorNode;
	end
	if Session.IsHost then
		return "npc", sActorNode;
	end
	return nil;
end

-- Attach an actor link to a rich-text segment (in place, returns it back).
function applyActorLink(tSegment, sActorNode)
	tSegment.sLinkClass, tSegment.sLinkPath = resolveActorLink(sActorNode);
	return tSegment;
end

-- Header name colour: must match cc_name in graphics_chatcards.xml.
local NAME_COLOR = "FF3B2A12";

function setActorNameLink(cControl, sActorNode)
	local sClass, sPath = resolveActorLink(sActorNode);
	setControlLink(cControl, sClass, sPath, NAME_COLOR);
end

-- Actor node path for a display name parsed back out of a chat message
-- (the effect card's source and target).
function getActorNodeByName(sName)
	local rActor = findActorBySenderName(sName);
	if not rActor then
		return "";
	end
	return ActorManager.getCreatureNodeName(rActor) or "";
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
