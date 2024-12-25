# inne++ - the N++ discord server chatbot
[![N++ Discord Server](https://img.shields.io/badge/N++-Discord-%235865F2.svg?logo=discord&logoColor=FFFFFF)](https://discord.gg/nplusplus)

***inne++*** is a bot for the [Discord server](https://discord.gg/nplusplus) of the game [N++](https://www.metanetsoftware.com/games/nplusplus) by [Metanet Software](https://www.metanetsoftware.com/). It provides plenty of functionalities related to highscoring, userlevels, custom mappacks, and more; and even serves as a 3rd party server for N++.

### Table of contents
- [For users](#for-users)
    - [Basics](#basics)
    - [Userlevel support](#userlevel-support)
    - [Mappack support](#mappack-support)
    - [Regular events](#regular-events)
    - [More advanced parameters](#more-advanced-parameters)
    - [Tips and Tricks](#tips-and-tricks)
- [For developers](#for-developers)
- [Credits](#credits)

## For users

You can interact with the bot in the [server](https://discord.gg/nplusplus) directly by either pinging or DM'ing it _with natural language_, it understands plenty of commands. To get a complete list and better documentation, use the `help` (or `commands`) command.

### Basics

Here are **only a few** common examples to get you started. Most of them support many additional options to further refine the query (see the following sections):

Command | Description
------- | -----------
`help` | Show command list, help and further documentation.
`scores for SI-A-00-00` | Fetches the top20 highscores for the specified level.
`top10 rank` | Computes the global Top10 player rankings.
`userlevel rank` | Computes the global userlevel 0th rankings.
`browse userlevels` | Browse the most recent userlevels.
`screenshot for the basics` | Generates a screenshot for a level _in the default palette_.
`trace SI-A-00-00` | Generate a PNG trace of the 0th run in SI-A-00-00.
`anim SI-A-00-00 0 1` | Generate an animated GIF simulation of multiple runs.
`search for table` | Search (fuzzy) for all levels with "table" in the name.
`stats for xela` | Returns some highscoring statistics and histogram.
`how many for xela` | Query current 0th count for a player.
`points` | Query total point count _for the currently identified player_.
`bottom5 list for xela` | Fetch list of 15th-19th highscores for player xela.
`compare "xela" "jp27ace"` | Compare the highscores of two players.
`top20 table` | Organizes all your top20 counts by tab and type.
`lotd` | Query what the current Level of the Day is.
`analysis 0 1 2 for -++` | Dissect the inputs (L, R, J) of the top 3 runs in -++ (S-C-19-04).
`splits for sia0` | Compute the individual level splits for episode SI-A-00's 0th run.
`sl top10 spread` | List SL levels with largest spread between 0th and 9th scores.
`cleanest su` | Find the cleanest episode runs in SU tab.
`missing top20 si` | Find your missing top20 scores in SI tab.
`worst` | List scores losing more time with respect to the 0th.
`download userlevel 22715` | Download a vanilla map or a userlevel.
`maxed` | List all levels with a fully maxed top20 leaderboard.
`maxable` | List all levels with many ties for 0th.
`random 10 si` | Find 10 random levels in SI tab.
`community` | Compute the current community total level and episode scores.
`twitch` | List all current active N++-related Twitch streams.

#### Notes:
- All commands are case insensitive.
- If a player is not specified, the identified player (presumably yourself) will be used.
- If tabs are not specified, all of them will be used.
- If the type is not specified, levels and episodes will both be used.

### Userlevel support

There is broad userlevel support, and most highscoring commands (such as the ones above) can be used for userlevels simply by adding `userlevel` somewhere in the command. By default, all userlevels are considered, but this can also be narrowed down to only the latest 500 published userlevels (what the community considers to be "Newest") by also appending `newest`:

- `userlevel top20 rank`
- `newest userlevel average rank for xela`
- ...

Individual userlevels can be referenced by their ID or by their name. If the name creates ambiguity, the list of matches will be printed instead:

- `userlevel screenshot palette metoro for 71088`
- `userlevel scores for bramble shamble 2: electric boogaloo`

Additionally, you can browse or search userlevels, filtering the results by title, author, mode (Solo, Coop, Race) or tab (All, Featured, Hardest, etc), and ordering by many fields:

- `search solo userlevels for "house" by "yefffef" order by -favs`
- `browse hardest userlevels sort by date`

This command, and many others, has components (buttons and select menus) to allow for better navigation and paging once the command has been issued.

### Mappack support

A mappack is a cohesive set of userlevels made by one or more members and published in the community under much fanfare. These maps replace part of the original vanilla campaign (often the intro tab, although larger mappacks do exist), and provide a fresh playing and highscoring experience for those than want more out of the game. It is recommended that a mappack always be played with a new savefile.

These mappacks are published in the [custom-tabs](https://discord.gg/E55W3qhBqW) forum of the N++ [Discord server](https://discord.gg/nplusplus). We have custom installers (see [this repo](https://github.com/edelkas/npp_mappacks)) that perform all the necessary patching for Windows, including but not limited to:

- Replacing the map files.
- Automatically swapping the savefile.
- Enabling custom leaderboards by redirecting your game to our custom 3rd party server.
- Implementing additional playing modes (speedrun and low-gold).
- Optionally installing new custom palettes.
- And some nice cosmetic changes to go along with the rest.

Mappacks are supported by the bot, and thus many of the aforementioned commands can be issued for mappacks as well (e.g. scores, rankings, screenshots, lists, etc). All mappacks have an associated 3 letter code. In order to specify a mappack, the code must be included somewhere in the command (e.g. `ctp rank`).

Use the `mappacks` command to get a list of all currently supported mappacks and their information. The backend of this bot also serves as the 3rd party server the patched games connect to for mappack support.

### Regular events

There are several events or tasks which take place regularly during inne's operations, most often daily:

- The userlevel database gets updated every **5 minutes** for new userlevels.
- The entire highscore database for Metanet scores gets updated once **daily**. This means that you may need to wait up to a day for all changes to reflect in rankings and statistics. An individual leaderboard will also be automatically updated if you manually query the scores with the `scores` command.
- The highscores for the newest 500 userlevels get updated **daily** in the database as well. Older userlevel scores get continuously updated in the background constantly and more slowly: it takes about 2 weeks for a full round trip across the currently published 100k+ userlevels, unless you manually query the scores.
- Every day a new Level of the Day (lotd) gets published in the `#highscores` channel, and the highscoring activity for the previous one gets summarized, to encourage competition. This currently happens 2 hours after the highscore update.
- Every sunday a new Episode of the Week is published.
- Every 1st of the month a new Column of the Month is published.
- The highscoring report is published **daily** in the `#highscores` channel, right after the new lotd. This summarizes information about the highscoring activity in the past 24h and in the past week.
- The userlevel report is published **daily** in the `#userlevels` channel. This summarizes highscoring activity (mainly 0ths and points) _in the newest 500 userlevels_.
- The [N++ category](https://www.twitch.tv/directory/category/n-2015) in Twitch is checked **every minute** for new N++ streams, which are posted automatically in the `#n-content-creation` channel. You can also use the `@Voyeur` Discord role to be notified (pinged) of this.

Some other regular events are omitted here due to their technical nature, such as monitor memory or database status. See the [Developer](#for-developers) section for more details.


### More advanced options

Most commands support many additional options. For a full reference, check the relevant `help` command, or if documentation is not yet available, ask a member in the server. For instance:

- In highscoring commands, results can often be filtered by tab (SI, S, SL, SU, ?, !) and type (Level, Episode, Story), in any order. Thus, one can ask `how many top5 * ? ! level`, which will return how many level top5's the identified player has in the secret tabs (`? !`) which used to be 0th (`*`).
- Furthermore, many commands support filtering by mappack, and even playing mode. Thus, one can say `ctp sr score si rank`, which will rank players (`rank`) by total score (`score`) in speedrun mode (`sr`) in the intro tab (`si`) of the CTP mappack (`ctp`).

### Tips and tricks

Here are some nifty features to make using the bot simpler:
- If you identify, you will be able to omit your player name in many commands. You can do this with the command `my name is PLAYERNAME`, changing `PLAYERNAME` with your actual N++ username. Now you can run `how many top20` and it will tell you _your_ top20 count.
- Similarly, you can specify a default palette with `my palette is PALETTE`, which is be used by default when generating screenshots or animations.
- Whenever you need to specify a name (player name, level name, palette name, etc) you can always put it at the end using the prefix `for` (e.g. `scores for the basics`), but you can also use quotes, which will help when there are multiple such terms. For instance, `browse userlevels for "house" by "yefffef"` will search for all userlevels by the author `yefffef` having the word "house" in their title.
- You can refer to levels in up to 3 different ways: the ID (e.g. `S-C-19-04`), the name (e.g. `nonplusplussed`) and the alias (e.g. `-++`). Aliases are added manually by the botmaster. PLayers can also have aliases.
- There is fuzzy searching for level names and palette names, which means that you can enter incomplete or approximate names and the closest matches will the found. If there's a single one, that one will be used. If there are multiple good matches, the list will be printed.
- You can shorten level IDs by omitting the dashes and extra zeroes if there's no ambiguity. For instance, level `S-B-01-03` can be referred to as `sb13`. In case of ambiguity, levels take precedence, so episode `S-B-13` cannot be shortened to `sb13`, because it would be confused with the previous level. In this case, the dashes are needed.


## For developers

TO DO

## Credits

This bot was originally developed and maintained by [@liam-mitchell](https://github.com/liam-mitchell), check out the [original repo](https://github.com/liam-mitchell/inne). It built on ideas developed for the previous iteration of the game, [N](https://www.thewayoftheninja.org/n.html), notably [NHigh](https://forum.droni.es/viewtopic.php?f=79&t=10472) by jg9000, which was focused solely around highscoring.