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
		sTitle = rangeWord(sRange) .. "Attack: " .. sLabel,
		sFormula = ChatCardsManager.buildDiceFormula(rRoll.aDice, rRoll.nMod or 0),
		sDice = ChatCardsManager.encodeDiceResults(rRoll.aDice),
		sMod = ChatCardsManager.formatMod(rRoll.nMod),
		sTotal = tostring(rRoll.nTotal or 0),
		sOutcome = outcomeText(rRoll.sResult),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rSource and Session.IsHost) and "1" or "",
		sLine2 = string.format("Modifier: %+d", rRoll.nMod or 0),
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
