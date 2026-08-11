--
-- ChatCards: 5E adapter.
-- Captures structured attack/damage/save/check data at resolution time
-- (before it is flattened into chat text) and broadcasts it to every client
-- as a card. Everything here touches 5E's own action managers, so the whole
-- script gates itself on the ruleset; the system-agnostic hooks live in
-- ChatCardsCore, and an adapter for another system would mirror this file.
--

local _fAttackResolve = nil;
local _fSaveResolve = nil;
local _fPowerPerformAction = nil;

function onInit()
	-- Adapter gate: without it the hooks below would grab same-named but
	-- incompatible globals on other systems (PFRPG2 and SavageWorlds both
	-- define their own ActionAttack, with different signatures).
	if not ChatCardsManager.isRuleset("5E") then
		return;
	end

	-- Roll types the hooks below card themselves, so the core resolveAction
	-- wrap must not card them again ("table" is claimed by ChatCardsCore's
	-- own capture).
	ChatCardsCore.registerDedicatedRollTypes({
		"attack", "damage", "heal", "save", "check", "skill",
	});
	-- The power card's title links to 5E's power record class.
	ChatCardsCore.setPowerRecordClass("power");

	-- 5E's message vocabulary, for the manager's chat classification: roll
	-- texts to skip beyond the common d20 set, apply labels whose outcome a
	-- card already reports, and apply labels that become banners.
	ChatCardsManager.registerRollTags({
		"DEATH", "CAST", "CONCENTRATION", "RECHARGE", "RECOVERY", "POWERSAVE",
	});
	ChatCardsManager.registerRedundantApplies({ "Concentration", "System Shock" });
	ChatCardsManager.registerApplyBanners({
		["Temporary hit points"] = { sVerb = "gains", sUnit = "temporary hit points" },
		["Fast healing"] = { sVerb = "recovers", sUnit = "hit points" },
		Regeneration = { sVerb = "recovers", sUnit = "hit points" },
		Recovery = { sVerb = "recovers", sUnit = "hit points" },
	});

	if ActionAttack and ActionAttack.onAttackResolve then
		_fAttackResolve = ActionAttack.onAttackResolve;
		ActionAttack.onAttackResolve = onAttackResolve;
	end
	if ActionSave and ActionSave.onSaveResolve then
		_fSaveResolve = ActionSave.onSaveResolve;
		ActionSave.onSaveResolve = onSaveResolve;
	end
	-- Checks and skills share one result handler, re-registered like damage.
	if ActionCheck and ActionCheck.onRoll then
		ActionsManager.registerResultHandler("check", onCheckRoll);
		ActionsManager.registerResultHandler("skill", onCheckRoll);
	end
	if ActionDamageD20 and ActionDamageD20.onRoll then
		-- The original handler reference was captured at ruleset init;
		-- re-registering replaces it with our wrapper.
		ActionsManager.registerResultHandler("damage", onDamageRoll);
		-- Healing shares the damage handler in the ruleset.
		ActionsManager.registerResultHandler("heal", onHealRoll);
	end

	-- Effect origin and cast cards. Every power use (PC, NPC, record sheet)
	-- funnels through PowerManager.performAction, the only point that still
	-- holds the power node an effect action belongs to: the power's name is
	-- stamped onto effect actions there (rAction.sChatCardsPower — carried
	-- to the host by ChatCardsCore's encode/decode chain), and a full cast
	-- announces itself as a power card.
	if PowerManager and PowerManager.performAction then
		_fPowerPerformAction = PowerManager.performAction;
		PowerManager.performAction = onPowerPerformAction;
	end

	-- This ruleset's card tags. The manager knows nothing about them; other
	-- systems (or plugin extensions) register their own the same way.
	ChatCardsManager.registerTagProvider("attack", getAttackTags);
	ChatCardsManager.registerTagProvider("damage", getDamageTags);
	ChatCardsManager.registerTagProvider("heal", getHealTags);
	-- Saves, checks and skills roll with advantage too
	ChatCardsManager.registerTagProvider("roll", getAdvantageTags);
end

--
--	POWER USE
--

-- The square brackets would collide with the notice's own [from ...] markers.
function onPowerPerformAction(draginfo, rActor, rAction, nodePower)
	if rAction and (rAction.type == "effect") and nodePower then
		local sPowerName = StringManager.trim(DB.getValue(nodePower, "name", "")):gsub("[%[%]]", "");
		if sPowerName ~= "" then
			rAction.sChatCardsPower = sPowerName;
		end
	end
	local bResult = _fPowerPerformAction(draginfo, rActor, rAction, nodePower);
	-- A full cast (subtype "" — the sub-roll buttons re-run only the attack
	-- or save part) announces the power. Its "[CAST] ..." text message is
	-- one of the skipped roll tags, so the card is the announcement.
	if bResult and rAction and (rAction.type == "cast") and ((rAction.subtype or "") == "") then
		ChatCardsCore.sendPowerCard(rActor, nodePower);
	end
	return bResult;
end

--
--	TAGS
--

-- tContext: { rSource, rTarget, rRoll, sLabel }
function getAttackTags(t)
	local tTags = { { sText = "Attack", sStyle = "negative" } };
	if t.rRoll and t.rRoll.sResult == "crit" then
		table.insert(tTags, { sText = "Critical!" });
	end
	-- Advantage before the weapon properties: slots fill in order, and a
	-- weapon with many properties would otherwise push it off the row.
	for _, tTag in ipairs(getAdvantageTags(t)) do
		table.insert(tTags, tTag);
	end
	for _, sProp in ipairs(getWeaponProperties(t.rSource, t.sLabel)) do
		table.insert(tTags, { sText = sProp });
	end
	return tTags;
end

function getDamageTags(t)
	local tTags = { { sText = "Damage", sStyle = "negative" } };
	local sDmgType = ((t.rRoll or {}).sDesc or ""):match("%[TYPE: (%a+)");
	if sDmgType then
		table.insert(tTags, { sText = StringManager.capitalize(sDmgType) });
	end
	for _, sProp in ipairs(getWeaponProperties(t.rSource, t.sLabel)) do
		table.insert(tTags, { sText = sProp });
	end
	return tTags;
end

function getHealTags(t)
	local bTemp = (((t.rRoll or {}).healtype or "") == "temp");
	return { { sText = bTemp and "Temporary HP" or "Healing", sStyle = "positive" } };
end

-- Advantage / disadvantage. The roll flags survive to resolve time, and the
-- kept die also carries the 'g'/'r' prefix ActionD20.decodeAdvantage puts on
-- it, which covers roll types that do not set the flags. Both together
-- cancel out, as in the rules, and produce no tag.
function getAdvantageTags(t)
	local rRoll = t.rRoll or {};
	local bADV, bDIS = rRoll.bADV, rRoll.bDIS;
	if not bADV and not bDIS then
		for _, vDie in ipairs(rRoll.aDice or {}) do
			local sType = (type(vDie) == "table") and (vDie.type or "") or "";
			if sType:match("^gd%d") then
				bADV = true;
			elseif sType:match("^rd%d") then
				bDIS = true;
			end
		end
	end
	if bADV and not bDIS then
		return { { sText = "Advantage", sStyle = "positive" } };
	elseif bDIS and not bADV then
		return { { sText = "Disadvantage", sStyle = "negative" } };
	end
	return {};
end

-- Weapon properties ("Finesse, Light") live on the weapon entry of the
-- source's sheet; the roll carries only the weapon's label, so match on
-- that. Range parentheses ("Thrown (20/60)") are dropped, and placeholders
-- are skipped: the field holds "-" when a weapon has no properties.
function getWeaponProperties(rSource, sLabel)
	local tProps = {};
	if not rSource or ((sLabel or "") == "") then
		return tProps;
	end
	local nodeActor = ActorManager.getCreatureNode(rSource);
	if not nodeActor then
		return tProps;
	end
	local sLabelLower = sLabel:lower();
	for _, nodeWeapon in ipairs(DB.getChildList(nodeActor, "weaponlist")) do
		if DB.getValue(nodeWeapon, "name", ""):lower() == sLabelLower then
			local sProps = DB.getValue(nodeWeapon, "properties", "");
			for _, sProp in ipairs(StringManager.splitByPattern(sProps, ",", true)) do
				sProp = StringManager.trim(sProp:gsub("%s*%(.*%)", ""));
				if isRealProperty(sProp) then
					table.insert(tProps, StringManager.capitalize(sProp));
				end
			end
			break;
		end
	end
	return tProps;
end

--
--	ATTACKS
--

function onAttackResolve(rSource, rTarget, rRoll, rMessage)
	_fAttackResolve(rSource, rTarget, rRoll, rMessage);

	local bSecret = ChatCardsManager.isRollSecret(rRoll) or rMessage.secret;

	local sRange, sLabel = parseDesc(rRoll.sDesc, "ATTACK");
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "attack",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = rangeWord(sRange) .. "Attack",
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sTotal = tostring(rRoll.nTotal or 0),
		sOutcome = outcomeText(rRoll.sResult),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
		sMods = buildAttackModBreakdown(rSource, rTarget, rRoll, sLabel),
	};
	if rTarget then
		local sAC = rRoll.nDefenseVal and (" (AC " .. rRoll.nDefenseVal .. ")") or "";
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget) .. sAC;
	end
	if rRoll.nDefenseVal then
		tCard.sFormula = tCard.sFormula .. " vs " .. rRoll.nDefenseVal;
	end
	tCard.sTags = ChatCardsManager.buildTags("attack",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, bSecret);

	-- Report into the power card's Attack row when the roll came from one:
	-- one entry per target, coloured by outcome (neutral without a target).
	local sEntry = tostring(rRoll.nTotal or 0);
	if rRoll.sResult == "crit" then
		sEntry = sEntry .. " Crit";
	elseif rRoll.sResult == "fumble" then
		sEntry = sEntry .. " Fumble";
	end
	ChatCardsManager.sendActionResult(rRoll, "add", sEntry, outcomeStyle(rRoll.sResult));
end

-- Row-entry colour from an attack result string.
function outcomeStyle(sResult)
	if (sResult == "hit") or (sResult == "crit") then
		return "positive";
	elseif (sResult == "miss") or (sResult == "fumble") then
		return "negative";
	end
	return "";
end

--
--	DAMAGE AND HEALING
--

-- The card goes out BEFORE the original resolves: resolution applies the
-- damage when the roll landed on a target, and its "takes N damage" banner
-- must follow the roll that caused it. Everything the card shows (dice
-- results, total, target, type tags in the desc) exists before resolution.
function onDamageRoll(rSource, rTarget, rRoll)
	-- A result dragged off a card resolves through the normal action path
	-- when dropped (that is what applies it) — but it was already carded
	-- when it was rolled, so don't card it again.
	if (rRoll.sType == "damage") and not rRoll.sChatCardsRedrop then
		sendDamageCard(rSource, rTarget, rRoll);
	end
	ActionDamageD20.onRoll(rSource, rTarget, rRoll);
end

function sendDamageCard(rSource, rTarget, rRoll)
	local _, sLabel = parseDesc(rRoll.sDesc, "DAMAGE");
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "damage",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = "Damage Roll",
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sLine2 = sLabel .. " " .. ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = "Damage",
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
		-- The rolled result stays draggable, like the entry in native chat:
		-- these plus sDice rebuild the roll at drag start (see the action
		-- card's onResultDrag). The desc carries the damage type tags, which
		-- is what ActionDamage reads when the drop applies.
		sRollType = rRoll.sType,
		sRollDesc = rRoll.sDesc or "",
		sRollMod = tostring(rRoll.nMod or 0),
	};
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags("damage",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, ChatCardsManager.isRollSecret(rRoll));

	-- Damage rolls once and resolves per target: "set" keeps the shared
	-- total from repeating in the power card's row.
	ChatCardsManager.sendActionResult(rRoll, "set",
		tostring(rRoll.nTotal or ActionsManager.total(rRoll)), "");
end

-- Healing and temporary hit points. rRoll.healtype distinguishes the two, and
-- the source (a spell, a potion) names the roll the way a weapon does on a
-- damage card. Card before resolution, as on the damage side, so the
-- "recovers N hit points" banner follows the roll.
function onHealRoll(rSource, rTarget, rRoll)
	-- Re-dropped result: apply without re-carding, as on the damage side.
	if (rRoll.sType == "heal") and not rRoll.sChatCardsRedrop then
		sendHealCard(rSource, rTarget, rRoll);
	end
	ActionDamageD20.onRoll(rSource, rTarget, rRoll);
end

function sendHealCard(rSource, rTarget, rRoll)
	local bTemp = ((rRoll.healtype or "") == "temp");
	local sLabel = rRoll.sLabel or "";
	if sLabel == "" then
		sLabel = ActionHealCore.decodeLabelText(rRoll.sDesc or "") or "";
	end
	local sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0);

	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "heal",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sActorNode = rSource and ActorManager.getCreatureNodeName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = bTemp and "Temporary HP" or "Healing",
		sFormula = sFormula,
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sLine2 = StringManager.trim(sLabel .. " " .. sFormula),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = bTemp and "Temp HP" or "Healing",
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
		-- Draggable result, as on the damage card. The desc's [HEAL]/[TEMP]
		-- tags tell ActionHeal what to apply on drop.
		sRollType = rRoll.sType,
		sRollDesc = rRoll.sDesc or "",
		sRollMod = tostring(rRoll.nMod or 0),
	};
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags("heal",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, ChatCardsManager.isRollSecret(rRoll));

	-- One shared total, like damage — and styled like it: a heal has no
	-- success or failure, and the row marks/tints are outcome semantics.
	ChatCardsManager.sendActionResult(rRoll, "set",
		tostring(rRoll.nTotal or ActionsManager.total(rRoll)), "");
end

--
--	SAVES, ABILITY CHECKS AND SKILL CHECKS
--

-- Saving throw. rRoll.nTarget carries the DC when the save has one; the ability
-- becomes the base modifier's label, the way a weapon does on an attack card.
function onSaveResolve(rSource, rRoll, rMessage)
	_fSaveResolve(rSource, rRoll, rMessage);

	local sAbility = rRoll.sSave or rRoll.sAbility or "";
	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = "Saving Throw",
		sLine1 = formatTargetDC(rRoll),
		sMods = buildRollModBreakdown(rSource, rRoll, StringManager.capitalize(sAbility),
			{ { sTag = "SAVE", tFilter = { sAbility } } }),
		sOutcome = outcomeVsDC(rRoll),
	});

	-- A save-vs from a power card marks each target's save through the
	-- desc (rRoll.sSaveDesc); the save resolves here, on the target's side.
	-- Green = the target saved, red = it failed.
	local sOutcome = outcomeVsDC(rRoll);
	local sStyle = "";
	if sOutcome == "Success" then
		sStyle = "positive";
	elseif sOutcome == "Failure" then
		sStyle = "negative";
	end
	ChatCardsManager.sendActionResult(rRoll, "add",
		tostring(rRoll.nTotal or ActionsManager.total(rRoll)), sStyle);
end

-- Ability and skill checks. A skill roll takes both the CHECK effects for its
-- ability and the SKILL effects for the skill itself, which is what the
-- ruleset queries when building the roll.
function onCheckRoll(rSource, rTarget, rRoll)
	ActionCheck.onRoll(rSource, rTarget, rRoll);

	local sAbility = rRoll.sAbility or "";
	local tQueries = { { sTag = "CHECK", tFilter = { sAbility } } };
	local sTitle, sLabel;
	if rRoll.sType == "skill" then
		sTitle = "Skill Check";
		local sSkill = rRoll.sSkill or "";
		-- Display the ruleset's own spelling ("Sleight of Hand"), but query
		-- effects with the roll's value, which is what the filter matched on.
		sLabel = getCanonicalSkillName(sSkill);
		table.insert(tQueries, { sTag = "SKILL", tFilter = { sAbility, sSkill } });
	else
		sTitle = "Ability Check";
		sLabel = StringManager.capitalize(sAbility);
	end

	ChatCardsManager.sendRollCard(rSource, rRoll, {
		sTitle = sTitle,
		sLine1 = formatTargetDC(rRoll),
		sMods = buildRollModBreakdown(rSource, rRoll, sLabel, tQueries),
		sOutcome = outcomeVsDC(rRoll),
	});
end

-- Skill names reach the card in whatever case the roll carried, often all
-- lowercase. DataCommon.skilldata is keyed by the ruleset's own localised
-- spelling ("Animal Handling", "Sleight of Hand"), so match that
-- case-insensitively rather than capitalising words ourselves, which would give
-- "Sleight Of Hand". Falls back to per-word capitalisation for anything custom.
function getCanonicalSkillName(sSkill)
	if (sSkill or "") == "" then
		return "";
	end
	local sLower = sSkill:lower();
	for sName, _ in pairs(DataCommon.skilldata or {}) do
		if sName:lower() == sLower then
			return sName;
		end
	end
	return StringManager.capitalizeAll(sSkill);
end

-- "DC: 15", rendered with the same bold label as an attack's "Target:" line.
function formatTargetDC(rRoll)
	local nDC = tonumber(rRoll.nTarget) or 0;
	if nDC <= 0 then
		return "";
	end
	return "DC: " .. nDC;
end

function outcomeVsDC(rRoll)
	local nDC = tonumber(rRoll.nTarget) or 0;
	if nDC <= 0 then
		return "";
	end
	if (rRoll.sDesc or ""):match("%[AUTOFAIL%]") then
		return "Failure";
	end
	local nTotal = rRoll.nTotal or ActionsManager.total(rRoll);
	return (nTotal >= nDC) and "Success" or "Failure";
end

-- Itemized modifiers for a save or check, in the same shape as the attack row:
-- each effect query contributes its own segments, and the roll's own bonus is
-- whatever remains of rRoll.nMod afterwards.
--
-- The ruleset's effect filters (tSaveFilter, tCheckFilter, tSkillFilter) are
-- tables, so they do not survive the dice throw and cannot be reused here —
-- they are rebuilt by the callers from the string fields that do survive
-- (sSave, sAbility, sSkill).
function buildRollModBreakdown(rSource, rRoll, sSourceLabel, tQueries)
	local tSegments = {};
	local nListed = 0;
	for _, tQuery in ipairs(tQueries or {}) do
		nListed = nListed + addEffectBreakdownItems(tSegments, tQuery.rActor or rSource,
			tQuery.sTag, tQuery.tData or { tFilter = tQuery.tFilter });
	end

	if (sSourceLabel or "") == "" then
		sSourceLabel = "Base";
	end
	table.insert(tSegments, 1, {
		sText = string.format("%s %+d", sSourceLabel, (rRoll.nMod or 0) - nListed),
	});
	return ChatCardsManager.encodeTags(tSegments);
end

-- Attack modifiers: the attacker's ATK effects plus the defender's @ATK
-- effects, with the weapon or spell naming the roll's own bonus. See
-- buildRollModBreakdown for how the base is derived and why.
function buildAttackModBreakdown(rSource, rTarget, rRoll, sSourceLabel)
	local tFilter = ActionCore.buildEffectFilter(rRoll);
	return buildRollModBreakdown(rSource, rRoll, sSourceLabel, {
		{ sTag = "ATK", tData = { rTarget = rTarget, tFilter = tFilter } },
		{ sTag = "@ATK", rActor = rTarget, tData = { rTarget = rSource, tFilter = tFilter } },
	});
end

-- Append "Name +bonus" segments for each active effect with matching
-- components; returns the flat-modifier total that was itemized.
function addEffectBreakdownItems(tParts, rActor, sTag, tData)
	if not rActor then
		return 0;
	end
	local nListedMod = 0;
	for _, tEffectData in ipairs(EffectQueryManager.getEffectsDataByTag(rActor, sTag, tData)) do
		if (tEffectData.nActive or 0) == 1 then
			local sName = StringManager.trim((tEffectData.sLabel or ""):match("^([^;]+)") or "") or "";
			if sName == "" or sName:match(":") then
				-- unnamed effect (label starts with a typed component)
				sName = "Effect";
			end

			local tDice = {};
			local nCompMod = 0;
			for _, tComp in ipairs(EffectManager.parseEffectComps(tEffectData)) do
				if tComp.type == sTag then
					for _, vDie in ipairs(tComp.dice or {}) do
						table.insert(tDice, vDie);
					end
					nCompMod = nCompMod + (tComp.mod or 0);
				end
			end

			if (#tDice > 0) or (nCompMod ~= 0) then
				local sBonus = ChatCardsManager.buildDiceFormula(tDice, nCompMod);
				if not sBonus:match("^[%+%-]") then
					sBonus = "+" .. sBonus;
				end
				table.insert(tParts, {
					sText = sName .. " " .. sBonus,
					sStyle = sBonus:match("^%-") and "negative" or "positive",
				});
				nListedMod = nListedMod + nCompMod;
			end
		end
	end
	return nListedMod;
end

-- Placeholders used for "no properties": a bare dash (any kind), or an
-- explicit none. Anything without a letter or digit is not a property.
local _tPropertyPlaceholders = { ["none"] = true, ["n/a"] = true, ["na"] = true };

function isRealProperty(sProp)
	if (sProp or "") == "" then
		return false;
	end
	if not sProp:match("%w") then
		return false;
	end
	return not _tPropertyPlaceholders[sProp:lower()];
end

-- "[ATTACK (M)] Shortsword [EXTRA TAG]" -> "M", "Shortsword"
function parseDesc(sDesc, sTag)
	sDesc = sDesc or "";
	local sRange = sDesc:match("^%[" .. sTag .. "%s*%(?(%u?)%)?%]") or "";
	local sLabel = sDesc:gsub("^%[[^%]]*%]%s*", "");
	sLabel = sLabel:gsub("%s*%[[^%]]*%]", "");
	return sRange, sLabel;
end

function rangeWord(sRange)
	if sRange == "M" then
		return "Melee ";
	elseif sRange == "R" then
		return "Ranged ";
	end
	return "";
end

function outcomeText(sResult)
	if sResult == "hit" then
		return "Success";
	elseif sResult == "miss" then
		return "Failure";
	elseif sResult == "crit" then
		return "Critical!";
	elseif sResult == "fumble" then
		return "Fumble";
	end
	return "";
end
