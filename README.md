# ChatCards

A Fantasy Grounds Unity extension that replaces the chat log with a card-style
message display — rolls, spells, speech and system messages each rendered as
their own card, in the spirit of modern VTT chat streams.

> **Status: early development (v0.1).** Playable and actively tested in 5E
> campaigns, but expect rough edges and visual placeholder art.

## What you get

- **Roll cards** — attacks, damage, healing, saves, ability and skill checks
  each get a card with the actor's portrait, per-die results, the total, and
  the outcome (hit/miss vs AC, success/failure vs DC). Modifiers are itemized
  ("Rapier +5 · Bless +1d4"), and keyword chips call out Advantage /
  Disadvantage, damage types and weapon properties.
- **Spell & power cards** — using a power announces it on a card with its
  name (linked to the record), a foldable description, and the power's
  actions as rollable rows. Rolls made from a row report their results back
  onto the card — for everyone at the table, including saves rolled by other
  players.
- **Drag & drop works like native chat** — damage and heal results drag from
  the card onto a token to apply them; record links dropped into chat become
  shared link cards; dice, numbers and strings drop onto the card list as
  they did onto the chat window.
- **Speech & story** — talk, emotes, OOC and whispers show as speech bubbles
  with character portraits; story text becomes narration cards. Character
  names link to their sheets (respecting GM-only records).
- **System messages, readable** — turn and round changes, applied and expired
  effects, and "takes N damage" results are rewritten as plain sentences on
  compact banners instead of bracket-tag chatter. Table rolls show their
  drawn results right on the roll card, and `/help` (or `/commands`) lists
  every chat command — including ones other extensions add.
- **Nothing breaks** — the engine's real chat log stays alive underneath
  (hidden), so `/log` export, secret-roll handling and other extensions keep
  working. Secret rolls and GM-only messages keep their reach.

## Ruleset support

ChatCards is built on CoreRPG with per-system adapters:

| Ruleset | Support |
| --- | --- |
| [5E](Docs/DnD5E.md) | Full: dedicated attack/damage/heal/save/check cards, spell cards with action rows, effect origins |
| [Daggerheart](Docs/Daggerheart.md) | Full: duality action/attack cards (Hope/Fear die tints, tags and crits), reaction, damage, heal and experience cards, effect origins, and ability cards with rollable action rows via a "send to chat" button added to the character sheet |
| Other CoreRPG-based rulesets | Generic: speech, story, system and table cards, plus a generic card for every dice roll |

Support for another system means writing one adapter script — see
[COLLABORATING.md](COLLABORATING.md).

## Installation

Copy (or clone) this folder into your Fantasy Grounds `extensions/`
directory and enable **ChatCards** in the campaign's extension list.

## For contributors

Implementation details — architecture, code conventions, how to add a
ruleset adapter, restyling — live in [COLLABORATING.md](COLLABORATING.md).
Design documentation (reference mockup, decision log) lives in
[`Design/`](Design/README.md).
