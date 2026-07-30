--
-- ChatCards: effect-applied card. The sentence names the source, the effect
-- and the target in bold, so it is drawn as text widgets rather than set on a
-- string control (see ChatCardsManager.setRichText).
--

local FONT_TEXT = "cc_body";
local FONT_BOLD = "cc_bodybold";
local LINE_HEIGHT = 18;
-- The sentence control's left/right anchors, used to derive its width from the
-- card's when the control cannot report its own yet.
local INSET = 17;
-- Only reached if neither the control nor the card knows its width yet (i.e.
-- before the first layout): enough for the sentence to wrap sensibly on the
-- default chat panel, and corrected by the first onFirstLayout/resize.
local FALLBACK_WIDTH = 300;

local _tData = nil;
local _nRenderedWidth = nil;

function setData(t)
	_tData = t;

	local sLogic = t.sLogic or "";
	logic.setValue(sLogic);
	if sLogic == "" then
		logic.setAnchoredHeight(0);
	end

	renderSentence();
end

-- Draw (or redraw) the sentence at the card's current width. Re-entrant by
-- design: the sentence control calls this from its layout events, and the
-- width check keeps the height change made here from bouncing back as another
-- render.
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
	-- This is a windowclass script, so the window's own methods are globals
	-- here ("window" only exists in control scripts).
	local nCardWidth = getSize();
	if (nCardWidth or 0) > (2 * INSET) then
		return nCardWidth - (2 * INSET);
	end
	return FALLBACK_WIDTH;
end

-- "**Wololo** has applied effect **LIGHT** to **Elara Brightwood**.", or when
-- the effect has no separate source (none at all, or the target did it to
-- themselves): "**Elara Brightwood** gains the effect **LIGHT**."
-- The full stop rides on the last bold segment so it can never wrap onto a
-- line of its own.
function getSentenceSegments()
	local sName = _tData.sName or "";
	local sSource = _tData.sSource or "";
	local sTarget = _tData.sTarget or "";
	if (sSource ~= "") and (sSource ~= sTarget) then
		return {
			{ sText = sSource, sFont = FONT_BOLD },
			{ sText = "has applied effect", sFont = FONT_TEXT },
			{ sText = sName, sFont = FONT_BOLD },
			{ sText = "to", sFont = FONT_TEXT },
			{ sText = sTarget .. ".", sFont = FONT_BOLD },
		};
	end
	return {
		{ sText = sTarget, sFont = FONT_BOLD },
		{ sText = "gains the effect", sFont = FONT_TEXT },
		{ sText = sName .. ".", sFont = FONT_BOLD },
	};
end
