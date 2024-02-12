# This file handles most of the internal logic of the main functions of outte
# (performing rankings, downloading scores, analyzing replays...).
# The actual output and communication is handled in messages.rb.
#
# This file also contains the main custom Modules and Classes used in the program
# (e.g. Highscoreable, Downloadable, Level, Episode, Story, Archive, Demo...).
# Including the modifications to 3rd party stuff (monkey patches).

require 'active_record'
require 'json'
require 'net/http'
require 'socket'
require 'webrick'
require 'zlib'

require_relative 'constants.rb'
require_relative 'utils.rb'

# Monkey patches to get some custom behaviour from a few core classes,
# as well as ActiveRecord, Discordrb and WEBrick
module MonkeyPatches
  def self.patch_core
    # Add justification to arrays, like for strings
    ::Array.class_eval do
      def rjust(n, x) Array.new([0, n - length].max, x) + self end
      def ljust(n, x) self + Array.new([0, n - length].max, x) end
    end

    # Stable sorting, i.e., ensures ties maintain their order
    ::Enumerable.class_eval do
      def stable_sort;    sort_by.with_index{ |x, idx| [      x,  idx] } end
      def stable_sort_by; sort_by.with_index{ |x, idx| [yield(x), idx] } end
    end

    # Add bool to int casting
    ::TrueClass.class_eval  do def to_i; 1 end end
    ::FalseClass.class_eval do def to_i; 0 end end
  end

  def self.patch_activerecord
    # Add custom method "where_like" to Relations. Takes care of:
    #   - Sanitizing user input
    #   - Adding wildcards before and after, for substring matches
    #   - Executing a where query
    ::ActiveRecord::QueryMethods.class_eval do
      def where_like(field, str, partial: true)
        return self if field.empty? || str.empty?
        str = sanitize_like(str.downcase)
        str = "%" + str + "%" if partial
        self.where("LOWER(#{field}) LIKE (?)", str)
      end
    end

    # Add same method to base classes
    ::ActiveRecord::Base.class_eval do
      def self.where_like(field, str, partial: true)
        return self if field.empty? || str.empty?
        str = sanitize_like(str.downcase)
        str = "%" + str + "%" if partial
        self.where("LOWER(#{field}) LIKE (?)", str)
      end
    end
  end

  # Customize Discordrb's log format to match outte's, for neatness
  # Also, disable printing entire backtrace when logging exceptions
  def self.patch_discordrb
    ::Discordrb::Logger.class_eval do
      def simple_write(stream, message, mode, thread_name, timestamp)
        Log.write(message, mode[:long].downcase.to_sym, 'DRB')
      end
      def log_exception(e)
        error("Exception: #{e.inspect}")
      end
    end
    ::Discordrb::Webhooks::View::RowBuilder.class_eval do
      def button(style:, label: nil, emoji: nil, custom_id: nil, disabled: nil, url: nil)
        style = ::Discordrb::Webhooks::View::BUTTON_STYLES[style] || style
        emoji = case emoji
                when Integer, String
                  emoji.to_i.positive? ? { id: emoji } : { name: emoji }
                when nil
                  nil
                else
                  emoji.to_h
                end
        @components << { type: ::Discordrb::Webhooks::View::COMPONENT_TYPES[:button], label: label, emoji: emoji, style: style, custom_id: custom_id, disabled: disabled, url: url }
      end
    end
    ::Discordrb::Webhooks::View::SelectMenuBuilder.class_eval do
      def option(label:, value:, description: nil, emoji: nil, default: nil)
        emoji = case emoji
                when Integer, String
                  emoji.to_i.positive? ? { id: emoji } : { name: emoji }
                when
                  nil
                else
                  emoji.to_h
                end
        @options << { label: label, value: value, description: description, emoji: emoji, default: default }
      end
    end
  end

  # Customize WEBRick's log format
  def self.patch_webrick
    ::WEBrick::BasicLog.class_eval do
      def initialize(log_file = nil, level = nil)
        @level = 3
        @log = $stderr
      end

      def log(level, data)
        return if level > @level
        data.gsub!(/^(?:FATAL|ERROR|WARN |INFO |DEBUG) /, '')
        mode = [:fatal, :error, :warn, :info, :debug][level - 1] || :info
        Log.write(data, mode, 'WBR')
      end
    end

    ::WEBrick::Log.class_eval do
      def log(level, data)
        super(level, data)
      end
    end

    ::WEBrick::HTTPServer.class_eval do
      def access_log(config, req, res)
        param = ::WEBrick::AccessLog::setup_params(config, req, res)
        param['U'] = param['U'].split('?')[0].split('/')[-1] rescue ''
        @config[:AccessLog].each{ |logger, fmt|
          str = ::WEBrick::AccessLog::format(fmt.gsub('%T', ''), param)
          str += " #{"%.3fms" % (1000 * param['T'])}" if fmt.include?('%T') rescue ''
          str.squish!
          fmt.include?('%s') ? lout(str) : lin(str)
        }
      end
    end
  end

  # Patch ChunkyPNG to add functionality and significantly optimize a few methods.
  # Optimizations are now obsolete, since I'm using the corresponding methods
  # in the C extension (OilyPNG)
  def self.patch_chunkypng
    # Faster method to render an opaque rectangle (~4x faster)
    ::ChunkyPNG::Canvas::Drawing.class_eval do
      def fast_rect(x0, y0, x1, y1, stroke_color = nil, fill_color = ChunkyPNG::Color::TRANSPARENT)
        stroke_color = ChunkyPNG::Color.parse(stroke_color) unless stroke_color.nil?
        fill_color   = ChunkyPNG::Color.parse(fill_color) unless fill_color.nil?

        # Fill
        if !fill_color.nil? && fill_color != ChunkyPNG::Color::TRANSPARENT
          [x0, x1].min.upto([x0, x1].max) do |x|
            [y0, y1].min.upto([y0, y1].max) do |y|
              pixels[y * width + x] = fill_color
            end
          end
        end

        # Stroke
        if !stroke_color.nil? && stroke_color != ChunkyPNG::Color::TRANSPARENT
          line(x0, y0, x0, y1, stroke_color, false)
          line(x0, y1, x1, y1, stroke_color, false)
          line(x1, y1, x1, y0, stroke_color, false)
          line(x1, y0, x0, y0, stroke_color, false)
        end

        self
      end
    end

    # Faster method to compose images where the pixels are either fully solid
    # or fully transparent (~10x faster)
    ::ChunkyPNG::Canvas::Operations.class_eval do
      def fast_compose!(other, offset_x = 0, offset_y = 0, bg = 0)
        check_size_constraints!(other, offset_x, offset_y)
        w = other.width
        o = width - w + 1
        i = offset_y * width + offset_x - o
        other.pixels.each_with_index{ |color, p|
          i += (p % w == 0 ? o : 1)
          next if color == bg
          pixels[i] = color
        }
        self
      end
    end

    ::ChunkyPNG::Canvas::Drawing.class_eval do
      # For an anti-aliased line, this adjusts the shade of each of the 2 borders
      # when there's a fractional line width. It also provides information to
      # adjust the integer width of the line later, which may've increased
      def adjust_fractional_width(w, frac_a, frac_b)
        # "Odd fractional part" (distance to greatest smaller odd number)
        # d in [0, 2)
        wi = w.to_i
        d = w - wi + (wi + 1) % 2

        # Extra darkness to add to each border of the line
        # frac_e in [0, 255]
        frac_e = (128 * d).to_i

        # Compute new border shades, and specify if we rolled over
        new_frac_a = (frac_a + frac_e) & 0xFF
        inc_a = new_frac_a < frac_a
        new_frac_b = (frac_b + frac_e) & 0xFF
        inc_b = new_frac_b < frac_b

        [new_frac_a, new_frac_b, inc_a, inc_b]
      end

      # Draws one chunk (set of pixels around one coordinate) of an anti-aliased line
      # Allows for arbitrary widths, even fractional
      def line_chunk(x, y, color = 0xFF, weight = 1, frac = 0xFF, s = 1, swap = false, antialiasing = true)
        weight = 1.0 if weight < 1.0

        # Optionally compute antialiased shades and new line width
        if antialiasing
          # Adjust line width and shade of line borders
          frac_a, frac_b, inc_a, inc_b = adjust_fractional_width(weight, frac, 0xFF - frac)
          weight = weight.to_i - (weight.to_i + 1) % 2

          # Prepare color shades
          fade_a = ChunkyPNG::Color.fade(color, frac_a)
          fade_b = ChunkyPNG::Color.fade(color, frac_b)
          fade_a, fade_b = fade_b, fade_a if s[1] < 0
          inc_a, inc_b = inc_b, inc_a if s[1] < 0

          # Draw range
          min = - weight / 2 - (inc_a ? 1 : 0)
          max =   weight / 2 + (inc_b ? 1 : 0)
        else
          weight = weight.to_i
          fade_a = color
          fade_b = color
          min = - weight / 2 + 1
          max =   weight / 2
        end

        # Draw
        w = min
        if !swap
          compose_pixel(x, y + w, fade_a)
          compose_pixel(x, y + w, color ) while (w += 1) < max
          compose_pixel(x, y + w, fade_b) if w <= max
        else
          compose_pixel(y + w, x, fade_a)
          compose_pixel(y + w, x, color ) while (w += 1) < max
          compose_pixel(y + w, x, fade_b) if w <= max
        end
      end

      # Simplified version of ChunkyPNG's implementation
      def line(x0, y0, x1, y1, stroke_color, inclusive = true, weight: 1, antialiasing: true)
        stroke_color = ChunkyPNG::Color.parse(stroke_color)

        # Normalize coordinates
        swap = (y1 - y0).abs > (x1 - x0).abs
        x0, x1, y0, y1 = y0, y1, x0, x1 if swap

        # Precompute useful parameters
        dx = x1 - x0
        dy = y1 - y0
        sx = dx < 0 ? -1 : 1
        sy = dy < 0 ? -1 : 1
        dx *= sx
        dy *= sy
        x, y = x0, y0
        s = [sx, sy]

        # If both endpoints are the same, draw a single point and return
        if dx == 0
          line_chunk(x0, y0, stroke_color, weight, 0xFF, s, swap)
          return self
        end

        # Rotate weight
        e_acc = 0
        e = ((dy << 16) / dx.to_f).round
        max = dy <= 1 ? dx - 1 : dx + weight.to_i - 2
        weight *= (1 + (dy.to_f / dx) ** 2) ** 0.5

        # Draw line chunks
        0.upto(max) do |i|
          e_acc += e
          y += sy if e_acc > 0xFFFF unless i == 0 && e == 0x10000
          e_acc &= 0xFFFF
          w = 0xFF - (e_acc >> 8)
          line_chunk(x, y, stroke_color, weight, w, s, swap, antialiasing)
          x += sx
        end

        self
      end
    end
  end

  def self.apply
    return if !MONKEY_PATCH
    patch_core         if MONKEY_PATCH_CORE
    patch_activerecord if MONKEY_PATCH_ACTIVE_RECORD
    patch_discordrb    if MONKEY_PATCH_DISCORDRB
    patch_webrick      if MONKEY_PATCH_WEBRICK
    patch_chunkypng    if MONKEY_PATCH_CHUNKYPNG
  end
end

# Common functionality for all highscoreables whose leaderboards we download from
# N++'s server (level, episode, story, userlevel).
module Downloadable
  # Submit zero scores to a list of Downloadables
  #   event: Send msgs to Discord if not nil
  #   msgs:  Discord message to edit for progress report
  def self.submit_zero_scores(list, event: nil, msgs: [nil])
    ul = list.first.is_a?(Userlevel)
    count = list.count
    good = 0
    bad = 0
    list.find_each{ |h|
      name = ul ? "userlevel #{h.id}" : h.name
      res = h.submit_zero_score
      if !res
        bad += 1
        concurrent_edit(event, msgs, "Failed to submit zero score to #{name} (outte++ inactive?).") unless !event
        sleep(5)
      elsif res.key?('rank') && !res['rank'].nil? && res['rank'].to_i >= 0
        h.update(completions: res['rank'].to_i + 1) if !h.completions || h.completions < res['rank'].to_i + 1
        h.update(submitted: true) if ul
        good += 1
        dbg("Submitted zero score to #{name}: rank #{res['rank']}", progress: true)
        concurrent_edit(event, msgs, "Submitted #{good} / #{count} zero scores (#{bad} failed)...") if good % 100 == 0 && event
      else
        bad += 1
        concurrent_edit(event, msgs, "Failed to submit zero score to #{name} (wrong hash?).") unless !event
      end
    }
  end

  # Update completions for a list of Downloadables
  #   event:   Send msgs to Discord if not nil
  #   msgs:    Discord message to edit for progress report
  #   retries: Retries before moving on to next level (0 = infinite)
  #   global:  Use global boards (true), around mine (false) or default (nil)
  def self.update_completions(list, event: nil, msgs: [nil], retries: 0, global: nil)
    type = list.first.class.to_s.downcase
    ul = list.first.is_a?(Userlevel)
    count = list.count
    delta = 0
    list.find_each.with_index{ |h, i|
      name = ul ? "userlevel #{h.id}" : h.name
      attempt = 0
      current = "#{name} [#{type} #{i} / #{count}]"
      count_old = h.completions.to_i
      count_new = h.update_completions(log: false, discord: false, global: global)

      while !count_new
        if retries == 0 || attempt < retries
          concurrent_edit(event, msgs, "Stopped updating at #{current} (waiting for outte++, attempt #{attempt + 1} / #{retries}).")
          attempt += 1
          sleep(5)
          count_new = h.update_completions(log: false, discord: false, global: global)
        else
          concurrent_edit(event, msgs, "Stopped updating at #{current} (timed out waiting for outte++).")
          return
        end
      end

      delta += [count_new - count_old, 0].max
      concurrent_edit(event, msgs, "Updated #{current} (Gained: #{delta})...") if i % 100 == 0
    }
    delta
  end

  def scores_uri(steam_id, qt: 0)
    klass = self.class == Userlevel ? "level" : self.class.to_s.downcase
    URI.parse("https://dojo.nplusplus.ninja/prod/steam/get_scores?steam_id=#{steam_id}&steam_auth=&#{klass}_id=#{self.id.to_s}&qt=#{qt}")
  end

  # Download the highscoreable's scores from Metanet's server
  def get_scores(fast: false)
    uri  = Proc.new { |steam_id| scores_uri(steam_id) }
    data = Proc.new { |data| correct_ties(clean_scores(JSON.parse(data)['scores'])) }
    err  = "error getting scores for #{self.class.to_s.downcase} with id #{self.id.to_s}"
    get_data(uri, data, err, fast: fast)
  end

  # Get number of completions (basically a simpler get_scores query)
  #   global  - Use global boards rather than around mine
  #   log     - Log download errors to the terminal
  #   discord - Log download errors to Discord (since this function may be executed manually)
  #   retries - Number of retries before giving up
  #   stop    - Throw exception if all retries fail (otherwise, return nil)
  def get_completions(global: false, log: false, discord: false, retries: 0, stop: false)
    res = nil

    # Make several attempts at retrieving the scores with outte++'s account
    while !res && retries >= 0
      # Fetch scores
      res = Net::HTTP.get_response(scores_uri(OUTTE_STEAM_ID, qt: global ? 0 : 1))

      # Received incorrect HTTP response
      if !res || !(200..299).include?(res.code.to_i)
        if retries != 0 || !stop
          res = nil
        else
          perror("Unsuccessful HTTP request.", log: log, discord: discord)
        end
      end

      # outte++'s isn't active
      if res && res.body == INVALID_RESP
        if retries != 0 || !stop
          res = nil
        else
          perror("outte++'s Steam ID not active.", log: log, discord: discord)
        end
      end

      retries -= 1
    end

    # Parse result (no result, no scores, or success)
    return nil if !res
    hash = JSON.parse(res.body)
    pb = hash['userInfo']
    if !pb
      return -1 if !stop
      perror("outte++ doesn't have a score in #{name}.", log: log, discord: discord)
    end

    # Return max rank between personal and whole leaderboard
    # Notes:
    #  - Returned ranks in the sores list might be null
    #  - The personal rank is sometimes incorrect. For example, for stories,
    #    it may actually incorrectly equal the episode rank instead.
    max_rank = hash['scores'].map{ |s| s['rank'].to_i }.max.to_i
    my_rank = pb['my_rank'].to_i
    my_rank = 0 if self.class == Story && my_rank + 1 >= Episode.find_by(id: id).completions rescue 0
    [max_rank, my_rank].max + 1
  rescue => e
    lex(e, "Failed to get completions for #{name}.")
    nil
  end

  # Sanitize received leaderboard data:
  #   - Reject scores by blacklisted players (hackers / cheaters)
  #   - Reject incorrect scores submitted accidentally by legitimate players
  #   - Patch score of runs submitted using old versions of the map, with different amount of gold
  def clean_scores(boards)
    # Compute score upper limit
    if self.class == Userlevel
      limit = 2 ** 32 - 1 # No limit
    else
      limit = TABS[self.class.to_s].map{ |k, v| v[1] }.max
      TABS[self.class.to_s].each{ |k, v| if v[0].include?(self.id) then limit = v[1]; break end  }
    end

    # Filter out cheated/hacked runs, incorrect scores and too high scores
    k = self.class.to_s.downcase.to_sym
    boards.reject!{ |s|
      BLACKLIST.keys.include?(s['user_id']) || BLACKLIST_NAMES.include?(s['user_name']) || PATCH_IND_DEL[k].include?(s['replay_id']) || s['score'] / 1000.0 >= limit
    }

    # Batch patch old incorrect runs
    if PATCH_RUNS[k].key?(self.id)
      boards.each{ |s|
        entry = PATCH_RUNS[k][self.id]
        s['score'] += 1000 * entry[1] if s['replay_id'] <= entry[0]
      }
    end

    # Individually patch old incorrect runs
    boards.each{ |s|
      s['score'] += 1000 * PATCH_IND_CHG[k][s['replay_id']] if PATCH_IND_CHG[k].key?(s['replay_id'])
    }

    boards
  rescue => e
    lex(e, "Failed to clean leaderboards for #{name}")
    boards
  end

  def save_scores(updated)
    ActiveRecord::Base.transaction do
      # Save stars so we can reassign them again later
      stars = scores.where(star: true).pluck(:player_id) if self.class != Userlevel

      # Loop through all new scores
      updated.each_with_index do |score, i|
        # Precompute player and score
        playerclass = self.class == Userlevel ? UserlevelPlayer : Player
        player = playerclass.find_or_create_by(metanet_id: score['user_id'])
        player.update(name: score['user_name'].force_encoding('UTF-8'))
        scoretime = score['score'] / 1000.0
        scoretime = (scoretime * 60.0).round if self.class == Userlevel

        # Update common values
        scores.find_or_create_by(rank: i).update(
          score:     scoretime,
          replay_id: score['replay_id'].to_i,
          player:    player,
          tied_rank: updated.find_index { |s| s['score'] == score['score'] }
        )

        # Non-userlevel updates (tab, archive, demos)
        next if self.class == Userlevel
        scores.find_by(rank: i).update(tab: self.tab, cool: false, star: false)

        # Create archive and demo if they don't already exist
        next if !Archive.find_by(highscoreable: self, replay_id: score['replay_id']).nil?

        # Update old archives
        Archive.where(highscoreable: self, player: player).update_all(expired: true)

        # Create archive
        ar = Archive.create(
          replay_id:     score['replay_id'].to_i,
          player:        player,
          highscoreable: self,
          score:         (score['score'] * 60.0 / 1000.0).round,
          metanet_id:    score['user_id'].to_i,
          date:          Time.now,
          tab:           self.tab,
          lost:          false,
          expired:       false
        )

        # Create demo
        Demo.find_or_create_by(id: ar.id).update_demo
      end

      # Update timestamps, cools and stars
      if self.class == Userlevel
        self.update(
          score_update: Time.now.strftime(DATE_FORMAT_MYSQL),
          scored:       updated.size > 0
        )
      else
        scores.where("rank < #{find_coolness}").update_all(cool: true)
        scores.where(player_id: stars).update_all(star: true)
        scores.where(rank: 0).update(star: true)
      end

      # Remove scores stuck at the bottom after ignoring cheaters
      scores.where(rank: (updated.size..19).to_a).delete_all
    end
  end

  def update_scores(fast: false)
    updated = get_scores(fast: fast)

    if updated.nil?
      err("Failed to download scores for #{self.class.to_s.downcase} #{self.id}") if LOG_DOWNLOAD_ERRORS
      return -1
    end

    save_scores(updated)
  rescue => e
    lex(e, "Error updating database with #{self.class.to_s.downcase} #{self.id}: #{e}")
    return -1
  end

  # Update how many completions this highscoreable has, by downloading the scores
  # using outte++'s N++ account, which has a score of 0.000 in all of them
  def update_completions(log: false, discord: false, retries: 0, stop: false, global: nil)
    if !global.nil?
      count = get_completions(global: global, log: log, discord: discord, retries: retries, stop: stop)
    else
      count = get_completions(global: false, log: log, discord: discord, retries: retries, stop: stop)
      count = get_completions(global: true, log: log, discord: discord, retries: retries, stop: stop) if count && completions && count < completions
    end

    return nil if !count
    self.update(completions: count) if count > completions.to_i
    completions || count
  rescue => e
    lex(e, "Failed to update the completions for #{name}.")
    nil
  end

  def submit_score(score, replays, player = nil, log: false)
    fname = verbatim(self.name.remove('`'))

    # Fetch player
    player = Player.find_by(metanet_id: OUTTE_ID) if !player
    if !player
      err("No player to submit score to #{fname}.", discord: log)
      return
    end
    pname = verbatim(player.name.remove('`'))

    # Construct replay data
    replays = replays.map{ |replay| replay.pack('C*') }
    replays = self.dump_demo(replays)
    replays = Zlib::Deflate.deflate(replays, 9)

    # Compute request parts
    klass = self.class.to_s.downcase
    klass = 'level' if klass == 'userlevel'
    qt = TYPES[klass.capitalize][:qt]
    score = (1000 * round_score(score)).round.to_s
    version = [2842, 3009, 3096].include?(self.id) ? 1 : 2
    hash = self.map.hash(c: true, v: version)
    if !hash
      err("Couldn't compute #{fname} hash, not submitting #{pname} score.", discord: log)
      return
    end
    hash = sha1(hash + score, c: true)

    parts = [
      { name: 'user_id',     binary: false, value: player.metanet_id },
      { name: "#{klass}_id", binary: false, value: self.id           },
      { name: 'qt',          binary: false, value: qt                },
      { name: 'size',        binary: false, value: replays.size      },
      { name: 'score',       binary: false, value: score             },
      { name: 'ninja_check', binary: true , value: hash              },
      { name: 'replay_data', binary: true , value: replays           }
    ]

    # Perform HTTP POST request
    res = post_form(
      path: '/prod/steam/submit_score',
      args: { user_id: player.metanet_id, steam_id: player.steam_id },
      parts: parts
    )
    if !res
      err("Failed to submit score by #{pname} to #{fname} (bad post-form).", discord: log)
      return
    elsif res == INVALID_RESP
      err("Failed to submit score by #{pname} to #{fname} (inactive Steam ID).", discord: log)
      return
    end
    JSON.parse(res)
  rescue => e
    lex(e, "Failed to submit score by #{pname} to #{fname}.", discord: log)
    nil
  end

  def submit_zero_score(log: false)
    score = 0
    replay_count = TYPES[self.class.to_s][:size] rescue 1
    replays = [[]] * replay_count
    player = Player.find_by(metanet_id: OUTTE_ID)
    submit_score(score, replays, player, log: log)
  end

  def correct_ties(score_hash)
    score_hash.sort_by{ |s| [-s['score'], s['replay_id']] }
  end
end

# Common functionality for all models that have leaderboards, whether we download
# from N++'s server (Metanet campaign, userlevels) or receive them directly from
# CLE (mappacks).
module Highscoreable
  def self.format_rank(rank)
    rank.nil? ? '--' : rank.to_s.rjust(2, '0')
  end

  # Fetches list of highscoreables with largest/smallest difference between
  # the 0th and Nth scores.
  # @par small:     Whether to find smallest or largest differences
  # @par player_id: Include only levels where the 0th is owned by player
  def self.spreads(n, type, tabs, small = false, player_id = nil, full = false, mappack = nil, board = 'hs')
    # Sanitize parameters
    n      = n.clamp(0,19)
    type   = ensure_type(type, mappack: !mappack.nil?)
    type   = type.mappack if mappack
    klass  = mappack ? MappackScore.where(mappack: mappack) : Score
    sfield = mappack ? "score_#{board}" : 'score'
    rfield = mappack ?  "rank_#{board}" : 'rank'
    scale  = mappack && board == 'hs' ? 60.0 : 1
    bench(:start) if BENCHMARK

    # Retrieve player's 0ths to filter scores, if necessary
    if !player_id.nil?
      ids = klass.where(highscoreable_type: type.to_s, rfield => 0, player_id: player_id)
      ids = ids.where(tab: tabs) if !tabs.empty?
      ids = ids.pluck('highscoreable_id')
    end

    # Fetch required scores and compute spreads
    ret1 = klass.where(highscoreable_type: type.to_s, rfield => 0)
    ret1 = ret1.where(tab: tabs) if !tabs.empty?
    ret1 = ret1.where(highscoreable_id: ids) if !player_id.nil?
    ret1 = ret1.pluck(:highscoreable_id, sfield).to_h

    ret2 = klass.where(highscoreable_type: type.to_s, rfield => n)
    ret2 = ret2.where(tab: tabs) if !tabs.empty?
    ret2 = ret2.where(highscoreable_id: ids) if !player_id.nil?
    ret2 = ret2.pluck(:highscoreable_id, sfield).to_h

    ret = ret2.map{ |id, s| [id, (ret1[id] - s).abs / scale] rescue nil }
              .compact
              .sort_by{ |id, s| small ? s : -s }
    ret = ret.take(NUM_ENTRIES) if !full
    ret = ret.to_h

    # Retrieve level names
    lnames = type.where(id: ret.keys)
                 .pluck(:id, :name)
                 .to_h

    # Retrieve player names
    pnames = klass.where(highscoreable_type: type.to_s, highscoreable_id: ret.keys, rfield => 0)
                  .joins("INNER JOIN players ON players.id = player_id")
                  .pluck('highscoreable_id', 'IF(display_name IS NOT NULL, display_name, name)')
                  .to_h

    # Format response
    ret = ret.map{ |id, s| [lnames[id], s, pnames[id]] }
    bench(:step) if BENCHMARK
    ret
  end

  # @par player_id: Exclude levels where the player already has a score
  # @par maxed:     Filter and sort differently for maxes and maxables
  # @par rank:      Return rankings of people with most scores in maxed / maxable levels
  def self.ties(type, tabs, player_id = nil, maxed = false, rank = false, mappack = nil, board = 'hs')
    type = ensure_type(type)
    bench(:start) if BENCHMARK

    # Prepare params
    type = type.mappack if mappack
    table = type.table_name
    rfield = !mappack ? 'rank' : "rank_#{board}"
    trfield = !mappack ? 'tied_rank' : "tied_rank_#{board}"

    # Retrieve highscoreables with more ties for 0th
    klass = mappack ? MappackScore : Score
    ret = !tabs.empty? ? klass.where(tab: tabs) : klass
    ret = ret.where(mappack: mappack) if mappack
    ret = ret.joins("INNER JOIN #{table} ON #{table}.id = highscoreable_id")
             .where(highscoreable_type: type, trfield => 0)
             .group(:highscoreable_id)
             .order(!maxed || mappack ? 'count(highscoreable_id) desc' : '', :highscoreable_id)
             .having("count(highscoreable_id) >= #{MIN_TIES}")
             .having(!player_id.nil? ? 'amount = 0' : '')
             .pluck('highscoreable_id', 'count(highscoreable_id)', 'name', !player_id.nil? ? "count(if(player_id = #{player_id}, player_id, NULL)) AS amount" : '1')
             .map{ |a, b, c| [a, [b, c]] }
             .to_h

    # Retrieve score counts for each highscoreable
    counts = klass.where(highscoreable_type: type, highscoreable_id: ret.keys)
                  .group(:highscoreable_id)
                  .order('count(id) desc')
                  .count(:id) unless mappack

    # Filter highscoreables
    maxed ? ret.select!{ |id, arr| arr[0] >= (!mappack ? counts[id] : 20) } : ret.select!{ |id, arr| arr[0] < (!mappack ? counts[id] : 20) } if !maxed.nil?

    if rank
      # Return only IDs, for the rankings
      ret = ret.keys
    else
      # Fetch player names owning the 0ths on said highscoreables
      names = klass.where(highscoreable_type: type, highscoreable_id: ret.keys, rfield => 0)
                    .joins("INNER JOIN players ON players.id = player_id")
                    .pluck('highscoreable_id', 'IF(display_name IS NOT NULL, display_name, name)')
                    .to_h

      # Format response
      ret = ret.map{ |id, arr| [arr[1], arr[0], names[id]] }
    end
    bench(:step) if BENCHMARK
    ret
  rescue => e
    lex(e, 'Failed to compute maxables or maxes')

  end

  # Returns episodes or stories sorted by cleanliness
  def self.cleanliness(type, tabs, rank = 0, mappack = nil, board = 'hs')
    # Integrity checks
    raise "Attempted to compute cleanliness of level" if type.include?(Levelish)
    raise "Attempted to compute non-hs/sr cleanliness" if !['hs', 'sr'].include?(board)

    # Setup params
    type   = type.to_s
    table  = type.downcase.pluralize
    table  = table.prepend('mappack_') if mappack
    count  = type == 'Episode' ? 5 : 25
    type   = type.prepend('Mappack') if mappack
    rfield = !mappack ? 'rank' : "rank_#{board}"
    sfield = !mappack ? 'score' : "score_#{board}"
    sfield += " / 60" if mappack && board == 'hs'
    offset = board == 'hs' ? 90 * (count - 1) : 0

    # Begin queries
    bench(:start) if BENCHMARK
    query = !mappack ? Score : MappackScore.where(mappack: mappack)
    query = !tabs.empty? ? query.where(tab: tabs) : query

    # Fetch level 0th sums
    lvls = query.where(highscoreable_type: mappack ? 'MappackLevel' : 'Level', rfield => 0)
                .joins("INNER JOIN #{table} ON #{table}.id = highscoreable_id DIV #{count}")
                .group("highscoreable_id DIV #{count}")
                .sum(sfield)

    # Fetch episode/story 0th scores and compute cleanliness
    ret = query.where(highscoreable_type: type, rfield => rank)
               .joins("INNER JOIN #{table} ON #{table}.id = highscoreable_id")
               .joins('INNER JOIN players ON players.id = player_id')
               .pluck("#{table}.id", "#{table}.name", sfield, 'IF(display_name IS NULL, players.name, display_name)')
               .map{ |id, e, s, p| [e, round_score((lvls[id] - s).abs - offset), p] }
    bench(:step) if BENCHMARK
    ret
  rescue => e
    lex(e, 'Failed to compute cleanlinesses')
    nil
  end

  def is_mappack?
    self.is_a?(MappackHighscoreable)
  end

  def is_level?
    self.is_a?(Levelish)
  end

  def is_episode?
    self.is_a?(Episodish)
  end

  def is_story?
    self.is_a?(Storyish)
  end

  # Arguments are unused, but they're necessary to be compatible with the corresponding
  # function in MappackHighscoreable
  def leaderboard(*args, **kwargs)
    ul = self.is_a?(Userlevel)
    attr_names = %W[rank id score name metanet_id cool star]
    attrs = [
      'rank',
      "#{ul ? 'userlevel_' : ''}scores.id",
      'score',
      ul ? 'name' : 'IF(display_name IS NOT NULL, display_name, name)',
      'metanet_id'
    ]
    attrs.push('cool', 'star') if !ul
    if !kwargs.key?(:pluck) || kwargs[:pluck]
      pclass = ul ? 'userlevel_players' : 'players'
      scores.joins("INNER JOIN #{pclass} ON #{pclass}.id = player_id")
            .pluck(*attrs).map{ |s| attr_names.zip(s).to_h }
    else
      scores
    end
  end

  def format_scores_board(board = 'hs', np: 0, sp: 0, ranks: 20.times.to_a, full: false, cools: true, stars: true)
    mappack = self.is_a?(MappackHighscoreable)
    userlevel = self.is_a?(Userlevel)
    hs = board == 'hs'

    # Reload scores, otherwise sometimes recent changes aren't in memory
    scores.reload
    boards = leaderboard(board, aliases: true, truncate: full ? 0 : 20).each_with_index.select{ |_, r|
      full ? true : ranks.include?(r)
    }.sort_by{ |_, r| full ? r : ranks.index(r) }

    # Calculate padding
    name_padding = np > 0 ? np : boards.map{ |s, _| s['name'].to_s.length }.max
    field = !mappack ? 'score' : "score_#{board}"
    score_padding = sp > 0 ? sp : boards.map{ |s, _|
      mappack && hs || userlevel ? s[field] / 60.0 : s[field]
    }.max.to_i.to_s.length + (!mappack || hs ? 4 : 0)

    # Print scores
    boards.map{ |s, r|
      Scorish.format(name_padding, score_padding, cools: cools, stars: stars, mode: board, t_rank: r, mappack: mappack, userlevel: userlevel, h: s)
    }
  end

  def format_scores(np: 0, sp: 0, mode: 'hs', ranks: 20.times.to_a, join: true, full: false, cools: true, stars: true)
    if !self.is_a?(MappackHighscoreable) || mode != 'dual'
      ret = format_scores_board(mode, np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars)
      ret = ["This #{self.class.to_s.remove('Mappack').downcase} has no scores!"] if ret.size == 0
      ret = ret.join("\n") if join
      return ret
    end
    board_hs = format_scores_board('hs', np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars)
    board_sr = format_scores_board('sr', np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars)
    length_hs = board_hs.first.length rescue 0
    length_sr = board_sr.first.length rescue 0
    size = [board_hs.size, board_sr.size].max
    if size == 0
      ret = ["This #{self.class.to_s.remove('Mappack').downcase} has no scores!"]
      ret = ret.join("\n") if join
      return ret
    end
    board_hs = board_hs.ljust(size, ' ' * length_hs)
    board_sr = board_sr.ljust(size, ' ' * length_sr)
    header = '     ' + 'Highscore'.center(length_hs - 4) + '   ' + 'Speedrun'.center(length_sr - 4)
    ret = [header, *board_hs.zip(board_sr).map{ |hs, sr| hs.sub(':', ' │') + ' │ ' + sr[4..-1] }]
    ret = ret.join("\n") if join
    ret
  end

  def difference(old, board = 'hs')
    rfield = is_mappack? ? "rank_#{board}" : 'rank'
    sfield = is_mappack? ? "score_#{board}" : 'score'
    scale  = is_mappack? && board == 'hs' ? 60.0 : 1
    leaderboard(board, pluck: false).map do |score|
      oldscore = old.find{ |o|
        o['player_id'] == score.player_id && (is_mappack? ? !o[rfield].nil? : true)
      }
      change = {
        rank:  oldscore[rfield] - score[rfield],
        score: (score[sfield] - oldscore[sfield]) / scale
      } if oldscore
      { score: score, change: change }
    end
  end

  # Format Top20 changes between the current boards and 'old' for a single board (e.g. hs / sr)
  #   diff_score : Show score changes
  #   empty      : Return an empty array if there are no differences
  def format_difference_board(old, board = 'hs', diff_score: true, empty: true)
    difffs = difference(old, board)
    return [] if empty && difffs.all?{ |d| !d[:change].nil? && d[:change][:score].abs < 0.01 && d[:change][:rank] == 0 }

    boards = leaderboard(board, pluck: false)
    sfield = is_mappack? ? "score_#{board}" : 'score'
    scale  = is_mappack? && board == 'hs' ? 60.0 : 1
    offset = is_mappack? && board == 'sr' ? 0 : 4

    name_padding   = boards.map{ |s| s.player.print_name.length }.max
    score_padding  = boards.map{ |s| (s[sfield] / scale).abs.to_i }.max.to_s.length + offset
    rank_padding   = difffs.map{ |d| d[:change] }.compact.map{ |c| c[:rank].abs.to_i  }.max.to_s.length
    change_padding = difffs.map{ |d| d[:change] }.compact.map{ |c| c[:score].abs.to_i }.max.to_s.length + offset

    difffs.each_with_index.map{ |o, i|
      c = o[:change]
      if c
        if c[:score].abs < 0.01 && c[:rank] == 0
          diff = '━'
          diff += ' ' * rank_padding
          diff += ' ' * (change_padding + 2) if diff_score
        else
          rank = "━▲▼"[c[:rank] <=> 0]
          rank += c[:rank] != 0 ? "%-#{rank_padding}d" % [c[:rank].abs] : ' ' * rank_padding
          score = c[:score] > 0 ? '+' : '-'
          fmt = c[:score].is_a?(Integer) ? 'd' : '.3f'
          score += "%#{change_padding}#{fmt}" % [c[:score].abs]
          diff = rank
          if diff_score
            diff += c[:score].abs > 0.01 ? ' ' + score : ' ' * (change_padding + 2)
          end
        end
      else
        diff = '❗' + ' ' * rank_padding
        diff += ' ' * (change_padding + 2) if diff_score
      end
      "#{o[:score].format(name_padding, score_padding, false, board, i)} #{diff}"
    }
  rescue
    []
  end

  # Format Top20 changes between the current boards and 'old'
  def format_difference(old, board = 'hs')
    if !is_mappack? || board != 'dual'
      return format_difference_board(old, board).join("\n")
    end

    diffs_hs = format_difference_board(old, 'hs', diff_score: false, empty: false)
    diffs_sr = format_difference_board(old, 'sr', diff_score: false, empty: false)
    empty_hs = diffs_hs.count{ |d| d.strip[-1] == '━' } == diffs_hs.size
    empty_sr = diffs_sr.count{ |d| d.strip[-1] == '━' } == diffs_sr.size
    return '' if diffs_hs.empty? && diffs_sr.empty? || empty_hs && empty_sr
    length_hs = diffs_hs.first.length rescue 0
    length_sr = diffs_sr.first.length rescue 0
    size = [diffs_hs.size, diffs_sr.size].max
    diffs_hs = diffs_hs.ljust(size, ' ' * length_hs)
    diffs_sr = diffs_sr.ljust(size, ' ' * length_sr)
    header = '     ' + 'Highscore'.center(length_hs - 4) + '   ' + 'Speedrun'.center(length_sr - 4)
    ret = [header, *diffs_hs.zip(diffs_sr).map{ |hs, sr| hs.sub(':', ' │') + ' │ ' + sr[4..-1] }]
    ret.join("\n")
  rescue
    nil
  end

  # Format the header for the Top20 changes
  def format_difference_header(diff, past: false)
    article = past ? 'last' : 'this'
    period = is_level? ? 'day' : is_episode? ? 'week' : 'month'
    since = is_level? ? (past ? 'yesterday' : 'today') : is_episode? ? "#{article} week" : "#{article} month"
    type = is_story? ? 'column' : self.class.to_s.downcase.remove('mappack')
    mappack = is_mappack? ? self.mappack.code.upcase : ''

    if diff.nil?
      "Failed to calculate top20 changes on #{since}'s #{mappack} #{type} of the #{period}, #{format_name}.".squish
    elsif diff.strip.empty?
      "There #{past ? 'were' : 'have been'} no top20 changes on #{since}'s #{mappack} #{type} of the #{period}, #{format_name}.".squish
    else
      header = "Top20 changes on #{since}'s #{mappack} #{type} of the #{period}, #{format_name}"
      format_header(header) + format_block(diff)
    end
  end

  def find_coolness
    max = scores.map(&:score).max.to_i.to_s.length + 4
    s1  = scores.first.score.to_s
    s2  = scores.last.score.to_s
    d   = (0...max).find{ |i| s1[i] != s2[i] }
    if !d.nil?
      d     = -(max - d - 5) - (max - d < 4 ? 1 : 0)
      cools = scores.size.times.find{ |i| scores[i].score < s1.to_f.truncate(d) }
    else
      cools = 0
    end
    cools
  end

  # The next function navigates through highscoreables.
  # @par1: Offset (1 = next, -1 = prev, 2 = next tab, -2 = prev tab).
  # @par2: Enable tab change with +-1, otherwise clamp to current tab
  #
  # Note:
  #   We deal with edge cases separately because we change the natural order
  #   of tabs, so the ID is not always what we want (the internal order of
  #   tabs is SI, S, SL, ?, SU, !, but we want SI, S, SU, SL, ?, !, as it
  #   appears in the game).
  def nav(c, tab: true)
    klass = self.class.to_s.remove("Mappack")
    short = klass != 'Level'
    mode = self.mode rescue 0
    tabs = TABS_NEW.select{ |k, v| v[:mode] == mode && (short ? !v[:secret] : true) }
                   .sort_by{ |k, v| v[:index] }.to_h
    i = tabs.keys.index(self.tab.to_sym)
    tabs = tabs.values
    old_id = self.is_a?(MappackHighscoreable) ? inner_id : id

    # Scale factor to translate Level IDs to Episode / Story IDs
    type = TYPES[klass]
    fo = 5 ** type[:id]
    offset = old_id - tabs[i][:start] / fo

    case c
    when 1
      new_tab = tabs[(i + 1) % tabs.size]
      fs = type[:id] == 2 && tabs[i][:x] ? 30 : fo
      if old_id < tabs[i][:start] / fo + tabs[i][:size] / fs - 1
        new_id = old_id + 1
      else
        new_id = tab ? new_tab[:start] / fo : old_id
      end
    when -1
      new_tab = tabs[(i - 1) % tabs.size]
      fs = type[:id] == 2 && new_tab[:x] ? 30 : fo
      if old_id > tabs[i][:start] / fo
        new_id = old_id - 1
      else
        new_id = tab ? new_tab[:start] / fo + new_tab[:size] / fs - 1 : old_id
      end
    when 2
      new_tab = tabs[(i + 1) % tabs.size]
      fs = type[:id] == 2 && new_tab[:x] ? 30 : fo
      new_id = new_tab[:start] / fo + offset.clamp(0, new_tab[:size] / fs - 1)
    when -2
      new_tab = tabs[(i - 1) % tabs.size]
      fs = type[:id] == 2 && new_tab[:x] ? 30 : fo
      new_id = new_tab[:start] / fo + offset.clamp(0, new_tab[:size] / fs - 1)
    else
      new_id = old_id
    end

    new_id += type[:slots] * mappack.id if self.is_a?(MappackHighscoreable)
    self.class.find(new_id) rescue self
  rescue => e
    lex(e, 'Failed to navigate highscoreable')
    self
  end

  # Shorcuts for the above
  def next_h(**args)
    nav(1, **args)
  end

  def prev_h(**args)
    nav(-1, **args)
  end

  def next_t(**args)
    nav(2, **args)
  end

  def prev_t(**args)
    nav(-2, **args)
  end
end

# Implemented by Level, MappackLevel and Userlevel
module Levelish
  # Return the Map object (containing map data), if it exists
  def map
    self.is_a?(Level) ? MappackLevel.find_by(id: id) : self
  end

  # Return the corresponding Level object of a MappackLevel
  # 'null' determines whether to return nil or self if no equivalent exists
  def vanilla(null = false)
    return self if self.is_a?(Level) || self.is_a?(Userlevel)
    level = Level.find_by(id: id)
    return level ? level : null ? nil : self
  end

  def story
    self.episode.story
  end

  def format_name
    str = "#{verbatim(longname)} (#{name.remove('MET-')})"
    str += " by #{verbatim(author)}" if author rescue ''
    str
  end

  def format_challenges
    pad = challenges.map{ |c| c.count }.max
    challenges.map{ |c| c.format(pad) }.join("\n")
  end

  # Dump demo header for communications with N++
  def demo_header(framecount)
    # Precompute some values
    m = mode.to_i
    n = m == 1 ? 2 : 1
    framecount /= n
    size = framecount * n + 26 + 4 * n
    h_id = self.is_a?(MappackHighscoreable) ? inner_id : id

    # Build header
    header = [0].pack('C')               # Type (0 lvl, 1 lvl in ep, 2 lvl in sty)
    header << [size].pack('L<')          # Data length
    header << [1].pack('L<')             # Replay version
    header << [framecount].pack('L<')    # Data size in bytes
    header << [h_id].pack('L<')          # Level ID
    header << [m].pack('L<')             # Mode (0-2)
    header << [0].pack('L<')             # ?
    header << (m == 1 ? "\x03" : "\x01") # Ninja mask (1,3)
    header << [-1, -1].pack("l<#{n}")    # ?

    # Return
    header
  end

  # Dumps the level's demo in the format N++ uses for server communications
  def dump_demo(demos)
    demo_header(demos[0].size) + demos[0]
  end
end

class Level < ActiveRecord::Base
  include Downloadable
  include Highscoreable
  include Levelish
  has_many :scores, ->{ order(:rank) }, as: :highscoreable
  has_many :videos, as: :highscoreable
  has_many :challenges
  has_many :level_aliases
  belongs_to :episode
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  def self.mappack
    MappackLevel
  end

  def self.vanilla
    Level
  end

  def add_alias(a)
    LevelAlias.find_or_create_by(level: self, alias: a)
  end
end

# Implemented by Episode and MappackEpisode
module Episodish

  # Return the Map object (containing map data), if it exists
  def map
    self.is_a?(Episode) ? MappackEpisode.find_by(id: id) : self
  end

  def vanilla(null = false)
    return self if self.is_a?(Episode)
    episode = Episode.find_by(id: id)
    return episode ? episode : null ? nil : self
  end

  def format_name
    "#{name.remove('MET-')}"
  end

  def cleanliness(rank = 0, board = 'hs')
    klass  = !is_mappack? ? Score : MappackScore
    rfield = !is_mappack? ? 'rank' : "rank_#{board}"
    sfield = !is_mappack? ? 'score' : "score_#{board}"
    scale  = is_mappack? && board == 'hs' ? 60.0 : 1.0
    offset = !is_mappack? || board == 'hs' ? 4 * 90.0 : 0.0

    level_scores = klass.where(highscoreable: levels, rfield => 0).sum(sfield) rescue nil
    episode_score = scores.find_by(rfield => rank)[sfield] rescue nil
    return nil if level_scores.nil? || episode_score.nil?
    diff = (level_scores - episode_score).abs / scale - offset
    diff = diff.to_i if is_mappack? && board != 'hs'

    diff
  rescue => e
    lex(e, "Failed to compute cleanliness of episode #{self.name}")
    nil
  end

  def ownage
    owner = scores[0].player
    lvls = Score.where(highscoreable: levels, rank: 0).count("if(player_id = #{owner.id}, 1, NULL)")
    [name, lvls == 5, owner.name]
  end

  def splits(rank = 0, board: 'hs')
    mappack = self.is_a?(MappackHighscoreable)
    scoref  = !mappack ? 'score' : "score_#{board}"
    start   = mappack && board == 'sr' ? 0 : 90.0
    factor  = mappack && board == 'hs' ? 60.0 : 1
    offset  = !mappack || board == 'hs' ? 90.0 : 0
    scores  = levels.map{ |l| l.leaderboard(board)[rank][scoref] }
    splits_from_scores(scores, start: start, factor: factor, offset: offset)
  rescue => e
    lex(e, 'Failed to compute splits')
    nil
  end

  # Header of an episode demo:
  #   4B - Magic number (0xffc0038e)
  #  20B - Block length for each level demo (5 * 4B)
  def demo_header(framecounts)
    header_size = 26 + 4 * (mode == 1 ? 2 : 1)
    replay = [MAGIC_EPISODE_VALUE].pack('L<')
    replay << framecounts.map{ |f| f + header_size }.pack('L<5')
  end

  # Dumps the episodes's demo in the format N++ uses for server communications
  def dump_demo(demos)
    replay = demo_header(demos.map(&:size))
    levels.each_with_index{ |l, i|
      replay << l.demo_header(demos[i].size)
      replay << demos[i]
    }
    replay
  end
end

class Episode < ActiveRecord::Base
  include Downloadable
  include Highscoreable
  include Episodish
  has_many :scores, ->{ order(:rank) }, as: :highscoreable
  has_many :videos, as: :highscoreable
  has_many :levels
  belongs_to :story
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  def self.mappack
    MappackEpisode
  end

  def self.vanilla
    Episode
  end

  def self.ownages(tabs)
    bench(:start) if BENCHMARK
    query = !tabs.empty? ? Score.where(tab: tabs) : Score
    # retrieve episodes with all 5 levels owned by the same person
    epis = query.where(highscoreable_type: 'Level', rank: 0)
                .joins('INNER JOIN levels ON levels.id = scores.highscoreable_id')
                .group('levels.episode_id')
                .having('cnt = 1')
                .pluck('levels.episode_id', 'MIN(scores.player_id)', 'COUNT(DISTINCT scores.player_id) AS cnt')
                .map{ |e, p, c| [e, p] }
                .to_h
    # retrieve respective episode 0ths
    zeroes = query.where(highscoreable_type: 'Episode', highscoreable_id: epis.keys, rank: 0)
                  .joins('INNER JOIN players ON players.id = scores.player_id')
                  .pluck('scores.highscoreable_id', 'players.id')
                  .to_h
    # retrieve episode names
    enames = Episode.where(id: epis.keys)
                    .pluck(:id, :name)
                    .to_h
    # retrieve player names
    pnames = Player.where(id: epis.values)
                   .pluck(:id, :name, :display_name)
                   .map{ |a, b, c| [a, [b, c]] }
                   .to_h
    # keep only matches between the previous 2 result sets to obtain true ownages
    ret = epis.reject{ |e, p| p != zeroes[e] }
              .sort_by{ |e, p| e }
              .map{ |e, p| [enames[e], pnames[p][1].nil? ? pnames[p][0] : pnames[p][1]] }
    bench(:step) if BENCHMARK
    ret
  end
end

# Implemented by Story and MappackStory
module Storyish
  # Return the Map object (containing map data), if it exists
  def map
    self.is_a?(Story) ? MappackStory.find_by(id: id) : self
  end

  def vanilla(null = false)
    return self if self.is_a?(Story)
    story = Story.find_by(id: id)
    return story ? story : null ? nil : self
  end

  def format_name
    "#{name.remove('MET-')}"
  end

  def levels
    (is_mappack? ? MappackLevel : Level).where("id DIV 25 = #{id}").order(:id)
  end

  def cleanliness(rank = 0, board = 'hs')
    klass  = !is_mappack? ? Score : MappackScore
    rfield = !is_mappack? ? 'rank' : "rank_#{board}"
    sfield = !is_mappack? ? 'score' : "score_#{board}"
    scale  = is_mappack? && board == 'hs' ? 60.0 : 1.0
    offset = !is_mappack? || board == 'hs' ? 24 * 90.0 : 0.0

    level_scores = klass.where(highscoreable: levels, rfield => 0).sum(sfield) rescue nil
    story_score = scores.find_by(rfield => rank)[sfield] rescue nil
    return nil if level_scores.nil? || story_score.nil?
    diff = (level_scores - story_score).abs / scale - offset
    diff = diff.to_i if is_mappack? && board != 'hs'

    diff
  rescue => e
    lex(e, "Failed to compute cleanliness of episode #{self.name}")
    nil
  end

  # Header of a story demo:
  #   4B - Magic number (0xff3800ce)
  #   4B - Demo data block total size
  # 100B - Block length for each level demo (25 * 4B)
  def demo_header(framecounts)
    header_size = 26 + 4 * (mode == 1 ? 2 : 1)
    replay = [MAGIC_STORY_VALUE].pack('L<')
    replay << [framecounts.sum + 25 * header_size].pack('L<')
    replay << framecounts.map{ |f| f + header_size }.pack('L<25')
  end

  # Dumps the story's demo in the format N++ uses for server communications
  def dump_demo(demos)
    replay = demo_header(demos.map(&:size))
    episodes.each_with_index{ |e, j|
      e.levels.each_with_index{ |l, i|
        replay << l.demo_header(demos[5 * j + i].size)
        replay << demos[5 * j + i]
      }
    }
    replay
  end
end

class Story < ActiveRecord::Base
  include Downloadable
  include Highscoreable
  include Storyish
  has_many :scores, ->{ order(:rank) }, as: :highscoreable
  has_many :videos, as: :highscoreable
  has_many :episodes
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  def self.mappack
    MappackStory
  end

  def self.vanilla
    Story
  end
end

# Implemented by Score and MappackScore
module Scorish

  def self.format(name_padding = DEFAULT_PADDING, score_padding = 0, cools: true, stars: true, mode: 'hs', t_rank: nil, mappack: false, userlevel: false, h: {})
    mode = 'hs' if mode.nil?
    hs = mode == 'hs'

    # Compose each element
    t_star   = mappack || !stars ? '' : (h['star'] ? '*' : ' ')
    t_rank   = !mappack ? h['rank'] : (t_rank || 0)
    t_rank   = Highscoreable.format_rank(t_rank)
    t_player = format_string(h['name'], name_padding)
    f_score  = !mappack ? 'score' : "score_#{mode}"
    s_score  = mappack && hs || userlevel ? 60.0 : 1
    t_score  = h[f_score] / s_score
    t_fmt    = !mappack || hs ? "%#{score_padding}.3f" : "%#{score_padding}d"
    t_score  = t_fmt % [t_score]
    t_cool   = !mappack && cools && h['cool'] ? " 😎" : ""

    # Put everything together
    "#{t_star}#{t_rank}: #{t_player} - #{t_score}#{t_cool}"
  end

  def format(name_padding = DEFAULT_PADDING, score_padding = 0, cools = true, mode = 'hs', t_rank = nil)
    h = self.as_json
    h['name'] = player.print_name if !h.key?('name')
    Scorish.format(name_padding, score_padding, cools: cools, mode: mode, t_rank: t_rank, mappack: self.is_a?(MappackScore), h: h)
  end
end

class Score < ActiveRecord::Base
  include Scorish
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
#  default_scope -> { select("scores.*, score * 1.000 as score")} # Ensure 3 correct decimal places
  enum tab:  TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  # Filter all scores by type, tabs, rank, etc.
  def self.filter(
      level   = 2,     # Which filters to apply
      player  = nil,   # Filter scores by player
      type    = [],    # Filter scores by type (Level, Episode, Story)
      tabs    = [],    # Filter scores by tab
      a       = 0,     # Lower rank
      b       = 20,    # Upper rank
      ties    = false, # Include ties in the above rank range
      cool    = false, # Include only cool scores
      star    = false, # Include only star scores
      mappack = nil,   # Mappack (nil = Metanet)
      mode    = 'hs',  # Playing mode
      old     = false  # Include obsolete scores (only makes sense for mappacks)
    )

    # Adapt params for mappacks, if necessary
    type = fix_type(type)
    mode = 'hs' if !['hs', 'sr'].include?(mode)
    ttype = ties ? 'tied_rank' : 'rank'
    ttype += "_#{mode}" if !mappack.nil?
    if !mappack.nil?
      klass = MappackScore.where(mappack: mappack)
      klass = klass.where.not(ttype.to_sym => nil) unless old
    else
      klass = Score
    end

    # Build the 3 levels of successive filters
    queries = []
    queries.push(
      klass.where(!player.nil? ? { player: player } : nil)
           .where(highscoreable_type: type)
           .where(!tabs.empty? ? { tab: tabs } : nil)
    )
    queries.push(
      queries.last.where(!a.blank?  ? "#{ttype} >= #{a}" : nil)
                  .where(!b.blank?  ? "#{ttype} < #{b}"  : nil)
    )
    queries.push(
      queries.last.where(cool ? { cool: true } : nil)
                  .where(star ? { star: true } : nil)
    )

    # Return the appropriate filter
    queries[level.clamp(0, queries.size - 1)]
  end

  # RANK players based on a variety of different filters and characteristic
  def self.rank(
      ranking: :rank, # Ranking type.             Def: Regular scores.
      type:    nil,   # Highscoreable type.       Def: Levels and episodes.
      tabs:    [],    # Highscoreable tabs.       Def: All tabs (SI, S, SU, SL, ?, !).
      players: [],    # Players to ignore.        Def: None.
      a:       0,     # Bottom rank of scores.    Def: 0th.
      b:       20,    # Top rank of scores.       Def: 19th.
      ties:    false, # Include ties or not.      Def: No.
      cool:    false, # Only include cool scores. Def: No.
      star:    false, # Only include * scores.    Def: No.
      mappack: nil,   # Mappack.                  Def: None.
      board:   'hs'   # Highscore or speedrun.    Def: Highscore.
    )
    board = 'hs' if board.nil?

    # Mappack rankings do not support excluding players yet
    players = [] if !mappack.nil?

    # Most rankings which exclude players need to be computed completely
    # differently, so we use another function.
    if !players.empty? && [:rank, :tied_rank, :points, :avg_points, :avg_rank, :avg_lead].include?(ranking)
      return rank_exclude(ranking, type, tabs, ties, b - 1, players)
    end

    # Normalize parameters and filter scores accordingly
    type     = fix_type(type, [:avg_lead, :maxed, :maxable].include?(ranking))
    basetype = type
    type     = [type].flatten.map{ |t| "Mappack#{t.to_s}".constantize } if !mappack.nil?
    level    = 2
    level    = 1 if mappack || [:maxed, :maxable].include?(ranking)
    level    = 0 if [:tied_rank, :avg_lead, :singular, :score, :gp, :gm].include?(ranking)
    old      = [:gp, :gm].include?(ranking)
    scores   = filter(level, nil, type, tabs, a, b, ties, cool, star, mappack, board, old)
    scores   = scores.where.not(player: players) if !mappack.nil? && !players.empty?

    # Named fields
    rankf  = mappack.nil? ? 'rank' : "rank_#{board}"
    trankf = "tied_#{rankf}"
    scoref = mappack.nil? ? 'score' : "score_#{board}"
    scale  = !mappack.nil? && board == 'hs' ? 60.0 : 1.0

    # Perform specific rankings to filtered scores
    bench(:start) if BENCHMARK
    case ranking
    when :rank
      scores = scores.group(:player_id)
                     .order('count_id DESC')
                     .count(:id)
    when :tied_rank
      scores_w  = scores.where("#{trankf} >= #{a} AND #{trankf} < #{b}")
                        .group(:player_id)
                        .order('count_id DESC')
                        .count(:id)
      scores_wo = scores.where("#{rankf} >= #{a} AND #{rankf} < #{b}")
                        .group(:player_id)
                        .order('count_id DESC')
                        .count(:id)
      scores = scores_w.map{ |id, count| [id, count - scores_wo[id].to_i] }
                       .sort_by{ |id, c| -c }
    when :singular
      types = type.map{ |t|
        ids = scores.where(rankf => 1, trankf => b, highscoreable_type: t)
                    .pluck(:highscoreable_id)
        scores.where(rankf => 0, highscoreable_type: t, highscoreable_id: ids)
              .group(:player_id)
              .count(:id)
      }
      scores = types.map(&:keys).flatten.uniq.map{ |id|
        [id, types.map{ |t| t[id].to_i }.sum]
      }.sort_by{ |id, c| -c }
    when :points
      scores = scores.group(:player_id)
                     .order("SUM(#{ties ? "20 - #{trankf}" : "20 - #{rankf}"}) DESC")
                     .sum(ties ? "20 - #{trankf}" : "20 - #{rankf}")
    when :avg_points
      scores = scores.select("COUNT(player_id)")
                     .group(:player_id)
                     .having("COUNT(player_id) >= #{min_scores(basetype, tabs, false, a, b, star, mappack)}")
                     .order("avg(#{ties ? "20 - #{trankf}" : "20 - #{rankf}"}) DESC")
                     .average(ties ? "20 - #{trankf}" : "20 - #{rankf}")
    when :avg_rank
      scores = scores.select("COUNT(player_id)")
                     .group(:player_id)
                     .having("COUNT(player_id) >= #{min_scores(basetype, tabs, false, a, b, star, mappack)}")
                     .order("avg(#{ties ? trankf : rankf})")
                     .average(ties ? trankf : rankf)
    when :avg_lead
      scores = scores.where(rankf => [0, 1])
                     .pluck(:player_id, :highscoreable_id, scoref)
                     .group_by{ |s| s[1] }
                     .reject{ |h, s| s.size < 2 }
                     .map{ |h, s| [s[0][0], (s[0][2] - s[1][2]).abs] }
                     .group_by{ |s| s[0] }
                     .map{ |p, s| [p, s.map(&:last).sum.to_f / s.map(&:last).count / scale] }
                     .sort_by{ |p, s| -s }
    when :score
      asc = !mappack.nil? && board == 'sr'
      scores = scores.group(:player_id)
                     .order(asc ? 'COUNT(id) DESC' : '', "SUM(#{scoref}) #{asc ? 'ASC' : 'DESC'}")
                     .pluck("player_id, SUM(#{scoref}), COUNT(id)")
                     .map{ |id, score, count|
                        score = round_score(score.to_f / scale)
                        [
                          id,
                          asc ? score.to_i : score.to_f,
                          asc ? count : nil
                        ]
                      }
    when :maxed
      scores = scores.where(highscoreable_id: Highscoreable.ties(basetype, tabs, nil, true, true, mappack, board))
                     .where("#{trankf} = 0")
                     .group(:player_id)
                     .order("COUNT(id) DESC")
                     .count(:id)
    when :maxable
      scores = scores.where(highscoreable_id: Highscoreable.ties(basetype, tabs, nil, false, true, mappack, board))
                     .where("#{trankf} = 0")
                     .group(:player_id)
                     .order("COUNT(id) DESC")
                     .count(:id)
    when :gp
      query = scores.select(:player_id, :highscoreable_id, 'MAX(gold) AS gold')
                    .group(:player_id, :highscoreable_id)
      scores = MappackScore.from(query, :t)
                           .group(:player_id)
                           .order('sum_t_gold DESC')
                           .sum('t.gold')
    when :gm
      query = scores.select(:player_id, :highscoreable_id, 'MIN(gold) AS gold')
                    .group(:player_id, :highscoreable_id)
      scores = MappackScore.from(query, :t)
                           .group(:player_id)
                           .order('COUNT(*) DESC', 'SUM(gold) ASC')
                           .pluck('t.player_id', 'SUM(gold)', 'COUNT(*)')
    end

    # Find players and save their display name, if it exists, or their name otherwise
    players = Player.where(id: scores.map(&:first))
                    .pluck(:id, "IF(display_name IS NULL, name, display_name)")
                    .to_h
    ret = scores.map{ |s| [players[s[0]], s[1], s[2]] }

    # Zeroes are only permitted in a few rankings, and negatives nowhere
    ret.reject!{ |s| s[1] <= 0  } unless [:avg_rank, :avg_lead, :gp, :gm].include?(ranking)

    # Sort ONLY ties alphabetically by player
    ret.sort!{ |a, b| (a[1] <=> b[1]) != 0 ? 0 : a[0].downcase <=> b[0].downcase }

    bench(:step) if BENCHMARK
    ret
  end

  # Rankings excluding specified players. Less optimized than the function above
  # because I couldn't find a way to ignore them other than loop through all levels
  # on a one by one basis.
  def self.rank_exclude(ranking, type, tabs, ties = false, n = 0, players = [])
    bench(:start) if BENCHMARK
    pids = players.map(&:id)
    p = Player.pluck(:id).map{ |id| [id, 0] }.to_h
    q = Player.pluck(:id).map{ |id| [id, 0] }.to_h
    type = [Level, Episode] if type.nil?
    t_rank = 0
    t_score = -1

    [type].flatten.each{ |t|
      (tabs.empty? ? t.all : t.where(tab: tabs)).each{ |e|
        t_rank = 0
        t_score = 3000.0
        if ranking == :avg_lead
          a_id = -1
          a_score = -1
        end
        e.scores.reject{ |s| pids.include?(s.player_id) }.sort_by{ |s| s.rank }.each_with_index{ |s, i|
          if s.score < t_score
            t_rank = i
            t_score = s.score
          end
          case ranking
          when :rank
            (ties ? t_rank : i) <= n ? p[s.player_id] += 1 : break
          when :tied_rank
            t_rank <= n ? (i <= n ? next : p[s.player_id] += 1) : break
          when :points
            p[s.player_id] += 20 - (ties ? t_rank : i)
          when :avg_points
            p[s.player_id] += 20 - (ties ? t_rank : i)
            q[s.player_id] += 1
          when :avg_rank
            p[s.player_id] += ties ? t_rank : i
            q[s.player_id] += 1
          when :avg_lead
            if i == 0
              a_id = s.player_id
              a_score = s.score
            elsif i == 1
              p[a_id] += a_score - s.score
              q[a_id] += 1
            else
              break
            end
          end
        }
      }
    }

    bench(:step) if BENCHMARK
    p = p.select{ |id, c| q[id] > (ranking == :avg_lead ? 0 : min_scores(type, tabs)) }
         .map{ |id, c| [id, c.to_f / q[id]] }
         .to_h if [:avg_points, :avg_rank, :avg_lead].include?(ranking)
    p.sort_by{ |id, c| ranking == :avg_rank ? c : -c }
     .reject{ |id, c| c == 0 unless [:avg_rank, :avg_lead].include?(ranking) }
     .map{ |id, c| [Player.find(id), c] }
  end

  def self.total_scores(type, tabs, rank, secrets)
    bench(:start) if BENCHMARK
    tabs = [:SI, :S, :SL, :SS, :SU, :SS2] if tabs.empty?
    tabs = tabs - [:SS, :SS2] if !secrets
    ret = self.where(highscoreable_type: type.to_s, tab: tabs, rank: rank)
              .pluck('SUM(score)', 'COUNT(score)')
              .map{ |score, count| [round_score(score.to_f), count.to_i] }
    bench(:step) if BENCHMARK
    ret.first
  end

  # Tally levels by count of scores under certain conditions
  # If 'list' we return list, otherwise just the count
  def self.tally(list, type, tabs, ties = false, cool = false, star = false, a = 0, b = 20)
    type = fix_type(type)
    res = type.map{ |t|
      t_str = t.to_s.downcase.pluralize
      query = filter(2, nil, t, tabs, a, b, false, cool, star)
              .where(ties ? { tied_rank: 0 } : nil)
              .joins("INNER JOIN #{t_str} ON #{t_str}.id = scores.highscoreable_id")
              .group(:highscoreable_id)
              .order("cnt DESC, highscoreable_id ASC")
              .select("#{t_str}.name AS name, count(scores.id) AS cnt")
      if list
        l = query.map{ |h| [h.name, h.cnt] }
                 .group_by(&:last)
                 .map{ |c, hs| [c, hs.map(&:first)] }
                 .to_h
        (0..20).map{ |r| l.key?(r) ? l[r] : [] }
      else
        Score.from(query).group('cnt').order('cnt').count('cnt')
      end
    }
    if list
      (0..20).map{ |r| res.map{ |t| t[r] }.flatten }
    else
      (0..20).map{ |r| res.map{ |t| t[r].to_i }.sum }
    end
  end

  def self.holders
    bench(:start) if BENCHMARK
    sql = %{
      SELECT min, COUNT(min) FROM (
        SELECT MIN(rank) AS min FROM scores GROUP BY player_id
      ) AS t GROUP BY min;
    }.gsub(/\s+/, ' ').strip
    res = ActiveRecord::Base.connection.execute(sql).to_h
    ranks = { 0 => res[0] }
    (1..19).each{ |r| ranks[r] = ranks[r - 1] + res[r] }
    bench(:step) if BENCHMARK
    ranks
  rescue => e
    lex(e, 'Failed to compute unique holders')
    nil
  end

  def spread
    highscoreable.scores.find_by(rank: 0).score - score
  end

  def archive
    Archive.find_by(replay_id: replay_id, highscoreable: highscoreable)
  end

  def demo
    archive.demo
  end
end

class Player < ActiveRecord::Base
  alias_attribute :tweaks, :mappack_scores_tweaks
  has_many :scores
  has_many :rank_histories
  has_many :points_histories
  has_many :total_score_histories
  has_many :player_aliases
  has_many :mappack_scores
  has_many :mappack_scores_tweaks

  def self.histories(type, attrs, column)
    attrs[:highscoreable_type] ||= ['Level', 'Episode'] # Don't include stories
    hist = type.where(attrs).includes(:player)

    ret = Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = 0 } }

    hist.each do |h|
      ret[h.player.name][h.timestamp] += h.send(column)
    end

    ret
  end

  def self.rank_histories(rank, type, tabs, ties)
    attrs = {rank: rank, ties: ties}
    attrs[:highscoreable_type] = type.to_s if type
    attrs[:tab] = tabs if !tabs.empty?

    self.histories(RankHistory, attrs, :count)
  end

  def self.score_histories(type, tabs)
    attrs = {}
    attrs[:highscoreable_type] = type.to_s if type
    attrs[:tab] = tabs if !tabs.empty?

    self.histories(TotalScoreHistory, attrs, :score)
  end

  def self.points_histories(type, tabs)
    attrs = {}
    attrs[:highscoreable_type] = type.to_s if type
    attrs[:tab] = tabs if !tabs.empty?

    self.histories(PointsHistory, attrs, :points)
  end

  # Only works for 1 type at a time
  def self.comparison_(type, tabs, p1, p2)
    type = ensure_type(type)
    request = Score.where(highscoreable_type: type)
    request = request.where(tab: tabs) if !tabs.empty?
    t = type.to_s.downcase.pluralize
    bench(:start) if BENCHMARK
    ids = request.where(player: [p1, p2])
                 .joins("INNER JOIN #{t} ON #{t}.id = scores.highscoreable_id")
                 .group(:highscoreable_id)
                 .having('count(highscoreable_id) > 1')
                 .pluck('MIN(highscoreable_id)')
    scores1 = request.where(highscoreable_id: ids, player: p1)
                     .joins("INNER JOIN #{t} ON #{t}.id = scores.highscoreable_id")
                     .order(:highscoreable_id)
                     .pluck(:rank, :highscoreable_id, "#{t}.name", :score)
    scores2 = request.where(highscoreable_id: ids, player: p2)
                     .joins("INNER JOIN #{t} ON #{t}.id = scores.highscoreable_id")
                     .order(:highscoreable_id)
                     .pluck(:rank, :highscoreable_id, "#{t}.name", :score)
    scores = scores1.zip(scores2).group_by{ |s1, s2| s1[3] <=> s2[3] }
    s1 = request.where(player: p1)
                .where.not(highscoreable_id: ids)
                .joins("INNER JOIN #{t} ON #{t}.id = scores.highscoreable_id")
                .pluck(:rank, :highscoreable_id, "#{t}.name", :score)
                .group_by{ |s| s[0] }
                .map{ |r, s| [r, s.sort_by{ |s| s[1] }] }
                .to_h
    s2 = scores.key?(1)  ? scores[1].group_by{ |s1, s2| s1[0] }
                                   .map{ |r, s| [r, s.sort_by{ |s1, s2| s1[1] }] }
                                   .to_h
                         : {}
    s3 = scores.key?(0)  ? scores[0].group_by{ |s1, s2| s1[0] }
                                   .map{ |r, s| [r, s.sort_by{ |s1, s2| s1[1] }] }
                                   .to_h
                         : {}
    s4 = scores.key?(-1) ? scores[-1].group_by{ |s1, s2| s1[0] }
                                     .map{ |r, s| [r, s.sort_by{ |s1, s2| s2[1] }] }
                                     .to_h
                         : {}
    s5 = request.where(player: p2)
                .where.not(highscoreable_id: ids)
                .joins("INNER JOIN #{t} ON #{t}.id = scores.highscoreable_id")
                .pluck(:rank, :highscoreable_id, "#{t}.name", :score)
                .group_by{ |s| s[0] }
                .map{ |r, s| [r, s.sort_by{ |s| s[1] }] }
                .to_h
    bench(:step) if BENCHMARK
    [s1, s2, s3, s4, s5]
  end

  # Merges the results for each type using the previous method
  def self.comparison(type, tabs, p1, p2)
    type = [Level, Episode] if type.nil?
    ret = (0..4).map{ |t| (0..19).to_a.map{ |r| [r, []] }.to_h }
    [type].flatten.each{ |t|
      scores = comparison_(t, tabs, p1, p2)
      (0..4).each{ |i|
        (0..19).each{ |r|
          ret[i][r] += scores[i][r] if !scores[i][r].nil?
        }
      }
    }
    (0..4).each{ |i|
      (0..19).each{ |r|
        ret[i].delete(r) if ret[i][r].empty?
      }
    }
    ret
  end

  # Proxy a login request and register player
  def self.login(mappack, req)
    # Forward request to Metanet
    res = forward(req)
    invalid = res.nil? || res == INVALID_RESP
    raise 'Invalid response' if invalid && !LOCAL_LOGIN
    locally = false

    if !invalid  # Parse server response and register player in database
      json = JSON.parse(res)
      player = Player.find_or_create_by(metanet_id: json['user_id'].to_i)
      player.update(
        name:        json['name'].to_s,
        steam_id:    json['steam_id'].to_s,
        last_active: Time.now,
        active:      true
      )
    else         # If no response was received, attempt to log in locally
      locally = true

      # Parse any param we can find
      params = CGI.parse(req.request_uri.query)
      ids = [
        (req.query['user_id'].to_i rescue 0),
        (params['user_id'][0].to_i rescue 0)
      ].uniq
      ids.reject!{ |id| id <= 0 || id >= 10000000 }
      steamid = params['steam_id'][0].to_s rescue ''
      raise "No parameters found" if ids.empty? && steamid.empty?

      # Try to locate player in the database based on those params
      player = nil
      ids.each{ |id|
        player = Player.find_by(metanet_id: id)
        break if !player.nil?
      }
      player = Player.find_by(steam_id: steamid) if !player

      # Initialize response
      json = {}

      # Fill in fields
      json['steam_id'] = steamid
      if player
        json['user_id'] = player.metanet_id
        json['name'] = player.name
        player.update(steam_id: steamid) if !steamid.empty?
      else
        id = 0
        name = ''
        if !ids.empty?
          id = ids[0]
          name = "Player #{ids[0]}"
          player = Player.create_by(metanet_id: id, name: name)
          player.update(steam_id: steamid) if !steamid.empty?
        end
        json['user_id'] = id
        json['name'] = name
      end
      res = json.to_json
    end

    # Return the same response
    dbg("#{json['name'].to_s} (#{json['user_id']}) logged in#{locally ? ' locally' : ''} to #{mappack.to_s.upcase}")
    res
  rescue => e
    lex(e, 'Failed to proxy login request')
    return nil
  end

  def users(array: true)
    list = User.where(player_id: id)
    array ? list.to_a : list
  end

  def user
    users.first
  end

  def add_alias(a)
    PlayerAlias.find_or_create_by(player: self, alias: a)
  end

  def print_name
    (display_name || name).remove("`")
  end

  def format_name(padding = DEFAULT_PADDING)
    format_string(print_name, padding)
  end

  def truncate_name(length = MAX_PADDING)
    TRUNCATE_NAME ? print_name[0..length] : print_name
  end

  def sanitize_name
    sanitize_filename(print_name)
  end

  def scores_by_type_and_tabs(type, tabs, include = nil, mappack = nil, board = 'hs')
    # Fetch complete list of scores
    if mappack.nil?
      list = scores
    else
      list = mappack_scores.where(mappack: mappack)
    end

    # Filter scores by type and tabs
    type = normalize_type(type, mappack: !mappack.nil?)
    list = list.where(highscoreable_type: type)
    list = list.where(tab: tabs) if !tabs.empty?

    # Further filters for mappack scores
    if !mappack.nil?
      case board
      when 'hs', 'sr'
        list = list.where.not("rank_#{board}" => nil)
      when 'gm'
        list = list.where(gold: 0).uniq{ |s| s.highscoreable_id }
      end
    end

    # Optionally, include other tables in the result for performance reasons
    case include
    when :scores
      list.includes(highscoreable: [:scores])
    when :name
      list.includes(:highscoreable)
    else
      list
    end
  end

  def top_ns(n, type, tabs, ties)
    scores_by_type_and_tabs(type, tabs).where("#{ties ? "tied_rank" : "rank"} < #{n}")
  end

  # Fetch player's scores (or, alternatively, missing scores) filtering by many
  # parameters, like type, tabs, rank...
  #
  # NOTE:
  #   If we're asking for missing 'cool' or 'star' scores, we actually take the
  #   scores the player HAS which are missing the cool/star badge.
  #   Otherwise, missing includes all the scores the player DOESN'T have.
  def range_ns(
      a,               # Bottom rank
      b,               # Lower rank
      type,            # Type
      tabs,            # Tab list
      ties,            # Include ties when filtering by rank (use tied rank field)
      tied    = false, # Only include tied scores when filtering by rank
      cool    = false, # Scores must be cool
      star    = false, # Scores must be star (ex-0ths)
      missing = false, # Fetch missing scores with the desired properties
      mappack = nil,   # Mappack to use (nil = Metanet)
      board   = 'hs'   # Leaderboard type
    )
    return missing(type, tabs, a, b, ties, tied, mappack, board) if missing && !cool && !star

    # Return highscoreable names rather than scores
    high = !mappack.nil? && board == 'gm'

    # Filter scores by type and tabs
    ret = scores_by_type_and_tabs(type, tabs, nil, mappack, board)
    return ret if high

    # Filter scores by rank
    if mappack.nil? || ['hs', 'sr'].include?(board)
      rankf = mappack.nil? ? 'rank' : "rank_#{board}"
      trankf = "tied_#{rankf}"
      if tied
        q = "#{trankf} >= #{a} AND #{trankf} < #{b} AND NOT (#{rankf} >= #{a} AND #{rankf} < #{b})"
      else
        rank_type = ties ? trankf : rankf
        q = "#{rank_type} >= #{a} AND #{rank_type} < #{b}"
      end
      ret = ret.where(q)
    end

    # Filter scores by cool and star, if not in a mappack
    if mappack.nil?
      ret = ret.where("#{missing ? 'NOT ' : ''}(cool = 1 AND star = 1)") if cool && star
      ret = ret.where(cool: !missing) if cool && !star
      ret = ret.where(star: !missing) if star && !cool
    end

    # Order results and return
    ret.order(rankf, 'highscoreable_type DESC', 'highscoreable_id')
  end

  def cools(type, tabs, r1 = 0, r2 = 20, ties = false, missing = false)
    range_ns(r1, r2, type, tabs, ties).where(cool: !missing)
  end

  def stars(type, tabs, r1 = 0, r2 = 20, ties = false, missing = false)
    range_ns(r1, r2, type, tabs, ties).where(star: !missing)
  end

  def scores_by_rank(type, tabs, r1 = 0, r2 = 20)
    bench(:start) if BENCHMARK
    ret = scores_by_type_and_tabs(type, tabs, :name).where("rank >= #{r1} AND rank < #{r2}")
                                                    .order('rank, highscoreable_type DESC, highscoreable_id')
    bench(:step) if BENCHMARK
    ret
  end

  def score_counts(tabs, ties)
    bench(:start) if BENCHMARK
    counts = {
      levels:   scores_by_type_and_tabs(Level,   tabs).group(ties ? :tied_rank : :rank).order(ties ? :tied_rank : :rank).count(:id),
      episodes: scores_by_type_and_tabs(Episode, tabs).group(ties ? :tied_rank : :rank).order(ties ? :tied_rank : :rank).count(:id),
      stories:  scores_by_type_and_tabs(Story,   tabs).group(ties ? :tied_rank : :rank).order(ties ? :tied_rank : :rank).count(:id)
    }
    bench(:step) if BENCHMARK
    counts
  end

  def missing(type, tabs, a, b, ties, tied = false, mappack = nil, board = 'hs')
    type = normalize_type(type, mappack: !mappack.nil?)
    bench(:start) if BENCHMARK
    scores = type.map{ |t|
      ids = range_ns(a, b, t, tabs, ties, tied, false, false, false, mappack, board).pluck(:highscoreable_id)
      t = t.where(mappack: mappack) if !mappack.nil?
      t = t.where(tab: tabs) if !tabs.empty?
      t.where.not(id: ids).order(:id).pluck(:name)
    }.flatten
    bench(:step) if BENCHMARK
    scores
  end

  # Return highscoreables with the biggest/smallest differences between the player's
  # score and the 0th.
  def score_gaps(type, tabs, worst = true, full = false, mappack = nil, board = 'hs')
    # Prepare params
    type = ensure_type(normalize_type(type))
    type = type.mappack if mappack
    tname = type.table_name
    sfield = mappack ? "score_#{board}" : 'score'
    rfield = mappack ? "rank_#{board}" : 'rank'
    klass = mappack ? MappackScore.where(mappack: mappack).where.not(rfield => nil) : Score
    klass = klass.where(tab: tabs) unless tabs.empty?
    diff = "ABS(MAX(#{sfield}) - MIN(#{sfield}))"
    diff += '/ 60.0' if mappack && board == 'hs'

    # Calculate gaps
    bench(:start) if BENCHMARK
    list = klass.joins("INNER JOIN #{tname} ON #{tname}.id = highscoreable_id")
                .where(highscoreable_type: type)
                .where("#{rfield} = 0 OR player_id = #{self.id}")
                .group(:highscoreable_id)
                .having('diff > 0')
                .order("diff #{worst ? 'DESC' : 'ASC'}")
                .limit(full ? nil : NUM_ENTRIES)
                .pluck(:name, "#{diff} AS diff")
    bench(:step) if BENCHMARK
    list
  end

  def points(type, tabs)
    bench(:start) if BENCHMARK
    points = scores_by_type_and_tabs(type, tabs).sum('20 - rank')
    bench(:step) if BENCHMARK
    points
  end

  def average_points(type, tabs)
    bench(:start) if BENCHMARK
    scores = scores_by_type_and_tabs(type, tabs).average('20 - rank')
    bench(:step) if BENCHMARK
    scores
  end

  def total_score(type, tabs)
    bench(:start) if BENCHMARK
    scores = scores_by_type_and_tabs(type, tabs).sum(:score)
    bench(:step) if BENCHMARK
    scores
  end

  def singular_(type, tabs, plural = false)
    req = Score.where(highscoreable_type: type.to_s)
    req = req.where(tab: tabs) if !tabs.empty?
    ids = req.where("rank = 1 AND tied_rank = #{plural ? 0 : 1}").pluck(:highscoreable_id)
    scores_by_type_and_tabs(type, tabs, :name).where(rank: 0, highscoreable_id: ids)
  end

  def singular(type, tabs, plural = false)
    bench(:start) if BENCHMARK
    type = type.nil? ? DEFAULT_TYPES : [type.to_s]
    ret = type.map{ |t| singular_(t, tabs, plural) }.flatten#.group_by(&:rank)
    bench(:step) if BENCHMARK
    ret
  end

  def average_lead(type, tabs)
    type = ensure_type(type) # only works for a single type
    bench(:start) if BENCHMARK

    ids = top_ns(1, type, tabs, false).pluck('highscoreable_id')
    ret = Score.where(highscoreable_type: type.to_s, highscoreable_id: ids, rank: [0, 1])
    ret = ret.where(tab: tabs) if !tabs.empty?
    ret = ret.pluck(:highscoreable_id, :score)
    count = ret.count / 2
    return 0 if count == 0
    ret = ret.group_by(&:first).map{ |id, sc| (sc[0][1] - sc[1][1]).abs }.sum / count
## alternative method, faster when the player has many 0ths but slower otherwise (usual outcome)
#    ret = Score.where(highscoreable_type: type.to_s, rank: [0, 1])
#    ret = ret.where(tab: tabs) if !tabs.empty?
#    ret = ret.pluck(:player_id, :highscoreable_id, :score)
#             .group_by{ |s| s[1] }
#             .map{ |h, s| s[0][2] - s[1][2] if s[0][0] == id }
#             .compact
#    count = ret.count
#    return 0 if count == 0
#    ret = ret.sum / count

    bench(:step) if BENCHMARK
    ret
  end

  def table(rank, ties, a, b, cool = false, star = false)
    ttype = ties ? 'tied_rank' : 'rank'
    [Level, Episode, Story].map do |type|
      if ![:maxed, :maxable].include?(rank)
        queryBasic = scores.where(highscoreable_type: type)
                          .where(!cool.blank? ? 'cool = 1' : '')
                          .where(!star.blank? ? 'star = 1' : '')
        query = queryBasic.where(!a.blank? ? "#{ttype} >= #{a}" : '')
                          .where(!b.blank? ? "#{ttype} < #{b}" : '')
                          .group(:tab)
      end
      case rank
      when :rank
        query.count(:id).to_h
      when :tied_rank
        scores1 = queryBasic.where("tied_rank >= #{a} AND tied_rank < #{b}")
                            .group(:tab)
                            .count(:id)
                            .to_h
        scores2 = queryBasic.where("rank >= #{a} AND rank < #{b}")
                            .group(:tab)
                            .count(:id)
                            .to_h
        scores1.map{ |tab, count| [tab, count - scores2[tab]] }.to_h
      when :points
        query.sum("20 - #{ttype}").to_h
      when :score
        query.sum(:score).to_h
      when :avg_points
        query.average("20 - #{ttype}").to_h
      when :avg_rank
        query.average(ttype).to_h
      when :maxed
        Highscoreable.ties(type, [], nil, true, false)
                 .group_by{ |t| t[0].split("-")[0] }
                 .map{ |tab, scores| [formalize_tab(tab), scores.size] }
                 .to_h
      when :maxable
        Highscoreable.ties(type, [], nil, false, false)
                 .group_by{ |t| t[0].split("-")[0] }
                 .map{ |tab, scores| [formalize_tab(tab), scores.size] }
                 .to_h
      else
        query.count(:id).to_h
      end
    end
  end
end

class LevelAlias < ActiveRecord::Base
  belongs_to :level
end

class PlayerAlias < ActiveRecord::Base
  belongs_to :player
end

class Role < ActiveRecord::Base
  def self.exists(discord_id, role)
    !self.find_by(discord_id: discord_id, role: role).nil?
  end

  def self.add(user, role)
    self.find_or_create_by(discord_id: user.id, role: role)
    User.find_or_create_by(discord_id: user.id).update(name: user.name)
  end

  def self.owners(role)
    User.where(discord_id: self.where(role: role).pluck(:discord_id))
  end
end

class User < ActiveRecord::Base
  belongs_to :mappack

  # TODO: Change this by a proper Rails association
  def player(userlevel: false)
    return nil if !player_id
    (userlevel ? UserlevelPlayer : Player).find_by(id: player_id)
  end

  def player=(player)
    self.update(player_id: player ? player.id : nil)
  end
end

class GlobalProperty < ActiveRecord::Base
  # Get current lotd/eotw/cotm
  def self.get_current(type, ctp = false)
    klass = ctp ? type.mappack : type
    key = "current_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}"
    name = self.find_by(key: key).value rescue nil
    return nil if name.nil?
    klass.find_by(name: name)
  end

  # Set (change) current lotd/eotw/cotm
  def self.set_current(type, curr, ctp = false)
    key = "current_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}"
    self.find_or_create_by(key: key).update(value: curr.name)
  end

  # Select a new lotd/eotw/cotm at random, and mark the current one as done
  # When all have been done, clear the marks to be able to start over
  def self.get_next(type, ctp = false)
    type = type.mappack.where(mappack_id: 1, tab: [0, 1]) if ctp
    type.update_all(completed: nil) if type.where(completed: nil).count <= 0
    ret = type.where(completed: nil).sample
    ret.update(completed: true)
    ret
  end

  # Get datetime for the next update of some property (e.g. new lotd, new
  # database score update, etc)
  def self.get_next_update(type, ctp = false)
    key = "next_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}_update"
    Time.parse(self.find_by(key: key).value)
  end

  # Set datetime for the next update of some property
  def self.set_next_update(type, time, ctp = false)
    key = "next_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}_update"
    self.find_or_create_by(key: key).update(value: time.to_s)
  end

  # Get the old saved scores for lotd/eotw/cotm (to compare against current scores)
  def self.get_saved_scores(type, ctp = false)
    key = "saved_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}_scores"
    JSON.parse(self.find_by(key: key).value)
  end

  # Save the current lotd/eotw/cotm scores (to see changes later)
  def self.set_saved_scores(type, curr, ctp = false)
    key = "saved_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}_scores"
    scores = curr.scores
    scores = scores.where("rank_hs IS NOT NULL OR rank_sr IS NOT NULL") if ctp
    fields = [:player_id]
    if ctp
      fields << [:rank_hs, :score_hs, :rank_sr, :score_sr]
    else
      fields << [:rank, :score]
    end
    self.find_or_create_by(key: key).update(value: scores.to_json(only: fields.flatten))
  end

  # Get the currently active Steam ID to latch onto
  def self.get_last_steam_id
    self.find_or_create_by(key: "last_steam_id").value
  end

  # Set currently active Steam ID
  def self.set_last_steam_id(id)
    self.find_or_create_by(key: "last_steam_id").update(value: id)
  end

  # Select a new Steam ID to set (we do it in order, so that we can loop the list)
  # If 'fast', we only try the recently active Steam IDs
  def self.update_last_steam_id(fast = false)
    current = (Player.find_by(steam_id: get_last_steam_id).id || 0) rescue 0
    query = Player.where.not(steam_id: nil)
    query = query.where(active: true) if fast
    next_player = (query.where('id > ?', current).first || query.first) rescue nil
    set_last_steam_id(next_player.steam_id) if !next_player.nil?
  end

  # Mark date of when current Steam ID was active
  def self.activate_last_steam_id
    p = Player.find_by(steam_id: get_last_steam_id)
    p.update(last_active: Time.now) if !p.nil?
    update_steam_actives
  end

  # Update "active" boolean for recently active IDs
  def self.update_steam_actives
    period = FAST_PERIOD * 24 * 60 * 60
    Player.where("unix_timestamp(last_active) >= #{Time.now.to_i - period}").update_all(active: true)
    Player.where("unix_timestamp(last_active) < #{Time.now.to_i - period}").update_all(active: false)
  end

  def self.get_avatar
    self.find_by(key: 'avatar').value
  end

  def self.set_avatar(str)
    self.find_by(key: 'avatar').update(value: str)
  end
end

class RankHistory < ActiveRecord::Base
  belongs_to :player
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  def self.compose(rankings, type, tab, rank, ties, time)
    rankings.select { |r| r[1] > 0 }.map do |r|
      {
        highscoreable_type: type.to_s,
        rank:               rank,
        ties:               ties,
        tab:                tab,
        player:             r[0],
        count:              r[1],
        metanet_id:         r[0].metanet_id,
        timestamp:          time
      }
    end
  end
end

class PointsHistory < ActiveRecord::Base
  belongs_to :player
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  def self.compose(rankings, type, tab, time)
    rankings.select { |r| r[1] > 0 }.map do |r|
      {
        timestamp:          time,
        tab:                tab,
        highscoreable_type: type.to_s,
        player:             r[0],
        metanet_id:         r[0].metanet_id,
        points:             r[1]
      }
    end
  end
end

class TotalScoreHistory < ActiveRecord::Base
  belongs_to :player
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  def self.compose(rankings, type, tab, time)
    rankings.select { |r| r[1] > 0 }.map do |r|
      {
        timestamp:          time,
        tab:                tab,
        highscoreable_type: type.to_s,
        player:             r[0],
        metanet_id:         r[0].metanet_id,
        score:              r[1]
      }
    end
  end
end

class Video < ActiveRecord::Base
  belongs_to :highscoreable, polymorphic: true

  def format_challenge
    return (challenge == "G++" || challenge == "?!") ? challenge : "#{challenge} (#{challenge_code})"
  end

  def format_author
    return "#{author} (#{author_tag})"
  end

  def format_description
    "#{format_challenge} by #{format_author}"
  end
end

class Challenge < ActiveRecord::Base
  belongs_to :level

  def objs
    {
      "G" => self.g,
      "T" => self.t,
      "O" => self.o,
      "C" => self.c,
      "E" => self.e
    }
  end

  def type
    index == 0 ? '!' : '?'
  end

  def count
    objs.select{ |k, v| v != 0 }.count
  end

  def format_type
    "[" + type * count + "]"
  end

  def format_objs
    objs.map{ |k, v|
      v == 1 ? "#{k}++" : (v == -1 ? "#{k}--" : "")
    }.join
  end

  def format(pad)
    format_type + " " * [1, pad - count + 1].max + format_objs
  end
end

class Archive < ActiveRecord::Base
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  has_one :demo, foreign_key: :id
  enum tab: TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h

  # Returns the leaderboards at a particular point in time
  def self.scores(highscoreable, date)
    self.select('metanet_id', 'max(score)')
        .where(highscoreable: highscoreable)
        .where("unix_timestamp(date) <= #{date}")
        .group('metanet_id')
        .order('max(score) desc, max(replay_id) asc')
        .take(20)
        .map{ |s|
          [s.metanet_id.to_i, s['max(score)'].to_i]
        }
  end

  # Return a list of all dates where a highscoreable changed
  # We consider dates less than MAX_SECS apart to be the same
  def self.changes(highscoreable)
    dates = self.where(highscoreable: highscoreable)
                .select('unix_timestamp(date)')
                .distinct
                .pluck('unix_timestamp(date)')
                .sort
    dates[0..-2].each_with_index.select{ |d, i| dates[i + 1] - d > MAX_SECS }.map(&:first).push(dates.last)
  end

  # Return a list of all 0th holders in history on a specific highscoreable
  # until a certain date (nil = present)
  # Care must be taken when the 0th was improved multiple times in the same update
  def self.zeroths(highscoreable, date = nil)
    dates = changes(highscoreable)
    return [] if dates.size == 0
    prev_date = dates[0]
    zeroth = scores(highscoreable, prev_date).first
    zeroths = [zeroth]
    date = Time.now.to_i if date.nil?

    dates[0..-2].each_with_index.reject{ |d, i| dates[i + 1] > date }.each{ |d, i|
      a = self.where(highscoreable: highscoreable)
              .where("unix_timestamp(date) > #{d} AND unix_timestamp(date) <= #{dates[i + 1]}")
              .order('score DESC')
              .first
      if a.score > zeroth[1]
        zeroth = [a.metanet_id, a.score]
        zeroths.push(zeroth)
      end
    }
    zeroths.map(&:first)
  end

  def self.format_scores(board, zeroths = [])
    pad = board.map{ |s| ("%.3f" % (s[1].to_f / 60.0)).length.to_i }.max
    board.each_with_index.map{ |s, i|
      star = zeroths.include?(s[0]) ? '*' : ' '
      "#{star}#{"%02d" % i}: #{format_string(Player.find_by(metanet_id: s[0]).print_name)} - #{"%#{pad}.3f" % (s[1].to_f / 60.0)}"
    }.join("\n")
  end

  # Clean database:
  #   - Remove scores, archives and players by blacklisted players
  #   - Remove orphaned demos (without a corresponding archive)
  #   - Remove individually blacklisted archives
  #   - Remove duplicated archives
  def self.sanitize
    # Store results to print summary after sanitization
    ret = {}

    # Delete scores by ignored players
    query = Score.joins("INNER JOIN players ON players.id = scores.player_id")
                 .where("players.metanet_id" => BLACKLIST.keys)
    count = query.count.to_i
    ret['score_del'] = "Deleted #{count} scores by ignored players." unless count == 0
    query.delete_all

    # Delete archives (and their corresponding demos) by ignored players
    query = Archive.where(metanet_id: BLACKLIST.keys)
    count = query.count.to_i
    ret['archive_del'] = "Deleted #{count} archives by ignored players." unless count == 0
    query.each(&:wipe)

    # Delete ignored players
    query = Player.where(metanet_id: BLACKLIST.keys)
    count = query.count.to_i
    ret['player_del'] = "Deleted #{count} ignored players." unless count == 0
    query.delete_all

    # Delete individual incorrect archives
    count = 0
    ["Level", "Episode", "Story"].each{ |mode|
      query = Archive.where(highscoreable_type: mode, replay_id: PATCH_IND_DEL[mode.downcase.to_sym])
      count += query.count.to_i
      query.each(&:wipe)
    }
    ret['archive_ind_del'] = "Deleted #{count} incorrect archives." unless count == 0

    # Delete duplicate archives (can happen on accident)
    duplicates = Archive.group(
      :highscoreable_type,
      :highscoreable_id,
      :player_id,
      :score
    ).having('count(score) > 1')
     .select(:highscoreable_type, :highscoreable_id, :player_id, :score, 'min(date)')
     .to_a
    count = 0
    duplicates.each{ |d|
      same = Archive.where(
        highscoreable_type: d.highscoreable_type,
        highscoreable_id:   d.highscoreable_id,
        player_id:          d.player_id,
        score:              d.score
      ).order(date: :asc).limit(1000).offset(1)
      count += same.count
      same.each(&:wipe)
    }
    ret['duplicates'] = "Deleted #{count} duplicated archives." unless count == 0

    # Delete demos with missing archives
    query = Demo.joins("LEFT JOIN archives ON archives.id = demos.id")
                .where("archives.id IS NULL")
    count = query.count.to_i
    ret['orphan_demos'] = "Deleted #{count} orphaned demos." unless count == 0
    query.delete_all

    # Patch archives
    # ONLY EXECUTE THIS ONCE!! Otherwise, the scores will be altered multiple times
    #s = Archive.find_by(highscoreable_type: "Level", replay_id: 3758900)
    #s.score -= 6 * 60;
    #s.save
    #s = Archive.find_by(highscoreable_type: "Episode", replay_id: 5067031)
    #s.score -= 6 * 60;
    #s.save
    #PATCH_RUNS.each{ |mode, entries|
    #  entries.each{ |id, entry|
    #    Archive.where(highscoreable_type: mode.to_s.capitalize, highscoreable_id: id).where("replay_id <= ?", entry[0]).each{ |a|
    #      a.score += entry[1] * 60
    #      a.save
    #    }
    #  }
    #}

    ret
  end

  # Returns the rank of the player at a particular point in time
  def find_rank(time)
    old_score = Archive.scores(self.highscoreable, time)
                       .each_with_index
                       .map{ |s, i| [i, s[0], s[1]] }
                       .select{ |s| s[1] == self.metanet_id }
    old_score.empty? ? 20 : old_score.first[0]
  end

  def format_score
    "%.3f" % self.score.to_f / 60.0
  end

  # Remove both the archive and its demo from the DB
  def wipe
    demo.destroy
    self.destroy
  end
end

#------------------------------------------------------------------------------#
#                    METANET REPLAY FORMAT DOCUMENTATION                       |
#------------------------------------------------------------------------------#
# REPLAY DATA:                                                                 |
#    4B  - Replay type (0 level / story, 1 episode)                            |
#    4B  - Replay ID                                                           |
#    4B  - Level ID                                                            |
#    4B  - User ID                                                             |
#   Rest - Demo data compressed with zlib                                      |
#------------------------------------------------------------------------------#
# LEVEL DEMO DATA FORMAT:                                                      |
#     1B - Type           (0 lvl, 1 lvl in ep, 2 lvl in sty)                   |
#     4B - Data length                                                         |
#     4B - Replay version (1)                                                  |
#     4B - Frame count                                                         |
#     4B - Level ID                                                            |
#     4B - Game mode      (0, 1, 2, 4)                                         |
#     4B - Unknown        (0)                                                  |
#     1B - Ninja mask     (1, 3)                                               |
#     4B - Static data    (0xFFFFFFFF)                                         |
#   Rest - Demo                                                                |
#------------------------------------------------------------------------------#
# EPISODE DEMO DATA FORMAT:                                                    |
#     4B - Magic number (0xffc0038e)                                           |
#    20B - Block length for each level demo (5 * 4B)                           |
#   Rest - Demo data (5 consecutive blocks, see above)                         |
#------------------------------------------------------------------------------#
# STORY DEMO DATA FORMAT:                                                      |
#     4B - Magic number (0xff3800ce)                                           |
#     4B - Demo data block size                                                |
#   100B - Block length for each level demo (25 * 4B)                          |
#   Rest - Demo data (25 consecutive blocks, see above)                        |
#------------------------------------------------------------------------------#
# DEMO FORMAT:                                                                 |
#   * One byte per frame.                                                      |
#   * 1st bit for jump, 2nd for right, 3rd for left, 4th for suicide           |
#------------------------------------------------------------------------------#
class Demo < ActiveRecord::Base
  belongs_to :archive, foreign_key: :id

  def self.encode(replay)
    replay = [replay] if replay.class == String
    Zlib::Deflate.deflate(replay.join('&'), 9)
  end

  # Read demo from database (decompress and turn to array)
  # Convert to integers, unless we're decoding for dumping later
  def self.decode(demo, dump = false)
    return nil if demo.nil?
    demos = Zlib::Inflate.inflate(demo).split('&')
    if !dump
      demos = demos.map{ |d| d.bytes }
      demos = demos.first if demos.size == 1
    end
    demos
  end

  # Parse 30 byte header of a level demo
  def self.parse_header(replay)
    replay = Zlib::Inflate.inflate(replay)[0...30]
    ret = {}
    ret[:type]       = replay[0].unpack('C')[0]
    ret[:size]       = replay[1..4].unpack('l<')[0]
    ret[:version]    = replay[5..8].unpack('l<')[0]
    ret[:framecount] = replay[9..12].unpack('l<')[0]
    ret[:id]         = replay[13..16].unpack('l<')[0]
    ret[:mode]       = replay[17..20].unpack('l<')[0]
    ret[:unknown]    = replay[21..24].unpack('l<')[0]
    ret[:mask]       = replay[25].unpack('C')[0]
    ret[:static]     = replay[26..29].unpack('l<')[0]
    ret
  end

  # Parse a demo, return array with inputs for each level
  def self.parse(replay, htype)
    data   = Zlib::Inflate.inflate(replay)
    header = { 'Level' => 0, 'Episode' =>  4, 'Story' =>   8 }[htype]
    offset = { 'Level' => 0, 'Episode' => 24, 'Story' => 108 }[htype]
    count  = { 'Level' => 1, 'Episode' =>  5, 'Story' =>  25 }[htype]

    mode  = _unpack(data[offset + 17..offset + 20])
    start = mode == 1 ? 34 : 30

    lengths = (0...count).map{ |d| _unpack(data[header + 4 * d...header + 4 * (d + 1)]) }
    lengths = [_unpack(data[1..4])] if htype == 'Level'
    lengths.map{ |l|
      raw_replay = data[offset...offset + l]
      offset += l
      raw_replay[start..-1]
    }
  end

  def qt
    TYPES[archive.highscoreable_type][:qt]
  rescue
    -1
  end

  def uri(steam_id)
    URI.parse("https://dojo.nplusplus.ninja/prod/steam/get_replay?steam_id=#{steam_id}&steam_auth=&replay_id=#{archive.replay_id}&qt=#{qt}")
  end

  def parse(replay)
    Demo.parse(replay, archive.highscoreable_type)
  end

  def decode
    Demo.decode(demo)
  end

  def get_demo
    uri = Proc.new { |steam_id| uri(steam_id) }
    data = Proc.new { |data| data }
    err  = "error getting demo with id #{archive.replay_id} "\
           "for #{archive.highscoreable_type.downcase} "\
           "with id #{archive.highscoreable_id}"
    get_data(uri, data, err)
  end

  # This is only used in the migration file, to compute the framecount of
  # preexisting demos. New ones get computed on the fly right after download.
  def framecount
    return -1 if demo.nil?
    demos = decode
    return (!demo[0].is_a?(Array) ? demos.size : demos.map(&:size).sum)
  rescue
    -1
  end

  def update_archive(framecounts, lost)
    return if archive.nil?
    framecount = framecounts.sum
    archive.update(
      framecount: framecount,
      gold: framecount != -1 ? (((archive.score + framecount).to_f / 60 - 90) / 2).round : -1,
      lost: lost
    )
  end

  def update_demo
    return nil if !demo.nil?
    replay = get_demo
    return nil if replay.nil? # replay was not fetched successfully
    if replay.empty? # replay does not exist
      archive.update(lost: true)
      return nil
    end
    demos = parse(replay[16..-1])
    update_archive(demos.map(&:size), false)
    self.update(demo: Demo.encode(demos))
  rescue => e
    lex(e, "Error updating demo with id #{archive.replay_id}: #{e}")
    nil
  end
end

module Twitch extend self

  GAME_IDS = {
#    'N'     => 12273,  # Commented because it's usually non-N related :(
    'N+'     => 18983,
    'Nv2'    => 105456,
    'N++'    => 369385
#    'GTASA'  => 6521    # This is for testing purposes, since often there are no N streams live
  }

  def get_twitch_token
    GlobalProperty.find_by(key: 'twitch_token').value
  end

  def set_twitch_token(token)
    GlobalProperty.find_by(key: 'twitch_token').update(value: token)
  end

  def length(s)
    (Time.now - DateTime.parse(s['started_at']).to_time).to_i / 60.0
  end

  def table_header
    "#{"Player".ljust(15, " ")} #{"Title".ljust(35, " ")} #{"Time".ljust(12, " ")} #{"Views".ljust(4, " ")}\n#{"-" * 70}"
  end

  def format_stream(s)
    name  = to_ascii(s['user_name']).strip[0...15].ljust(15, ' ')
    title = to_ascii(s['title']).strip[0...35].ljust(35, ' ')
    time  = "#{length(s).to_i} mins ago".rjust(12, ' ')
    views = s['viewer_count'].to_s.rjust(5, ' ')
    "#{name} #{title} #{time} #{views}"
  end

  def update_twitch_token
    res = Net::HTTP.post_form(
      URI.parse("https://id.twitch.tv/oauth2/token"),
      {
        client_id: $config['twitch_client'].to_s,
        client_secret: $config['twitch_secret'].to_s,
        grant_type: 'client_credentials'
      }
    )
    if res.code.to_i == 401
      err("TWITCH: Unauthorized to perform requests, please verify you have this correctly configured.")
    elsif res.code.to_i != 200
      err("TWITCH: App access token request failed (code #{res.body}).")
    else
      $twitch_token = JSON.parse(res.body)['access_token']
      set_twitch_token($twitch_token)
    end
  rescue => e
    lex(e, "TWITCH: App access token request method failed")
    sleep(5)
    retry
  end

  # TODO: Add attempts to the loop, raise if fail
  def get_twitch_game_id(name)
    update_twitch_token if $twitch_token.nil?
    uri = URI("https://api.twitch.tv/helix/games?name=#{name}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    loop do
      res = http.get(
        uri.request_uri,
        {
          'Authorization' => "Bearer #{$twitch_token}",
          'Client-Id' => $config['twitch_client'].to_s
        }
      )
      if res.code.to_i == 401
        update_twitch_token
        sleep(5)
      elsif res.code.to_i != 200
        err("TWITCH: Game ID request failed.")
        sleep(5)
      else
        return JSON.parse(res.body)['id'].to_i
      end
    end
  rescue => e
    lex(e, 'TWITCH: Game ID request method failed.')
    sleep(5)
    retry
  end

 # TODO: Add attempts to the loops, raise if fail
 # TODO: Add offset/pagination for when there are many results
  def get_twitch_streams(name, offset = nil)
    if !GAME_IDS.key?(name)
      err("TWITCH: Supplied game not known.")
      return
    end
    while $twitch_token.nil?
      update_twitch_token
      sleep(5)
    end
    uri = URI("https://api.twitch.tv/helix/streams?first=100&game_id=#{GAME_IDS[name]}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    res = nil
    loop do
      res = http.get(
        uri.request_uri,
        {
          'Authorization' => "Bearer #{$twitch_token}",
          'Client-Id' => $config['twitch_client'].to_s
        }
      )
      if res.code.to_i == 401
        update_twitch_token
        sleep(5)
      elsif res.code.to_i != 200
        err("TWITCH: Stream list request for #{name} failed (code #{res.code.to_i}).")
        sleep(5)
      else
        break
      end
    end
    JSON.parse(res.body)['data']
  rescue => e
    lex(e, "TWITCH: Stream list request method for #{name} failed.")
    sleep(5)
    retry
  end

  def update_twitch_streams
    # Update streams for each followed game
    GAME_IDS.each{ |game, id|
      new_streams = get_twitch_streams(game)
      $twitch_streams[game] = [] if !$twitch_streams.key?(game)

      # Reject blacklisted streams
      new_streams.reject!{ |s| TWITCH_BLACKLIST.include?(s['user_name']) }

      # Update values of already existing streams
      $twitch_streams[game].each{ |stream|
        new_stream = new_streams.select{ |s| s['user_id'] == stream['user_id'] }.first
        if !new_stream.nil?
          stream.merge!(new_stream)
          stream['on'] = true
        else
          stream['on'] = false
        end
      }

      # Add new streams
      new_streams.reject!{ |s|
        $twitch_streams[game].map{ |ss| ss['user_id'] }.include?(s['user_id'])
      }
      new_streams.each{ |stream| stream['on'] = true }
      $twitch_streams[game].push(*new_streams)

      # Delete obsolete streams
      $twitch_streams[game].reject!{ |stream|
        stream.key?('on') && !stream['on'] && stream.key?('posted') && (Time.now.to_i - stream['posted'] > TWITCH_COOLDOWN)
      }

      # Reorder streams
      $twitch_streams[game].sort_by!{ |s| -Time.parse(s['started_at']).to_i }
    }
  end

  def active_streams
    $twitch_streams.map{ |game, list|
      [game, list.select{ |s| s['on'] }]
    }.to_h
  end

  def new_streams
    active_streams.map{ |game, list|
      [game, list.select{ |s| !s['posted'] && Time.parse(s['started_at']).to_i > $boot_time }]
    }.to_h
  end

  def post_stream(stream)
    return if $content_channel.nil?
    game = GAME_IDS.invert[stream['game_id'].to_i]
    return if !game
    send_message($content_channel, content: "#{ping(TWITCH_ROLE)} #{verbatim(stream['user_name'])} started streaming **#{game}**! #{verbatim(stream['title'])} <https://www.twitch.tv/#{stream['user_login']}>")
    return if !$twitch_streams.key?(game)
    s = $twitch_streams[game].select{ |s| s['user_id'] ==  stream['user_id'] }.first
    s['posted'] = Time.now.to_i if !s.nil?
  rescue => e
    lex(e, 'Failed to post new Twitch stream')
  end
end

# This class logs all messages sent by outte, and who it is in response to
# That way, the user may request to delete the message later by any mechanism
# we decide to devise
class Message < ActiveRecord::Base
  # Clear expired message logs
  def self.clean
    where("date < ?", Time.now - DELETE_TIMELIMIT).delete_all
  end
end

# See "Socket Variables" in constants.rb for docs
module Sock extend self
  @@servers = {}

  # Stops all servers
  def self.off
    @@servers.keys.each{ |s| Sock.stop(s) }
  end

  # Start a basic HTTP server at the specified port
  def start(port, name)
    # Create WEBrick HTTP server
    @@servers[name] = WEBrick::HTTPServer.new(
      Port: port,
      AccessLog: [
        [$stdout, "#{name} %h %m %U"],
        [$stdout, "#{name} %s %b bytes %T"]
      ]
    )
    # Setup callback for requests
    @@servers[name].mount_proc '/' do |req, res|
      handle(req, res)
    end
    # Start server (blocks thread)
    log("Started #{name} server")
    @@servers[name].start
  rescue => e
    lex(e, "Failed to start #{name} server")
  end

  # Stops server, needs to be summoned from another thread
  def stop(name)
    @@servers[name].shutdown
    log("Stopped #{name} server")
  rescue => e
    lex(e, "Failed to stop #{name} server")
  end
end

module Server extend self
  extend Sock

  def on
    start(SOCKET_PORT, 'CLE')
  end

  def off
    stop('CLE')
  end

  def handle(req, res)
    # Ignore empty requests
    return respond(res) if req.path.strip == '/'

    # Parse request parameters
    mappack = req.path.split('/')[1][/\D+/i]
    method  = req.request_method
    query   = req.path.split('/')[-1]

    # Always log players in, regardless of mappack
    return respond(res, Player.login(mappack, req)) if method == 'POST' && query == 'login'

    # Automatically forward requests for certain mappacks that lack custom boards
    return fwd(req, res) if ['rdx'].include?(mappack)

    # CUSE requests only affect userlevel searching
    if mappack == 'cuse'
      return fwd(req, res) unless method == 'GET' && query == 'levels'
      return respond(res, Userlevel.search(req))
    end

    # Parse request
    case method
    when 'GET'
      case query
      when 'get_scores'
        return respond(res, MappackScore.get_scores(mappack, req.query.map{ |k, v| [k, v.to_s] }.to_h, req))
      when 'get_replay'
        return respond(res, MappackScore.get_replay(mappack, req.query.map{ |k, v| [k, v.to_s] }.to_h, req))
      when 'levels'
        return respond(res, Userlevel.search(req))
      end
    when 'POST'
      req.continue # Respond to "Expect: 100-continue"
      case query
      when 'submit_score'
        return respond(res, MappackScore.add(mappack, req.query.map{ |k, v| [k, v.to_s] }.to_h, req))
      when 'login'
        return respond(res, Player.login(mappack, req))
      end
    end

    fwd(req, res)
  rescue => e
    lex(e, "CLE socket failed to parse request for: #{req.path}")
    nil
  end

  def respond(res, body = nil)
    if body.nil?
      res.status = 400
      res.body = ''
    else
      res.status = 200
      res.body = body
    end
  end

  def fwd(req, res)
    respond(res, CLE_FORWARD ? forward(req) : nil)
  end
end
