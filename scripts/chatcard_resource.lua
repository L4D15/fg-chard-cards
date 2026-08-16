--
-- ChatCards: resource card (Daggerheart's hope and fear economy). One
-- sentence — "Adolfoss has gained 2 hope" — with the name bold and linked,
-- and the amount and resource word in bold. Shared by chatcard_hope and
-- chatcard_fear (a windowclass frame is static, so the two backgrounds are
-- two classes); the fear card's art is dark, so its sentence renders in
-- the light fonts, and the linked name carries its colour so the link
-- hover restores it light (see setRichText).
--

local LINE_HEIGHT = 18;
-- The sentence control's left/right anchors, used to derive its width from
-- the card's before the first layout (see chatcard_effect.lua).
local INSET = 17;
local FALLBACK_WIDTH = 300;

-- Must match cc_bodybold_light in graphics_chatcards.xml.
local LIGHT_TEXT_COLOR = "FFFFFFFF";

local _tData = nil;
local _nRenderedWidth = nil;

-- No weak tables in FG's sandbox: the manager's link state is released by
-- hand when the card closes (and hope prompts leave the id registry).
function onClose()
	ChatCardsManager.unregisterCard((_tData or {}).sCardId);
	ChatCardsManager.releaseControlState(sentence);
end

-- Re-set by the prompt buttons (onFearApply locally, the hope prompt's
-- card-update OOB via updateCard), so the width memo is cleared for the
-- re-render.
function setData(t)
	_tData = t;
	_nRenderedWidth = nil;
	-- The GM prompt variant ("X has rolled with fear"): the button that
	-- banks the fear point. Only the fear windowclass has the control.
	if applyfear then
		applyfear.setVisible(t.sPrompt == "1");
	end
	-- The player prompt variants ("X has rolled with hope" with the
	-- take-a-hope button; the crit prompt "X has rolled a critical" adds
	-- the clear-a-stress button beside it). The card broadcasts to the
	-- whole table, so the buttons gate themselves — only the GM and the
	-- owner of the rolling character get them. Only the hope windowclass
	-- has the controls.
	if applyhope or applystress then
		local nodeChar = DB.findNode(t.sActorNode or "");
		local bCanApply = Session.IsHost or ((nodeChar ~= nil) and DB.isOwner(nodeChar));
		if applyhope then
			applyhope.setVisible((t.sPrompt == "1") and bCanApply);
		end
		if applystress then
			applystress.setVisible((t.sPromptStress == "1") and bCanApply);
		end
	end
	renderSentence();
end

-- The card-update OOB's entry point (ChatCardsManager.handleCardUpdateOOB):
-- the hope prompt's button re-points every copy of the card — the
-- presser's own included — so the whole table sees the prompt resolve.
function updateCard(t)
	setData(t);
end

-- Adjacent same-kind merging (offered by ChatCardsManager.addCard to the
-- list's last card only, so anything in between breaks the run): a
-- following resource card with the same name, verb and resource folds its
-- amount into this one — "gained 1 fear" twice reads "gained 2 fear".
-- Prompts never merge, in either direction: each carries its own button.
function absorbCard(sClass, tData)
	if (sClass ~= getClass()) or not _tData then
		return false;
	end
	if (tData.sPrompt == "1") or (_tData.sPrompt == "1")
			or (tData.sPromptStress == "1") or (_tData.sPromptStress == "1") then
		return false;
	end
	if (tData.sName ~= _tData.sName) or (tData.sVerb ~= _tData.sVerb)
			or (tData.sResource ~= _tData.sResource) then
		return false;
	end

	_tData.sAmount = tostring((tonumber(_tData.sAmount) or 0) + (tonumber(tData.sAmount) or 0));
	_nRenderedWidth = nil;
	renderSentence();
	return true;
end

-- The prompt card's button (the card is GM-only, so this runs on the
-- host): bank the fear point — capped like the ruleset's auto-gain, see
-- manager_action_attack.lua — and turn this card into the gained notice,
-- in place.
function onFearApply()
	local nFear = DB.getValue("fear.value", 0);
	local nCap = tonumber(OptionsManager.getOption("HR_FEARCAP")) or 0;
	if (nCap ~= 0) and ((nFear + 1) > nCap) then
		setData({ sName = "The GM", sVerb = "reached", sResource = "the fear cap" });
		return;
	end
	DB.setValue("fear.value", "number", nFear + 1);
	setData({ sName = "The GM", sVerb = "gained", sAmount = "1", sResource = "fear" });
end

-- Resolve one pressed prompt button into tNotice ({ sVerb, sAmount,
-- sResource }). The single-button hope prompt turns into its notice in
-- place, like the fear prompt. The crit prompt can't — it carries two
-- independent buttons and its sentence ("X has rolled a critical") must
-- survive the first press — so its outcome goes out as a standalone
-- notice card (sCardType picks the art: hope card or the neutral stress
-- one) and the update only retires the pressed button, keeping the other
-- one live on every copy.
local function resolvePrompt(sFlag, sCardType, tNotice)
	local bSecret = (_tData.sSecret == "1");
	if _tData.sCrit == "1" then
		ChatCardsManager.sendCardOOB({
			sCardType = sCardType,
			sName = _tData.sName or "",
			sActorNode = _tData.sActorNode or "",
			sVerb = tNotice.sVerb,
			sAmount = tNotice.sAmount or "",
			sResource = tNotice.sResource,
		}, bSecret);
		-- The update re-sends the card's own fields (never the raw _tData,
		-- which carries the OOB's type field and would reroute the update)
		-- with the pressed button's flag cleared.
		local tUpdate = {
			sCardId = _tData.sCardId or "",
			sName = _tData.sName or "",
			sActorNode = _tData.sActorNode or "",
			sVerb = _tData.sVerb or "",
			sAmount = _tData.sAmount or "",
			sResource = _tData.sResource or "",
			sPrompt = _tData.sPrompt or "",
			sPromptStress = _tData.sPromptStress or "",
			sCrit = _tData.sCrit or "",
			sSecret = _tData.sSecret or "",
		};
		tUpdate[sFlag] = "";
		ChatCardsManager.sendCardUpdateOOB(tUpdate, bSecret);
	else
		ChatCardsManager.sendCardUpdateOOB({
			sCardId = _tData.sCardId or "",
			sName = _tData.sName or "",
			sActorNode = _tData.sActorNode or "",
			sVerb = tNotice.sVerb,
			sAmount = tNotice.sAmount or "",
			sResource = tNotice.sResource,
		}, bSecret);
	end
end

-- The hope prompt's take-a-hope button (only the GM and the rolling
-- player hold one, and both may write the character's pool — the owner
-- owns the node, the host owns everything): bank the hope point — capped
-- by the character's own maximum, like the ruleset's auto-gain
-- (manager_action_attack.lua) — and resolve the press on every copy of
-- the card through the card-update OOB. The write is direct, not through
-- the sheet tracker, so the stepResourceAdjustment wrap doesn't card the
-- gain a second time.
function onHopeApply()
	local nodeChar = DB.findNode(_tData.sActorNode or "");
	if not nodeChar then
		return;
	end
	local tNotice;
	local nHope = DB.getValue(nodeChar, "hope.value", 0);
	if (nHope + 1) > DB.getValue(nodeChar, "hope.total", 0) then
		tNotice = { sVerb = "reached", sResource = "the hope cap" };
	else
		DB.setValue(nodeChar, "hope.value", "number", nHope + 1);
		tNotice = { sVerb = "gained", sAmount = "1", sResource = "hope" };
	end
	resolvePrompt("sPrompt", "hope", tNotice);
end

-- The crit prompt's clear-a-stress button, same treatment. Stress wounds
-- count UP as they are marked, so clearing one steps the pool down,
-- floored at zero — a press with nothing marked reports "has no stress
-- to clear" instead. The notice rides the stress card type (the neutral
-- system art the tracker's own stress cards use).
function onStressApply()
	local nodeChar = DB.findNode(_tData.sActorNode or "");
	if not nodeChar then
		return;
	end
	local tNotice;
	local nStress = DB.getValue(nodeChar, "stress.wounds", 0);
	if nStress <= 0 then
		tNotice = { sVerb = "no", sResource = "stress to clear" };
	else
		DB.setValue(nodeChar, "stress.wounds", "number", nStress - 1);
		tNotice = { sVerb = "cleared", sAmount = "1", sResource = "stress" };
	end
	resolvePrompt("sPromptStress", "stress", tNotice);
end

-- Draw (or redraw) the sentence at the card's current width; re-entrant by
-- design, like the effect card (the sentence control calls this from its
-- layout events, and the width memo stops the bounce).
function renderSentence()
	if not _tData then
		return;
	end
	local nWidth = getSentenceWidth();
	if nWidth == _nRenderedWidth then
		return;
	end
	_nRenderedWidth = nWidth;

	local nHeight = ChatCardsManager.setRichText(sentence, getSentenceSegments(), nWidth, LINE_HEIGHT);
	sentence.setAnchoredHeight(nHeight);
end

function getSentenceWidth()
	local nWidth = sentence.getSize();
	if (nWidth or 0) > 0 then
		return nWidth;
	end
	-- Windowclass script: the window's own methods are globals here.
	local nCardWidth = getSize();
	if (nCardWidth or 0) > (2 * INSET) then
		return nCardWidth - (2 * INSET);
	end
	return FALLBACK_WIDTH;
end

-- "**Adolfoss** has gained **2 hope**" / "**The GM** has spent **1 fear**"
-- / the prompt "**Adolfoss** has rolled with **fear**" (sVerb "rolled
-- with", no amount). The GM's fear pool has no actor node, so that name
-- simply stays plain. Light text follows the windowclass (the fear card's
-- dark art), not the data — the prompt's button re-sets the data but the
-- card keeps its background.
function getSentenceSegments()
	local bLight = (getClass() == "chatcard_fear");
	local sBody = bLight and "cc_body_light" or "cc_body";
	local sBold = bLight and "cc_bodybold_light" or "cc_bodybold";

	local tName = { sText = _tData.sName or "", sFont = sBold };
	if bLight then
		tName.sColor = LIGHT_TEXT_COLOR;
	end
	ChatCardsManager.applyActorLink(tName, _tData.sActorNode or "");

	return {
		tName,
		{ sText = "has " .. (_tData.sVerb or "gained"), sFont = sBody },
		{
			sText = StringManager.trim((_tData.sAmount or "") .. " " .. (_tData.sResource or "")),
			sFont = sBold,
		},
	};
end
