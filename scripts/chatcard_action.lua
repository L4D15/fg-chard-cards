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

	line1.setValue(t.sLine1 or "");
	line2.setValue(t.sLine2 or "");

	formula.setValue(t.sFormula or "");
	total.setValue(t.sTotal or "");

	local sOutcome = t.sOutcome or "";
	outcome.setValue(sOutcome);
	if sOutcome == "Success" or sOutcome == "Critical!" then
		outcome.setFont("cc_success");
	elseif sOutcome == "Failure" or sOutcome == "Fumble" then
		outcome.setFont("cc_failure");
	else
		outcome.setFont("cc_subtitle");
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

	-- 20 formula strip + 2 gap + dice rows + 30 total + 16 outcome + 4 pad
	local nBoxHeight = 72 + nDiceHeight;
	resultbox.setAnchoredHeight(nBoxHeight);

	-- Fixed extent of the left column (namebar 26 + 2 + subtitle 18 + 4 +
	-- line1 19 + 2 + line2 19 + 6 + chips 20 + sizer 12) — keep in sync
	-- with the windowclass anchors.
	local LEFT_COLUMN_HEIGHT = 128;
	-- The box needs at least the header above it (namebar 26 + 6 gap).
	local nCardHeight = math.max(LEFT_COLUMN_HEIGHT, 32 + nBoxHeight);
	boxpusher.setAnchoredHeight(nCardHeight - nBoxHeight);
end

-- Render individual die results ("d20:15;gd20:15;d6:3:x", ':x' = dropped)
-- as rows of engine dice icons with the rolled number on top. Dropped
-- dice are dimmed the same way native chat dims them. Returns the height
-- used, with glyphs wrapping into as many rows as needed.
function setDiceResults(sDice)
	local tDice = {};
	for sEntry in string.gmatch(sDice, "[^;]+") do
		local sType, sResult, sDropped = sEntry:match("^([^:]+):(%-?%d+):?(x?)$");
		if sType then
			table.insert(tDice, {
				sType = sType,
				sResult = sResult,
				bDropped = (sDropped == "x"),
			});
		end
	end

	local nCount = #tDice;
	if nCount == 0 then
		diceresults.setAnchoredHeight(0);
		return 0;
	end

	local nRows = math.ceil(nCount / PER_ROW);
	local nHeight = nRows * (GLYPH + GAP);
	diceresults.setAnchoredHeight(nHeight);

	local nAreaWidth = 110 - 8;
	for i, tDie in ipairs(tDice) do
		local nRow = math.floor((i - 1) / PER_ROW);
		local nCol = (i - 1) % PER_ROW;
		local nInRow = math.min(nCount - (nRow * PER_ROW), PER_ROW);
		local nRowWidth = (nInRow * GLYPH) + ((nInRow - 1) * GAP);
		local x = math.floor((nAreaWidth - nRowWidth) / 2) + (nCol * (GLYPH + GAP)) + (GLYPH / 2);
		local y = (nRow * (GLYPH + GAP)) + (GLYPH / 2);

		local wBitmap = diceresults.addBitmapWidget({
			icon = "diceselect_desktop_" .. tDie.sType,
			position = "topleft", x = x, y = y,
			w = GLYPH, h = GLYPH,
		});
		local wText = diceresults.addTextWidget({
			font = "cc_die", text = tDie.sResult,
			position = "topleft", x = x, y = y,
		});
		if tDie.bDropped then
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
