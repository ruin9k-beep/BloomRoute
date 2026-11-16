# BloomRoute

A World of Warcraft addon that turns herb and mining nodes into farming loops. Pick any mix
of herbs and ores, follow the loop on the world map and minimap, and let the tracker point
you to the next stop.

One download works in two clients:

- **Turtle WoW / Octo WoW (1.12)** loads `BloomRoute.toc`, which runs the code in `Vanilla`
  and ships with spawn data for every node.
- **WoW Forever** loads `BloomRoute_Mainline.toc`, which runs the code in `Forever`. It
  starts with no node data and learns each herb and vein as you gather it.

## Features

The features below describe the 1.12 build. The Forever build has the same loops, tracker,
node memory, ignoring and options, built from the nodes you have gathered.

- **Herbs and ores:** every herbalism node used in Alchemy recipes, plus mining veins used
  in crafting (rich, small and ooze-covered veins are merged into their base type) and
  Turtle's Gemstone Deposits. Quest-only nodes are left out.
- **Combined loops:** tick several herbs and ores and get one loop through all of them.
- **World map and minimap:** a dotted trail, numbered stops and your next stop highlighted.
  Minimap stops are hollow rings sized to your reach radius.
- **Tracker window:** a rotating arrow, the distance to your next stop, and buttons to step
  through the loop, jump to the nearest stop, reverse direction, and turn on Find Herbs or
  Find Minerals.
- **Node memory:** stops you reach or pick are grayed out and skipped until they respawn,
  with respawn times you can set per node type and per zone.
- **Learning:** picking a node that isn't in the data adds it as a new spawn.
- **Ignoring nodes:** shift-right-click a stop on the world map to leave it out.
- **Options:** General, Visuals and Node Types tabs, including colors for the trail and
  rings, and toggles to leave rich or ooze-covered veins out of the loop.

## Installing

Install it with a git addon manager using this repository's URL, or download the code and
put the files in `Interface\AddOns\BloomRoute` so that `BloomRoute.toc` sits directly
inside that folder. Use the same folder for either client; each one picks its own `.toc`.

## Usage

Click the minimap button (or type `/bloom show`) to open the window, then use the button at
the top to pick herbs or ores. Type `/bloom` to list every chat command.

## Credits

Node spawn points and zone sizes come from the pfQuest and pfQuest-turtle databases, and
the herb and ore lists were checked against the OctoWow database (octowow.st/db).

Made by ruin9k.
