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
    - [Requirements](#requirements)
    - [Configuring your environment](#configuring-your-environment)
    - [Configuring the database](#configuring-the-database)
    - [Configuring the bot](#configuring-the-bot)
    - [Building the C native extension](#building-the-c-native-extension)
    - [Final remarks](#final-remarks)
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
- Similarly, you can specify a default palette with `my palette is PALETTE`, which will be used by default when generating screenshots or animations.
- Whenever you need to specify a name (player name, level name, palette name, etc) you can always put it at the end using the prefix `for` (e.g. `scores for the basics`), but you can also use quotes, which will help when there are multiple such terms. For instance, `browse userlevels for "house" by "yefffef"` will search for all userlevels by the author `yefffef` having the word "house" in their title.
- You can refer to levels in up to 3 different ways: the ID (e.g. `S-C-19-04`), the name (e.g. `nonplusplussed`) and the alias (e.g. `-++`). Aliases are added manually by the botmaster. Player names can also have aliases.
- There is fuzzy searching for level names and palette names, which means that you can enter incomplete or approximate names and the closest matches will the found. If there's a single one, that one will be used. If there are multiple good matches, the list will be printed.
- You can shorten level IDs by omitting the dashes and extra zeroes if there's no ambiguity. For instance, level `S-B-01-03` can be referred to as `sb13`. In case of ambiguity, levels take precedence, so episode `S-B-13` cannot be shortened to `sb13`, because it would be confused with the previous level. In this case, the dashes are needed.

## For developers

Anyone looking forward to run their own fully featured version of outte, or even start contributing to it in a meaningful way, is advised to contact me through [Discord](https://discord.gg/nplusplus), as the initial setup process is complex enough to warrant it. Nevertheless, here are some pointers and things to look for. If you haven't read the section [For Users](#for-users) I recommend to do so first.

### Requirements

- [Ruby 2.7](https://www.ruby-lang.org/en/downloads/) or higher. I did most development there, and recently migrated to Ruby 3.3 while making sure to preserve backwards compatibility. If you need to use multiple versions of Ruby simultaneously for other projects, I recommend using [rbenv](https://github.com/rbenv/rbenv).
- [MySQL 5.7](https://dev.mysql.com/downloads/) or higher. Again, that's what I used until recently migrating to MySQL 8.0 while preserving backwards compatibility. For configuration, make sure to use `utf8mb4` for both encoding and collation, either server-wide or at least for outte's database. I recommend to use the [my.cnf](https://dev.mysql.com/doc/refman/8.4/en/option-files.html) configuration file provided in [./util/my.cnf](https://github.com/edelkas/inne/blob/master/util/my.cnf) for a tested configuration.
- [Python 3](https://www.python.org/downloads/) for some auxiliary tools, notably SimVYo's [nclone](https://github.com/SimonV42/nclone) to simulate N++'s physics engine and trace or animate runs. Technically this is optional, if you don't have it you'll have to disable `FEATURE_NTRACE` (see [here](#configuring-the-bot)).
- A **Discord bot** account. A bot is simply a particular type of application you can have associated to your Discord account, you can create and configure it in the [Developer Portal](https://discord.com/developers/applications). You'll need to get the bot invited to the server in order to have it authorized to operate, just like any other user. There are many tutorials for all this online. Finally, you'll need to take note of the _Application ID_ (also known as the  _Client ID_), which identifies your bot, and the _Token_ (also known as the _Client Secret_), which authenticates it. Needless to say, this last one is secret and should never be shared publicly, _nor included in the code base of inne_.
* **Optionally but recommended**: I've done all development on _Linux_, and a few minor things are actually dependent on it (such as memory monitoring or SHA1 hashing). The rest should work (and those things could be adapted), but I haven't tested anything there in years. When on Windows, I develop it via [WSL](https://learn.microsoft.com/en-us/windows/wsl/install). The bot itself is hosted in a Linux server I connect to via SSH (not covered here).

### Configuring your environment

First you'll need to ensure you have all required gems (libraries) installed. If you have bundler installed, it should suffice to run `bundle install`, this process may take a while the first time. If you don't, install it first with `gem install bundler`. Some gems have prerequirements, such as ImageMagick, which you'll have to deal with, so don't expect this process to be seamless!

Then, you'll need to create a few environment variables to hold the private login information, which should never be directly in the code base. Those marked with * are required, the others are optional.

Variable | Content
-------- | -------
`DISCORD_CLIENT`* | The _Client ID_ of your bot account.
`DISCORD_TOKEN`* | The _Client Secret_ of your bot account.
`DISCORD_CLIENT_TEST` | Client ID of your alternative, testing bot.
`DISCORD_TOKEN_TEST` | Client Secret of your alternative, testing bot.
`TWITCH_CLIENT` | Client ID for Twitch authentication.
`TWITCH_SECRET` | Client Secret for Twitch authentication.
`NPP_HASH` | Secret password to compute integrity hashes.

#### Notes:

- Having a **test bot** is of course not necessary if you're just going to contribute, but it is for me, so that I can develop on a bot that's not the one currently running in the N++ server.

- If you're not interested in having **Twitch** functionality (which basically notifies of new N++ streams), simply toggle off `UPDATE_TWITCH` (see [here](#configuring-the-bot)).

- If you're not going to run inne as a 3rd party server for mappack support, you don't need the security hash either (and even then, you can turn them off by toggling `INTEGRITY_CHECKS`).


### Configuring the database

By default, outte will connect to the MySQL database named `inne` using the configuration parameters from the [./db/config.yml](https://github.com/edelkas/inne/blob/master/db/config.yml) file. You can set these up as you need, although I wouldn't recommend changing the connector, encoding/collation, and timeout parameters, unless you know what you're doing. Look into the `DATABASE` variable (see [here](#configuring-the-bot)) if you want to have multiple database environments configured.

Seeding the initial data in the database so that it's ready for operation is not trivial, and I haven't done it in years. Therefore, the recommended way to get it is to just ask me for a database dump you can import. However, if that's not possible or you want to do it yourself, follow these rough steps:

- **Create** a new database named `inne` (by default) using `CREATE DATABASE inne`.
- Run all the **migrations** using `rails db:migrate`. This will run dozens of migrations, which essentially create the tables in the database and configure them. Unfortunately some migrations which I haven't run in years might fail and you'll have to debug them.
- **Seed** some more initial data into the database using `rails db:seed`. This will initialize some records in the database, such as the stuff that was introduced in UE.

I've seeded plenty of data directly in the migrations, however, which is bad practice. Ideally, migrations should only affect the database schema (the structure, tables, configuration, etc), and inserting initial data and records should be done in the seeding. This method is more future-proof. Cleaning this up would be nice for the project, but alas, you'll have to deal with it for now.

### Configuring the bot

Finally, there are hundreds of variables in the [./src/constants.rb](https://github.com/edelkas/inne/blob/master/src/constants.rb) file you can modify to properly configure the bot. This file is decently well documented. These are some of the most crucial ones you may want to pay attention to at the beginning:

Variable | Description
-------- | -----------
`TEST` | Toggles between production and development bot.
`DO_EVERYTHING` | Perform all [background tasks](#regular-events).
`DO_NOTHING` | Don't perform any background task.
`BOTMASTER_ID` | Your Discord ID, to manage the bot.
`SERVER_ID` | The Discord server ID where the bot resides.
`SERVER_WHITELIST` | Servers allowed to be connected to.
`SUPPORTED_COMMANDS` | Enabled slash commands.
`DATABASE` | The database environment to use from `config.yml`.
`HACKERS` | Keeps track of all ignored players.
`CHEATERS` | More ignored players.

Additionally you may be particularly interested in the following sections of the file:
- The **logging** variables, which specify how much to log to the terminal and to the logfiles.
- The **benchmarking** variables may come in handy if you're working on improving the performance of some function.
- The **task** variables are useful for enabling/disabling individual background tasks, for testing purposes.
- The **Discord** variables have some interesting settings of the bot's behaviour.

### Building the C native extension

The project includes a native module writen in C using the [Ruby C API](https://silverhammermba.github.io/emberb/c/) (also see the [official docs](https://github.com/ruby/ruby/blob/master/doc/extension.rdoc)), the code is located in the [ext](https://github.com/edelkas/inne/tree/master/ext) folder. This API allows to communicate directly with the underlying C implementation of Ruby, greatly speeding up most tasks.

To build it, it suffices to run the [build.sh](https://github.com/edelkas/inne/blob/master/ext/build.sh) script. Alternatively, you can generate the Makefile with [extconf.rb](https://github.com/edelkas/inne/blob/master/ext/extconf.rb), then _Make_ it manually, and finally copy it to the `/lib` directory (not present in the Github repo because the `.so` file is git-ignored).

When the module is required in Ruby it calls the entry point function `Init_cinne()` defined in [main.c](https://github.com/edelkas/inne/blob/master/ext/main.c). You'll know it's been properly included if the global constant `C_INNE` is defined. Nevertheless, it should be optional, as all functions have Ruby alternatives, but it's highly recommended.

### Final remarks

Make sure to:

- Edit and save all source files in **UTF8**.
- Run the bot directly from the root directory of the repo, not from the `src` one, or any other one (the relative paths may then fail).

To conclude: I've documented here the major steps of the process to get started, but I'm sure I've missed other minor things, as I haven't had to start from scratch in years. This means the process is likely going to stump you in more than one place, so don't hesitate to contact me over at the [Discord server](https://discord.gg/nplusplus).

## Credits

This bot was originally developed and maintained by [@liam-mitchell](https://github.com/liam-mitchell), check out the [original repo](https://github.com/liam-mitchell/inne). It built on ideas developed for the previous iteration of the game, [N](https://www.thewayoftheninja.org/n.html), notably [NHigh](https://forum.droni.es/viewtopic.php?f=79&t=10472) by jg9000, which was focused solely around highscoring.