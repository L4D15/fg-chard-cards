--
-- ChatCards: power-use / spell-cast card. The sentence puts the actor and the
-- power name in bold, so it is drawn as text widgets (see
-- ChatCardsManager.setRichText and chatcard_effect.lua, this card's sibling).
--

local FONT_TEXT = "cc_body";
local FONT_BOLD = "cc_bodybold";
local LINE_HEIGHT = 18;
-- The sentence control's left/right anchors (width derivation, see
-- chatcard_effect.lua for why the fallbacks exist).
local INSET = 17;
local FALLBACK_WIDTH = 300;

-- Action-button row geometry
local BUTTON_SIZE = 22;
local BUTTON_GAP = 6;

local _tData = nil;
local _nRenderedWidth = nil;
local _tActions = {};
local _sDesc = "";
local _bExpanded = false;

-- No weak tables in FG's sandbox: the manager's link state is released by
-- hand when the card closes.
function onClose()
	ChatCardsManager.releaseControlState(sentence);
end

function setData(t)
	_tData = t;

	local sType = t.sTypeLabel or "";
	typeline.setValue(sType);
	if sType == "" then
		typeline.setAnchoredHeight(0);
	end

	_sDesc = t.sDesc or "";
	if _sDesc == "" then
		-- Never expandable, so pinning the heights is safe here.
		desctoggle.setAnchoredHeight(0);
		desc.setAnchoredHeight(0);
	end
	updateDescription();

	buildActionBar(t.sPowerNode or "");
	renderSentence();
end

-- ===== Foldable description =====
-- Collapsed by default: spell texts run long, and the card announces the
-- use — the details are one click away. NOTE: the body's height is driven
-- purely by setValue autosizing (empty string when folded), never by
-- setAnchoredHeight, which would stick and keep the fold from reopening.

function hasDescription()
	return _sDesc ~= "";
end

function toggleDescription()
	if _sDesc == "" then
		return;
	end
	_bExpanded = not _bExpanded;
	updateDescription();
end

function updateDescription()
	if _sDesc == "" then
		desctoggle.setValue("");
		desc.setValue("");
		return;
	end
	desctoggle.setValue(_bExpanded and "Hide description" or "Show description");
	desc.setValue(_bExpanded and _sDesc or "");
end

-- The same buttons as the power's row on the Actions tab, one per action
-- node, through the same PowerActionManagerCore handlers the sheet uses.
-- The bar only appears where the power node is readable and the local user
-- may act for it: the caster's own client and the GM. Other clients get the
-- path but cannot resolve (or don't own) the node, and the bar collapses.
function buildActionBar(sPowerNode)
	_tActions = {};
	local nodePower = (sPowerNode ~= "") and DB.findNode(sPowerNode) or nil;
	if nodePower and (Session.IsHost or DB.isOwner(nodePower)) then
		for _, nodeAction in ipairs(UtilityManager.getNodeSortedChildren(nodePower, "actions")) do
			local sIcon = PowerActionManagerCore.getActionButtonIcons(nodeAction, nil);
			if (sIcon or "") ~= "" then
				table.insert(_tActions, {
					nodeAction = nodeAction,
					sTooltip = PowerActionManagerCore.getActionTooltip(nodeAction, nil),
				});
				actionbar.addBitmapWidget({
					icon = sIcon,
					position = "topleft",
					x = (#_tActions - 1) * (BUTTON_SIZE + BUTTON_GAP) + (BUTTON_SIZE / 2),
					y = BUTTON_SIZE / 2,
					w = BUTTON_SIZE, h = BUTTON_SIZE,
				});
			end
		end
	end
	actionbar.setAnchoredHeight((#_tActions > 0) and (BUTTON_SIZE + 2) or 0);
	-- Section header, only when there are buttons under it.
	actionsheader.setValue((#_tActions > 0) and "Actions" or "");
	actionsheader.setAnchoredHeight((#_tActions > 0) and 15 or 0);
end

-- Which button a bar-local point lands on, or nil (between or past them).
function getActionIndexAt(x, y)
	if (y < 0) or (y > BUTTON_SIZE) then
		return nil;
	end
	local nIndex = math.floor(x / (BUTTON_SIZE + BUTTON_GAP)) + 1;
	if (nIndex < 1) or (nIndex > #_tActions) then
		return nil;
	end
	if (x - ((nIndex - 1) * (BUTTON_SIZE + BUTTON_GAP))) > BUTTON_SIZE then
		return nil;
	end
	return nIndex;
end

function onActionClick(nButton, x, y)
	if nButton ~= 1 then
		return;
	end
	local nIndex = getActionIndexAt(x, y);
	if not nIndex then
		return;
	end
	PowerActionManagerCore.performAction(nil, _tActions[nIndex].nodeAction, nil);
	return true;
end

function onActionHover(x, y)
	local nIndex = getActionIndexAt(x, y);
	actionbar.setTooltipText(nIndex and _tActions[nIndex].sTooltip or "");
end

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

-- "**Elara Brightwood** casts **Mage Armor**." — the verb arrives in the
-- data ("casts" from a cast action, "uses" from the use button). The actor
-- links to their sheet and the power name to its record (a power link
-- wherever the node resolves: the caster's client, the GM, loaded library
-- records); link handling lives in the manager.
function getSentenceSegments()
	local tActor = ChatCardsManager.applyActorLink(
		{ sText = _tData.sName or "", sFont = FONT_BOLD }, _tData.sActorNode);
	local tPower = { sText = (_tData.sPower or "") .. ".", sFont = FONT_BOLD };
	local sPowerNode = _tData.sPowerNode or "";
	if (sPowerNode ~= "") and DB.findNode(sPowerNode) then
		tPower.sLinkClass = "power";
		tPower.sLinkPath = sPowerNode;
	end
	return {
		tActor,
		{ sText = _tData.sVerb or "uses", sFont = FONT_TEXT },
		tPower,
	};
end
