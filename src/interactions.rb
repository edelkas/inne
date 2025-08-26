# This file handles outte's usage of Discord's interactions.
# These can either be:
#   - Application commands
#   - Message components:
#       * Buttons
#       * Select menus
#       * Text inputs
# Currently, only buttons and select menus are being used.

def initialize_components
  $components = Discordrb::Webhooks::View.new
end

# ActionRow builder for a generic Select Menu
def interaction_add_select_menu(view = nil, id = 'menu', names = [], default = '', placeholder = 'Section')
  view = Discordrb::Webhooks::View.new if !view
  view.row do |row|
    row.select_menu(custom_id: id, placeholder: placeholder, max_values: 1) do |menu|
      names.each.with_index do |name, i|
        menu.option(label: name, value: i.to_s, default: name == default)
      end
    end
  end
ensure
  return view
end

# ActionRow builder with a Select Menu for the mode
#   mode: Name of mode that is currently selected
#   all:  Whether to allow an "All" option
def interaction_add_select_menu_mode(view = nil, id = '', mode = nil, all = true)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: "#{id}:mode", placeholder: 'Mode', max_values: 1){ |m|
      MODES.reject{ |k, v| all ? false : v == 'all' }.each{ |k, v|
        m.option(label: "Mode: #{v.capitalize}", value: v, default: v == mode)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select Menu for the tab
def interaction_add_select_menu_tab(view = nil, id = '', tab = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: "#{id}:tab", placeholder: 'Tab', max_values: 1){ |m|
      USERLEVEL_TABS.each{ |t, v|
        m.option(label: "Tab: #{v[:fullname]}", value: v[:name], default: v[:name] == tab)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select Menu for the order
#   order:   The name of the current ordering
#   default: Whether to plug "Default" option at the top
def interaction_add_select_menu_order(view = nil, id = '', order = nil, default = true)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: "#{id}:order", placeholder: 'Order', max_values: 1){ |m|
      ["default", "title", "date", "favs"][(default ? 0 : 1) .. -1].each{ |b|
        m.option(label: "Sort by: #{b.capitalize}", value: b, default: b == order)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select Menu for the highscoreable type
# (All, Level, Episode, Story)
def interaction_add_select_menu_type(view = nil, type = nil)
  type = 'overall' if type.nil? || type.empty?
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'menu:type', placeholder: 'Type', max_values: 1){ |m|
      ['overall', 'level', 'episode', 'story'].each{ |b|
        label = b == 'overall' ? 'Levels + Episodes' : b.capitalize.pluralize
        m.option(label: "Type: #{label}", value: b, default: b == type)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select menu for the highscorable tabs
# (All, SI, S, SU, SL, SS, SS2)
def interaction_add_select_menu_metanet_tab(view = nil, id = '', tab = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: "#{id}:tab", placeholder: 'Tab', max_values: 1){ |m|
      ['all', 'si', 's', 'su', 'sl', 'ss', 'ss2'].each{ |t|
        m.option(
          label:   t == 'all' ? 'All tabs' : format_tab(t.upcase.to_sym) + ' tab',
          value:   t,
          default: t == tab
        )
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select menu for the ranking types
# (0th, Top5, Top10, Top20, Average rank,
# 0th (w/ ties), Tied 0ths, Singular 0ths, Plural 0ths, Average 0th lead
# Maxed, Maxable, Score, Points, Average points)
def interaction_add_select_menu_rtype(view = nil, id = '', rtype = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: "#{id}:rtype", placeholder: 'Ranking type', max_values: 1){ |m|
      RTYPES.each{ |t|
        m.option(
          label:   "#{format_rtype(t).gsub(/\b(\w)/){ $1.upcase }}",
          value:   t,
          default: t == rtype
        )
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select Menu for the alias type
def interaction_add_select_menu_alias_type(view = nil, type = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'alias:type', placeholder: 'Alias type', max_values: 1){ |m|
      ['level', 'player'].each{ |b|
        m.option(label: "#{b.capitalize} aliases", value: b, default: b == type)
      }
    }
  }
ensure
  return view
end

# Template ActionRow builder with Buttons for navigation
def interaction_add_navigation(
    view = nil,
    labels:   ['First', 'Previous', 'Current', 'Next', 'Last'],
    disabled: [false, false, true, false, false],
    ids:      ['button:nav:first', 'button:nav:prev', 'button:nav:cur', 'button:nav:next', 'button:nav:last'],
    styles:   [:primary, :primary, :secondary, :primary, :primary],
    emojis:   [nil, nil, nil, nil, nil]
  )
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.button(label: labels[0], style: styles[0], disabled: disabled[0], custom_id: ids[0], emoji: emojis[0])
    r.button(label: labels[1], style: styles[1], disabled: disabled[1], custom_id: ids[1], emoji: emojis[1])
    r.button(label: labels[2], style: styles[2], disabled: disabled[2], custom_id: ids[2], emoji: emojis[2])
    r.button(label: labels[3], style: styles[3], disabled: disabled[3], custom_id: ids[3], emoji: emojis[3])
    r.button(label: labels[4], style: styles[4], disabled: disabled[4], custom_id: ids[4], emoji: emojis[4])
  }
ensure
  return view
end

# Template ActionRow builder with Buttons for navigation (short version)
def interaction_add_navigation_short(
    view = nil,
    labels:   ['Previous', 'Current', 'Next'],
    disabled: [false, true, false],
    ids:      ['button:nav:prev', 'button:nav:cur', 'button:nav:next'],
    styles:   [:primary, :secondary, :primary],
    emojis:   [nil, nil, nil]
  )
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.button(label: labels[0], style: styles[0], disabled: disabled[0], custom_id: ids[0], emoji: emojis[0])
    r.button(label: labels[1], style: styles[1], disabled: disabled[1], custom_id: ids[1], emoji: emojis[1])
    r.button(label: labels[2], style: styles[2], disabled: disabled[2], custom_id: ids[2], emoji: emojis[2])
  }
ensure
  return view
end


# ActionRow builder with Buttons for standard page navigation
def interaction_add_button_navigation(view, page = 1, pages = 1, offset = 1000000000, func: nil, force: false, source: 'button')
  view = Discordrb::Webhooks::View.new if !view
  return view if pages == 1 && !force
  interaction_add_navigation(
    view,
    labels:   ["❙❮", "❮", "#{page} / #{pages}", "❯", "❯❙"],
    disabled: [page == 1, page == 1, true, page == pages, page == pages],
    ids:      [
      "#{source}:nav:#{-offset}#{func ? ':' + func : ''}",
      "#{source}:nav:-1#{func ? ':' + func : ''}",
      "#{source}:nav:page",
      "#{source}:nav:1#{func ? ':' + func : ''}",
      "#{source}:nav:#{offset}#{func ? ':' + func : ''}"
    ]
  )
end

# ActionRow builder with Buttons for standard page navigation
#   - func:  The name of the function this button will call
#   - wrap:  Whether buttons will wrap once you get to the end of the list, or be disabled instead
#   - force: Force buttons to show even if there's a single page
#   - total: Show the total amount of pages, useful for when it's not known
def interaction_add_button_navigation_short(view, page = 1, pages = 1, func = nil, wrap: false, force: false, total: true, source: 'button')
  view = Discordrb::Webhooks::View.new if !view
  return view if pages == 1 && !force
  offset_left = wrap && page == 1 ? 1000000000 : -1
  offset_right = wrap && page == pages ? -1000000000 : 1
  suf = func ? ':' + func : ''
  interaction_add_navigation_short(
    view,
    labels:   ["❮", page.to_s + (total ? " / #{pages}" : ''), "❯"],
    disabled: [wrap ? false : page == 1, true, wrap ? false : page == pages],
    ids:      [
      "#{source}:nav:#{offset_left}#{suf}",
      "#{source}:nav:page",
      "#{source}:nav:#{offset_right}#{suf}"
    ]
  )
end

# ActionRow builder with Buttons for page navigation, together with center action button
def interaction_add_action_navigation(view, page = 1, pages = 1, action = '', text = '', emoji = nil)
  emoji = find_emoji(emoji).id rescue nil if emoji && emoji.ascii_only?
  text = "#{page} / #{pages}" if text.empty? && emoji.nil?
  interaction_add_navigation(
    view,
    labels:   ["❙❮", "❮", text, "❯", "❯❙"],
    disabled: [page == 1, page == 1, false, page == pages, page == pages],
    styles:   [:primary, :primary, :success, :primary, :primary],
    emojis:   [nil, nil, emoji, nil, nil],
    ids:      [
      "button:nav:-1000000",
      "button:nav:-1",
      "button:#{action}:",
      "button:nav:1",
      "button:nav:1000000"
    ]
  )
end

# ActionRow builder with Buttons for level/episode/story navigation
def interaction_add_level_navigation(view, name)
  interaction_add_navigation(
    view,
    labels:   ["❮❮", "❮", name, "❯", "❯❯"],
    disabled: [false, false, true, false, false],
    ids:      [
      "nav_scores:h:-2",
      "nav_scores:h:-1",
      "nav_scores:h:page",
      "nav_scores:h:1",
      "nav_scores:h:2"
    ]
  )
end

# ActionRow builder with Buttons for date navigation
def interaction_add_date_navigation(view, page = 1, pages = 1, date = 0, label = "")
  interaction_add_navigation(
    view,
    labels:   ["❙❮", "❮", label, "❯", "❯❙"],
    disabled: [page == 1, page == 1, true, page == pages, page == pages],
    ids:      [
      "nav_scores:date:-1000000000",
      "nav_scores:date:-1",
      "nav_scores:date:#{date}",
      "nav_scores:date:1",
      "nav_scores:date:1000000000"
    ]
  )
end

# ActionRow builder with Buttons to specify type (Level, Episode, Story)
# in Rankings, also button to include ties.
def interaction_add_type_buttons(view = nil, types = [], ties = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    TYPES.each{ |t, h|
      r.button(
        label: h[:name].capitalize.pluralize,
        style: types.include?(h[:name].capitalize) ? :success : :danger,
        custom_id: "button:type:#{h[:name].downcase}"
      )
    }
    r.button(label: 'Ties', style: ties ? :success : :danger, custom_id: "button:ties:#{!ties}")
  }
ensure
  return view
end

# ActionRow builder with Yes/No buttons to confirm an action
def interaction_add_confirmation_buttons(view = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.button(label: 'Yes', style: :success, custom_id: 'button:confirm:yes')
    r.button(label: 'No',  style: :danger,  custom_id: 'button:confirm:no')
  }
ensure
  return view
end

def interaction_button(text = "Text", id = 'test', view = nil, style: :primary)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.button(label: text, style: style, custom_id: "button:#{id}")
  }
ensure
  return view
end

def refresh_button(id = 'test')
  interaction_button("⟳", "refresh:#{id}")
end

def add_refresh_button(id = 'test')
  $components.row{ |r|
    r.button(label: "⟳", style: :primary, custom_id: "refresh:#{id}")
  }
end

def modal(
    event,
    title:      'Modal',
    custom_id:  'modal:test',
    style:      :short,
    label:      'Enter text:',
    min_length:  0,
    max_length:  64,
    required:    false,
    value:       nil,
    placeholder: 'Placeholder'
  )
  event.show_modal(title: title, custom_id: custom_id) do |modal|
    modal.row do |row|
      row.text_input(
        style:       style,
        custom_id:   'name',
        label:       label,
        min_length:  min_length,
        max_length:  max_length,
        required:    required,
        value:       value,
        placeholder: placeholder
      )
    end
  end
end

# Get a new builder based on a pre-existing component collection (i.e., for
# messages that have already been sent, so that we can send the same components
# back automatically).
def to_builder(components)
  view = Discordrb::Webhooks::View.new
  components.each{ |row|
    view.row{ |r|
      row.components.each{ |c|
        case c
        when Discordrb::Components::Button
          r.button(
            label:     c.label,
            style:     c.style,
            emoji:     c.emoji,
            custom_id: c.custom_id,
            disabled:  c.disabled,
            url:       c.url
          )
        when Discordrb::Components::SelectMenu
          r.select_menu(
            custom_id:   c.custom_id,
            min_values:  c.min_values,
            max_values:  c.max_values,
            placeholder: c.placeholder
          ) { |m|
            c.options.each{ |o|
              m.option(
                value:       o.value,
                label:       o.label,
                emoji:       o.emoji,
                description: o.description
              )
            }
          }
        end
      }
    }
  }
  view
rescue
  Discordrb::Webhooks::View.new
end

# Given a message event, presumably with select menus, this will fetch the
# current value of a menu given the id.
# It assumes the last part of the custom ID of the select menu is the current value
def get_menu_value(event, id)
  event.message.components.each{ |row|
    row.components.each{ |c|
      return $2 if c.custom_id =~ /^(.+):(.+)$/ && $1 == id
    }
  }
  nil
end

# Modal shown to identify a player (i.e., assign a player to a Discord user),
# if the player is found, otherwise respond with an error
def modal_identify(event, name: '')
  name.strip!
  user = parse_user(event.user)
  player = Player.find_by(name: name)

  if !player
    user.player = nil
    event.respond(
      content:   "No player found by the name #{verbatim(name)}, did you write it correctly?",
      ephemeral: true
    )
    return false
  end

  user.player = player
  event.respond(content: "Identified correctly, you are #{verbatim(name)}.", ephemeral: true)
end

# Called after clicking button to confirm the deletion of a mappack score
def delete_score(event, yes: false)
  expired = Time.now - event.message.timestamp > CONFIRM_TIMELIMIT
  return send_message(event, content: 'Dismissed.', append: true) if !yes
  return send_message(event, content: 'Expired.',   append: true) if expired

  id = event.message.content[/\(ID\s+(\d+)\)/i, 1]
  perror("Score ID not found in source message.") if !id
  score = MappackScore.find_by(id: id.to_i)
  perror("Mappack score with ID #{id} not found.") if !score
  score.destroy

  msg = "#{score.player.name}'s score (ID #{id}) in #{score.highscoreable.name}"
  msg = score.destroyed? ? "Deleted #{msg}." : "Failed to delete #{msg}."
  send_message(event, content: msg, append: true)
end

# Register a global command. Will update (overwrite) if it already exists.
def register_command(cmd, update = false, server_id: nil)
  sig = ''
  case cmd
  when :browse
    sig = 'str,str,str,str,str,bool'
    $bot.register_application_command(:browse, 'Browse or search userlevels', server_id: server_id) do |cmd|
      cmd.string(:name, 'Search by title')
      cmd.string(:author, 'Search by author name')
      cmd.string(:mode, 'Gameplay mode', choices: { 'Solo' => 'solo', 'Coop' => 'coop', 'Race' => 'race' })
      cmd.string(:tab, 'Search in a specific tab', choices: { 'Featured' => 'featured', 'Hardest' => 'hardest', 'Best' => 'best', 'Top Weekly' => 'top' })
      cmd.string(:order, 'Order of the results', choices: { 'Date' => 'date', 'Title' => 'title', '++\'s' => 'favs' })
      cmd.boolean(:reverse, 'Reverse ordering')
    end
  when :config
    sig = 'str,str,str,str'
    $bot.register_application_command(:config, 'Configure your outte++ usage', server_id: server_id) do |cmd|
      cmd.string(:player, 'Specify your actual N++ / Steam player name so you can omit it in the future')
      cmd.string(:nickname, 'Specify your alternative display name, will be used in future output')
      cmd.string(:palette, 'Specify your default palette to use in screenshots, traces and animations')
      cmd.string(:mappack, 'Specify your default mappack (MET to restore to vanilla)')
    end
  when :screenshot
    sig = 'str,str'
    $bot.register_application_command(:screenshot, 'Generate a screenshot', server_id: server_id) do |cmd|
      cmd.string(:name, 'The level, episode or story ID or name', required: true)
      cmd.string(:palette, 'Official palette to use')
    end
  end
  succ("%s %s command: %s(%s)" % [update ? 'Updated' : 'Registered', server_id ? 'guild' : 'global', cmd, sig])
rescue => e
  lex(e, "Failed to %s %s command: %s(%s)" % [update ? 'update' : 'register', server_id ? 'guild' : 'global', cmd, sig])
end

# Check that all commands are registered, and create any new ones
def register_commands()
  server_id = TEST ? TEST_SERVER_ID : nil
  commands = $bot.get_application_commands(server_id: server_id)
  registered = commands.map(&:name).map(&:to_sym)
  to_register = SUPPORTED_COMMANDS - DISABLED_COMMANDS
  to_update = [] # To force an update, for development

  # Register or update all supported commands
  to_register.each{ |cmd|
    next if registered.include?(cmd) && !to_update.include?(cmd)
    register_command(cmd, to_update.include?(cmd), server_id: server_id)
  }

  # Unregister unsupported commands
  commands.each{ |cmd|
    next if to_register.include?(cmd.name.to_sym)
    $bot.delete_application_command(cmd.id, server_id: server_id)
  }
  log("Registered commands")
end

# Register Discordrb handlers for all supported application commands
def register_command_handlers(&handler)
  SUPPORTED_COMMANDS.each{ |cmd|
    $bot.application_command(cmd, {}, &handler) unless DISABLED_COMMANDS.include?(cmd)
  }
end

# Important notes for parsing interaction components:
#
# 1) We determine the origin of the interaction (the bot's source message) based
#    on the first component of the button ID, or the first word of the message.
#    Therefore, we have to format this first word (and, often, the first sentence)
#    properly for the bot to parse it.
#
# 2) We use the custom_id of the component (button, select menu, modal) and of the
#    component option (select menu option) to classify them and determine what
#    they do. Therefore, they must ALL follow a specific pattern:
#
#    IDs will be strings composed by a series of keywords separated by colons:
#      The first keyword specifies the source of the interaction (in essence, what function).
#      The second keyword specifies the category of the component (up to you).
#      The third keyword specifies the specific component.
#      Optionally, the fourth keyword specifies the method name.

def respond_interaction_button(event)
  keys = event.custom_id.to_s.split(':') # Component parameters
  keys[0] = parse_message(event)[/\w+/i].to_s.downcase if keys[0] == 'button'

  # If it's a refresh button or a pager, we simply resend the exact same command,
  # editing the old one
  return send(keys[2], event)                if keys[1] == 'refresh' && !!keys[2]
  return send(keys[3], event, page: keys[2]) if keys[1] == 'nav'     && !!keys[3]

  # Otherwise, distinguish depending on the source message
  case keys[0]
  when 'aliases'
    case keys[1]
    when 'nav'
      send_aliases(event, page: keys[2])
    end
  when 'authors'
    case keys[1]
    when 'nav'
      UserlevelAuthor.parse(event: event, page: keys[2])
    end
  when 'browsing'
    case keys[1]
    when 'nav'
      send_userlevel_browse(event, page: keys[2])
    when 'play'
      send_userlevel_cache(event)
    end
  when 'delete'
    case keys[1]
    when 'confirm'
      delete_score(event, yes: keys[2] == 'yes')
    end
  when 'nav_scores'
    case keys[1]
    when 'h'
      send_scores(event, offset: keys[2])
    when 'date'
      send_scores(event, date_change: keys[2])
    end
  when 'rankings'
    case keys[1]
    when 'nav'
      send_rankings(event, page: keys[2])
    when 'ties'
      send_rankings(event, ties: keys[2] == 'true')
    when 'type'
      send_rankings(event, type: keys[2])
    end
  when 'results'
    case keys[1]
    when 'nav'
      send_query(event, page: keys[2])
    end
  when 'thumbnail'
    send_thumbnail(event, keys[1])
  end
end

def respond_interaction_menu(event)
  keys = event.custom_id.to_s.split(':') # Component parameters
  val  = event.values.first              # Identifier of selected option

  case keys[0]
  when 'alias'    # Select Menus for the alias list function
    case keys[1]
    when 'type'   # Change type of alias (level, player)
      send_aliases(event, type: val)
    end
  when 'browse'   # Select Menus for the userlevel browse function
    case keys[1]
    when 'order'  # Reorder userlevels (by title, author, date, favs)
      send_userlevel_browse(event, order: val)
    when 'tab'    # Change tab (all, best, featured, top, hardest)
      send_userlevel_browse(event, tab: val)
    when 'mode'   # Change mode (all, solo, coop, race)
      send_userlevel_browse(event, mode: val)
    end
  when 'help'     # Select Menus for the help function
    case keys[1]
    when 'sect'   # Change section (Introduction, Commands, etc)
      send_help(event, section: val)
    end
  when 'rank'     # Select Menus for the rankings function
    case keys[1]
    when 'rtype'  # Change rankings type (0th rankings, top20 rankings, etc)
      send_rankings(event, rtype: val)
    when 'tab'    # Change highscoreable tab (all, si, s, su, sl, ss, ss2)
      send_rankings(event, tab: val)
    end
  when 'speedrun' # Select Menus for the Speedrun API function
    if keys[1] =~ /^var-(.+)$/
      send_speedruns(event, variable: $1, value: val)
    else
      send_speedruns(event, keys[1].to_sym => val)
    end
  end
end

def respond_interaction_modal(event)
  keys = event.custom_id.to_s.split(':') # Component parameters
  return if keys[0] != 'modal'           # Only listen to modals

  case keys[1]
  when 'identify'
    modal_identify(event, name: event.value('name'))
  end
end

def respond_application_command(event)
  return if event.interaction.type != 2 # Only respond to application commands
  opt = event.options

  case event.command_name
  when :browse
    send_userlevel_browse(event, **opt.symbolize_keys)
  when :config
    send_config(event, **opt.symbolize_keys)
  when :screenshot
    send_screenshot(event, id: opt['id'], palette: opt['palette'])
  else
    perror("Unrecognized application command.")
  end
end
