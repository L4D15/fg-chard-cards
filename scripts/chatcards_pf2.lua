--
-- ChatCards: Pathfinder 2 (PFRPG2) adapter.
-- Captures structured attack/save/check/damage data at resolution time and
-- broadcasts it to every client as a card. Everything here touches PFRPG2's
-- own action managers, so the whole script gates itself on the ruleset (see
-- chatcards_5e.lua for the adapter pattern).
--
-- PFRPG2 notes:
--  - Every roll resolves to FOUR degrees of success
--    (GameSystem.getd20CheckResult): crit success / success / failure /
--    crit failure, with nat 20/1 stepping the result up/down.
--  - Resolution is split across clients: attacks, skills and abilities
--    resolve on the rolling client, but saves (ActionSave.applySave) and
--    activity checks (ActionVsDC.applyVsDC) resolve on the HOST, where the
--    (hidden) DCs live. The outcome cards for those come from host wraps.
--  - The apply messages are NOT bracket-tagged ("Damage [7] ->\r[to X]",
--    "Attack (M) (Rapier) [22] -> ..."), so the manager's banner path never
--    sees them: banners come from a messageDamage wrap instead, and the raw
--    texts are dropped by skip patterns.
--  - There is no PowerManagerCore flow: every sheet action button funnels
--    through SpellManager.onSpellAction(draginfo, nodeAction, sSubRoll).
--    A full cast inserts a "cast" roll — the power card's announce moment —
--    and the power card's rows drive onSpellAction through the core's
--    row-handler seam (ChatCardsCore.setPowerRowHandlers).
--

local _fAttackResolve = nil;
local _fApplySave = nil;
local _fApplyVsDC = nil;
local _fMessageDamage = nil;
local _fGetSpellAction = nil;

function onInit()
	-- Adapter gate: same-named but incompatible action managers exist on
	-- other systems (5E and PFRPG2 both define their own ActionAttack).
	-- SFRPG2 (Starfinder 2E) layers on this same codebase, so it rides along.
	if not (ChatCardsManager.isRuleset("PFRPG2") or ChatCardsManager.isRuleset("SFRPG2")) then
		return;
	end

	-- Roll types the hooks below card themselves, so the core resolveAction
	-- wrap must not card them again ("table" is claimed by ChatCardsCore's
	-- own capture). Left unclaimed on purpose: init and concentration keep
	-- the generic roll card.
	ChatCardsCore.registerDedicatedRollTypes({
		"attack", "grapple", "critconfirm", "misschance",
		"damage", "heal", "save", "skill", "ability",
		"vsdc", "cast", "castsave", "spellsave", "flatcheck", "recovery",
	});
	-- The power card's title links to the spell record display class.
	ChatCardsCore.setPowerRecordClass("spelldesc");

	-- Broadcast system sentences (save outcomes, apply banners, save-DC
	-- announcements) ride the plain system card.
	ChatCardsManager.registerCardClass("sysnotice", "chatcard_system");

	-- PFRPG2's message vocabulary. CAST is the full-cast announcement the
	-- power card replaces; ABILITY/CM/RECOVERY/FLAT tag ability checks,
	-- combat maneuvers, recovery checks and flat checks (the classifier
	-- captures the first uppercase word, so "[FLAT CHECK]" reads FLAT).
	ChatCardsManager.registerRollTags({
		"CAST", "ABILITY", "CM", "RECOVERY", "FLAT",
	});
	-- Apply texts a card or banner already covers. PFRPG2 writes them
	-- WITHOUT a leading bracket ("Attack (M) (Rapier) [22] -> ..."), so they
	-- ride skip patterns rather than the redundant-apply labels; the damage
	-- family is replaced by the banners the messageDamage wrap sends.
	ChatCardsManager.registerSkipPatterns({
		"^Attack[%s%(%[]",
		"^Damage[%s%[]", "^Heal[%s%[]",
		"^Temporary hit points[%s%[]", "^Fast healing[%s%[]",
		"^Regeneration[%s%[]", "^Shared ",
	});

	-- Attacks (grapple and critconfirm funnel through onAttack too). The
	-- resolve is called package-qualified, so a wrap works.
	if ActionAttack and ActionAttack.onAttackResolve then
		_fAttackResolve = ActionAttack.onAttackResolve;
		ActionAttack.onAttackResolve = onAttackResolve;
	end
	-- Miss-chance flat checks report through their own result handler.
	if ActionAttack and ActionAttack.onMissChance then
		ActionsManager.registerResultHandler("misschance", onMissChanceRoll);
	end
	-- Damage and healing: the original handler reference was captured at
	-- ruleset init; re-registering replaces it with our wrapper.
	if ActionDamage and ActionDamage.onDamage then
		ActionsManager.registerResultHandler("damage", onDamageRoll);
	end
	if ActionHeal and ActionHeal.onHeal then
		ActionsManager.registerResultHandler("heal", onHealRoll);
	end
	-- Saves: the roll cards from the result handler; the outcome resolves on
	-- the host in applySave (the DC is hidden from players), reported by the
	-- wrap below.
	if ActionSave and ActionSave.onSave then
		ActionsManager.registerResultHandler("save", onSaveRoll);
		_fApplySave = ActionSave.applySave;
		ActionSave.applySave = onApplySave;
	end
	-- Skills and abilities resolve (and print their degree) on the rolling
	-- client; the wrappers parse the outcome from the delivered message so
	-- result-step effects (SKILLRESULT) are honoured.
	if ActionSkill and ActionSkill.onRoll then
		ActionsManager.registerResultHandler("skill", onSkillRoll);
	end
	if ActionAbility and ActionAbility.onRoll then
		ActionsManager.registerResultHandler("ability", onAbilityRoll);
	end
	-- Activity checks (Trip, Demoralize, ...): the roll message is unbracketed
	-- (no tag to skip by), so it is captured at the source; the card comes
	-- from the host's applyVsDC, the one place that knows the outcome.
	if ActionVsDC and ActionVsDC.onVsDC then
		ActionsManager.registerResultHandler("vsdc", onVsDCRoll);
		_fApplyVsDC = ActionVsDC.applyVsDC;
		ActionVsDC.applyVsDC = onApplyVsDC;
	end
	-- Flat checks (persistent damage) print an unbracketed line too.
	if ActionFlatcheck and ActionFlatcheck.onFlatcheck then
		ActionsManager.registerResultHandler("flatcheck", onFlatcheckRoll);
	end
	-- Recovery checks: dying value read before/after the original applies it.
	if ActionRecovery and ActionRecovery.onRecovery then
		ActionsManager.registerResultHandler("recovery", onRecoveryRoll);
	end

	-- Spell casts announce as power cards. The "cast" roll (diceless) is
	-- only inserted for a FULL cast (no subtype), so this is the moment.
	if ActionSpell and ActionSpell.onSpellCast then
		ActionsManager.registerResultHandler("cast", onSpellCastRoll);
	end
	-- Untargeted save-vs rolls print the DC line the SAVE tag would skip;
	-- a system card replaces it.
	if ActionSpell and ActionSpell.onSpellSave then
		ActionsManager.registerResultHandler("spellsave", onSpellSaveRoll);
		ActionsManager.registerResultHandler("castsave", onCastSaveRoll);
	end

	-- Applied damage/healing banners ("Grig takes 12 damage"). applyDamage
	-- runs on the host and words its result through messageDamage; the raw
	-- texts are dropped by the skip patterns above, the banner replaces them.
	if ActionDamage and ActionDamage.messageDamage then
		_fMessageDamage = ActionDamage.messageDamage;
		ActionDamage.messageDamage = onMessageDamage;
	end

	-- Effect origin. Every sheet action is built by SpellManager's
	-- getSpellAction with the action node in hand; the owning spell's name is
	-- stamped onto effect actions there and carried to the host by
	-- ChatCardsCore's encode/decode chain.
	if SpellManager and SpellManager.getSpellAction then
		_fGetSpellAction = SpellManager.getSpellAction;
		SpellManager.getSpellAction = onGetSpellAction;
	end

	-- A power card's save row crosses to each target's client through
	-- ActionSpell's OOB, where only the desc survives: the row marker must
	-- ride the desc on these roll types.
	ChatCardsManager.registerMarkDescRollTypes({ "castsave", "spellsave" });

	-- Power-card rows. The row split mirrors the sheet: a cast action
	-- contributes its Attack and/or Save halves (rows whose sub-roll the
	-- action does not define are dropped by the card); other types keep the
	-- default one-row-per-action.
	ChatCardsCore.setPowerRowBuilder(function(_, sType)
		if sType == "cast" then
			return {
				{ sSubRoll = "atk", sLabel = "Attack" },
				{ sSubRoll = "save", sLabel = "Save" },
			};
		end
	end);
	-- ...and the rows' look and perform: PFRPG2's sheets never touch
	-- PowerActionManagerCore, so the core's defaults would draw nothing.
	ChatCardsCore.setPowerRowHandlers({
		fIcon = getRowIcon,
		fText = getRowText,
		fTooltip = function() return ""; end,
		fPerform = function(draginfo, nodeAction, tData)
			SpellManager.onSpellAction(draginfo, nodeAction, tData and tData.sSubRoll or nil);
		end,
	});

	-- This ruleset's card tags. Fortune/misfortune (the system's roll-twice
	-- effects) ride every d20 card through the "roll" providers, along with
	-- the proficiency rank and save traits.
	ChatCardsManager.registerTagProvider("attack", getAttackTags);
	ChatCardsManager.registerTagProvider("damage", getDamageTags);
	ChatCardsManager.registerTagProvider("heal", getHealTags);
	ChatCardsManager.registerTagProvider("vsdc", getVsDCTags);
	ChatCardsManager.registerTagProvider("roll", getRollTags);
end

--
--	SHARED HELPERS
--

-- Run fn with the Comm delivery calls intercepted: every table message's
-- text is collected, and fnDrop (when given) decides which are swallowed
-- rather than sent. Used where the ruleset prints output with no bracketed
-- tag the manager could classify, so the card must replace it at the source.
function runWithMessageCapture(fnDrop, fnRun)
	local tSeen = {};
	local fDeliver = Comm.deliverChatMessage;
	local fAdd = Comm.addChatMessage;
	local function intercept(fOriginal)
		return function(msg, ...)
			if type(msg) == "table" then
				table.insert(tSeen, msg.text or "");
				if fnDrop and fnDrop(msg) then
					return;
				end
			end
			return fOriginal(msg, ...);
		end;
	end
	Comm.deliverChatMessage = intercept(fDeliver);
	Comm.addChatMessage = intercept(fAdd);
	local bOK, vError = pcall(fnRun);
	Comm.deliverChatMessage = fDeliver;
	Comm.addChatMessage = fAdd;
	if not bOK then
		Debug.console("ChatCardsPF2.runWithMessageCapture: ", vError);
	end
	return tSeen;
end

-- The four degrees, as the ruleset writes them into message texts (last
-- match wins: earlier bracketed chatter like "[+1 DEGREE OF SUCCESS EFFECT]"
-- never spells a full result tag).
local _tResultWords = {
	["CRITICAL SUCCESS"] = "Critical Success",
	["SUCCESS"] = "Success",
	["FAILURE"] = "Failure",
	["CRITICAL FAILURE"] = "Critical Failure",
};

function resultWord(sResult)
	return _tResultWords[sResult or ""] or "";
end

-- Extract the final degree from a delivered message text ("... [CRITICAL
-- SUCCESS]"); scanning specific-first so "[CRITICAL SUCCESS]" is not read
-- as "[SUCCESS]".
function parseResultFromText(sText)
	sText = sText or "";
	for _, sResult in ipairs({ "CRITICAL SUCCESS", "CRITICAL FAILURE", "SUCCESS", "FAILURE" }) do
		if sText:find("%[" .. sResult .. "%]") then
			return sResult;
		end
	end
	return "";
end

function resultStyle(sResult)
	if (sResult == "CRITICAL SUCCESS") or (sResult == "SUCCESS") then
		return "positive";
	elseif (sResult == "FAILURE") or (sResult == "CRITICAL FAILURE") then
		return "negative";
	end
	return "";
end

-- Comma-separated trait string -> capitalized pills. tSkip (lowercased
-- keys) drops traits another pill already covers ("basic" on save cards).
function addTraitTags(tTags, sTraits, tSkip)
	for sEntry in tostring(sTraits or ""):gmatch("[^,]+") do
		local sTrait = StringManager.trim(sEntry);
		if (sTrait ~= "") and not (tSkip and tSkip[sTrait:lower()]) then
			table.insert(tTags, { sText = StringManager.capitalize(sTrait) });
		end
	end
end

--
--	TAGS
--

-- tContext: { rSource, rTarget, rRoll, sLabel }
function getAttackTags(t)
	local rRoll = t.rRoll or {};
	local sDesc = rRoll.sDesc or "";
	local tTags = { { sText = "Attack", sStyle = "negative" } };
	if rRoll.sResult == "crit" then
		table.insert(tTags, { sText = "Critical!" });
	end
	for _, tTag in ipairs(getFortuneTags(rRoll)) do
		table.insert(tTags, tTag);
	end
	if sDesc:match("%[Spell%]") then
		table.insert(tTags, { sText = "Spell" });
	end
	if sDesc:match("%[KEEN%]") then
		table.insert(tTags, { sText = "Keen" });
	end
	local sMAP = sDesc:match("%[MULTI ATK (#%d+):");
	if sMAP then
		table.insert(tTags, { sText = "MAP " .. sMAP, sStyle = "negative" });
	end
	addTraitTags(tTags, rRoll.traits);
	return tTags;
end

function getDamageTags(t)
	local rRoll = t.rRoll or {};
	local tTags = { { sText = "Damage", sStyle = "negative" } };
	if rRoll.bCritical then
		table.insert(tTags, { sText = "Critical!" });
	end
	for _, sType in ipairs(getClauseTypes(rRoll)) do
		table.insert(tTags, { sText = sType });
	end
	return tTags;
end

function getHealTags(t)
	local rRoll = t.rRoll or {};
	local sHealType = rRoll.healtype or "";
	if sHealType == "temp" then
		return { { sText = "Temporary HP", sStyle = "positive" } };
	elseif sHealType == "shield" then
		return { { sText = "Shield Repair", sStyle = "positive" } };
	end
	return { { sText = "Healing", sStyle = "positive" } };
end

-- Activity checks: the skill rolled and the action's traits.
function getVsDCTags(t)
	local rRoll = t.rRoll or {};
	local tTags = {};
	if (rRoll.sSourceAction or "") ~= "" then
		table.insert(tTags, { sText = StringManager.capitalize(rRoll.sSourceAction) });
	end
	addTraitTags(tTags, rRoll.traits);
	return tTags;
end

-- Every roll-card type: fortune/misfortune, the proficiency rank riding the
-- desc ("[Trained]"), Assurance/assisted checks and a save's Basic marker
-- plus the triggering action's traits (from the save-vs desc).
function getRollTags(t)
	local rRoll = t.rRoll or {};
	local sDesc = rRoll.sDesc or "";
	local tTags = getFortuneTags(rRoll);
	local sProf = sDesc:match("%[(Untrained)%]") or sDesc:match("%[(Trained)%]")
		or sDesc:match("%[(Expert)%]") or sDesc:match("%[(Master)%]")
		or sDesc:match("%[(Legendary)%]");
	if sProf then
		table.insert(tTags, { sText = sProf });
	end
	if sDesc:match("%[ASSURANCE%]") then
		table.insert(tTags, { sText = "Assurance" });
	end
	if sDesc:match("%[ASSIST%]") then
		table.insert(tTags, { sText = "Assist" });
	end
	local sSaveDesc = rRoll.sSaveDesc or "";
	if sSaveDesc:match("%[BASIC%]") then
		table.insert(tTags, { sText = "Basic" });
	end
	-- The ruleset appends "basic" to the trait list too; the pill covers it.
	addTraitTags(tTags, sSaveDesc:match("%[TRAITS ([^%]]*)%]"), { basic = true });
	return tTags;
end

-- Fortune/misfortune (the system's roll-twice-keep effects): decodeR2K
-- marks the kept die with a 'g'/'r' prefix, like 5E's advantage.
function getFortuneTags(rRoll)
	for _, vDie in ipairs(rRoll.aDice or {}) do
		local sType = (type(vDie) == "table") and (vDie.type or "") or "";
		if sType:match("^gd%d") then
			return { { sText = "Fortune", sStyle = "positive" } };
		elseif sType:match("^rd%d") then
			return { { sText = "Misfortune", sStyle = "negative" } };
		end
	end
	return {};
end

-- One entry per damage-clause type, deduped ("piercing", "fire,spell" ->
-- Piercing, Fire, Spell). The clauses were decoded by the mod phase, so
-- they are a real table by resolve time.
function getClauseTypes(rRoll)
	local tSeen = {};
	local tTypes = {};
	for _, tClause in ipairs(type((rRoll or {}).clauses) == "table" and rRoll.clauses or {}) do
		for sType in tostring(tClause.dmgtype or ""):gmatch("[^,%s]+") do
			sType = sType:lower();
			if not tSeen[sType] then
				tSeen[sType] = true;
				table.insert(tTypes, StringManager.capitalize(sType));
			end
		end
	end
	return tTypes;
end

--
--	ATTACKS
--

-- Outcome words in the system's own attack vocabulary.
function attackOutcome(sResult)
	if sResult == "crit" then
		return "Critical Hit!";
	elseif sResult == "hit" then
		return "Hit";
	elseif sResult == "miss" then
		return "Miss";
	elseif sResult == "fumble" then
		return "Critical Miss";
	end
	return "";
end

function attackOutcomeStyle(sResult)
	if (sResult == "hit") or (sResult == "crit") then
		return "positive";
	elseif (sResult == "miss") or (sResult == "fumble") then
		return "negative";
	end
	return "";
end

-- The resolve sees the four-degree result already decided (rRoll.sResult);
-- the defense value stays host-side knowledge, so the card reports target
-- and outcome without a "vs AC" figure. Grapples/maneuvers ride the same
-- resolve with a [CM] desc.
function onAttackResolve(rSource, rTarget, rRoll, rMessage, rRoll2, nMissChance)
	_fAttackResolve(rSource, rTarget, rRoll, rMessage, rRoll2, nMissChance);

	local bSecret = ChatCardsManager.isRollSecret(rRoll) or rMessage.secret;
	local sLabel = StringManager.trim(rRoll.sAbilityTitle or "");

	local sTitle;
	if (rRoll.sDesc or ""):match("^%[CM%]") or (rRoll.sType == "grapple") then
		sTitle = "Combat Maneuver";
	else
		local sRange = ActionAttackCore.decodeRangeText(rRoll.sDesc or "");
		if sRange == "R" then
			sTitle = "Ranged Attack";
		elseif sRange == "M" then
			sTitle = "Melee Attack";
		else
			sTitle = "Attack";
		end
	end

	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "attack",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = sTitle,
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = attackOutcome(rRoll.sResult),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
	};
	-- The weapon or maneuver names the modifier line, as on the other systems.
	if sLabel ~= "" then
		local sModLine = sLabel;
		if (rRoll.nMod or 0) ~= 0 then
			sModLine = string.format("%s %+d", sLabel, rRoll.nMod);
		end
		tCard.sMods = ChatCardsManager.encodeTags({ { sText = sModLine } });
	end
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags("attack",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, bSecret);

	-- Report into a power card's Attack row when the roll came from one:
	-- one entry per target, coloured by outcome.
	local sEntry = tostring(rRoll.nTotal or 0);
	if rRoll.sResult == "crit" then
		sEntry = sEntry .. " Crit";
	elseif rRoll.sResult == "fumble" then
		sEntry = sEntry .. " Fumble";
	end
	ChatCardsManager.sendActionResult(rRoll, "add", sEntry, attackOutcomeStyle(rRoll.sResult));
end

-- The concealment/hidden flat check a non-miss triggers. The original
-- appends the outcome to its message (skipped by the ATTACK tag its desc
-- carries), so it is parsed back out of the capture.
function onMissChanceRoll(rSource, rTarget, rRoll)
	local tSeen = runWithMessageCapture(nil, function()
		ActionAttack.onMissChance(rSource, rTarget, rRoll);
	end);

	local sText = tSeen[#tSeen] or "";
	local sOutcome = "";
	if sText:find("%[MISS%]") then
		sOutcome = "Miss";
	elseif sText:find("%[CRITICAL%]") then
		sOutcome = "Critical Hit!";
	elseif sText:find("%[HIT%]") then
		sOutcome = "Hit";
	end
	local nDC = tonumber((rRoll.sDesc or ""):match("%[MISS CHANCE DC (%d+)%]")) or 0;
	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = "Miss Chance",
		sLine1 = (nDC > 0) and ("DC: " .. nDC) or "",
		sOutcome = sOutcome,
	});
end

--
--	DAMAGE AND HEALING
--

-- The card goes out BEFORE the original resolves: resolution applies the
-- damage when the roll landed on a target, and its "takes N damage" banner
-- must follow the roll that caused it.
function onDamageRoll(rSource, rTarget, rRoll)
	-- A result dragged off a card resolves through the normal action path
	-- when dropped (that is what applies it) — but it was already carded
	-- when it was rolled, so don't card it again.
	if (rRoll.sType == "damage") and not rRoll.sChatCardsRedrop then
		sendDamageHealCard(rSource, rTarget, rRoll, {
			sCardType = "damage",
			sTitle = "Damage Roll",
			sOutcome = "Damage",
		});
	end
	ActionDamage.onDamage(rSource, rTarget, rRoll);
end

function onHealRoll(rSource, rTarget, rRoll)
	if (rRoll.sType == "heal") and not rRoll.sChatCardsRedrop then
		local bTemp = ((rRoll.healtype or "") == "temp");
		sendDamageHealCard(rSource, rTarget, rRoll, {
			sCardType = "heal",
			sTitle = bTemp and "Temporary HP" or "Healing",
			sOutcome = bTemp and "Temp HP" or "Healing",
		});
	end
	ActionHeal.onHeal(rSource, rTarget, rRoll);
end

-- Damage and healing share the card shape; tKind carries what differs.
function sendDamageHealCard(rSource, rTarget, rRoll, tKind)
	local sLabel = StringManager.trim(rRoll.sLabel or "");
	if sLabel == "" then
		sLabel = ActionDamageCore.decodeLabelText(rRoll.sDesc or "") or "";
	end
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
		-- apply path reads, so they ride re-encoded — the drop's mod phase
		-- (CoreRPG setupModRoll) decodes them exactly as for a fresh roll.
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

-- Applied damage/healing, worded on the host after resistances, weaknesses
-- and shields (the skip patterns drop the raw "Damage [7] ->" texts this
-- replaces). The notifications the ruleset appends ([RESISTED], [SHIELD
-- BROKEN], ...) become a plain-word suffix.
local _tApplyPhrases = {
	["Damage"] = { sVerb = "takes", sUnit = "damage" },
	["Heal"] = { sVerb = "recovers", sUnit = "hit points" },
	["Temporary hit points"] = { sVerb = "gains", sUnit = "temporary hit points" },
	["Fast healing"] = { sVerb = "recovers", sUnit = "hit points" },
	["Regeneration"] = { sVerb = "recovers", sUnit = "hit points" },
};

function onMessageDamage(rSource, rTarget, bSecret, sDamageType, sDamageDesc, sTotal, sExtraResult, bNotApplied)
	_fMessageDamage(rSource, rTarget, bSecret, sDamageType, sDamageDesc, sTotal, sExtraResult, bNotApplied);

	-- Shared (linked-PC) copies and untargeted results keep no banner.
	local tPhrase = _tApplyPhrases[sDamageType or ""];
	if bNotApplied or not rTarget or not tPhrase then
		return;
	end

	local sAmount = StringManager.trim(tostring(sTotal or ""));
	local sText;
	if sAmount ~= "" then
		sText = string.format("%s %s %s %s",
			ChatCardsManager.getActorName(rTarget), tPhrase.sVerb, sAmount, tPhrase.sUnit);
	else
		sText = string.format("%s %s %s",
			ChatCardsManager.getActorName(rTarget), tPhrase.sVerb, tPhrase.sUnit);
	end
	-- "[RESISTED] [SHIELD BROKEN]" -> " (resisted, shield broken)"
	local tNotes = {};
	for sNote in tostring(sExtraResult or ""):gmatch("%[([^%]]+)%]") do
		table.insert(tNotes, sNote:lower());
	end
	if #tNotes > 0 then
		sText = sText .. " (" .. table.concat(tNotes, ", ") .. ")";
	end
	ChatCardsManager.sendCardOOB({ sCardType = "sysnotice", sText = sText }, bSecret or false);
end

--
--	SAVES
--

-- The roll card, from the rolling client. The DC stays hidden (as in the
-- ruleset: the roll message never shows it); what the target saves against
-- is public and names the line. The outcome resolves host-side in
-- applySave, which sends the outcome card below — the roll card goes out
-- BEFORE the original so the outcome always lands after it (on the host
-- both fire in the same call chain). decodeR2K first, so a fortune roll
-- shows its kept die; the original's own decode then no-ops (one die left).
function onSaveRoll(rSource, rTarget, rRoll)
	ActionsManager2.decodeR2K(rRoll);

	local sSave = ActionSaveCore.decodeLabelText(rRoll.sDesc or "") or "";
	local sVs = "";
	if (rRoll.sSaveDesc or "") ~= "" then
		sVs = ActionCore.decodeLabelText(rRoll.sSaveDesc, "action_savevs_tag") or "";
	end
	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = StringManager.capitalize(sSave) .. " Save",
		sLine1 = (sVs ~= "") and ("vs: " .. StringManager.trim(sVs)) or "",
		sMods = ChatCardsManager.encodeTags({
			{ sText = string.format("%s %+d", StringManager.capitalize(sSave), rRoll.nMod or 0) },
		}),
	});

	ActionSave.onSave(rSource, rTarget, rRoll);
end

-- Host-side save resolution: the one place the final degree exists (hidden
-- DCs, SAVERESULT step effects, evasion). The native "[Name] Save [23] ->"
-- messages are dropped from the capture — the outcome card replaces them —
-- while anything else the original prints (activity result texts) passes.
function onApplySave(rSource, rOrigin, rAction, sUser)
	runWithMessageCapture(function(msg)
		local sText = msg.text or "";
		return (sText:find(" Save %[", 1) or sText:find(" Save %->", 1)) and true or false;
	end, function()
		_fApplySave(rSource, rOrigin, rAction, sUser);
	end);

	local sResult = rAction.sSaveResult or "";
	if sResult == "" then
		return;
	end

	local sAttack = "";
	if (rAction.sSaveDesc or "") ~= "" then
		sAttack = StringManager.trim(ActionCore.decodeLabelText(rAction.sSaveDesc, "action_savevs_tag") or "");
	end
	local sText = string.format("%s saves [%d]", ChatCardsManager.getActorName(rSource), rAction.nTotal or 0);
	if sAttack ~= "" then
		sText = sText .. " vs " .. sAttack;
	elseif rOrigin then
		sText = sText .. " vs " .. ChatCardsManager.getActorName(rOrigin);
	end
	sText = sText .. ": " .. resultWord(sResult);
	ChatCardsManager.sendCardOOB({ sCardType = "sysnotice", sText = sText }, rAction.bSecret or false);

	-- Report into a power card's Save row when the save came from one (the
	-- marker rode the save-vs desc across clients): one entry per target.
	local tMark = ChatCardsManager.getRollMark(rAction);
	if tMark then
		ChatCardsManager.sendActionResultDirect(tMark, tMark.bSecret or rAction.bSecret or false,
			"add", tostring(rAction.nTotal or 0), resultStyle(sResult));
	end
end

--
--	SKILL AND ABILITY CHECKS
--

-- Both resolve on the rolling client and append the degree to their message
-- (kept — the SKILL/ABILITY tags skip it), which is parsed back for the
-- card so result-step effects (SKILLRESULT) are honoured. The DC itself is
-- shown only where the ruleset shows it (ability checks).
function onSkillRoll(rSource, rTarget, rRoll)
	local tSeen = runWithMessageCapture(nil, function()
		ActionSkill.onRoll(rSource, rTarget, rRoll);
	end);

	local sSkill = ActionCore.decodeLabelText(rRoll.sDesc or "", "action_skill_tag") or "";
	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = "Skill Check",
		sMods = ChatCardsManager.encodeTags({
			{ sText = string.format("%s %+d", sSkill, rRoll.nMod or 0) },
		}),
		sOutcome = resultWord(parseResultFromText(tSeen[#tSeen])),
	});
end

function onAbilityRoll(rSource, rTarget, rRoll)
	local tSeen = runWithMessageCapture(nil, function()
		ActionAbility.onRoll(rSource, rTarget, rRoll);
	end);

	local sAbility = ActionCore.decodeLabelText(rRoll.sDesc or "", "action_ability_tag") or "";
	local nDC = tonumber(rRoll.nTarget) or 0;
	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = "Ability Check",
		sLine1 = (nDC > 0) and ("DC: " .. nDC) or "",
		sMods = ChatCardsManager.encodeTags({
			{ sText = string.format("%s %+d", StringManager.capitalize(sAbility), rRoll.nMod or 0) },
		}),
		sOutcome = resultWord(parseResultFromText(tSeen[#tSeen])),
	});
end

--
--	ACTIVITY CHECKS (vsdc)
--

-- The roll message is unbracketed ("Trip [Athletics vs. reflex] ..."), so
-- it is swallowed at the source; the card comes from the host's applyVsDC,
-- the only place that knows the DC and the degree.
function onVsDCRoll(rSource, rTarget, rRoll)
	runWithMessageCapture(function(msg)
		return #(msg.dice or {}) > 0;
	end, function()
		ActionVsDC.onVsDC(rSource, rTarget, rRoll);
	end);
end

-- Host-side resolution. The native output (msgLong opens with the roll
-- desc) is dropped; warnings the original prints through other paths (no
-- valid shield, ...) pass through. The card carries the kept die, total,
-- target and outcome.
function onApplyVsDC(rSource, rTarget, rRoll, bSecret, sAttackType, sDesc, nTotal, nFirstDie, sAbilityTitle, sActionNodeName)
	local sDescHead = (sDesc or ""):match("^[^\r\n]*") or "";
	local tSeen = runWithMessageCapture(function(msg)
		return (sDescHead ~= "") and StringManager.startsWith(msg.text or "", sDescHead) and true or false;
	end, function()
		_fApplyVsDC(rSource, rTarget, rRoll, bSecret, sAttackType, sDesc, nTotal, nFirstDie, sAbilityTitle, sActionNodeName);
	end);

	local sResult = "";
	for _, sText in ipairs(tSeen) do
		local s = parseResultFromText(sText);
		if s ~= "" then
			sResult = s;
		end
	end

	local sLabel = StringManager.trim(GameSystem.cleanAbilityNameText(sAbilityTitle or "") or "");
	if sLabel == "" then
		sLabel = "Activity Check";
	end
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "vsdc",
		sName = ChatCardsManager.getActorName(rSource, nil),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		-- The card is sent by the host (resolution lives here) and the OOB
		-- that carried the roll drops the rolling user, so no player line.
		sSub = "",
		sTitle = sLabel,
		sFormula = ChatCardsManager.buildDiceFormula({ "d20" }, rRoll.nMod or 0),
		sDice = string.format("d20:%d", nFirstDie or 0),
		sTotal = tostring(nTotal or 0),
		sOutcome = resultWord(sResult),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
	};
	if (rRoll.sSourceAction or "") ~= "" then
		tCard.sMods = ChatCardsManager.encodeTags({
			{ sText = string.format("%s %+d", StringManager.capitalize(rRoll.sSourceAction), rRoll.nMod or 0) },
		});
	end
	if rTarget and (rTarget ~= "fixed") then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags("vsdc",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, bSecret or false);
end

--
--	FLAT CHECKS AND RECOVERY
--

-- Persistent-damage flat checks print an unbracketed line ("Persistent
-- Damage [on Grig] [FLAT CHECK] [Fire] [DC:15] ..."), swallowed here; the
-- follow-up effect-removal notice (no dice on it) passes through and keeps
-- its own card. The outcome recomputes the same way the original did (no
-- effects touch it in between).
function onFlatcheckRoll(rSource, rTarget, rRoll)
	runWithMessageCapture(function(msg)
		return #(msg.dice or {}) > 0;
	end, function()
		ActionFlatcheck.onFlatcheck(rSource, rTarget, rRoll);
	end);

	local sDesc = rRoll.sDesc or "";
	local nDC = tonumber(sDesc:match("%[DC:(%d+)%]")) or 0;
	local sLabel = sDesc:match("%[FLAT CHECK%]%s*%[([^%]]+)%]") or "";
	local sSubject = StringManager.trim(sDesc:match("^([^%[]+)") or "");
	local sOutcome = "";
	if (nDC > 0) and rRoll.aDice and rRoll.aDice[1] then
		sOutcome = resultWord(GameSystem.getd20CheckResult(
			rRoll.aDice[1].result or 0, ActionsManager.total(rRoll), nDC));
	end

	-- Mirror the ruleset's reach: checks on friendly-faction actors show to
	-- the table (the original clears its message's secret flag the same
	-- way). sendRollCard reads the roll's own flag, so it is cleared here —
	-- the original already ran, nothing else reads it after this.
	if rTarget and (ActorManager.getFaction(rTarget) == "friend") then
		rRoll.bSecret = nil;
	end

	ChatCardsManager.sendRollCard(rSource or rTarget, rRoll, {
		sTitle = "Flat Check",
		sLine1 = (nDC > 0) and ("DC: " .. nDC) or "",
		sMods = (sSubject ~= "") and ChatCardsManager.encodeTags({
			{ sText = StringManager.trim(sSubject .. " " .. sLabel) },
		}) or "",
		sOutcome = sOutcome,
	});
end

-- Recovery checks (dying PCs): DC 10 + dying, applied inside the original
-- (its "[RECOVERY]" message is skipped by the roll tag). The dying value is
-- read before and after, so the card reports what actually changed.
function onRecoveryRoll(rSource, rTarget, rRoll)
	local nodeChar = ActorManager.getCreatureNode(rSource);
	local bPC = rSource and ActorManager.isPC(rSource);
	local nBefore = bPC and nodeChar and DB.getValue(nodeChar, "hp.dying", 0) or 0;

	ActionRecovery.onRecovery(rSource, rTarget, rRoll);

	if not (bPC and nodeChar) or (nBefore == 0) then
		return;
	end
	local nAfter = DB.getValue(nodeChar, "hp.dying", 0);
	local nDC = 10 + nBefore;
	local sOutcome = "";
	if rRoll.aDice and rRoll.aDice[1] then
		sOutcome = resultWord(GameSystem.getd20CheckResult(
			rRoll.aDice[1].result or 0, ActionsManager.total(rRoll), nDC));
	end

	local sChange = string.format("Dying %d \194\187 %d", nBefore, nAfter);
	if nAfter == 0 then
		sChange = sChange .. " (stable, wounded +1)";
	elseif nAfter >= DB.getValue(nodeChar, "hp.dieatdying", 4) then
		sChange = sChange .. " (dead)";
	end

	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = "Recovery Check",
		sLine1 = "DC: " .. nDC,
		sMods = ChatCardsManager.encodeTags({ { sText = sChange } }),
		sOutcome = sOutcome,
	});
end

--
--	SPELL CASTS AND SAVE-VS
--

-- A full cast's "cast" roll: the original prints "[CAST] Fireball [at X]"
-- (skipped by the CAST tag) and the power card is the announcement — name,
-- description, rollable Attack/Save/Damage/Heal/Effect rows. A cast against
-- several targets resolves once per target; only the first sends the card.
function onSpellCastRoll(rSource, rTarget, rRoll)
	ActionSpell.onSpellCast(rSource, rTarget, rRoll);

	if rTarget and ((rTarget.nOrder or 1) ~= 1) then
		return;
	end

	local bSecret = ChatCardsManager.isRollSecret(rRoll);
	if Session.IsHost and rSource and CombatManager.isCTHidden(ActorManager.getCTNode(rSource)) then
		bSecret = true;
	end

	-- The action node rides the roll; its owning spell is the grandparent
	-- (spell -> actions -> action).
	local nodeAction = ((rRoll.sActionNodeName or "") ~= "") and DB.findNode(rRoll.sActionNodeName) or nil;
	local nodeSpell = nodeAction and DB.getChild(nodeAction, "...") or nil;
	if nodeSpell and ChatCardsCore.sendPowerCard(rSource, nodeSpell, bSecret) then
		return;
	end

	-- No resolvable spell node (a chat-dragged cast): announce name-only.
	local sName = StringManager.trim(ActionCore.decodeLabelText(rRoll.sDesc or "", "action_cast_tag") or "");
	if sName == "" then
		return;
	end
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	ChatCardsManager.sendCardOOB({
		sCardType = "power",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or (Session.IsHost and "Gamemaster" or ""),
		sPower = sName,
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
	}, bSecret);
end

-- Save-vs rolls. Targeted ones request each target's save silently (the
-- saves card themselves as they resolve); an untargeted spellsave prints
-- the DC announcement the SAVE tag skips, so a notice card replaces it.
function onCastSaveRoll(rSource, rTarget, rRoll)
	ActionSpell.onCastSave(rSource, rTarget, rRoll);
end

function onSpellSaveRoll(rSource, rTarget, rRoll)
	ActionSpell.onSpellSave(rSource, rTarget, rRoll);

	if rTarget then
		return;
	end
	local sDesc = rRoll.sDesc or "";
	local sLabel = StringManager.trim(ActionCore.decodeLabelText(sDesc, "action_savevs_tag") or "");
	local sSaveShort, sSaveDC = sDesc:match("%[(%w+) DC (%d+)%]");
	if not sSaveShort then
		return;
	end
	local sSave = DataCommon.save_stol[sSaveShort] or sSaveShort:lower();
	local sText = string.format("%s: %s save DC %s",
		(sLabel ~= "") and sLabel or "Save", StringManager.capitalize(sSave), sSaveDC);
	ChatCardsManager.sendCardOOB({ sCardType = "sysnotice", sText = sText },
		ChatCardsManager.isRollSecret(rRoll));
end

--
--	EFFECT ORIGIN
--

-- The square brackets would collide with the notice's own [from ...]
-- markers. The action node's owning spell/ability is its grandparent
-- (spell -> actions list -> action).
function onGetSpellAction(rActor, nodeAction, sSubRoll, ...)
	local rAction = _fGetSpellAction(rActor, nodeAction, sSubRoll, ...);
	if rAction and (rAction.type == "effect") and nodeAction then
		local nodeSpell = DB.getChild(nodeAction, "...");
		local sPowerName = nodeSpell
			and StringManager.trim(DB.getValue(nodeSpell, "name", "")):gsub("[%[%]]", "") or "";
		if sPowerName ~= "" then
			rAction.sChatCardsPower = sPowerName;
		end
	end
	return rAction;
end

--
--	POWER-CARD ROWS
--

-- Row icons by action type/sub-roll: PFRPG2's own action-button art where
-- it exists, CoreRPG's plain roll button elsewhere.
function getRowIcon(nodeAction, tData)
	local sSubRoll = tData and tData.sSubRoll or "";
	if sSubRoll == "atk" then
		return "button_action_attack";
	elseif sSubRoll == "save" then
		return "button_roll";
	end
	local sType = DB.getValue(nodeAction, "type", "");
	if sType == "damage" then
		return "button_action_damage";
	elseif sType == "heal" then
		return "button_action_heal";
	elseif sType == "effect" then
		return "button_action_effect";
	end
	return "button_roll";
end

-- Row detail text, from the same SpellManager views the sheet shows. An
-- empty text on a sub-roll row drops the row (an attack-less spell has no
-- Attack half), which is the card's contract.
function getRowText(nodeAction, tData)
	local sSubRoll = tData and tData.sSubRoll or "";
	if sSubRoll == "atk" then
		return SpellManager.getActionAttackText(nodeAction) or "";
	elseif sSubRoll == "save" then
		return SpellManager.getActionSaveText(nodeAction) or "";
	end
	local sType = DB.getValue(nodeAction, "type", "");
	if sType == "damage" then
		return SpellManager.getActionDamageText(nodeAction) or "";
	elseif sType == "heal" then
		return SpellManager.getActionHealText(nodeAction) or "";
	elseif sType == "effect" then
		local sLabel = DB.getValue(nodeAction, "label", "");
		local sDuration = SpellManager.getActionEffectDurationText(nodeAction) or "";
		return StringManager.trim(sLabel .. " " .. sDuration);
	elseif sType == "skill" then
		return SpellManager.getActionSkillText(nodeAction) or "";
	end
	return "";
end
