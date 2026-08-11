--
-- ChatCards: CoreRPG-level hooks, active on every ruleset the extension
-- loads on. Cards for everything CoreRPG itself resolves — generic rolls,
-- table rolls, the default power use — plus the effect-origin plumbing whose
-- hook points live in CoreRPG's EffectManager. A system's adapter script
-- (chatcards_5e.lua) layers its own resolve hooks on top and claims the roll
-- types it cards itself via registerDedicatedRollTypes.
--

local _fResolveAction = nil;
local _fDefaultPowerUse = nil;
local _fEffectRollEncode = nil;
local _fEffectRollDecode = nil;
local _fEffectAddNotify = nil;

-- Roll types the active system adapter cards through a dedicated hook, so
-- the resolveAction wrap must not card them again. "table" is claimed here:
-- the capture below cards table rolls with their drawn results. Types that
-- roll no dice produce no generic card either way.
local _tDedicatedTypes = { table = true };

function registerDedicatedRollTypes(tTypes)
	for _, sType in ipairs(tTypes or {}) do
		_tDedicatedTypes[sType] = true;
	end
end

-- Windowclass the power card's title link opens — the system's power record
-- class ("power" on 5E), which CoreRPG does not define. Empty (no adapter
-- set one) leaves the title as plain text.
local _sPowerRecordClass = "";

function setPowerRecordClass(sClass)
	_sPowerRecordClass = sClass or "";
end

function getPowerRecordClass()
	return _sPowerRecordClass;
end

function onInit()
	-- Single hook point for every roll type without a dedicated card hook
	-- (basic tray dice, init, and everything an adapter did not claim):
	-- runs on the rolling client only.
	_fResolveAction = ActionsManager.resolveAction;
	ActionsManager.resolveAction = onResolveAction;

	-- Table rolls: the drawn rows the ruleset prints as follow-up chat
	-- lines move into the roll card instead (see onTableRoll).
	if TableManager and TableManager.onTableRoll then
		ActionsManager.registerResultHandler("table", onTableRoll);
	end

	-- Power-use card. The "use" button funnels through
	-- PowerManagerCore.usePower(node), which runs the ruleset's registered
	-- fnUsePower handler when there is one — real mechanics that must keep
	-- running — and falls back to performDefaultPowerUse: the power name as
	-- a text message. Only that default output is replaced by the card
	-- (see onDefaultPowerUse), so rulesets with their own use handler are
	-- untouched unless they call into the default themselves.
	if PowerManagerCore and PowerManagerCore.performDefaultPowerUse then
		_fDefaultPowerUse = PowerManagerCore.performDefaultPowerUse;
		PowerManagerCore.performDefaultPowerUse = onDefaultPowerUse;
	end

	-- Effect origin. The roll <-> effect copies use CoreRPG's official hook
	-- points, chained in case another extension registered them first. The
	-- stamp itself (rAction.sChatCardsPower, set where the power node is
	-- still in hand) is the system adapter's job — without an adapter these
	-- carry nil and the notice path stays stock.
	if EffectManager and EffectManager.setCustomOnEffectRollEncode
			and GameManager and GameManager.getFunction then
		_fEffectRollEncode = GameManager.getFunction("onEffectRollEncode");
		EffectManager.setCustomOnEffectRollEncode(onEffectRollEncode);
		_fEffectRollDecode = GameManager.getFunction("onEffectRollDecode");
		EffectManager.setCustomOnEffectRollDecode(onEffectRollDecode);

		_fEffectAddNotify = EffectManager.onEffectAddNotify;
		EffectManager.onEffectAddNotify = onEffectAddNotify;
	end
end

function onResolveAction(rSource, rTarget, rRoll)
	_fResolveAction(rSource, rTarget, rRoll);

	-- Effects apply through a diceless roll; a power card's Effect row
	-- reports from its resolution, which covers the click (resolves
	-- immediately) and a drag (resolves on drop — or never, if cancelled).
	-- "set": applying to several targets resolves once per target.
	-- Textless: a performed-only action shows just the success mark.
	if rRoll.sType == "effect" then
		ChatCardsManager.sendActionResult(rRoll, "set", "", "positive");
	end

	if _tDedicatedTypes[rRoll.sType or ""] then
		return;
	end
	if #(rRoll.aDice or {}) == 0 then
		return;
	end
	ChatCardsManager.sendGenericRollCard(rSource, rRoll);
end

--
--	POWER-USE CARDS
--

-- The default power use is just the power name as a text message; the card
-- replaces it. It carries no tag a receiving client could suppress the
-- message by, so when a card is sent the original is skipped — its message
-- would show as a duplicate notice. If the card cannot be built the
-- original runs unchanged.
function onDefaultPowerUse(node)
	local rActor = ActorManager.resolveActor(PowerManagerCore.getPowerActorNode(node));
	-- Mirror the default output's reach: NPC power use stays GM-only.
	local bSecret = not (rActor and ActorManager.isPC(rActor));
	if sendPowerCard(rActor, node, bSecret) then
		return;
	end
	_fDefaultPowerUse(node);
end

-- Broadcast a power card: who (actor + player, as on the roll cards), the
-- power's name and its description text. Also the seam a system adapter
-- cards its own power announcements through (5E's full casts).
function sendPowerCard(rActor, nodePower, bSecret)
	if not nodePower then
		return false;
	end
	local sPowerName = StringManager.trim(DB.getValue(nodePower, "name", ""));
	if sPowerName == "" then
		return false;
	end

	local tPortrait = ChatCardsManager.getActorPortrait(rActor);
	ChatCardsManager.sendCardOOB({
		sCardType = "power",
		-- Filed under this id on every client, so the action rows' results
		-- can address the card after the fact.
		sCardId = ChatCardsManager.nextCardId(),
		-- The rows' own rolls must keep the card's reach: a GM-only card's
		-- results stay GM-only.
		sSecret = bSecret and "1" or "",
		sName = ChatCardsManager.getActorName(rActor, nil),
		sActorNode = rActor and ActorManager.getCreatureNodeName(rActor) or "",
		-- The header's player line, as on the roll cards: the card is sent
		-- by the acting client.
		sSub = Session.IsHost and "Gamemaster" or (Session.UserName or ""),
		sPower = sPowerName,
		sDesc = getPowerDescription(nodePower),
		-- For the card's action rows. A path, not data: each receiving
		-- client resolves it itself, so the rows only appear where the
		-- node is readable AND owned (the caster's client, the GM).
		sPowerNode = DB.getPath(nodePower),
		sIconAsset = tPortrait.sIconAsset,
		sTokenAsset = tPortrait.sTokenAsset,
		sIsGM = (not rActor and Session.IsHost) and "1" or "",
	}, bSecret or false);
	return true;
end

-- Description text for the card. PC powers and library spells carry a
-- formattedtext "description" (an XML string when read through getValue);
-- NPC spells a plain "desc". Formatting is flattened: paragraph breaks
-- become line breaks and the remaining markup is stripped.
function getPowerDescription(nodePower)
	local s = DB.getValue(nodePower, "description", "");
	if s == "" then
		s = DB.getValue(nodePower, "desc", "");
	end
	s = s:gsub("</p>%s*<p>", "\r"):gsub("<br%s*/?>", "\r"):gsub("<[^>]->", "");
	s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\""):gsub("&#39;", "'");
	return StringManager.trim(s);
end

--
--	EFFECT ORIGIN
--

function onEffectRollEncode(rRoll, rAction)
	if _fEffectRollEncode then
		_fEffectRollEncode(rRoll, rAction);
	end
	rRoll.sChatCardsPower = rAction.sChatCardsPower;
end

function onEffectRollDecode(rRoll, rEffect)
	if _fEffectRollDecode then
		_fEffectRollDecode(rRoll, rEffect);
	end
	rEffect.sChatCardsPower = rRoll.sChatCardsPower;
end

-- Runs on the host for every applied effect. When the effect opens straight
-- with a rules tag ("AC: 3") and its originating power is known, the notice
-- gets a "[from Mage Armor]" line, which the card parser prefers as the
-- effect's name. Named effects and effects from outside a power (typed or
-- dragged onto the CT) keep the stock notice, built by the original.
--
-- The tagged branch reproduces CoreRPG's message construction and delivery
-- (manager_effect.lua onEffectAddNotify, checked against CoreRPG 2025-06):
-- there is no seam to add a line to the message the original builds, since it
-- delivers the message itself.
function onEffectAddNotify(rActor, nodeEffect, rEffect)
	local sPower = StringManager.trim(rEffect.sChatCardsPower or "");
	if (sPower == "") or ChatCardsManager.hasEffectName(rEffect.sName or "") then
		return _fEffectAddNotify(rActor, nodeEffect, rEffect);
	end
	if rEffect.bSkipAnnounce then
		return;
	end

	local msg = { font = "msgfont", icon = "action_effect" };
	msg.text = string.format("%s ['%s']\r-> [to %s]",
		Interface.getString("effect_label"), rEffect.sName, ActorManager.getDisplayName(rActor));
	if (rEffect.sSource or "") ~= "" then
		msg.text = msg.text .. string.format("\r[by %s]", ActorManager.getDisplayName(DB.findNode(rEffect.sSource)));
	end
	msg.text = msg.text .. string.format("\r[from %s]", sPower);

	if (rEffect.nGMOnly or 0) == 1 then
		msg.secret = true;
		Comm.addChatMessage(msg);
	elseif CombatManager.isCTHidden(ActorManager.getCTNode(rActor)) then
		if (rEffect.sUser or "") == "" then
			msg.secret = true;
			Comm.addChatMessage(msg);
		else
			Comm.addChatMessage(msg);
			Comm.deliverChatMessage(msg, rEffect.sUser);
		end
	else
		Comm.deliverChatMessage(msg);
	end
end

--
--	TABLE ROLLS
--

-- A table roll's card should carry what the roll actually produced.
-- CoreRPG's TableManager.onTableRoll both computes the drawn rows AND
-- outputs them itself — as follow-up chat messages (chat output) or as a
-- record link on the roll message (story/parcel/encounter outputs) — with no
-- seam between the two. So the Comm delivery calls are intercepted for the
-- duration of the original handler: the follow-up result lines are captured
-- into the card and dropped from chat, while the roll message passes through
-- (receiving clients already skip its "[TABLE]" text) after donating any
-- record link it carries.
--
-- Cascading table links resolve synchronously inside the parent's handler
-- (CoreRPG disables dice rolling around them), so rolls nest: each roll
-- captures into its own frame on the stack, and a parent's card is flushed
-- right before its first sub-roll so cards keep the rolling order.

local MAX_TABLE_RESULTS = 10;
local _tTableFrames = {};
local _fCommDeliver = nil;
local _fCommAdd = nil;

function onTableRoll(rSource, rTarget, rRoll)
	for _, tParent in ipairs(_tTableFrames) do
		flushTableCard(tParent);
	end

	local tFrame = { rRoll = rRoll, rSource = rSource, tResults = {} };
	table.insert(_tTableFrames, tFrame);
	if #_tTableFrames == 1 then
		_fCommDeliver = Comm.deliverChatMessage;
		Comm.deliverChatMessage = onTableMessageDeliver;
		_fCommAdd = Comm.addChatMessage;
		Comm.addChatMessage = onTableMessageAdd;
	end

	local bOK, vError = pcall(TableManager.onTableRoll, rSource, rTarget, rRoll);

	table.remove(_tTableFrames);
	if #_tTableFrames == 0 then
		Comm.deliverChatMessage = _fCommDeliver;
		Comm.addChatMessage = _fCommAdd;
	end
	if not bOK then
		Debug.console("ChatCardsCore.onTableRoll: ", vError);
	end
	flushTableCard(tFrame);
end

-- Comm stand-ins while a table roll resolves; anything not recognized as
-- table output passes through untouched.
function onTableMessageDeliver(msg, ...)
	if not captureTableMessage(msg) then
		return _fCommDeliver(msg, ...);
	end
end

function onTableMessageAdd(msg, ...)
	if not captureTableMessage(msg) then
		return _fCommAdd(msg, ...);
	end
end

-- Sort one delivery into the current roll's frame. The roll message itself
-- is recognized by its dice (or its text, which opens with the roll desc on
-- the error paths): it stays in chat, but its shortcuts — the record a
-- story/parcel/encounter output created — become the card's result. The
-- follow-up systemfont result lines become results too, and are consumed.
-- Returns true when the message should not reach chat.
function captureTableMessage(msg)
	local tFrame = _tTableFrames[#_tTableFrames];
	if not tFrame or (type(msg) ~= "table") then
		return false;
	end
	if (#(msg.dice or {}) > 0)
			or StringManager.startsWith(msg.text or "", tFrame.rRoll.sDesc or "") then
		for _, tShortcut in ipairs(msg.shortcuts or {}) do
			-- "[RESULT] Camp Events" -> "Camp Events"
			local sText = tShortcut.description or "";
			local sTag = "[" .. Interface.getString("table_result_tag") .. "] ";
			if StringManager.startsWith(sText, sTag) then
				sText = sText:sub(#sTag + 1);
			end
			addTableResult(tFrame, sText, tShortcut);
		end
		return false;
	end
	addTableResult(tFrame, msg.text or "", (msg.shortcuts or {})[1]);
	return true;
end

function addTableResult(tFrame, sText, tShortcut)
	sText = StringManager.trim(sText or "");
	if (sText == "") and tShortcut then
		sText = StringManager.trim(tShortcut.description or "");
	end
	if (sText == "") or (#tFrame.tResults >= MAX_TABLE_RESULTS) then
		return;
	end
	table.insert(tFrame.tResults, {
		sText = sText,
		sClass = tShortcut and tShortcut.class or "",
		sRecord = tShortcut and tShortcut.recordname or "",
	});
end

-- Send the frame's card, once: a roll card whose extras carry the drawn
-- results. Called after the original resolves — or, for a parent table,
-- right before its first sub-roll's own card (its output is complete by
-- then: results go out before the cascade starts).
function flushTableCard(tFrame)
	if tFrame.bFlushed then
		return;
	end
	tFrame.bFlushed = true;
	ChatCardsManager.sendRollCard(tFrame.rSource, tFrame.rRoll,
		{ tResults = tFrame.tResults });
end
