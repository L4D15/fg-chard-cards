--
-- ChatCards: 5E hooks.
-- Captures structured attack/damage data at resolution time (before it is
-- flattened into chat text) and broadcasts it to every client as a card.
--

local _fAttackResolve = nil;
local _fSaveResolve = nil;
local _fResolveAction = nil;

-- Roll types with a dedicated card hook; everything else gets a generic
-- roll card from the resolveAction wrap. Types that roll no dice produce
-- no card either way.
local _tDedicatedTypes = {
	attack = true, damage = true, save = true, check = true, skill = true,
};

function onInit()
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
	end
	-- Single hook point for every other roll type (basic dice, saves,
	-- checks, skills, init, ...): runs on the rolling client only.
	_fResolveAction = ActionsManager.resolveAction;
	ActionsManager.resolveAction = onResolveAction;

	-- This ruleset's card tags. The manager knows nothing about them; other
	-- systems (or plugin extensions) register their own the same way.
	ChatCardsManager.registerTagProvider("attack", getAttackTags);
	ChatCardsManager.registerTagProvider("damage", getDamageTags);
	-- Saves, checks and skills roll with advantage too
	ChatCardsManager.registerTagProvider("roll", getAdvantageTags);
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

function onResolveAction(rSource, rTarget, rRoll)
	_fResolveAction(rSource, rTarget, rRoll);

	if _tDedicatedTypes[rRoll.sType or ""] then
		return;
	end
	if #(rRoll.aDice or {}) == 0 then
		return;
	end
	ChatCardsManager.sendGenericRollCard(rSource, rRoll);
end

function onAttackResolve(rSource, rTarget, rRoll, rMessage)
	_fAttackResolve(rSource, rTarget, rRoll, rMessage);

	local bSecret = ChatCardsManager.isRollSecret(rRoll) or rMessage.secret;

	local sRange, sLabel = parseDesc(rRoll.sDesc, "ATTACK");
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "attack",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
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
end

function onDamageRoll(rSource, rTarget, rRoll)
	ActionDamageD20.onRoll(rSource, rTarget, rRoll);

	if rRoll.sType ~= "damage" then
		return;
	end

	local _, sLabel = parseDesc(rRoll.sDesc, "DAMAGE");
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "damage",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
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
	};
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	tCard.sTags = ChatCardsManager.buildTags("damage",
		{ rSource = rSource, rTarget = rTarget, rRoll = rRoll, sLabel = sLabel });
	ChatCardsManager.sendCardOOB(tCard, ChatCardsManager.isRollSecret(rRoll));
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
		sLabel = rRoll.sSkill or "";
		table.insert(tQueries, { sTag = "SKILL", tFilter = { sAbility, sLabel } });
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
