# This file handles outte's usage of Discord's interactions.
# These can either be:
#   - Application commands
#   - Message components:
#       * Buttons
#       * Select menus
#       * Text inputs
# Currently, only buttons and select menus are being used.

require_relative 'constants.rb'
require_relative 'utils.rb'
require_relative 'messages.rb'
require_relative 'userlevels.rb'

# ActionRow builder with a Select Menu for the mode
#   mode: Name of mode that is currently selected
#   all:  Whether to allow an "All" option
def interaction_add_select_menu_mode(view = nil, mode = nil, all = true)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'menu:mode', placeholder: 'Mode', max_values: 1){ |m|
      MODES.reject{ |k, v| all ? false : v == 'all' }.each{ |k, v|
        m.option(label: "Mode: #{v.capitalize}", value: "menu:mode:#{v}", default: v == mode)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select Menu for the tab
def interaction_add_select_menu_tab(view = nil, tab = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'menu:tab', placeholder: 'Tab', max_values: 1){ |m|
      USERLEVEL_TABS.each{ |t, v|
        m.option(label: "Tab: #{v[:fullname]}", value: "menu:tab:#{v[:name]}", default: v[:name] == tab)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select Menu for the order
#   order:   The name of the current ordering
#   default: Whether to plug "Default" option at the top
def interaction_add_select_menu_order(view = nil, order = nil, default = true)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'menu:order', placeholder: 'Order', max_values: 1){ |m|
      ["default", "title", "date", "favs"][(default ? 0 : 1) .. -1].each{ |b|
        m.option(label: "Sort by: #{b.capitalize}", value: "menu:order:#{b}", default: b == order)
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
        m.option(label: "Type: #{label}", value: "menu:type:#{b}", default: b == type)
      }
    }
  }
ensure
  return view
end

# ActionRow builder with a Select menu for the highscorable tabs
# (All, SI, S, SU, SL, SS, SS2)
def interaction_add_select_menu_metanet_tab(view = nil, tab = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'menu:tab', placeholder: 'Tab', max_values: 1){ |m|
      ['all', 'si', 's', 'su', 'sl', 'ss', 'ss2'].each{ |t|
        m.option(
          label:   t == 'all' ? 'All tabs' : format_tab(t.upcase.to_sym) + ' tab',
          value:   "menu:tab:#{t}",
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
def interaction_add_select_menu_rtype(view = nil, rtype = nil)
  view = Discordrb::Webhooks::View.new if !view
  view.row{ |r|
    r.select_menu(custom_id: 'menu:rtype', placeholder: 'Ranking type', max_values: 1){ |m|
      RTYPES.each{ |t|
        m.option(
          label:   "#{format_rtype(t).gsub(/\b(\w)/){ $1.upcase }}",
          value:   "menu:rtype:#{t}",
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
    r.select_menu(custom_id: 'menu:alias', placeholder: 'Alias type', max_values: 1){ |m|
      ['level', 'player'].each{ |b|
        m.option(label: "#{b.capitalize} aliases", value: "menu:alias:#{b}", default: b == type)
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

# ActionRow builder with Buttons for standard page navigation
def interaction_add_button_navigation(view, page = 1, pages = 1, offset = 1000000000)
  interaction_add_navigation(
    view,
    labels:   ["❙❮", "❮", "#{page} / #{pages}", "❯", "❯❙"],
    disabled: [page == 1, page == 1, true, page == pages, page == pages],
    ids:      [
      "button:nav:#{-offset}",
      "button:nav:-1",
      "button:nav:page",
      "button:nav:1",
      "button:nav:#{offset}"
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
      "button:id:-2",
      "button:id:-1",
      "button:id:page",
      "button:id:1",
      "button:id:2"
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
      "button:date:-1000000000",
      "button:date:-1",
      "button:date:#{date}",
      "button:date:1",
      "button:date:1000000000"
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
  deleted = score.wipe

  msg = "#{score.player.name}'s score (ID #{id}) in #{score.highscoreable.name}"
  msg = deleted ? "Deleted #{msg}." : "Failed to delete #{msg}."
  send_message(event, content: msg, append: true)
end

# Important notes for parsing interaction components:
#
# 1) We determine the origin of the interaction (the bot's source message) based
#    on the first word of the message. Therefore, we have to format this first
#    word (and, often, the first sentence) properly for the bot to parse it.
#
# 2) We use the custom_id of the component (button, select menu, modal) and of the
#    component option (select menu option) to classify them and determine what
#    they do. Therefore, they must ALL follow a specific pattern:
#
#    IDs will be strings composed by a series of keywords separated by colons:
#      The first keyword specifies the type of component (button, menu).
#      The second keyword specifies the category of the component (up to you).
#      The third keyword specifies the specific component.

def respond_interaction_button(event)
  keys = event.custom_id.to_s.split(':')       # Component parameters
  type = parse_message(event)[/\w+/i].downcase # Source message type
  return if keys[0] != 'button'                # Only listen to buttons

  case type
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
  when 'navigating'
    case keys[1]
    when 'id'
      send_nav_scores(event, offset: keys[2])
    when 'date'
      send_nav_scores(event, date: keys[2])
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
  when 'status'
    case keys[1]
    when 'refresh'
      send_status(event)
    end
  end
end

def respond_interaction_menu(event)
  keys   = event.custom_id.to_s.split(':')       # Component parameters
  values = event.values.map{ |v| v.split(':') }  # Component option parameters
  type   = parse_message(event)[/\w+/i].downcase # Source message type
  return if keys[0] != 'menu'                    # Only listen to select menus

  case type
  when 'browsing' # Select Menus for the userlevel browse function
    case keys[1]
    when 'order'  # Reorder userlevels (by title, author, date, favs)
      send_userlevel_browse(event, order: values.first.last)
    when 'tab'    # Change tab (all, best, featured, top, hardest)
      send_userlevel_browse(event, tab: values.first.last)
    when 'mode'   # Change mode (all, solo, coop, race)
      send_userlevel_browse(event, mode: values.first.last)
    end
  when 'aliases'  # Select Menus for the alias list function
    case keys[1]
    when 'alias'  # Change type of alias (level, player)
      send_aliases(event, type: values.first.last)
    end
  when 'rankings' # Select Menus for the rankings function
    case keys[1]
    when 'rtype'  # Change rankings type (0th rankings, top20 rankings, etc)
      send_rankings(event, rtype: values.first.last)
    when 'tab'    # Change highscoreable tab (all, si, s, su, sl, ss, ss2)
      send_rankings(event, tab: values.first.last)
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
