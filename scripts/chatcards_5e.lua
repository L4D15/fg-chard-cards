--
-- ChatCards: 5E hooks.
-- Captures structured attack/damage data at resolution time (before it is
-- flattened into chat text) and broadcasts it to every client as a card.
--

local _fAttackResolve = nil;

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
end

function onAttackResolve(rSource, rTarget, rRoll, rMessage)
	_fAttackResolve(rSource, rTarget, rRoll, rMessage);

	if rRoll.bSecret or rMessage.secret then
		return;
	end

	local sRange, sLabel = parseDesc(rRoll.sDesc, "ATTACK");
	local tCard = {
		sCardType = "attack",
		sName = ActorManager.getDisplayName(rSource) or rMessage.sender or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = rangeWord(sRange) .. "Attack: " .. sLabel,
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sTotal = tostring(rRoll.nTotal or 0),
		sOutcome = outcomeText(rRoll.sResult),
		sIdentity = ChatCardsManager.getIdentityFromActor(rSource),
		sLine2 = string.format("Modifier: %+d", rRoll.nMod or 0),
	};
	if rTarget then
		local sAC = rRoll.nDefenseVal and (" (AC " .. rRoll.nDefenseVal .. ")") or "";
		tCard.sLine1 = "Target: " .. (ActorManager.getDisplayName(rTarget) or "") .. sAC;
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
	local tCard = {
		sCardType = "damage",
		sName = ActorManager.getDisplayName(rSource) or "",
		sSub = rRoll.sUser or "Gamemaster",
		sTitle = "Damage Roll: " .. sLabel,
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sTotal = tostring(rRoll.nTotal or ActionsManager.total(rRoll)),
		sOutcome = "Damage",
		sIdentity = ChatCardsManager.getIdentityFromActor(rSource),
	};
	if rTarget then
		tCard.sLine1 = "Target: " .. (ActorManager.getDisplayName(rTarget) or "");
	end
	local sDmgType = (rRoll.sDesc or ""):match("%[TYPE: (%a+)");
	if sDmgType then
		tCard.sChip2 = StringManager.capitalize(sDmgType);
	end
	ChatCardsManager.sendCardOOB(tCard);
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
