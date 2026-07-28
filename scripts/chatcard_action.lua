--
-- ChatCards: action card window (attack / damage / generic roll).
-- All values arrive as strings (OOB payloads are stringified in transit).
--

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
end
