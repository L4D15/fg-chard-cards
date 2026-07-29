--
-- ChatCards: action card window (attack / damage / generic roll).
-- All values arrive as strings (OOB payloads are stringified in transit).
--

local GLYPH = 22;    -- die glyph size
local GAP = 2;       -- spacing between glyphs
local PER_ROW = 4;   -- glyphs per row inside the 110px result box

function setData(t)
	name.setValue(t.sName or "");
	subtitle.setValue(t.sSub or "");
	title.setValue(t.sTitle or "");
	ChatCardsManager.setCardPortrait(porticon, tokenview, t);

	-- Empty body lines collapse so they don't inflate the card height;
	-- the card then hugs whichever column is actually taller.
	setBodyLine(line1, t.sLine1 or "");
	setBodyLine(line2, t.sLine2 or "");

	total.setValue(t.sTotal or "");

	local sOutcome = t.sOutcome or "";
	outcome.setValue(sOutcome);
	outcome.setAnchoredHeight((sOutcome ~= "") and 16 or 0);
	if sOutcome == "Success" or sOutcome == "Critical!" then
		outcome.setFont("cc_success");
	elseif sOutcome == "Failure" or sOutcome == "Fumble" then
		outcome.setFont("cc_failure");
	else
		outcome.setFont("cc_outcome");
	end

	local sType = t.sCardType or "roll";
	if sType == "attack" then
		chip1.setText("Attack", true);
	elseif sType == "damage" then
		chip1.setText("Damage", true);
	else
		chip1.setText(t.sChip1 or "", true);
	end
	chip2.setText(t.sChip2 or "", false);
	chip3.setText(t.sChip3 or "", false);

	local nDiceHeight = setDiceResults(t.sDice or "");

	-- Result-area content: 2 pad + roll-type label 18 + 2 + dice rows +
	-- 30 total + outcome line when there is one.
	local nBoxContent = 2 + 18 + 2 + nDiceHeight + 30;
	if sOutcome ~= "" then
		nBoxContent = nBoxContent + 16;
	end

	-- Window height each column needs, mirroring the windowclass anchors.
	-- INSET is the card art's shadow border, which all content sits inside.
	local INSET = 5;
	local nLine1 = ((t.sLine1 or "") ~= "") and 16 or 0;
	local nLine2 = ((t.sLine2 or "") ~= "") and 16 or 0;
	local bChips = (sType == "attack") or (sType == "damage")
		or ((t.sChip1 or "") ~= "") or ((t.sChip2 or "") ~= "") or ((t.sChip3 or "") ~= "");
	-- namebar 26 + 2 + subtitle 18, + 2 + line1, + 2 + line2, + 2 + chips,
	-- + 4 bottom padding, all between the two inset borders.
	local nLeftNeeds = INSET + 46 + 2 + nLine1 + 2 + nLine2 + 2
		+ (bChips and 14 or 0) + 4 + INSET;
	local nBoxNeeds = INSET + nBoxContent + 4 + INSET;

	-- The result area spans the card's full inner height, so it stretches
	-- when the left column is taller and drives the card height otherwise.
	local nCardHeight = math.max(nLeftNeeds, nBoxNeeds);
	resultbox.setAnchoredHeight(nCardHeight - (2 * INSET));
end

-- Fill a body line ("Target: Elara (AC 13)") with two widgets: the
-- "Label:" part in bold and the value after it in the regular body font.
-- Widgets are positioned by their center, so each is measured first.
function setBodyLine(cLine, sText)
	if sText == "" then
		cLine.setAnchoredHeight(0);
		return;
	end
	cLine.setAnchoredHeight(16);

	-- Lines without a "Label:" prefix render entirely in the body font
	local sLabel, sValue = sText:match("^([^:]+:)%s*(.*)$");
	if not sLabel then
		sLabel = "";
		sValue = sText;
	end

	local nLabelWidth = 0;
	if sLabel ~= "" then
		local wLabel = cLine.addTextWidget({
			font = "cc_bodybold", text = sLabel,
			position = "topleft", y = 8,
		});
		if wLabel then
			nLabelWidth = (wLabel.getSize() or 0) + 4;
			wLabel.setPosition("topleft", math.floor((nLabelWidth - 4) / 2), 8);
		end
	end

	if sValue ~= "" then
		local wValue = cLine.addTextWidget({
			font = "cc_body", text = sValue,
			position = "topleft", y = 8,
		});
		if wValue then
			local nValueWidth = wValue.getSize() or 0;
			wValue.setPosition("topleft", nLabelWidth + math.floor(nValueWidth / 2), 8);
		end
	end
end

-- Known die shapes; anything else (custom dice) falls back to the square
local _tDieIcons = {
	d4 = "cc_die_d4", d6 = "cc_die_d6", d8 = "cc_die_d8",
	d10 = "cc_die_d10", d12 = "cc_die_d12", d20 = "cc_die_d20",
	d100 = "cc_die_d10",
};

function getDieIcon(sType)
	-- strip advantage/disadvantage color prefixes (gd20 / rd20)
	local sBase = sType:match("d%d+") or sType;
	return _tDieIcons[sBase] or "cc_die_d6";
end

-- Render individual die results ("d20:15;gd20:15;d6:3:x", ':x' = dropped)
-- as rows of black die silhouettes (native chat style) with the rolled
-- number on top. The roll modifier is not shown here — the card's
-- modifier list itemizes it in more detail. Dropped dice are dimmed the
-- same way native chat dims them. Returns the height used, wrapping into
-- as many rows as needed.
function setDiceResults(sDice)
	local tItems = {};
	for sEntry in string.gmatch(sDice, "[^;]+") do
		local sType, sResult, sDropped = sEntry:match("^([^:]+):(%-?%d+):?(x?)$");
		if sType then
			table.insert(tItems, {
				sType = sType,
				sResult = sResult,
				bDropped = (sDropped == "x"),
			});
		end
	end

	local nCount = #tItems;
	if nCount == 0 then
		diceresults.setAnchoredHeight(0);
		return 0;
	end

	local nRows = math.ceil(nCount / PER_ROW);
	local nHeight = nRows * (GLYPH + GAP);
	diceresults.setAnchoredHeight(nHeight);

	local nAreaWidth = 110 - 8;
	for i, tItem in ipairs(tItems) do
		local nRow = math.floor((i - 1) / PER_ROW);
		local nCol = (i - 1) % PER_ROW;
		local nInRow = math.min(nCount - (nRow * PER_ROW), PER_ROW);
		local nRowWidth = (nInRow * GLYPH) + ((nInRow - 1) * GAP);
		local x = math.floor((nAreaWidth - nRowWidth) / 2) + (nCol * (GLYPH + GAP)) + (GLYPH / 2);
		local y = (nRow * (GLYPH + GAP)) + (GLYPH / 2);

		local wBitmap = diceresults.addBitmapWidget({
			icon = getDieIcon(tItem.sType),
			position = "topleft", x = x, y = y,
			w = GLYPH, h = GLYPH,
		});
		local wText = diceresults.addTextWidget({
			font = "cc_die", text = tItem.sResult,
			position = "topleft", x = x, y = y,
		});
		if tItem.bDropped then
			if wBitmap then
				wBitmap.setColor("80FFFFFF");
			end
			if wText then
				wText.setColor("80FFFFFF");
			end
		end
	end
	return nHeight;
end
