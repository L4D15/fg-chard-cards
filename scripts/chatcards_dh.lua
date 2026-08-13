--
-- ChatCards: Daggerheart adapter.
-- Captures structured action/attack, reaction, damage and heal data at
-- resolution time and broadcasts it to every client as a card. Everything
-- here touches Daggerheart's own action managers, so the whole script gates
-- itself on the ruleset (see chatcards_5e.lua for the adapter pattern).
--
-- Daggerheart notes:
--  - Duality rolls ride the "attack" type: targeted = an attack vs the
--    target's defense (sResult hit/miss/crit), untargeted = an action roll
--    vs a DC (sResult success/failure/crit). rRoll.sDuality carries which
--    die won ("hope"/"fear"), rRoll.bCritical the doubles crit.
--  - Saves are reaction rolls (type "save"); their result line ("Reaction
--    [12][vs. DC 14] -> ...") carries no bracketed tag, so it is dropped by
--    a skip pattern rather than the roll-tag vocabulary.
--  - There is no power-use flow (nothing calls PowerManagerCore.usePower;
--    abilities roll straight from their action buttons), so power cards
--    are sent from a "send to chat" button merged into the sheet's power
--    rows instead (sendSheetPowerCard, common/sheet_chatcards_dh.xml).
--    Effect origins are stamped via the ActionPower.performAction wrap.
--

local _fAttackResolve = nil;
local _fPowerPerformAction = nil;
local _fModResolve = nil;
local _fApplyFearAndMessage = nil;
local _fStepResourceAdjustment = nil;
local _fStepFearAdjustment = nil;

-- The ruleset's own hope/fear die tints (dicebodycolor in
-- manager_action_attack.lua), reused for the card's die glyphs.
local COLOR_HOPE_DIE = "FFF9B70D";
local COLOR_FEAR_DIE = "FF251566";

function onInit()
	-- Adapter gate: same-named but incompatible action managers exist on
	-- other systems (5E and PFRPG2 both define their own ActionAttack).
	if not ChatCardsManager.isRuleset("Daggerheart") then
		return;
	end

	-- Roll types the hooks below card themselves, so the core resolveAction
	-- wrap must not card them again ("table" is claimed by ChatCardsCore's
	-- own capture).
	ChatCardsCore.registerDedicatedRollTypes({
		"attack", "damage", "heal", "save",
	});

	-- Daggerheart's message vocabulary. Attack/action rolls are tagged
	-- "[ACTION ...]", reaction rolls "[REACTION ...]" and next-roll
	-- modifiers "[MOD] ..." (the ruleset overrides CoreRPG's tag strings);
	-- reaction *results* are plain "Reaction [12][vs. DC 14] -> ..." lines
	-- with no bracketed tag, so they need a skip pattern instead.
	-- Regeneration applies become a banner like the other recovery labels.
	ChatCardsManager.registerRollTags({ "ACTION", "REACTION", "MOD" });
	ChatCardsManager.registerSkipPatterns({ "^Reaction%s" });
	ChatCardsManager.registerApplyBanners({
		Regeneration = { sVerb = "recovers", sUnit = "hit points" },
	});

	-- Hope/fear die glyph accents: encodeDualityDice marks the two duality
	-- dice with these prefixes in the card's dice string.
	ChatCardsCore.registerDieStyles({
		h = COLOR_HOPE_DIE,
		f = COLOR_FEAR_DIE,
	});

	-- Power-card rows: a Daggerheart action node is already a single sheet
	-- button whose meaning rides the node's own fields — attack actions
	-- carry a "subroll" ("", "save", "mod"), damage and heal a "resource"
	-- (hp/stress/armor/hope/fear) — mirroring the sheet's
	-- power_action_mini.getActionData.
	ChatCardsCore.setPowerRowBuilder(function(nodeAction, sType)
		local sSubRoll = DB.getValue(nodeAction, "subroll", "");
		if (sType == "damage") or (sType == "heal") then
			sSubRoll = DB.getValue(nodeAction, "resource", "");
		end
		local sLabel = StringManager.capitalize(sType);
		if sType == "attack" then
			if sSubRoll == "save" then
				sLabel = "Save";
			elseif sSubRoll == "mod" then
				sLabel = "Modifier";
			end
		end
		return { {
			sSubRoll = (sSubRoll ~= "") and sSubRoll or nil,
			sLabel = sLabel,
		} };
	end);

	if ActionAttack and ActionAttack.onAttackResolve then
		_fAttackResolve = ActionAttack.onAttackResolve;
		ActionAttack.onAttackResolve = onAttackResolve;
	end
	-- Reactions resolve (and report their result) inside ActionSave.onSave,
	-- so the card is sent from a wrapper registered over it.
	if ActionSave and ActionSave.onSave then
		ActionsManager.registerResultHandler("save", onSaveRoll);
	end
	if ActionDamageD20 and ActionDamageD20.onRoll then
		-- The original handler reference was captured at ruleset init;
		-- re-registering replaces it with our wrapper. Damage and healing
		-- share CoreRPG's d20 resolve handler, as on 5E.
		ActionsManager.registerResultHandler("damage", onDamageRoll);
		ActionsManager.registerResultHandler("heal", onHealRoll);
	end

	-- Effect origin. Every power action funnels through
	-- ActionPower.performAction with its action node in hand; the owning
	-- power's name is stamped onto effect actions there and carried to the
	-- host by ChatCardsCore's encode/decode chain.
	if ActionPower and ActionPower.performAction then
		_fPowerPerformAction = ActionPower.performAction;
		ActionPower.performAction = onPowerPerformAction;
	end

	-- Next-roll modifiers (an experience spent onto the modifier stack).
	-- ActionMod.onRoll runs outside ActionsManager.resolveAction, so no
	-- generic card fires; the delivery seam is onModResolve, right after
	-- checkModResult decided whether the bonus reaches the stack.
	if ActionMod and ActionMod.onModResolve then
		_fModResolve = ActionMod.onModResolve;
		ActionMod.onModResolve = onModResolve;
	end

	-- Hope/fear economy cards ("Adolfoss has gained 2 hope"), on their own
	-- card art. Three sources: the duality riders on action rolls (read in
	-- onAttackResolve), the GM fear pool (applyFearAndMessage, called
	-- late-bound so a wrap works), and actor-held pools
	-- (applySetHealthDefault — the ruleset registered its REFERENCE at
	-- init, so the GameManager function is re-registered with the wrapper
	-- instead). Both apply seams run on the host. The raw "[Hope] Spends
	-- 1" / "[FEAR] Gains 2" apply texts are dropped by the skip patterns
	-- below; the cards replace them.
	ChatCardsManager.registerCardClass("hope", "chatcard_hope");
	ChatCardsManager.registerCardClass("fear", "chatcard_fear");
	-- HP and stress share the sentence shape on the neutral system card.
	ChatCardsManager.registerCardClass("hp", "chatcard_resource_system");
	ChatCardsManager.registerCardClass("stress", "chatcard_resource_system");
	if ActionHealthDH and ActionHealthDH.applyFearAndMessage then
		_fApplyFearAndMessage = ActionHealthDH.applyFearAndMessage;
		ActionHealthDH.applyFearAndMessage = onApplyFearAndMessage;
	end
	if ActionHealthDH and ActionHealthDH.applySetHealthDefault
			and GameManager and GameManager.setFunction then
		GameManager.setFunction("onHealthApplySetHealth", onApplySetHealth);
	end
	-- Manual adjustments: the sheet trackers (hope, and the sheet's fear
	-- counter) funnel through CharManager.stepResourceAdjustment, the
	-- desktop fear tracker through stepFearAdjustment — both called
	-- package-qualified, so wraps work.
	if CharManager and CharManager.stepResourceAdjustment then
		_fStepResourceAdjustment = CharManager.stepResourceAdjustment;
		CharManager.stepResourceAdjustment = onStepResourceAdjustment;
	end
	if CharManager and CharManager.stepFearAdjustment then
		_fStepFearAdjustment = CharManager.stepFearAdjustment;
		CharManager.stepFearAdjustment = onStepFearAdjustment;
	end
	-- applyFearAndMessage writes its notifications as literals; the
	-- per-actor pools go through the localized resource strings. The last
	-- block drops the manual trackers' own texts ("'Adolfoss' gains
	-- 'hope'", "Fear Gained"/"Fear Marked") that the cards replace.
	local sHope = Interface.getString("resource_title_hope");
	local sFear = Interface.getString("resource_title_fear");
	local sGains = Interface.getString("resource_adjustment_gains");
	local sSpends = Interface.getString("resource_adjustment_spends");
	local sHopeV = Interface.getString("resource_value_hope");
	local sFearV = Interface.getString("resource_value_fear");
	local sHpV = Interface.getString("resource_value_hp");
	local sStressV = Interface.getString("resource_value_stress");
	ChatCardsManager.registerSkipPatterns({
		"%[FEAR%] Spends", "%[FEAR%] Gains",
		"%[" .. sHope .. "%] " .. sGains, "%[" .. sHope .. "%] " .. sSpends,
		"%[" .. sFear .. "%] " .. sGains, "%[" .. sFear .. "%] " .. sSpends,
		"^'[^']+' gains '" .. sHopeV .. "'", "^'[^']+' spends '" .. sHopeV .. "'",
		"^'[^']+' gains '" .. sFearV .. "'", "^'[^']+' spends '" .. sFearV .. "'",
		"^'[^']+' marks '" .. sHpV .. "'", "^'[^']+' clears '" .. sHpV .. "'",
		"^'[^']+' marks '" .. sStressV .. "'", "^'[^']+' clears '" .. sStressV .. "'",
		"^Fear Gained$", "^Fear Marked$",
	});

	-- This ruleset's card tags. Duality (Hope/Fear/Critical) rides every
	-- card type; sendRollCard-based cards (reactions, generic rolls) get it
	-- through the "roll" providers.
	ChatCardsManager.registerTagProvider("attack", getAttackTags);
	ChatCardsManager.registerTagProvider("damage", getDamageTags);
	ChatCardsManager.registerTagProvider("heal", getHealTags);
	ChatCardsManager.registerTagProvider("roll", getDualityTags);
	ChatCardsManager.registerTagProvider("roll", getAdvantageTags);
end

--
--	EFFECT ORIGIN
--

-- The square brackets would collide with the notice's own [from ...] markers.
-- The action node's owning power is its grandparent (power -> actions list
-- -> action).
function onPowerPerformAction(draginfo, rActor, rAction, nodeAction)
	if rAction and (rAction.type == "effect") and nodeAction then
		local nodePower = DB.getParent(DB.getParent(nodeAction));
		local sPowerName = nodePower
			and StringManager.trim(DB.getValue(nodePower, "name", "")):gsub("[%[%]]", "") or "";
		if sPowerName ~= "" then
			rAction.sChatCardsPower = sPowerName;
		end
	end
	return _fPowerPerformAction(draginfo, rActor, rAction, nodeAction);
end

--
--	HOPE AND FEAR CARDS
--

-- Broadcast one resource card ("{name} has {verb} {n} {resource}"). rActor
-- may be nil (the GM's fear pool); sFallback names the card then, plain.
function sendResourceCard(rActor, sFallback, sVerb, nAmount, sResource, bSecret)
	ChatCardsManager.sendCardOOB({
		sCardType = sResource,
		sName = rActor and ChatCardsManager.getActorName(rActor, nil) or (sFallback or ""),
		sActorNode = rActor and ActorManager.getCreatureNodeName(rActor) or "",
		sVerb = sVerb,
		sAmount = tostring(nAmount or 0),
		sResource = sResource,
	}, bSecret or false);
end

-- The GM fear pool (fear-resource damage and heals from powers): the
-- original applies the change and outputs the "[FEAR] Spends 2" apply
-- message (dropped by the skip patterns); the card replaces it. Fear
-- damage spends from the pool, fear healing feeds it.
function onApplyFearAndMessage(rSource, rRoll)
	local bResult = _fApplyFearAndMessage(rSource, rRoll);
	if (rRoll.nFear or 0) > 0 then
		sendResourceCard(rSource, "The GM",
			(rRoll.sType == "damage") and "spent" or "gained", rRoll.nFear, "fear");
	end
	return bResult;
end

-- Actor-held pools (a PC's hope, mostly): the original computes, applies
-- and words the adjustments (its "[Hope] Spends 1" notification is dropped
-- by the skip patterns), and leaves the nPrevWounds/nWounds pairs behind,
-- which are re-read here for the cards. Both pools count upward, so a
-- positive adjustment is a gain — the ruleset words it the same way.
function onApplySetHealth(rActor, rRoll, tApplyData)
	ActionHealthDH.applySetHealthDefault(rActor, rRoll, tApplyData);

	for _, sResource in ipairs({ "hope", "fear" }) do
		local tRes = (tApplyData.tHealth or {})[sResource];
		if tRes and tRes.nPrevWounds and ((tRes.nWounds or 0) ~= tRes.nPrevWounds) then
			local nAdj = (tRes.nWounds or 0) - tRes.nPrevWounds;
			sendResourceCard(rActor, nil,
				(nAdj > 0) and "gained" or "spent", math.abs(nAdj), sResource);
		end
	end
end

-- The pools the tracker wrap cards, with where each lives and its verb
-- pair — hope/fear speak the economy's language (gained/spent), hp/stress
-- the ruleset's bookkeeping one (marked/cleared; their wounds count UP as
-- they are marked). Fear is the one global pool. Armor is left alone.
local _tTrackedPools = {
	hope = { sPath = "hope.value", sGain = "gained", sLose = "spent" },
	fear = { sPath = "fear.value", sGain = "gained", sLose = "spent", bGlobal = true },
	hp = { sPath = "hp.wounds", sGain = "marked", sLose = "cleared" },
	stress = { sPath = "stress.wounds", sGain = "marked", sLose = "cleared" },
};

-- Manual pool adjustments from the sheet trackers: the original clamps and
-- writes the value and outputs the "'Adolfoss' gains 'hope'" / "'Adolfoss'
-- marks 'hp'" text (dropped by the skip patterns); the card reports the
-- ACTUAL change, read as a before/after of the pool, so a click at the cap
-- or the floor cards nothing. Untracked resources pass through untouched.
function onStepResourceAdjustment(nodeChar, sResource, nAdjustment)
	local tPool = _tTrackedPools[sResource];
	if not tPool then
		return _fStepResourceAdjustment(nodeChar, sResource, nAdjustment);
	end

	local function readPool()
		if tPool.bGlobal then
			return DB.getValue(tPool.sPath, 0);
		end
		return DB.getValue(nodeChar, tPool.sPath, 0);
	end
	local nBefore = readPool();
	_fStepResourceAdjustment(nodeChar, sResource, nAdjustment);
	local nDelta = readPool() - nBefore;
	if nDelta == 0 then
		return;
	end

	local rActor = (not tPool.bGlobal) and ActorManager.resolveActor(nodeChar) or nil;
	sendResourceCard(rActor, "The GM",
		(nDelta > 0) and tPool.sGain or tPool.sLose, math.abs(nDelta), sResource);
end

-- The desktop fear tracker, same treatment ("Fear Gained" / "Fear Marked"
-- — marked meaning spent — dropped by the skip patterns).
function onStepFearAdjustment(nAdjustment)
	local nBefore = DB.getValue("fear.value", 0);
	_fStepFearAdjustment(nAdjustment);
	local nDelta = DB.getValue("fear.value", 0) - nBefore;
	if nDelta ~= 0 then
		sendResourceCard(nil, "The GM",
			(nDelta > 0) and "gained" or "spent", math.abs(nDelta), "fear");
	end
end

--
--	SHEET POWER CARDS
--

-- The "send to chat" button merged into the sheet's power rows (see
-- common/sheet_chatcards_dh.xml): Daggerheart has no power-use flow of its
-- own, so the button is the announce moment that sends the power card —
-- name, description and rollable action rows, like a 5E cast. sClass is
-- the windowclass the row's own name link opens (card / feature /
-- subfeature), for the card's title link.
function sendSheetPowerCard(nodePower, sClass)
	if not nodePower then
		return;
	end
	local rActor = ActorManager.resolveActor(PowerManagerDH.getPowerActorNode(nodePower));
	-- Mirror the sheet's reach: nodes owned by NPC records stay GM-only.
	local bSecret = not (rActor and ActorManager.isPC(rActor));
	ChatCardsCore.sendPowerCard(rActor, nodePower, bSecret, sClass);
end

--
--	SHEET ROW STRIPES
--

-- Alternating shade for the sheet's power lists (the stripe control merged
-- into the rows, see common/sheet_chatcards_dh.xml): every other row shows
-- a translucent black over its header row. The shade alternates over the
-- rows AS THE EYE READS THEM — a card's nested feature rows continue the
-- count, not their own — so the restripe walks depth-first from the
-- outermost list. Each stripe's onFirstLayout restripes the whole tree;
-- the last row to lay out sets the final parity, which also covers rows
-- added while the sheet is open. A deletion restripes when the sheet
-- reopens.

-- Depth-first: the entry takes the next slot, then its sub-rows (the
-- features sublist on card rows) continue the count. Returns the count.
local function stripeList(cList, n)
	for _, w in ipairs(cList.getWindows() or {}) do
		n = n + 1;
		if w.chatcards_stripe then
			w.chatcards_stripe.setVisible((n % 2) == 0);
		end
		if w.features and w.features.getWindows then
			n = stripeList(w.features, n);
		end
	end
	return n;
end

function updateListStripes(cList)
	if not cList then
		return;
	end
	-- Climb to the outermost list: a feature row's list sits inside a
	-- cards-list entry, whose own window belongs to the section and has
	-- no list above it.
	while cList.window and cList.window.windowlist do
		cList = cList.window.windowlist;
	end
	stripeList(cList, 0);
end

--
--	NEXT-ROLL MODIFIERS
--

-- An experience spent onto the modifier stack ("[MOD] Bodyguard [ADDED TO
-- MODIFIER STACK]"): the message is skipped by the MOD roll tag, and an
-- effect-style card announces it instead — "Bodyguard experience will
-- apply +1 to next roll of Romualda", with the name bold, the bonus
-- coloured like other bonuses and the actor linked. A DC-gated mod that
-- missed gets the failed wording (nothing reached the stack). The card
-- broadcasts, like the message it replaces; the stack itself only changed
-- on the rolling client.
function onModResolve(rSource, rTarget, rRoll, rMessage)
	_fModResolve(rSource, rTarget, rRoll, rMessage);

	local sLabel = StringManager.trim(rRoll.sLabel or "");
	if (sLabel == "") and ActionMod.decodeLabelText then
		sLabel = StringManager.trim(ActionMod.decodeLabelText(rRoll.sDesc or "") or "");
	end
	if sLabel == "" then
		return;
	end

	ChatCardsManager.sendCardOOB({
		sCardType = "nextrollmod",
		sName = sLabel,
		sKind = "experience",
		sBonus = string.format("%+d", rRoll.nTotal or 0),
		sFailed = (rRoll.sResult == "fail") and "1" or "",
		sActorName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
	}, ChatCardsManager.isRollSecret(rRoll) or rMessage.secret);
end

--
--	TAGS
--

-- tContext: { rSource, rTarget, rRoll, sLabel }
function getAttackTags(t)
	local tTags;
	if t.rTarget then
		tTags = { { sText = "Attack", sStyle = "negative" } };
	else
		tTags = { { sText = "Action" } };
	end
	for _, tTag in ipairs(getDualityTags(t)) do
		table.insert(tTags, tTag);
	end
	for _, tTag in ipairs(getAdvantageTags(t)) do
		table.insert(tTags, tTag);
	end
	return tTags;
end

function getDamageTags(t)
	local tTags = { { sText = "Damage", sStyle = "negative" } };
	for _, tTag in ipairs(getClauseTypeTags(t.rRoll)) do
		table.insert(tTags, tTag);
	end
	return tTags;
end

function getHealTags(t)
	local tTags = { { sText = "Healing", sStyle = "positive" } };
	for _, tTag in ipairs(getClauseTypeTags(t.rRoll)) do
		table.insert(tTags, tTag);
	end
	return tTags;
end

-- The duality outcome as pills: which die won, and the doubles crit. The
-- outcome slot in the result box keeps the short Success/Failure word, so
-- the flavour lives here.
function getDualityTags(t)
	local rRoll = t.rRoll or {};
	local tTags = {};
	if rRoll.bCritical or (rRoll.sResult == "crit") then
		table.insert(tTags, { sText = "Critical!" });
	end
	if rRoll.sDuality == "hope" then
		table.insert(tTags, { sText = "Hope", sStyle = "positive" });
	elseif rRoll.sDuality == "fear" then
		table.insert(tTags, { sText = "Fear", sStyle = "negative" });
	end
	return tTags;
end

-- Advantage/disadvantage from the roll flags (they survive the throw; the
-- ruleset reads them the same way at resolve time). Daggerheart adds an
-- advantage die rather than rolling twice, so there is no kept-die prefix
-- to fall back on.
function getAdvantageTags(t)
	local rRoll = t.rRoll or {};
	if rRoll.bADV and not rRoll.bDIS then
		return { { sText = "Advantage", sStyle = "positive" } };
	elseif rRoll.bDIS and not rRoll.bADV then
		return { { sText = "Disadvantage", sStyle = "negative" } };
	end
	return {};
end

-- One tag per damage/heal clause type. Types can be resources ("stress",
-- "armor", "hope", "fear") as well as wound types; either way the name is
-- the tag. rRoll.clauses was decoded by the mod phase on the rolling
-- client, so it is a real table here.
function getClauseTypeTags(rRoll)
	local tSeen = {};
	local tTags = {};
	for _, tClause in ipairs(type((rRoll or {}).clauses) == "table" and rRoll.clauses or {}) do
		for sType in tostring(tClause.dmgtype or ""):gmatch("[^,%s]+") do
			sType = sType:lower();
			if not tSeen[sType] then
				tSeen[sType] = true;
				table.insert(tTags, { sText = StringManager.capitalize(sType) });
			end
		end
	end
	return tTags;
end

--
--	DUALITY HELPERS
--

-- The short outcome word for the result box (the duality flavour is a pill,
-- see getDualityTags): hit/success -> Success, miss/failure -> Failure,
-- doubles -> Critical!, and a reaction's half save -> Partial.
function outcomeText(rRoll)
	if rRoll.bCritical or (rRoll.sResult == "crit") then
		return "Critical!";
	end
	if (rRoll.sResult == "hit") or (rRoll.sResult == "success") then
		return "Success";
	elseif (rRoll.sResult == "miss") or (rRoll.sResult == "failure") then
		return "Failure";
	elseif rRoll.sResult == "half_success" then
		return "Partial";
	end
	return "";
end

-- Row-entry colour for a power card's action rows.
function outcomeStyle(rRoll)
	local sOutcome = outcomeText(rRoll);
	if (sOutcome == "Success") or (sOutcome == "Critical!") or (sOutcome == "Partial") then
		return "positive";
	elseif sOutcome == "Failure" then
		return "negative";
	end
	return "";
end

-- Encode the roll's dice with the hope and fear dice marked: their types get
-- an "h"/"f" prefix, which the action card tints through the die styles
-- registered in onInit (the prefix keeps the die number, so the glyph shape
-- is untouched). Only PC duality rolls have the pair; everything else
-- encodes plain.
function encodeDualityDice(rSource, rRoll)
	local nHope, nFear = 0, 0;
	if rRoll.bDuality and rSource and ActorManager.isPC(rSource)
			and DiceManager2 and DiceManager2.collectHopeFear then
		nHope, nFear = DiceManager2.collectHopeFear(rSource, rRoll.aDice);
	end
	if (nHope == 0) or (nFear == 0) then
		return ChatCardsManager.encodeDiceResults(rRoll.aDice);
	end

	local tMarked = {};
	for i, d in ipairs(rRoll.aDice) do
		if type(d) == "table" then
			local tDie = {
				type = d.type or "d6",
				result = d.result or d.value or 0,
				dropped = d.dropped,
			};
			if i == nHope then
				tDie.type = "h" .. tDie.type;
			elseif i == nFear then
				tDie.type = "f" .. tDie.type;
			end
			table.insert(tMarked, tDie);
		end
	end
	return ChatCardsManager.encodeDiceResults(tMarked);
end

--
--	ACTION / ATTACK ROLLS
--

function onAttackResolve(rSource, rTarget, rRoll, rMessage)
	_fAttackResolve(rSource, rTarget, rRoll, rMessage);

	local bSecret = ChatCardsManager.isRollSecret(rRoll) or rMessage.secret;
	local sLabel = StringManager.trim(rRoll.sLabel or "");

	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "attack",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = (rTarget or rRoll.nDefenseVal) and "Attack" or "Action Roll",
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = encodeDualityDice(rSource, rRoll),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = outcomeText(rRoll),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
	};
	-- The rolled trait or weapon names the modifier line, as on 5E cards.
	if sLabel ~= "" then
		local sModLine = sLabel;
		if (rRoll.nMod or 0) ~= 0 then
			sModLine = string.format("%s %+d", sLabel, rRoll.nMod);
		end
		tCard.sMods = ChatCardsManager.encodeTags({ { sText = sModLine } });
	end
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
		if rRoll.nDefenseVal then
			tCard.sFormula = tCard.sFormula .. " vs " .. rRoll.nDefenseVal;
		end
	elseif (tonumber(rRoll.nTarget) or 0) > 0 then
		tCard.sLine1 = "DC: " .. tonumber(rRoll.nTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags("attack",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, bSecret);

	-- Report into a power card's Attack row when the roll came from one:
	-- one entry per target, coloured by outcome.
	local sEntry = tostring(rRoll.nTotal or 0);
	if rRoll.bCritical or (rRoll.sResult == "crit") then
		sEntry = sEntry .. " Crit";
	end
	ChatCardsManager.sendActionResult(rRoll, "add", sEntry, outcomeStyle(rRoll));

	-- Hope/fear from the duality result. With the auto-gain option (HRAG)
	-- on, the ruleset adjusted the pools itself and left riders on the
	-- roll message (suppressed with it by the ACTION tag), so the
	-- adjustments get resource cards of their own. The marker strings are
	-- literals in the ruleset (manager_action_attack.lua).
	local bAutoFear = false;
	for _, sMsg in ipairs(rRoll.aMessages or {}) do
		if sMsg == "[GAINS 1 HOPE]" then
			sendResourceCard(rSource, nil, "gained", 1, "hope", bSecret);
		elseif sMsg == "[GM GAINS 1 FEAR]" then
			bAutoFear = true;
			sendResourceCard(nil, "The GM", "gained", 1, "fear", bSecret);
		end
	end

	-- Without the auto-gain, a roll with fear is the GM's cue to bank a
	-- fear point by hand: a GM-only prompt card whose button does it (see
	-- chatcard_resource.onFearApply — pressing turns the prompt into the
	-- gained notice, in place). Only PC duality rolls carry sDuality.
	if (rRoll.sDuality == "fear") and not bAutoFear then
		ChatCardsManager.sendCardOOB({
			sCardType = "fear",
			sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
			sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
			sVerb = "rolled with",
			sResource = "fear",
			sPrompt = "1",
		}, true);
	end
end

--
--	REACTION ROLLS
--

-- The original resolves the reaction AND applies its result (rRoll.sResult
-- and bCritical are set inside, by applySave), so the card is built after
-- it returns. Its "Reaction ..." result line is dropped by the skip
-- pattern; the card carries the same information.
function onSaveRoll(rSource, rTarget, rRoll)
	ActionSave.onSave(rSource, rTarget, rRoll);

	local nDC = tonumber(rRoll.nTarget) or 0;
	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = "Reaction Roll",
		sLine1 = (nDC > 0) and ("DC: " .. nDC) or "",
		sOutcome = outcomeText(rRoll),
	});

	-- A save-vs from a power card marks each target's reaction through the
	-- desc (rRoll.sSaveDesc); the reaction resolves here, on the target's
	-- side.
	ChatCardsManager.sendActionResult(rRoll, "add",
		tostring(rRoll.nTotal or ActionsManager.total(rRoll)), outcomeStyle(rRoll));
end

--
--	DAMAGE AND HEALING
--

-- The card goes out BEFORE the original resolves: resolution applies the
-- damage (thresholds, resources) when the roll landed on a target, and its
-- apply banner must follow the roll that caused it.
function onDamageRoll(rSource, rTarget, rRoll)
	-- A result dragged off a card resolves through the normal action path
	-- when dropped (that is what applies it) — but it was already carded
	-- when it was rolled, so don't card it again.
	if (rRoll.sType == "damage") and not rRoll.sChatCardsRedrop then
		sendDamageCard(rSource, rTarget, rRoll);
	end
	ActionDamageD20.onRoll(rSource, rTarget, rRoll);
end

function onHealRoll(rSource, rTarget, rRoll)
	if (rRoll.sType == "heal") and not rRoll.sChatCardsRedrop then
		sendHealCard(rSource, rTarget, rRoll);
	end
	ActionDamageD20.onRoll(rSource, rTarget, rRoll);
end

function sendDamageCard(rSource, rTarget, rRoll)
	sendDamageHealCard(rSource, rTarget, rRoll, {
		sCardType = "damage",
		sTitle = "Damage Roll",
		sOutcome = "Damage",
	});
end

function sendHealCard(rSource, rTarget, rRoll)
	sendDamageHealCard(rSource, rTarget, rRoll, {
		sCardType = "heal",
		sTitle = "Healing",
		sOutcome = "Healing",
	});
end

-- Damage and healing share the card shape (they share the resolve handler
-- too); tKind carries the three fields that differ.
function sendDamageHealCard(rSource, rTarget, rRoll, tKind)
	local sLabel = StringManager.trim(rRoll.sLabel or "");
	local sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0);

	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = tKind.sCardType,
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = tKind.sTitle,
		sFormula = sFormula,
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sLine2 = StringManager.trim(sLabel .. " " .. sFormula),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = tKind.sOutcome,
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
		-- The rolled result stays draggable, like the entry in native chat:
		-- these plus sDice rebuild the roll at drag start (see the action
		-- card's onResultDrag). The clauses carry the damage/heal types the
		-- apply path reads, so they ride re-encoded (the mod phase consumed
		-- rRoll.sClauseData on the way here).
		sRollType = rRoll.sType,
		sRollDesc = rRoll.sDesc or "",
		sRollMod = tostring(rRoll.nMod or 0),
		sRollClauses = (type(rRoll.clauses) == "table")
			and UtilityManager.encodeTableToString(rRoll.clauses) or "",
	};
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags(tKind.sCardType,
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, ChatCardsManager.isRollSecret(rRoll));

	-- One shared total for a power card's row: rolls once, resolves per
	-- target, so "set" keeps it from repeating.
	ChatCardsManager.sendActionResult(rRoll, "set",
		tostring(rRoll.nTotal or ActionsManager.total(rRoll)), "");
end
