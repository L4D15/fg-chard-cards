--
-- ChatCards: power-use / spell-cast card. The sentence puts the actor and the
-- power name in bold, so it is drawn as text widgets (see
-- ChatCardsManager.setRichText and chatcard_effect.lua, this card's sibling).
--

local FONT_TEXT = "cc_body";
local FONT_BOLD = "cc_bodybold";
local LINE_HEIGHT = 18;
-- The description sets its own, tighter leading (the body font is 14px).
local DESC_LINE_HEIGHT = 16;
-- The sentence control's left/right anchors (width derivation, see
-- chatcard_effect.lua for why the fallbacks exist).
local INSET = 17;
local FALLBACK_WIDTH = 300;

-- Action-row geometry: button on the left, the row's description next to
-- it, the roll results right-justified.
local BUTTON_SIZE = 22;
local ROW_H = 24;
local ROW_TEXT_X = BUTTON_SIZE + 8;
local RESULT_GAP = 8;
local ROW_WIDGET = "actrow";

local _tData = nil;
local _nRenderedWidth = nil;
local _tRows = {};
local _tResults = {};
local _sDesc = "";
local _bExpanded = false;

-- No weak tables in FG's sandbox: the manager's link state is released by
-- hand when the card closes (desc renders through setRichText too), and so
-- is the card-id registry entry that routes result updates here.
function onClose()
	ChatCardsManager.releaseControlState(sentence, desc);
	ChatCardsManager.unregisterCard((_tData or {}).sCardId);
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
		desctoggle.setAnchoredHeight(0);
	end
	updateDescription();

	buildActionRows(t.sPowerNode or "");
	renderSentence();
end

-- ===== Foldable description =====
-- Collapsed by default: spell texts run long, and the card announces the
-- use — the details are one click away. The body is rich text on a generic
-- control (one plain segment; setRichText honours its line breaks), so both
-- states set an exact height — string-control autosizing kept a one-line
-- height for the empty folded value.

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
		return;
	end
	desctoggle.setValue(_bExpanded and "Hide description" or "Show description");
	renderDescription();
end

function renderDescription()
	if not _bExpanded or (_sDesc == "") then
		ChatCardsManager.clearRichText(desc);
		desc.setAnchoredHeight(0);
		return;
	end
	-- 4px top pad: breathing room under the toggle line, rendered into the
	-- control so the folded state stays exactly 0.
	local nHeight = ChatCardsManager.setRichText(desc,
		{ { sText = _sDesc, sFont = FONT_TEXT } }, getSentenceWidth(), DESC_LINE_HEIGHT, 4);
	desc.setAnchoredHeight(nHeight);
end

-- One row per rollable piece of the power, through the same
-- PowerActionManagerCore handlers the sheet uses. A cast action is compound
-- (the sheet's full Actions view splits it the same way), so it contributes
-- an Attack and/or a Save row rather than a full-cast button — the card
-- itself is the cast announcement. The rows only appear where the power
-- node is readable and the local user may act for it: the caster's own
-- client and the GM. Other clients get the path but cannot resolve (or
-- don't own) the node, and the list collapses.
function buildActionRows(sPowerNode)
	_tRows = {};
	local nodePower = (sPowerNode ~= "") and DB.findNode(sPowerNode) or nil;
	if nodePower and (Session.IsHost or DB.isOwner(nodePower)) then
		for _, nodeAction in ipairs(UtilityManager.getNodeSortedChildren(nodePower, "actions")) do
			local sType = DB.getValue(nodeAction, "type", "");
			if sType == "cast" then
				addActionRow(nodeAction, "atk", "Attack");
				addActionRow(nodeAction, "save", "Save");
			elseif sType == "damage" then
				addActionRow(nodeAction, nil, "Damage");
			elseif sType == "heal" then
				addActionRow(nodeAction, nil, "Heal");
			elseif sType == "effect" then
				addActionRow(nodeAction, nil, "Effect");
			elseif sType ~= "" then
				-- Types from other extensions keep their single row.
				addActionRow(nodeAction, nil, StringManager.capitalize(sType));
			end
		end
	end
	actionbar.setAnchoredHeight((#_tRows > 0) and (#_tRows * ROW_H + 2) or 0);
	-- Section header, only when there are rows under it.
	actionsheader.setValue((#_tRows > 0) and "Actions" or "");
	actionsheader.setAnchoredHeight((#_tRows > 0) and 15 or 0);
	renderActionRows();
end

-- A cast sub-roll the action does not define has no text (a save-only spell
-- has no attack half, and vice versa) and gets no row.
function addActionRow(nodeAction, sSubRoll, sLabel)
	local tData = sSubRoll and { sSubRoll = sSubRoll } or nil;
	local sIcon = PowerActionManagerCore.getActionButtonIcons(nodeAction, tData);
	if (sIcon or "") == "" then
		return;
	end
	local sDetail = PowerActionManagerCore.getActionText(nodeAction, tData) or "";
	if sSubRoll and (sDetail == "") then
		return;
	end
	table.insert(_tRows, {
		nodeAction = nodeAction,
		sSubRoll = sSubRoll,
		-- Row key for result routing: every client derives the same key
		-- from the same action node, so results address rows by it.
		sKey = DB.getName(nodeAction) .. (sSubRoll and ("." .. sSubRoll) or ""),
		sIcon = sIcon,
		sLabel = sLabel,
		sDetail = sDetail,
		sTooltip = PowerActionManagerCore.getActionTooltip(nodeAction, tData),
	});
end

-- ===== Row rendering =====
-- The rows are widgets on one control (cards are not database-bound windows,
-- so the sheet's action list cannot be reused here) and are rebuilt
-- wholesale whenever a result arrives.

local _tResultColors = nil;

function renderActionRows()
	-- Drop the previous pass; widgets are named consecutively (there is no
	-- "destroy every widget" call).
	local nOld = 1;
	while actionbar.findWidget(ROW_WIDGET .. nOld) do
		actionbar.findWidget(ROW_WIDGET .. nOld).destroy();
		nOld = nOld + 1;
	end
	if #_tRows == 0 then
		return;
	end

	_tResultColors = _tResultColors or {
		positive = ChatCardsManager.COLOR_POSITIVE,
		negative = ChatCardsManager.COLOR_NEGATIVE,
	};

	local nWidth = getRowsWidth();
	local nWidgets = 0;
	local function nextName()
		nWidgets = nWidgets + 1;
		return ROW_WIDGET .. nWidgets;
	end

	for nRow, tRow in ipairs(_tRows) do
		local yMid = ((nRow - 1) * ROW_H) + (ROW_H / 2);

		actionbar.addBitmapWidget({
			name = nextName(),
			icon = tRow.sIcon,
			position = "topleft",
			x = BUTTON_SIZE / 2, y = yMid,
			w = BUTTON_SIZE, h = BUTTON_SIZE,
		});

		-- Results first: their width decides how much room the description
		-- has. Entries are middot-separated, each in its outcome colour.
		local nResultX = nWidth;
		local tEntries = (_tResults[tRow.sKey] or {}).tEntries or {};
		if #tEntries > 0 then
			local tPieces = {};
			local nTotalW = 0;
			for i, tEntry in ipairs(tEntries) do
				if i > 1 then
					local wSep = actionbar.addTextWidget({
						name = nextName(), font = "cc_body",
						text = " \194\183 ", position = "topleft", x = 0, y = yMid,
					});
					table.insert(tPieces, { w = wSep, nW = wSep and (wSep.getSize() or 0) or 0 });
					nTotalW = nTotalW + tPieces[#tPieces].nW;
				end
				local wEntry = actionbar.addTextWidget({
					name = nextName(), font = "cc_body",
					text = tEntry.sText or "", position = "topleft", x = 0, y = yMid,
				});
				if wEntry and _tResultColors[tEntry.sStyle or ""] then
					wEntry.setColor(_tResultColors[tEntry.sStyle]);
				end
				table.insert(tPieces, { w = wEntry, nW = wEntry and (wEntry.getSize() or 0) or 0 });
				nTotalW = nTotalW + tPieces[#tPieces].nW;
			end
			-- Right-justified: lay the pieces out ending at the row's edge.
			local nX = math.max(nWidth - nTotalW, ROW_TEXT_X);
			nResultX = nX;
			for _, tPiece in ipairs(tPieces) do
				if tPiece.w then
					tPiece.w.setPosition("topleft", nX + math.floor(tPiece.nW / 2), yMid);
				end
				nX = nX + tPiece.nW;
			end
		end

		-- Bold label, then the action's own text, truncated to the room the
		-- results leave.
		local nMaxText = nResultX - RESULT_GAP - ROW_TEXT_X;
		local nX = ROW_TEXT_X;
		local wLabel = actionbar.addTextWidget({
			name = nextName(), font = "cc_bodybold",
			text = tRow.sLabel, position = "topleft", x = 0, y = yMid,
		});
		if wLabel then
			local nLabelW = fitTextWidget(wLabel, tRow.sLabel, nMaxText);
			wLabel.setPosition("topleft", nX + math.floor(nLabelW / 2), yMid);
			nX = nX + nLabelW + 4;
		end
		if (tRow.sDetail ~= "") and ((nResultX - RESULT_GAP - nX) > 12) then
			local wDetail = actionbar.addTextWidget({
				name = nextName(), font = "cc_body",
				text = tRow.sDetail, position = "topleft", x = 0, y = yMid,
			});
			if wDetail then
				local nDetailW = fitTextWidget(wDetail, tRow.sDetail, nResultX - RESULT_GAP - nX);
				wDetail.setPosition("topleft", nX + math.floor(nDetailW / 2), yMid);
			end
		end
	end
end

-- Shrink a text widget's text to nMax pixels with a trailing ellipsis;
-- returns the width actually used. Bytes of a partial UTF-8 sequence are
-- dropped together so a cut never splits a character.
function fitTextWidget(wgt, sText, nMax)
	local nW = wgt.getSize() or 0;
	while (nW > nMax) and (#sText > 1) do
		repeat
			sText = sText:sub(1, -2);
		until (#sText == 0) or (sText:byte(-1) < 0x80) or (sText:byte(-1) >= 0xC0);
		if sText:byte(-1) and (sText:byte(-1) >= 0xC0) then
			sText = sText:sub(1, -2);
		end
		wgt.setText(sText .. "...");
		nW = wgt.getSize() or 0;
	end
	return nW;
end

function getRowsWidth()
	local nWidth = actionbar.getSize();
	if (nWidth or 0) > 0 then
		return nWidth;
	end
	return getSentenceWidth();
end

-- ===== Row actions and results =====

-- Which row's button a control-local point lands on, or nil (the text and
-- result parts of a row are not clickable).
function getActionIndexAt(x, y)
	if (x < 0) or (x > BUTTON_SIZE) then
		return nil;
	end
	local nIndex = math.floor(y / ROW_H) + 1;
	if (nIndex < 1) or (nIndex > #_tRows) then
		return nil;
	end
	local nPad = (ROW_H - BUTTON_SIZE) / 2;
	local yIn = y - ((nIndex - 1) * ROW_H);
	if (yIn < nPad) or (yIn > (ROW_H - nPad)) then
		return nil;
	end
	return nIndex;
end

-- Perform a row's action, marked so its rolls report back into this card.
-- draginfo is nil for a click; on a drag the (already stamped) rolls are
-- encoded into it at drag start and resolve wherever the drop lands, so a
-- cancelled drag simply never reports.
function performRowAction(tRow, draginfo)
	local tActionData = tRow.sSubRoll and { sSubRoll = tRow.sSubRoll } or nil;

	local sCardId = (_tData or {}).sCardId or "";
	if sCardId == "" then
		-- Cards from before result support (or without an id) still roll.
		PowerActionManagerCore.performAction(draginfo, tRow.nodeAction, tActionData);
		return;
	end

	-- One press = one volley: every roll it triggers reports back under
	-- this id, and the next press starts the row over.
	local sVolley = ChatCardsManager.nextVolleyId();
	local bSecret = ((_tData or {}).sSecret == "1");
	ChatCardsManager.performMarkedAction(sCardId, tRow.sKey, sVolley, bSecret, function()
		PowerActionManagerCore.performAction(draginfo, tRow.nodeAction, tActionData);
	end);
end

function onActionClick(nButton, x, y)
	if nButton ~= 1 then
		return;
	end
	local nIndex = getActionIndexAt(x, y);
	if not nIndex then
		return;
	end
	performRowAction(_tRows[nIndex], nil);
	return true;
end

-- Same action as the click, carried by a drag: like the sheet's buttons,
-- the drop decides the targets (a token to attack, the chat to roll plain).
function onActionDrag(nButton, x, y, draginfo)
	local nIndex = getActionIndexAt(x, y);
	if not nIndex then
		return;
	end
	performRowAction(_tRows[nIndex], draginfo);
	return true;
end

function onActionHover(x, y)
	local nIndex = getActionIndexAt(x, y);
	actionbar.setTooltipText(nIndex and _tRows[nIndex].sTooltip or "");
end

-- A result entry from the manager (an OOB sent by whichever client resolved
-- the roll — target saves resolve on the target's side). Entries of the
-- current volley aggregate; a new volley replaces them.
function applyActionResult(sKey, sVolley, sMode, sText, sStyle)
	local tRowResults = _tResults[sKey];
	if (not tRowResults) or (tRowResults.sVolley ~= sVolley) then
		tRowResults = { sVolley = sVolley, tEntries = {} };
		_tResults[sKey] = tRowResults;
	end
	local tEntry = { sText = sText or "", sStyle = sStyle or "" };
	if sMode == "set" then
		tRowResults.tEntries = { tEntry };
	else
		table.insert(tRowResults.tEntries, tEntry);
	end
	renderActionRows();
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
	-- The description wraps at the same width, so it re-renders with the
	-- sentence (the toggle path re-renders it directly).
	renderDescription();
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
