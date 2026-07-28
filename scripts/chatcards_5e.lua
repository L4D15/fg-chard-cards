--
-- ChatCards: 5E hooks.
-- Captures structured attack/damage data at resolution time (before it is
-- flattened into chat text) and broadcasts it to every client as a card.
--

local _fAttackResolve = nil;
local _fResolveAction = nil;

-- Roll types with a dedicated card hook; everything else gets a generic
-- roll card from the resolveAction wrap. Types that roll no dice produce
-- no card either way.
local _tDedicatedTypes = { attack = true, damage = true };

function onInit()
	if ActionAttack and ActionAttack.onAttackResolve then
		_fAttackResolve = ActionAttack.onAttackResolve;
		ActionAttack.onAttackResolve = onAttackResolve;
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
end

function onResolveAction(rSource, rTarget, rRoll)
	_fResolveAction(rSource, rTarget, rRoll);

	if _tDedicatedTypes[rRoll.sType or ""] then
		return;
	end
	if rRoll.bSecret then
		return;
	end
	if #(rRoll.aDice or {}) == 0 then
		return;
	end
	ChatCardsManager.sendGenericRollCard(rSource, rRoll);
end

function onAttackResolve(rSource, rTarget, rRoll, rMessage)
	_fAttackResolve(rSource, rTarget, rRoll, rMessage);

	if rRoll.bSecret or rMessage.secret then
		return;
	end

	local sRange, sLabel = parseDesc(rRoll.sDesc, "ATTACK");
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "attack",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = rangeWord(sRange) .. "Attack",
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sMod = ChatCardsManager.formatMod(rRoll.nMod),
		sTotal = tostring(rRoll.nTotal or 0),
		sOutcome = outcomeText(rRoll.sResult),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
		sLine2 = buildAttackModBreakdown(rSource, rTarget, rRoll, sLabel),
	};
	if rTarget then
		local sAC = rRoll.nDefenseVal and (" (AC " .. rRoll.nDefenseVal .. ")") or "";
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget) .. sAC;
	end
	if rRoll.nDefenseVal then
		tCard.sFormula = tCard.sFormula .. " vs " .. rRoll.nDefenseVal;
	end
	if rRoll.sResult == "crit" then
		tCard.sChip2 = "Critical!";
	end
	ChatCardsManager.sendCardOOB(tCard);
end

function onDamageRoll(rSource, rTarget, rRoll)
	ActionDamageD20.onRoll(rSource, rTarget, rRoll);

	if rRoll.sType ~= "damage" or rRoll.bSecret then
		return;
	end

	local _, sLabel = parseDesc(rRoll.sDesc, "DAMAGE");
	local tPortrait = ChatCardsManager.getActorPortrait(rSource);
	local tCard = {
		sCardType = "damage",
		sName = ChatCardsManager.getActorName(rSource, rRoll.sUser),
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = "Damage Roll: " .. sLabel,
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sMod = ChatCardsManager.formatMod(rRoll.nMod),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = "Damage",
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
	};
	if rTarget then
		tCard.sLine1 = "Target: " .. ChatCardsManager.getActorName(rTarget);
	end
	local sDmgType = (rRoll.sDesc or ""):match("%[TYPE: (%a+)");
	if sDmgType then
		tCard.sChip2 = StringManager.capitalize(sDmgType);
	end
	ChatCardsManager.sendCardOOB(tCard);
end

-- Itemized attack modifier line: "Crossbow, Light +3 · Bless +1d4".
-- The first entry is the roll source's own listed bonus (ability +
-- proficiency + item bonuses as printed on the sheet), named after the
-- weapon/spell. Effects are re-queried the same way the ruleset queried
-- them when building the roll; rRoll.nEffectMod (tracked by
-- ActionCore.applyModRollEffect) separates the sheet bonus from effect
-- contributions, and flat mods not attributable to a named ATK/@ATK
-- effect are lumped as "Other effects". Middot-separated because
-- weapon names can contain commas.
function buildAttackModBreakdown(rSource, rTarget, rRoll, sSourceLabel)
	local nMod = rRoll.nMod or 0;
	local nEffectMod = tonumber(rRoll.nEffectMod or 0) or 0;
	if (sSourceLabel or "") == "" then
		sSourceLabel = "Base";
	end
	local tParts = { string.format("%s %+d", sSourceLabel, nMod - nEffectMod) };

	local tFilter = ActionCore.buildEffectFilter(rRoll);
	local nListed = 0;
	nListed = nListed + addEffectBreakdownItems(tParts, rSource, "ATK", { rTarget = rTarget, tFilter = tFilter });
	nListed = nListed + addEffectBreakdownItems(tParts, rTarget, "@ATK", { rTarget = rSource, tFilter = tFilter });

	local nOther = nEffectMod - nListed;
	if nOther ~= 0 then
		table.insert(tParts, string.format("Other effects %+d", nOther));
	end
	return table.concat(tParts, " \194\183 ");
end

-- Append "Name +bonus" entries for each active effect with matching
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
				table.insert(tParts, sName .. " " .. sBonus);
				nListedMod = nListedMod + nCompMod;
			end
		end
	end
	return nListedMod;
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
