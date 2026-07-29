--
-- ChatCards: action card window (attack / damage / generic roll).
-- All values arrive as strings (OOB payloads are stringified in transit).
--

local GLYPH = 22;    -- die glyph size
local GAP = 2;       -- spacing between glyphs
local PER_ROW = 4;   -- glyphs per row inside the 110px result box

-- The die art is white so it can be tinted here; without a tint it would be
-- invisible on the card. Normal dice take the neutral tag pill's colour, so the
-- two read as one family; the mockup's understated grey was #C0C0C0.
local DIE_COLOR = "FFD8D2BD";
-- Dropped by advantage/disadvantage: dimmed the way native chat dims it.
local DIE_COLOR_DROPPED = "80D8D2BD";
local DIE_LABEL_DROPPED = "80FFFFFF";

function setData(t)
	name.setValue(t.sName or "");
	subtitle.setValue(t.sSub or "");
	title.setValue(t.sTitle or "");
	ChatCardsManager.setCardPortrait(porticon, tokenview, portraitframe, t);

	-- Empty body lines collapse so they don't inflate the card height;
	-- the card then hugs whichever column is actually taller.
	setBodyLine(line1, t.sLine1 or "");
	local bMods = setModifierLine(line2, t.sMods or "");
	if not bMods then
		setBodyLine(line2, t.sLine2 or "");
	end

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

	local bChips = setTags(t.sTags or "");

	local nDiceHeight = setDiceResults(t.sDice or "");

	-- Result-area content: dice rows + 30 total + outcome line when there is
	-- one (its row overlaps the total's by 4px).
	local nBoxContent = nDiceHeight + 30;
	if sOutcome ~= "" then
		nBoxContent = nBoxContent + 12;
	end

	-- Window height each column needs, mirroring the windowclass anchors.
	-- INSET is the card art's shadow border, which all content sits inside.
	local INSET = 5;
	local nLine1 = ((t.sLine1 or "") ~= "") and 16 or 0;
	local nLine2 = (bMods or ((t.sLine2 or "") ~= "")) and 16 or 0;
	-- Name block stacked flush (namebar 16 + subtitle 15 + roll-type 15),
	-- then 4 + line1, + 2 + line2, + 2 + chips, + 4 bottom pad, keeping the
	-- body rows at y=55. They cannot start above y=49 anyway: they sit
	-- under the 44px avatar, which is the floor for this column.
	local nLeftNeeds = INSET + 16 + 15 + 15 + 4 + nLine1 + 2 + nLine2 + 2
		+ (bChips and 14 or 0) + 4 + INSET;
	-- 4px of padding above and below the contents when the box is at its
	-- minimum size.
	local nBoxNeeds = INSET + 4 + nBoxContent + 4 + INSET;

	-- The result area spans the card's full inner height, so it stretches
	-- when the left column is taller and drives the card height otherwise.
	local nCardHeight = math.max(nLeftNeeds, nBoxNeeds);
	local nBoxHeight = nCardHeight - (2 * INSET);
	resultbox.setAnchoredHeight(nBoxHeight);
	-- Split the box's free space evenly above and below the contents.
	boxpad.setAnchoredHeight(math.max(4, math.floor((nBoxHeight - nBoxContent) / 2)));
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

-- Fill the pill controls from the card's encoded tag list. Slots are filled
-- in order (empty ones collapse, and the row is a single line), so a
-- provider should return its most important tags first; anything past the
-- last slot is dropped. Returns whether any tag was shown.
local _tChipControls = nil;

function setTags(sTags)
	_tChipControls = _tChipControls or { chip1, chip2, chip3, chip4, chip5, chip6 };
	local tTags = ChatCardsManager.decodeTags(sTags);
	for i, cChip in ipairs(_tChipControls) do
		local tTag = tTags[i];
		if tTag then
			cChip.setText(tTag.sText, tTag.sStyle);
		else
			cChip.setText("", nil);
		end
	end
	return #tTags > 0;
end

-- Modifier row: segments encoded by the ruleset ("Crossbow, Light +3;Bless
-- +1d4:positive"), joined here with a middot. Only each segment's *value* is
-- coloured — the trailing +/- token — and only when the segment carries a
-- style, so the roll's own bonus stays plain. Returns whether anything was
-- rendered.
local _tSegmentColors = nil;

function setModifierLine(cLine, sMods)
	local tSegments = ChatCardsManager.decodeTags(sMods);
	if #tSegments == 0 then
		cLine.setAnchoredHeight(0);
		return false;
	end
	cLine.setAnchoredHeight(16);

	_tSegmentColors = _tSegmentColors or {
		positive = ChatCardsManager.COLOR_POSITIVE,
		negative = ChatCardsManager.COLOR_NEGATIVE,
	};

	-- Widgets are positioned by their centre, so each piece is measured and
	-- the pen advances by its width.
	local nX = 0;
	local function addPiece(sText, sColor)
		if (sText or "") == "" then
			return;
		end
		local wPiece = cLine.addTextWidget({ font = "cc_body", text = sText, position = "topleft", y = 8 });
		if not wPiece then
			return;
		end
		local nPieceWidth = wPiece.getSize() or 0;
		wPiece.setPosition("topleft", nX + math.floor(nPieceWidth / 2), 8);
		if sColor then
			wPiece.setColor(sColor);
		end
		nX = nX + nPieceWidth;
	end

	for i, tSegment in ipairs(tSegments) do
		if i > 1 then
			addPiece(" \194\183 ", nil);
		end
		-- The value is a signed number or dice expression, so require a digit
		-- or "d" after the sign: a hyphenated name would otherwise split.
		local sName, sValue = tSegment.sText:match("^(.-)%s*([%+%-][%dd]%w*)$");
		if sName then
			addPiece(sName .. " ", nil);
			addPiece(sValue, _tSegmentColors[tSegment.sStyle or ""]);
		else
			addPiece(tSegment.sText, nil);
		end
	end
	return true;
end

-- A die type is a leading letter plus its number of sides: "d20" normally,
-- and on an advantage or disadvantage roll ActionD20.decodeAdvantage *replaces*
-- that letter on the kept die — "g20" for advantage, "r20" for disadvantage
-- (not "gd20"; it swaps the character rather than prefixing). So both the
-- shape and the tint key off the number, and the letter only picks the colour.
function getDieSides(sType)
	return tonumber((sType or ""):match("%d+"));
end

-- Tint for a die: the kept die of an advantage/disadvantage roll carries the
-- same colour as its tag pill. Dropped dice stay dimmed.
function getDieColor(sType, bDropped)
	if bDropped then
		return DIE_COLOR_DROPPED;
	end
	local sPrefix = (sType or ""):sub(1, 1);
	if sPrefix == "g" then
		return ChatCardsManager.COLOR_POSITIVE;
	elseif sPrefix == "r" then
		return ChatCardsManager.COLOR_NEGATIVE;
	end
	return DIE_COLOR;
end

-- Known die shapes by side count; anything else (custom dice) falls back to
-- the square, and percentile dice reuse the d10 shape.
local _tDieIcons = {
	[4] = "cc_die_d4", [6] = "cc_die_d6", [8] = "cc_die_d8",
	[10] = "cc_die_d10", [12] = "cc_die_d12", [20] = "cc_die_d20",
	[100] = "cc_die_d10",
};

function getDieIcon(sType)
	return _tDieIcons[getDieSides(sType)] or "cc_die_d6";
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
		if wBitmap then
			wBitmap.setColor(getDieColor(tItem.sType, tItem.bDropped));
		end
		local wText = diceresults.addTextWidget({
			font = "cc_die", text = tItem.sResult,
			position = "topleft", x = x, y = y,
		});
		if wText and tItem.bDropped then
			wText.setColor(DIE_LABEL_DROPPED);
		end
	end
	return nHeight;
end
