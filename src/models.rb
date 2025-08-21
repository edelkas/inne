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

    # Add upwards truncation with precision
    ::Numeric.class_eval do
      def truncate_up(precision = 0)
        factor = 10 ** -precision
        n = (self.to_f / factor).ceil * factor
        self.is_a?(Integer) || precision <= 0 ? n.round : n.to_f
      end
    end
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

    # Allow raw SQL queries for pluck, order, etc
    [
      (::ActiveRecord::Sanitization::ClassMethods rescue nil),
      (::ActiveRecord::AttributeMethods::ClassMethods rescue nil),
      (::ActiveRecord::InsertAll rescue nil)
    ].compact.each do |klass|
      klass.class_eval do
        def disallow_raw_sql!(args, permit: nil)
        end
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
        #param['U'] = param['U'].split('?')[0].split('/')[-1] rescue '' # Uncomment to show only last component
        @config[:AccessLog].each{ |logger, fmt|
          str = ::WEBrick::AccessLog::format(fmt.gsub('%T', ''), param)
          str += " #{"%.3fms" % (1000 * param['T'])}" if fmt.include?('%T') rescue ''
          str.squish!
          fmt.include?('%s') ? lout(str) : lin(str) if $log[:socket]
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
    ul = list.first.is_userlevel?
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
    ul = list.first.is_userlevel?
    count = list.count
    delta = 0
    list.find_each.with_index{ |h, i|
      name = ul ? "userlevel #{h.id}" : h.name
      attempt = 0
      current = "#{name} [#{type} #{i} / #{count}]"
      count_old = h.completions.to_i
      count_new = h.update_completions(log: false, discord: false, global: global)

      while !count_new
        acquire_connection # In case we spend too long here, we may've disconnected
        if retries == 0 || attempt < retries
          concurrent_edit(event, msgs, "Stopped updating at #{current} (waiting for outte++).") if attempt == 0
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
    id_key = (is_userlevel? ? 'level' : self.class.to_s.downcase) + '_id'
    npp_uri(:scores, steam_id, id_key => id, qt: qt)
  end

  # Download the highscoreable's scores from Metanet's server
  def get_scores(fast: false)
    uri  = Proc.new { |steam_id| scores_uri(steam_id) }
    data = Proc.new { |data| correct_ties(clean_scores(JSON.parse(data)['scores'])) }
    err  = "error getting scores for #{self.class.to_s.downcase} with id #{self.id.to_s}"
    get_data(uri, data, err, fast: fast)
  end

  # Download personal score
  def get_pb(steam_id, silent: false)
    # Fetch scores
    res = Net::HTTP.get_response(scores_uri(steam_id)) rescue nil
    err_msg = "Failed to fetch scores for #{name}"

    # Integrity checks
    if !res.is_a?(Net::HTTPSuccess)
      err("#{err_msg} (unsuccessful request #{res.code}).") unless silent
      return :error
    elsif res.body.blank?
      err("#{err_msg} (empty response).") unless silent
      return :empty
    elsif res.body == METANET_INVALID_RES
      err("#{err_msg} (inactive Steam ID).") unless silent
      return :inactive
    end

    # Parse score from personal field
    hash = JSON.parse(res.body)['userInfo'] rescue nil
    if !hash
      err("#{err_msg} (no score).") unless silent
      return :none
    end
    hash
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
      if res && res.body == METANET_INVALID_RES
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

    # Filter out hacked runs, incorrect scores and too high scores
    k = self.class.to_s.downcase.to_sym
    boards.reject!{ |s|
      HACKERS.key?(s['user_id']) || BLACKLIST_NAMES.include?(s['user_name']) || PATCH_IND_DEL[k].include?(s['replay_id']) || s['score'] / 1000.0 >= limit
    }

    # Mark cheated runs, to be archived separately
    boards.each{ |s|
      s['cheated'] = true if CHEATERS.key?(s['user_id'])
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
      i = -1
      updated.each do |score|
        # Rank field
        i += 1 unless score['cheated']

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
          tied_rank: updated.reject{ |s| s['cheated'] }.find_index { |s| s['score'] == score['score'] }
        ) unless score['cheated']

        # Non-userlevel updates (tab, archive, demos)
        next if self.class == Userlevel
        scores.find_by(rank: i).update(tab: self.tab, cool: false, star: false) unless score['cheated']

        # Create archive and demo if they don't already exist
        ar = Archive.find_by(highscoreable: self, replay_id: score['replay_id'])
        if !!ar
          ar.update(cheated: true) if score['cheated']
          next
        end

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
          expired:       false,
          cheated:       !!score['cheated']
        )

        # Create demo
        Demo.find_or_create_by(id: ar.id).update_demo
      end

      # Update timestamps, cools and stars
      if self.class == Userlevel
        self.update(
          score_update: Time.now,
          scored:       updated.size > 0
        )
      else
        scores.where("`rank` < #{find_coolness}").update_all(cool: true)
        scores.where(player_id: stars).update_all(star: true)
        scores.where(rank: 0).update(star: true)
      end

      # Remove scores stuck at the bottom after ignoring cheaters
      # TODO: We should use the non-cheated size of updated for this
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

  def submit_score(score, replays, player = nil, log: false, silent: false)
    fname = verbatim(self.name.remove('`'))

    # Fetch player
    player = Player.find_by(metanet_id: OUTTE_ID) if !player
    if !player
      err("No player to submit score to #{fname}.", discord: log) unless silent
      return
    end
    pname = verbatim(player.name.remove('`'))

    # Construct replay data
    frames = replays.map(&:size).sum
    replays = replays.map{ |replay| replay.pack('C*') }
    replays = self.dump_demo(replays)
    replays = Zlib::Deflate.deflate(replays, 9)

    # Compute request parts
    klass = self.class.to_s.downcase
    klass = 'level' if klass == 'userlevel'
    qt = TYPES[klass.capitalize][:qt]
    score = (1000 * round_score(score)).round.to_s
    version = [2842, 3009, 3096].include?(self.id) ? 1 : 2
    hash = self.map._hash(c: true, v: version)
    if !hash
      err("Couldn't compute #{fname} hash, not submitting #{pname} score.", discord: log) unless silent
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
    res = player.send_post(METANET_POST_SCORE, parts: parts, auth: true, silent: silent)
    return if !res
    return false if res == METANET_INVALID_RES
    args = [score.to_i / 1000.0, frames, player.name, player.metanet_id, self.class.to_s.downcase, self.name, self.id]
    dbg("Submitted score %.3f (%df) by %s (%d) to %s %s (%d)" % args) unless silent
    JSON.parse(res)
  rescue => e
    lex(e, "Failed to submit score by #{pname} to #{fname}.", discord: log) unless silent
    nil
  end

  def submit_zero_score(log: false)
    score = 0
    replay_count = TYPES[self.class.to_s][:size] rescue 1
    replays = [[]] * replay_count
    player = Player.find_by(metanet_id: OUTTE_ID)
    submit_score(score, replays, player, log: log)
  end

  #   Starting with a score of 0, submit progressively higher scores until we
  # cover the entire leaderboard, so we can map it out. Ensure the last score
  # we submit is just outside the top20.
  #   We do things slightly differently if we know we're multithreading, such as
  # not setting breakpoints and not logging debug info to the terminal.
  # TODO: Save directly on the db
  # TODO: Update the completions field of the highscoreable
  # worker - When multithreading, the ThreadPool::Thread that is running this method
  def scan_boards(metanet_id: OUTTE2_ID, worker: nil)
    data = {}
    global_gap = true
    holes = 0
    cur_score = 0
    max_score = (1000 * round_score(scores.minimum(:score) - 0.017)).round
    cur_rank = -1
    max_rank = 0
    cur_id = -1
    wait = 10
    i = 0

    loop do
      # Add some randomized wait when multithreading to avoid hammering the server simultaneously
      sleep(rand / 10) if worker

      # Submit improved score
      cur_score = [cur_score, max_score].min
      score = round_score(cur_score / 1000.0)
      replay_count = TYPES[self.class.to_s][:size] rescue 1
      replays = [[]] * replay_count
      player = Player.find_by(metanet_id: metanet_id)
      status = submit_score(score, replays, player, log: false, silent: true)
      if !status
        # Submission error (commonly timeout due to bad network), or multithreading
        if status.nil? || worker
          worker ? worker.idle(wait) : sleep(wait)
          next
        end

        # Inactive user in single-thread mode
        err("Failed to fetch scores (inactive Steam ID).")
        quiet_breakpoint
        next
      end
      reached_top = status['better'] == 0 && cur_score == max_score
      i += 1

      # Fetch scores around me
      res = nil
      begin
        res = Net::HTTP.get_response(scores_uri(OUTTE2_STEAM_ID, qt: reached_top ? 0 : 1)) rescue nil
        if !res.is_a?(Net::HTTPSuccess)
          worker ? worker.idle(wait) : sleep(wait)
          raise
        elsif res.body == METANET_INVALID_RES
          worker.idle(wait) if worker
          err("Failed to fetch scores (inactive Steam ID).") if !worker
          quiet_breakpoint if !worker
          raise
        end
      rescue
        retry
      end

      # Fill data
      hash = JSON.parse(res.body)
      board = hash['scores']
      return err("No scores found.") if board.empty?
      board.each{ |s| data[s['replay_id']] = s }
      (cur_id = hash['userInfo']['my_replay_id']) rescue -1
      data.reject!{ |id, s| s['user_id'] == metanet_id && id != cur_id }

      # Log progress
      (cur_rank = board.find{ |s| s['user_id'] == metanet_id }['rank']) rescue -1
      top_rank = board.max_by{ |s| s['rank'] }['rank']
      bot_rank = board.min_by{ |s| s['rank'] }['rank']
      max_rank = top_rank if top_rank > max_rank
      if worker
        worker.progress = 100.0 * (1.0 - bot_rank.to_f / (max_rank + 1))
        worker.status = "%s: %4d / %4d" % [name, data.size, max_rank + 1]
      else
        params = [cur_rank.ordinalize, round_score(cur_score / 1000.0), data.size, max_rank + 1, name, i, holes]
        dbg("%s: %7.3f - Scanned %4d / %4d scores in %s after %3d submissions (%d holes)" % params, progress: true)
      end

      # Prepare next iteration
      break if reached_top
      top_score = board.max_by{ |s| s['score'] }['score']
      top_score_m1 = (1000 * ((60 * top_score / 1000.0).round - 1) / 60.0).round # one less frame
      top_score_p1 = (1000 * ((60 * top_score / 1000.0).round + 1) / 60.0).round # one more frame
      holes += 1 if cur_score == top_score
      global_gap = false if top_score_m1 > max_score
      cur_score = cur_score < top_score_m1 ? top_score_m1 : cur_score < top_score ? top_score : top_score_p1
    end
  ensure
    # Ensure we export the data even if an exception is raised, we only get one chance at this!
    data.reject!{ |id, s| s['user_id'] == metanet_id && id != cur_id }
    list = correct_ties(data.values)
    list.each_with_index{ |s, i| s['rank'] = i }
    json = list.to_json
    export = [list.size].pack('L<').b + list.map{ |s|
      [s['replay_id'], (60 * s['score'] / 1000.0).round, s['user_id'], s['user_name'].delete(0.chr)].pack('L<3Z*')
    }.join.b
    fn = is_userlevel? ? id : name.sub(/.+?-/, tab + '-')
    File.binwrite("boards/json/#{tab}/#{fn}.json", json)
    File.binwrite("boards/raw/#{tab}/#{fn}", export)

    # Log progress
    Log.clear
    params = [cur_rank.ordinalize, round_score(cur_score / 1000.0), data.size, max_rank + 1, name, i, holes]
    log_line = "%s: %7.3f - Scanned %4d / %4d scores in %s after %3d submissions (%d holes)" % params
    func = data.size == max_rank + 1 ? :succ : !global_gap ? :alert : :err
    if !worker
      send(func, log_line)
    else
      mode = func == :succ ? :good : func == :alert ? :warn : :error
      worker.pool.report(Log.format(log_line, mode)[:fancy])
    end
  end

  # Parse exported scores from scan_boards and create corresponding RawScores
  def parse_raw_scores(file, format: :json)
    if !File.file?(file)
      err("File #{file} not found")
      return 0
    end

    # Fetch list
    if format == :json
      list = JSON.parse(File.read(file))
      count = list.size
    else
      f = File.binread(file)
      count = f.unpack1('L<')
      list = f.unpack('L<3Z*' * count, offset: 4).each_slice(4)

      if list.size < count
        alert("Missing #{name} raw scores (#{list.size} / #{count}) in #{file}")
        count = list.size
      end
    end

    # Init state
    tied_rank = 0
    tied_score = nil

    # Iterate list
    list.each_with_index do |s, i|
      # Get fields
      replay_id = format != :json ? s[0] : s['replay_id']
      score     = format != :json ? s[1] : (60 * s['score'] / 1000.0).round
      player_id = format != :json ? s[2] : s['user_id']
      name      = format != :json ? s[3] : s['user_name']

      # Compute tied rank
      if !tied_score || tied_score > score
        tied_rank = i
        tied_score = score
      end

      # Create records
      RawPlayer.where(id: player_id).first_or_create(name: name)
      score = RawScore.where(highscoreable_type: type_id, replay_id: replay_id)
                      .first_or_create(
                        highscoreable_id: id,
                        player_id:        player_id,
                        rank:             i,
                        tied_rank:        tied_rank,
                        score:            score
                      )

      # Log
      dbg("Parsed #{i + 1} / #{count} raw scores for #{self.name}", progress: true)
    end

    count
  end

  def correct_ties(score_hash)
    score_hash.sort_by{ |s| [-s['score'], s['replay_id']] }
  end

  # Return a list of all dates where the top20 changed
  # We consider dates less than MAX_SECS apart to be the same
  # The board is unused but necessary for compatibility with the mappack version
  def changes(board = 'hs')
    return [] if is_userlevel?
    dates = Archive.where(highscoreable: self, cheated: false)
                   .order(:date)
                   .distinct
                   .pluck(:date)
    dates[0..-2].each_with_index.select{ |d, i| dates[i + 1] - d > MAX_SECS }
                .map(&:first).push(dates.last)
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
  # small     - Whether to find smallest or largest differences
  # player_id - Include only levels where the 0th is owned by player
  # full      - Export entire list (vs. top20 only)
  # mappack   - Use a mappack's boards (vs. vanilla)
  # board     - The mode (hs, sr), mappack-only
  # frac      - Compute spreads between fractional scores
  def self.spreads(n, type, tabs, small = false, player_id = nil, full = false, mappack = nil, board = 'hs', frac = false)
    # Sanitize parameters
    n      = n.clamp(0,19)
    type   = ensure_type(type, mappack: !mappack.nil?)
    type   = type.mappack if mappack
    frac &&= type.include?(Levelish)
    klass  = mappack ? MappackScore.where(mappack: mappack) : Score
    sfield = mappack ? "`score_#{board}`" : frac ? '`archives`.`score`' : '`score`'
    sfield += (board == 'hs' ? ' - ' : ' + ') + '`fraction`' if frac
    rfield = mappack ? "rank_#{board}" : 'rank'
    tname = type.table_name
    scale  = mappack && board == 'hs' || !mappack && frac ? 60.0 : 1
    bench(:start) if BENCHMARK

    # Fetch list of target scores
    list = klass.where(highscoreable_type: type)
                .where(!tabs.empty? ? { tab: tabs } : {})
    ids = list.where(rfield => 0, player_id: player_id).pluck('`highscoreable_id`') if player_id

    # Fetch spreads
    ret = list.joins(!mappack && frac ? 'INNER JOIN `archives` ON `archives`.`replay_id` = `scores`.`replay_id`' : '')
              .joins("INNER JOIN `#{tname}` ON `#{tname}`.`id` = `#{klass.table_name}`.`highscoreable_id`")
              .where(ids ? { highscoreable_id: ids } : {})
              .where("`#{rfield}` <= #{n}")
              .group(:highscoreable_id)
              .order("`spread` #{small ? 'ASC' : 'DESC'}", highscoreable_id: :asc)
              .limit(full ? nil : NUM_ENTRIES)
              .pluck(:highscoreable_id, :name, "(MAX(#{sfield}) - MIN(#{sfield})) / #{scale} AS `spread`")

    # Retrieve player names
    pnames = klass.where(highscoreable_type: type.to_s, highscoreable_id: ret.map(&:first), rfield => 0)
                  .joins("INNER JOIN `players` ON `players`.`id` = `player_id`")
                  .pluck('`highscoreable_id`', 'IF(`display_name` IS NOT NULL, `display_name`, `name`)')
                  .to_h

    # Format response
    ret = ret.map{ |id, level, spread| [level, spread, pnames[id]] }
    bench(:step) if BENCHMARK
    ret
  end

  # @par player_id: Exclude levels where the player already has a score
  # @par maxed:     Filter and sort differently for maxes and maxables
  # @par rank:      Return rankings of people with most scores in maxed / maxable levels
  # TODO: Change so that levels with all scores being equal also count towards being maxed,
  #       even if it's less than 20 due to cheaters. Ditto for maxables.
  def self.ties(type, tabs, player_id = nil, maxed = false, rank = false, mappack = nil, board = 'hs')
    type = ensure_type(type)
    bench(:start) if BENCHMARK

    # Prepare params
    type = type.mappack if mappack
    table = type.table_name
    rfield = (!mappack ? 'rank' : "rank_#{board}").to_sym
    trfield = (!mappack ? 'tied_rank' : "tied_rank_#{board}").to_sym

    # Retrieve highscoreables with more ties for 0th
    klass = mappack ? MappackScore : Score
    ret = !tabs.empty? ? klass.where(tab: tabs) : klass
    ret = ret.where(mappack: mappack) if mappack
    ret = ret.joins("INNER JOIN `#{table}` ON `#{table}`.`id` = `highscoreable_id`")
             .where(highscoreable_type: type, trfield => 0)
             .group(:highscoreable_id)
             .order(!maxed || mappack ? 'COUNT(`highscoreable_id`) DESC' : '', :highscoreable_id)
             .having("COUNT(`highscoreable_id`) >= #{MIN_TIES}")
             .having(!player_id.nil? ? 'amount = 0' : '')
             .pluck('`highscoreable_id`', 'COUNT(`highscoreable_id`)', '`name`', !player_id.nil? ? "COUNT(IF(`player_id` = #{player_id}, `player_id`, NULL)) AS `amount`" : '1')
             .map{ |a, b, c| [a, [b, c]] }
             .to_h

    # Retrieve score counts for each highscoreable
    counts = klass.where(highscoreable_type: type, highscoreable_id: ret.keys)
                  .group(:highscoreable_id)
                  .order('COUNT(`id`) DESC')
                  .count(:id) unless mappack

    # Filter highscoreables
    maxed ? ret.select!{ |id, arr| arr[0] >= (!mappack ? counts[id] : 20) } : ret.select!{ |id, arr| arr[0] < (!mappack ? counts[id] : 20) } if !maxed.nil?

    if rank
      # Return only IDs, for the rankings
      ret = ret.keys
    else
      # Fetch player names owning the 0ths on said highscoreables
      names = klass.where(highscoreable_type: type, highscoreable_id: ret.keys, rfield => 0)
                    .joins("INNER JOIN `players` ON `players`.`id` = `player_id`")
                    .pluck('`highscoreable_id`', 'IF(`display_name` IS NOT NULL, `display_name`, `name`)')
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
                .joins("INNER JOIN `#{table}` ON `#{table}`.`id` = `highscoreable_id` DIV #{count}")
                .group("`highscoreable_id` DIV #{count}")
                .sum(sfield)

    # Fetch episode/story 0th scores and compute cleanliness
    ret = query.where(highscoreable_type: type, rfield => rank)
               .joins("INNER JOIN `#{table}` ON `#{table}`.`id` = `highscoreable_id`")
               .joins('INNER JOIN `players` ON `players`.`id` = `player_id`')
               .pluck("`#{table}`.`id`", "`#{table}`.`name`", sfield, 'IF(`display_name` IS NULL, `players`.`name`, `display_name`)')
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

  def is_userlevel?
    self.is_a?(Userlevel)
  end

  def is_vanilla?
    !is_mappack? && !is_userlevel?
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

  def is_lotd?
    GlobalProperty.get_current(self.class.vanilla, is_mappack?) == self
  end

  def type_id
    case self
    when Levelish
      TYPE_LEVEL
    when Episodish
      TYPE_EPISODE
    when Storyish
      TYPE_STORY
    end
  end

  # Protected levels have secret replays
  def is_protected?
    return false if self.class == Userlevel
    code = map.mappack.code
    name = map.name[4..-1]
    PROTECTED_BOARDS.key?(code) && PROTECTED_BOARDS[code].include?(name)
  end

  # Private levels have secret scores (and replays)
  def is_private?
    return false if self.class == Userlevel
    return true if is_protected?
    code = map.mappack.code
    name = map.name[4..-1]
    PRIVATE_BOARDS.key?(code) && PRIVATE_BOARDS[code].include?(name)
  end

  # Arguments are unused, but they're necessary to be compatible with the corresponding
  # function in MappackHighscoreable
  def leaderboard(*args, **kwargs)
    return Archive.scores(self, kwargs[:date], full: kwargs[:truncate] == 0, **kwargs) if kwargs[:date]
    return scores if kwargs[:pluck] == false # not nil!
    ul = is_userlevel?
    attr_names = %W[rank id score name metanet_id replay_id]
    attrs = [
      'rank',
      "#{ul ? 'userlevel_' : ''}scores.id",
      'score',
      ul ? 'name' : 'IF(`display_name` IS NOT NULL, `display_name`, `name`)',
      'metanet_id',
      'replay_id'
    ]
    attr_names << 'cool' << 'star' if !ul
    attrs      << 'cool' << 'star' if !ul
    pclass = ul ? 'userlevel_players' : 'players'
    scores.joins("INNER JOIN `#{pclass}` ON `#{pclass}`.`id` = `player_id`")
          .pluck(*attrs).map{ |s| attr_names.zip(s).to_h }
  end

  # Format a single leaderboard for printing
  def format_scores_single(board = 'hs', np: 0, sp: 0, ranks: 20.times.to_a, full: false, cools: true, stars: true, cheated: false, frac: false, dev: true, prec: -1, flags: true, date: nil)
    # Reload scores, otherwise sometimes recent changes aren't in memory
    scores.reload
    boards = leaderboard(board, pluck: true, aliases: true, truncate: full ? 0 : 20, frac: frac && !is_vanilla?, cheated: cheated, date: date, cools: cools, stars: stars).each_with_index.select{ |_, r|
      full ? true : ranks.include?(r)
    }.sort_by{ |_, r| full ? r : ranks.index(r) }
    sfield = !is_mappack? ? 'score' : "score_#{board}"
    rfield = !is_mappack? ? 'replay_id' : 'id'

    # If we have a vanilla highscoreable and we don't provide a date then we're using
    # the scores table. Otherwise we're using the archives table or the mappack_scores table.
    vanilla_table = is_vanilla? && !date

    # Figure out if cheated scores need to be inserted (they already have if we provided a date)
    if SHOW_CHEATERS && cheated && vanilla_table
      cheated_scores = Archive.where(highscoreable: self, expired: false, cheated: true)
                              .joins("INNER JOIN `players` ON `players`.`metanet_id` = `archives`.`metanet_id`")
                              .order('`score` DESC', '`replay_id` ASC')
                              .pluck(:name, '`score` / 60.0', :metanet_id, :replay_id)
      cheated_scores.map!{ |s|
        h = {}
        h[sfield]       = s[1].to_f
        h['name']       = s[0]
        h['metanet_id'] = s[2]
        h[rfield]       = s[3]
        h['cool']       = false
        h['star']       = false
        h['cheated']    = true
        [h, -1]
      }
      boards += cheated_scores
      boards.sort_by!{ |s, _| [-(s[sfield] * 60).round, s[rfield]] }
    end

    # Scale scores stored as frame counts
    scale = is_mappack? && board == 'hs' || is_userlevel? || is_vanilla? && !!date
    boards.each{ |s, _| s[sfield] /= 60.0 } if scale

    # Figure out if interpolated fractional scores need to be used instead
    frac &&= is_level? && ['hs', 'sr'].include?(board)
    equals = []
    if frac
      if vanilla_table
        boards.each{ |s, _| s[sfield] = round_score(s[sfield]) } # Normalize scores
        fractions = Archive.where(highscoreable: self).pluck(:replay_id, :fraction).to_h
      end
      cools = false
      boards.each{ |s, _|
        fraction = vanilla_table ? fractions[s[rfield]] : s['fraction']
        s['question'] = true if fraction == 1
        if board == 'hs'
          s[sfield] -= fraction / 60.0
        elsif board == 'sr'
          s[sfield] += fraction
        end
      }
      boards.sort_by!{ |s, _| [board == 'hs' ? -s[sfield] : s[sfield], s[rfield]] }
      equals = boards.group_by{ |s, _| s[sfield] }
                     .select{ |_, list| list.size > 1 }
                     .map{ |_, list| list.map{ |s, _| s[rfield] } }
                     .flatten
    end

    # Insert DEV scores if required
    if dev && is_mappack? && (dev_score = board == 'hs' ? dev_hs : dev_sr)
      index = boards.index{ |s, _|
        board == 'hs' ? s[sfield] <= dev_score : s[sfield] >= dev_score
      }
      score = {
        sfield       => round_score(dev_score),
        'name'       => DEV_PLAYER_NAME,
        'metanet_id' => -1,
        rfield       => -1,
        'cool'       => false,
        'star'       => false,
        'fraction'   => 0,
        'cheated'    => false,
        'dev'        => true
      }
      boards.insert(index || -1, [score, -1])
    end

    # Calculate padding
    float = (!is_mappack? || board == 'hs' || frac) && prec != 0
    name_padding = np > 0 ? np : boards.map{ |s, _| s['name'].to_s.length }.max
    score_padding = sp > 0 ? sp : boards.map{ |s, _| s[sfield] }.max.to_i.to_s.length
    score_padding += float ? (prec > 0 ? prec : frac && board == 'hs' ? 6 : 3) + 1 : 0

    # Print scores
    color = !full || boards.size <= 20
    rank = -1
    boards.map{ |s, r|
      rank += 1 if !s['cheated'] && !s['dev']
      Scorish.format(
        name_padding, score_padding, cools: cools, stars: stars, mode: board,
        t_rank: rank, mappack: is_mappack?, userlevel: is_userlevel?, h: s,
        frac: frac, equal: equals.include?(s[rfield]), prec: prec, flags: flags,
        color: !color ? nil : s['cheated'] ? ANSI.red : s['dev'] ? ANSI.blue : nil
      )
    }
  end

  # Format a dual leaderboard for printing
  def format_scores_dual(np: 0, sp: 0, ranks: 20.times.to_a, full: false, cools: true, stars: true, cheated: false, frac: false, dev: true, prec: -1, flags: true, date: nil)
    # Fetch scores
    board_hs = format_scores_single('hs', np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars, cheated: cheated, frac: frac, dev: dev, prec: prec, flags: flags, date: date)
    board_sr = format_scores_single('sr', np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars, cheated: cheated, frac: frac, dev: dev, prec: prec, flags: flags, date: date)
    size = [board_hs.size, board_sr.size].max
    return [] if size == 0

    # Pad each board for alignment
    length_hs = board_hs.first.length rescue 0
    length_sr = board_sr.first.length rescue 0
    board_hs = board_hs.ljust(size, ' ' * length_hs)
    board_sr = board_sr.ljust(size, ' ' * length_sr)

    # Format boards
    header = '     ' + 'Highscore'.center(length_hs - 4) + '   ' + 'Speedrun'.center(length_sr - 4)
    [header, *board_hs.zip(board_sr).map{ |hs, sr| hs.sub(':', ' │') + ' │ ' + sr[4..-1] }]
  end

  # Format a leaderboard for printing
  def format_scores(np: 0, sp: 0, mode: 'hs', ranks: 20.times.to_a, join: true, full: false, cools: true, stars: true, cheated: false, frac: false, dev: true, prec: -1, flags: true, date: nil)
    ret = if !is_mappack? || mode != 'dual'
      format_scores_single(mode, np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars, cheated: cheated, frac: frac, dev: dev, prec: prec, flags: flags, date: date)
    else
      format_scores_dual(np: np, sp: sp, ranks: ranks, full: full, cools: cools, stars: stars, cheated: cheated, frac: frac, dev: dev, prec: prec, flags: flags, date: date)
    end
    ret = ["This #{self.class.to_s.remove('Mappack').downcase} has no scores!"] if ret.size == 0
    ret = ret.join("\n") if join
    ret
  end

  # Given a date, compute the differences between the current leaderboards and
  # the leaderboards on that date.
  def difference(date, board = 'hs')
    rfield = is_mappack? ? "rank_#{board}" : 'rank'
    sfield = is_mappack? ? "score_#{board}" : 'score'
    old_scale = !is_mappack? || board == 'hs' ? 60.0 : 1
    cur_scale =  is_mappack? && board == 'hs' ? 60.0 : 1

    # Fetch old and current leaderboards
    if is_mappack?
      old_boards = leaderboard(board, truncate: 0, pluck: true, date: date)
    else
      old_boards = Archive.scores(self, date.to_i, pluck: true)
    end
    cur_boards = leaderboard(board, pluck: false)

    # Compute differences
    cur_boards.map do |cur_score|
      old_score = old_boards.each_with_index.find{ |s, i|
        s['player_id'] == cur_score.player_id
      }
      change = {
        rank:  old_score[1] - cur_score[rfield],
        score: cur_score[sfield] / cur_scale - old_score[0][sfield] / old_scale
      } if old_score
      { score: cur_score, change: change }
    end
  end

  # Given the changes in a leaderboard, format the suffix for each line, containing
  # the change in rank and score, with colors if RICH_DIFFS is true.
  # c          - The change for this player, in the format given by "difference"
  # diff       - The output string, modified in place
  # diff_score - Include score change in the suffix (not used for dual boards)
  # pad_rank   - Length of rank change number
  # pad_change - Length of score change number
  # inc        - Whether higher scores are better, for coloring
  # TODO: Remove trailing whitespace
  def self.format_diff_change(c, diff, diff_score, pad_rank, pad_change, inc = true)
    # Score is brand new
    if !c
      diff << ANSI.alert if RICH_DIFFS && diff_score
      diff << 'NEW'
      diff << ' ' * (pad_change + 2) if diff_score
      diff << ANSI.reset if RICH_DIFFS
      return ANSI.alert
    end

    # Nothing changed (neither rank nor score)
    if c[:score].abs < 0.01 && c[:rank] == 0
      diff << '━'
      diff << ' ' * pad_rank
      diff << ' ' * (pad_change + 2) if diff_score
      return ANSI.none
    end

    # Determine score and rank colors
    better = inc && c[:score] >  0.01 || !inc && c[:score] < -0.01
    worse  = inc && c[:score] < -0.01 || !inc && c[:score] >  0.01
    score_color = better       ? ANSI.good : worse        ? ANSI.bad : ANSI.none
    rank_color  = c[:rank] > 0 ? ANSI.good : c[:rank] < 0 ? ANSI.bad : ANSI.none

    # Format rank change
    needs_color = diff_score && rank_color != ANSI.none || !diff_score && score_color != rank_color
    rank = "━▲▼"[c[:rank] <=> 0]
    rank << (c[:rank] != 0 ? "%-#{pad_rank}d" % [c[:rank].abs] : ' ' * pad_rank)
    diff << rank_color if RICH_DIFFS && needs_color
    diff << rank
    diff << ANSI.reset if RICH_DIFFS && rank_color != ANSI.none && !diff_score
    return score_color unless diff_score

    # Format score change (optional, we don't use it in dual boards)
    fmt = c[:score].is_a?(Integer) ? 'd' : '.3f'
    score = "(%+#{pad_change + 1}#{fmt})" % c[:score]
    changed = better || worse
    diff << score_color if RICH_DIFFS && score_color != rank_color
    diff << (changed ? ' ' + score : ' ' * (pad_change + 2))
    diff << ANSI.reset if RICH_DIFFS && score_color != ANSI.none

    score_color
  end

  # Format Top20 changes between the current boards and 'date' for a single board (e.g. hs / sr)
  # Returns an array of strings, one per line / rank
  #   diff_score : Show score changes
  #   empty      : Return an empty array if there are no differences
  def format_difference_board(date, board = 'hs', diff_score: true, empty: true, pad_end: false)
    difffs = difference(date, board)
    return [] if empty && difffs.all?{ |d| !d[:change].nil? && d[:change][:score].abs < 0.01 && d[:change][:rank] == 0 }

    sfield = is_mappack? ? "score_#{board}" : 'score'
    scale  = is_mappack? && board == 'hs' ? 60.0 : 1
    offset = is_mappack? && board == 'sr' ? 0 : 4

    pad_name   = difffs.map{ |o| o[:score].player.print_name.length }.max
    pad_score  = difffs.map{ |o| (o[:score][sfield] / scale).abs.to_i }.max.to_s.length + offset
    pad_rank   = [difffs.map{ |d| d[:change] }.compact.map{ |c| c[:rank].abs.to_i  }.max.to_s.length, 2].max
    pad_change = difffs.map{ |d| d[:change] }.compact.map{ |c| c[:score].abs.to_i }.max.to_s.length + offset
    pad_rank   = 0 if !pad_end && !diff_score
    pad_change = 0 if !pad_end

    difffs.each_with_index.map{ |o, i|
      diff = ''
      score = o[:score].format(pad_name, pad_score, false, board, i)
      color = Highscoreable.format_diff_change(o[:change], diff, diff_score, pad_rank, pad_change, board != 'sr')
      score.gsub!(/(\S+)$/, color + '\1') if RICH_DIFFS && !diff_score && color != ANSI.none
      "#{score} #{diff}"
    }
  rescue => e
    lex(e, 'Formatting leaderboard differences')
    nil
  end

  # Format Top20 changes between the current boards and the boards on 'date'
  # Returns a string, empty if no differences. Returns nil if error.
  def format_difference(date, board = 'hs')
    # Differences for a single board
    return format_difference_board(date, board).join("\n") if !is_mappack? || board != 'dual'

    # Construct differences for dual boards (hs and sr)
    diffs_hs = format_difference_board(date, 'hs', diff_score: false, empty: false, pad_end: true)
    diffs_sr = format_difference_board(date, 'sr', diff_score: false, empty: false)

    # Return empty string if there are no differences in hs nor sr
    empty_hs = diffs_hs.count{ |d| d.strip[-1] == '━' && d.scan(/\x1B\[\d+m/).size == 0 } == diffs_hs.size
    empty_sr = diffs_sr.count{ |d| d.strip[-1] == '━' && d.scan(/\x1B\[\d+m/).size == 0 } == diffs_sr.size
    return '' if diffs_hs.empty? && diffs_sr.empty? || empty_hs && empty_sr

    # Pad both boards to the same size (they should already be!)
    length_hs = diffs_hs.first.gsub(/\x1B\[\d+m/, '').length rescue 0
    length_sr = diffs_sr.first.gsub(/\x1B\[\d+m/, '').length rescue 0
    size = [diffs_hs.size, diffs_sr.size].max
    diffs_hs = diffs_hs.ljust(size, ' ' * length_hs)
    diffs_sr = diffs_sr.ljust(size, ' ' * length_sr)

    # Format header and list
    header = '     ' + 'Highscore'.center(length_hs - 4) + '   ' + 'Speedrun'.center(length_sr - 4)
    ret = [header, *diffs_hs.zip(diffs_sr).map{ |hs, sr| hs.sub(':', ' │') + ' │ ' + sr[4..-1] }]
    ret.join("\n")
  rescue => e
    lex(e, 'Formatting leaderboard differences')
    nil
  end

  # Format the message for Top20 changes, header included
  def format_difference_message(diff, date, past: false, explicit: false)
    # Format highscoreable reference
    if explicit
      name = format_name
    else
      article = past ? 'last' : 'this'
      period = is_level? ? 'day' : is_episode? ? 'week' : 'month'
      since = is_level? ? (past ? 'yesterday' : 'today') : is_episode? ? "#{article} week" : "#{article} month"
      type = is_story? ? 'column' : self.class.to_s.downcase.remove('mappack')
      mappack = is_mappack? ? self.mappack.code.upcase : ''
      name = "#{since}'s #{mappack} #{type} of the #{period}, #{format_name},"
    end
    span = format_timestamp(date, date: true, long: true)

    # Format header and message
    changes = "top20 changes on #{name} since #{span}"
    return "Failed to calculate #{changes}.".squish if diff.nil?
    return "There #{past ? 'were' : 'have been'} no #{changes} :(".squish if diff.strip.empty?
    format_header(changes) + format_block(diff)
  end

  # Computes the amount of cool scores on the board
  # TODO: Support frac
  def find_coolness(scores: nil, date: nil, board: 'hs')
    # Fetch list of scores
    scores = scores ? scores.map(&:dup) : leaderboard(board, aliases: true, date: date)
    return 0 if scores.empty?
    hs = board == 'hs'
    sfield = !is_mappack? ? 'score' : "score_#{board}"
    if hs
      scores.each{ |s| s[sfield] /= 60.0 } if is_mappack? || date
      scores.each{ |s| s[sfield] = round_score(s[sfield]) }
    end

    # Compare string scores and find first difference
    max = scores.max_by{ |s| s[sfield] }[sfield].to_i.to_s.length
    max += 4 if hs
    fmt = hs ? '%0*.3f' : '%0*d'
    s1  = fmt % [max, scores.first[sfield]]
    s2  = fmt % [max, scores.last[sfield]]
    d   = (0...max).find{ |i| s1[i] != s2[i] }
    return 0 if !d

    # Count scores before first difference
    d = hs ? -(max - d - 5) - (max - d < 4 ? 1 : 0) : -(max - d - 1)
    threshold = scores[0][sfield].truncate(d)
    threshold += 10 ** -d if !hs
    scores.index{ |s| hs ? s[sfield] < threshold : s[sfield] >= threshold } || 0
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
    old_id = is_mappack? ? inner_id : id

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

    new_id += type[:slots] * mappack.id if is_mappack?
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
  TYPE = TYPE_LEVEL

  # Return the Map object (containing map data), if it exists
  def map
    self.is_a?(Level) ? MappackLevel.find_by(id: id) : self
  end

  # Return the corresponding Level object of a MappackLevel
  # 'null' determines whether to return nil or self if no equivalent exists
  def vanilla(null = false)
    return self if self.is_a?(Level) || is_userlevel?
    level = Level.find_by(id: id)
    return level ? level : null ? nil : self
  end

  def story
    self.episode.story
  end

  def levels
    [self]
  end

  def format_name(bold: false)
    bd = bold ? '**' : ''
    str = "#{verbatim(longname)} (#{bd}#{name.remove('MET-')}#{bd})"
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
    h_id = is_mappack? ? inner_id : id

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
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

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
  TYPE = TYPE_EPISODE

  # Return the Map object (containing map data), if it exists
  def map
    self.is_a?(Episode) ? MappackEpisode.find_by(id: id) : self
  end

  def vanilla(null = false)
    return self if self.is_a?(Episode)
    episode = Episode.find_by(id: id)
    return episode ? episode : null ? nil : self
  end

  def is_eotw?
    GlobalProperty.get_current(Episode, is_mappack?) == self
  end

  def format_name(bold: false)
    bd = bold ? '**' : ''
    "#{bd}#{name.remove('MET-')}#{bd}"
  end

  def cleanliness(rank = 0, board = 'hs')
    klass  = !is_mappack? ? Score : MappackScore
    rfield = (!is_mappack? ? 'rank' : "rank_#{board}").to_sym
    sfield = (!is_mappack? ? 'score' : "score_#{board}").to_sym
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

  def splits(rank = 0, board: 'hs', frac: false)
    sfield  = !is_mappack? ? 'score' : "score_#{board}"
    start   = is_mappack? && board == 'sr' ? 0 : 90.0
    factor  = is_mappack? && board == 'hs' ? 60.0 : 1
    offset  = !is_mappack? || board == 'hs' ? 90.0 : 0
    scores  = levels.map{ |l| l.leaderboard(board, frac: frac)[rank][sfield] }
    splits_from_scores(scores, start: start, factor: factor, offset: offset, frac: frac)
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
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

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
  TYPE = TYPE_STORY

  # Return the Map object (containing map data), if it exists
  def map
    self.is_a?(Story) ? MappackStory.find_by(id: id) : self
  end

  def vanilla(null = false)
    return self if self.is_a?(Story)
    story = Story.find_by(id: id)
    return story ? story : null ? nil : self
  end

  def is_cotm?
    GlobalProperty.get_current(Story, is_mappack?) == self
  end

  def format_name(bold: false)
    bd = bold ? '**' : ''
    "#{bd}#{name.remove('MET-')}#{bd}"
  end

  def levels
    (is_mappack? ? MappackLevel : Level).where("id DIV 25 = #{id}").order(:id)
  end

  def cleanliness(rank = 0, board = 'hs')
    klass  = !is_mappack? ? Score : MappackScore
    rfield = (!is_mappack? ? 'rank' : "rank_#{board}").to_sym
    sfield = (!is_mappack? ? 'score' : "score_#{board}").to_sym
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
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

  def self.mappack
    MappackStory
  end

  def self.vanilla
    Story
  end
end

# Implemented by Score and MappackScore
module Scorish

  def self.format(
      name_pad  = DEFAULT_PADDING,
      score_pad = 0,
      cools:      true,
      stars:      true,
      mode:       'hs',
      t_rank:     nil,
      mappack:    false,
      userlevel:  false,
      h:          {},
      frac:       false,
      equal:      false,
      prec:       -1,
      flags:      true,
      color:      nil
    )
    mode = 'hs' if mode.nil?
    hs = mode == 'hs'
    cheat = !!h['cheated']
    dev = !!h['dev']
    decimals = (!mappack || hs || frac) && prec != 0 ? (prec > 0 ? prec : hs && frac ? 6 : 3) : 0

    # Compose each element
    t_star   = userlevel || mappack || !stars || !flags ? '' : (h['star'] ? '*' : ' ')
    t_rank   = cheat ? 'xx' : dev ? '++' : t_rank || h['rank'] || '--'
    t_rank   = Highscoreable.format_rank(t_rank)
    t_player = format_string(h['name'], name_pad)
    f_score  = !mappack ? 'score' : "score_#{mode}"
    t_fmt    = decimals > 0 ? "%#{score_pad}.#{decimals}f" : "%#{score_pad}d"
    t_score  = t_fmt % [h[f_score]]
    t_cool   = flags && cools && h['cool'] ? " 😎" : ""
    t_eql    = flags && equal && !h['question'] ? ' =' : ''
    t_quest  = flags && h['question'] ? ' ?' : ''

    # Put everything together
    line = "#{t_star}#{t_rank}: #{t_player} - #{t_score}#{t_cool}#{t_eql}#{t_quest}"
    line = "#{color}#{line}#{ANSI.clear}" if color
    line
  end

  def self.total_scores(type, tabs, secrets, x = true, mappack = nil, board = 'hs', frac = false)
    bench(:start) if BENCHMARK
    # Prepare fields
    klass  = !mappack ? Score : MappackScore.where(mappack: mappack)
    sfield = !mappack ? '`scores`.`score`' : board == 'hs' ? '`score_hs` / 60.0' : '`score_sr`'
    sfield += board == 'hs' ? ' - `fraction` / 60.0' : ' + `fraction`' if frac
    tabs   = (tabs.empty? ? TABS_SOLO : tabs) - TABS_SECRET if type.include?(Levelish) && !secrets

    # Ignore X row (assuming it's at the end of the tab)
    size = TYPES[type.vanilla.to_s][:size]
    hfield = !mappack ? '`scores`.`highscoreable_id`' : 'MOD(`mappack_scores`.`highscoreable_id`, 20000)'
    sql_ranges = TABS_NEW.select{ |k, v| v[:mode] == MODE_SOLO && !v[:secret] && v[:x] }
                        .map{ |k, v|
                          [
                            (v[:start] + 5.0 * v[:size] / 6).to_i / size,
                            (v[:start] + v[:size] - 1).to_i / size
                          ]
                        }.map{ |s, e|
                          "(#{hfield} NOT BETWEEN #{s} AND #{e})"
                        }.join(' AND ')

    # Compute community total score
    total = klass.joins(!mappack && frac ? "INNER JOIN `archives` ON `archives`.`replay_id` = `scores`.`replay_id`" : '')
                  .where(highscoreable_type: mappack ? type.mappack : type.vanilla)
                  .where(!tabs.empty? ? { tab: tabs } : {})
                  .where(!x ? sql_ranges : '')
                  .group(:highscoreable_id)
                  .pluck(board == 'hs' ? "MAX(#{sfield})" : "MIN(#{sfield})")

    bench(:step) if BENCHMARK
    [frac ? total.sum : round_score(total.sum), total.count]
  end

  def format(name_padding = DEFAULT_PADDING, score_padding = 0, cools = true, mode = 'hs', t_rank = nil)
    h = self.as_json
    h['name'] = player.print_name if !h.key?('name')
    h['score_hs'] /= 60.0 if highscoreable.is_mappack?
    Scorish.format(name_padding, score_padding, cools: cools, mode: mode, t_rank: t_rank, mappack: self.is_a?(MappackScore), h: h)
  end

  def splits(board = 'hs', event: nil, frac: false)
    return if !highscoreable.is_episode?

    # Speedrun splits do not require nsim
    if board == 'sr'
      scores = Demo.decode(demo.demo, true).map(&:size)
      splits = splits_from_scores(scores, start: 0, factor: 1, offset: 0, frac: frac)
      return { valid:  [true] * 5, scores: scores, splits: splits }
    end
    return if !FEATURE_NTRACE

    # Execute ntrace in mutex
    TmpMsg.update(event, '-# Running simulation...') if event
    nsim = NSim.new(highscoreable.levels.map{ |l| l.map.dump_level }, demo.demo)
    nsim.run
    res = { valid: nsim.valid_flags, splits: nsim.splits, scores: nsim.scores }
    nsim.destroy
    res
  end
end

class Score < ActiveRecord::Base
  include Scorish
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
#  default_scope -> { select("scores.*, score * 1.000 as score")} # Ensure 3 correct decimal places
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

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
      board   = 'hs',  # Playing mode
      old     = false, # Include obsolete scores (only makes sense for mappacks)
      dev     = false  # Include only over-DEV scores
    )

    # Adapt params for mappacks, if necessary
    type = fix_type(type)
    board = 'hs' if !['hs', 'sr'].include?(board)
    ttype = "#{ties ? 'tied_' : ''}rank#{mappack ? "_#{board}" : ''}".to_sym
    if !mappack.nil?
      klass = MappackScore.where(mappack: mappack)
      klass = klass.where.not(ttype => nil) unless old
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
      queries.last.where(!a.blank?  ? "`#{ttype}` >= #{a}" : nil)
                  .where(!b.blank?  ? "`#{ttype}` < #{b}"  : nil)
    )
    queries.push(
      queries.last.where(cool && !mappack ? { cool: true } : nil)
                  .where(star && !mappack ? { star: true } : nil)
    )

    # Over-DEV scores are special and require a join
    if dev && mappack
      join = <<~STR.gsub(/\s+/, ' ').strip
        LEFT JOIN `mappack_levels`   ON (`mappack_scores`.`highscoreable_type` = 'MappackLevel'   AND `mappack_levels`.`id`   = `mappack_scores`.`highscoreable_id`)
        LEFT JOIN `mappack_episodes` ON (`mappack_scores`.`highscoreable_type` = 'MappackEpisode' AND `mappack_episodes`.`id` = `mappack_scores`.`highscoreable_id`)
        LEFT JOIN `mappack_stories`  ON (`mappack_scores`.`highscoreable_type` = 'MappackStory'   AND `mappack_stories`.`id`  = `mappack_scores`.`highscoreable_id`)
      STR
      dev_score = <<~STR.gsub(/\s+/, ' ').strip
        CASE
          WHEN `mappack_scores`.`highscoreable_type` = 'MappackLevel'   THEN `mappack_levels`.`dev_#{board}`
          WHEN `mappack_scores`.`highscoreable_type` = 'MappackEpisode' THEN `mappack_episodes`.`dev_#{board}`
          WHEN `mappack_scores`.`highscoreable_type` = 'MappackStory'   THEN `mappack_stories`.`dev_#{board}`
          ELSE ''
        END
      STR
      queries[-1] = queries[-1].joins(join).where("`score_#{board}` #{board == 'hs' ? '>' : '<'} (#{dev_score})#{board == 'hs' ? ' * 60.0' : ''}")
    end

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
      dev:     false, # Only over-DEV scores.     Def: No.
      frac:    false, # Use fractional scores.    Def: No.
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
    type     = fix_type(type, [:avg_lead, :score, :maxed, :maxable].include?(ranking))
    basetype = type
    type     = [type].flatten.map{ |t| "Mappack#{t.to_s}".constantize } if !mappack.nil?
    level    = 2
    level    = 1 if (mappack && !dev) || [:maxed, :maxable].include?(ranking)
    level    = 0 if [:tied_rank, :avg_lead, :singular, :score, :gp, :gm].include?(ranking)
    old      = [:gp, :gm].include?(ranking)
    scores   = filter(level, nil, type, tabs, a, b, ties, cool, star, mappack, board, old, dev)
    scores   = scores.where.not(player: players) if !mappack.nil? && !players.empty?

    # Named fields
    rankf  = mappack.nil? ? 'rank' : "rank_#{board}"
    trankf = "tied_#{rankf}"
    sfield = !mappack ? '`scores`.`score`' : board == 'hs' ? '`score_hs` / 60.0' : '`score_sr`'
    sfield += board == 'hs' ? ' - `fraction` / 60.0' : ' + `fraction`' if frac

    # Perform specific rankings to filtered scores
    bench(:start) if BENCHMARK
    case ranking
    when :rank
      scores = scores.group(:player_id)
                     .order('`count_id` DESC')
                     .count(:id)
    when :tied_rank
      scores_w  = scores.where(!a.blank? ? "`#{trankf}` >= #{a}" : nil)
                        .where(!b.blank? ? "`#{trankf}` < #{b}"  : nil)
                        .group(:player_id)
                        .order('`count_id` DESC')
                        .count(:id)
      scores_wo = scores.where(!a.blank? ? "`#{rankf}` >= #{a}" : nil)
                        .where(!b.blank? ? "`#{rankf}` < #{b}"  : nil)
                        .group(:player_id)
                        .order('`count_id` DESC')
                        .count(:id)
      scores = scores_w.map{ |id, count| [id, count - scores_wo[id].to_i] }
                       .sort_by{ |id, c| -c }
    when :singular
      types = type.map{ |t|
        ids = scores.where(rankf.to_sym => 1, trankf.to_sym => b, highscoreable_type: t)
                    .pluck(:highscoreable_id)
        scores.where(rankf.to_sym => 0, highscoreable_type: t, highscoreable_id: ids)
              .group(:player_id)
              .count(:id)
      }
      scores = types.map(&:keys).flatten.uniq.map{ |id|
        [id, types.map{ |t| t[id].to_i }.sum]
      }.sort_by{ |id, c| -c }
    when :points
      scores = scores.group(:player_id)
                     .order("SUM(#{ties ? "20 - `#{trankf}`" : "20 - `#{rankf}`"}) DESC")
                     .sum(ties ? "20 - `#{trankf}`" : "20 - `#{rankf}`")
    when :avg_points
      scores = scores.select("COUNT(`player_id`)")
                     .group(:player_id)
                     .having("COUNT(`player_id`) >= #{min_scores(basetype, tabs, false, a, b, star, mappack)}")
                     .order("AVG(#{ties ? "20 - `#{trankf}`" : "20 - `#{rankf}`"}) DESC")
                     .average(ties ? "20 - `#{trankf}`" : "20 - `#{rankf}`")
    when :avg_rank
      scores = scores.select("COUNT(`player_id`)")
                     .group(:player_id)
                     .having("COUNT(`player_id`) >= #{min_scores(basetype, tabs, false, a, b, star, mappack)}")
                     .order("AVG(`#{ties ? trankf : rankf}`)")
                     .average('`' + (ties ? trankf : rankf) + '`')
    when :avg_lead
      scores = scores.where(rankf => [0, 1])
                     .pluck(:player_id, :highscoreable_id, sfield)
                     .group_by{ |s| s[1] }
                     .reject{ |h, s| s.size < 2 }
                     .map{ |h, s| [s[0][0], (s[0][2] - s[1][2]).abs] }
                     .group_by{ |s| s[0] }
                     .map{ |p, s| [p, s.map(&:last).sum.to_f / s.map(&:last).count] }
                     .sort_by{ |p, s| -s }
    when :score
      asc = !mappack.nil? && board == 'sr'
      scores = scores.joins(!mappack && frac ? "INNER JOIN `archives` ON `archives`.`replay_id` = `scores`.`replay_id`" : '')
                     .where(!mappack && frac ? { archives: { highscoreable_type: type } } : {} )
                     .group(:player_id)
                     .order(asc ? 'COUNT(`id`) DESC' : '', "`sfield` #{asc ? 'ASC' : 'DESC'}")
                     .pluck(:player_id, "SUM(#{sfield}) AS `sfield`", "COUNT(`#{rankf}`)")
                     .map{ |id, score, count|
                        score = round_score(score.to_f) unless frac
                        score = score.to_i if mappack && board == 'sr' && !frac
                        [id, score, asc ? count : nil]
                      }
    when :maxed
      scores = scores.where(highscoreable_id: Highscoreable.ties(basetype, tabs, nil, true, true, mappack, board))
                     .where("`#{trankf}` = 0")
                     .group(:player_id)
                     .order("COUNT(`id`) DESC")
                     .count(:id)
    when :maxable
      scores = scores.where(highscoreable_id: Highscoreable.ties(basetype, tabs, nil, false, true, mappack, board))
                     .where("`#{trankf}` = 0")
                     .group(:player_id)
                     .order("COUNT(`id`) DESC")
                     .count(:id)
    when :gp
      query = scores.select(:player_id, :highscoreable_id, 'MAX(`gold`) AS `gold`')
                    .group(:player_id, :highscoreable_id)
      scores = MappackScore.from(query, :t)
                           .group(:player_id)
                           .order('`sum_t_gold` DESC')
                           .sum('`t`.`gold`')
    when :gm
      query = scores.select(:player_id, :highscoreable_id, 'MIN(`gold`) AS `gold`')
                    .group(:player_id, :highscoreable_id)
      scores = MappackScore.from(query, :t)
                           .group(:player_id)
                           .order('COUNT(*) DESC', 'SUM(`gold`) ASC')
                           .pluck('`t`.`player_id`', 'SUM(`gold`)', 'COUNT(*)')
    end

    # Find players and save their display name, if it exists, or their name otherwise
    players = Player.where(id: scores.map(&:first))
                    .pluck(:id, "IF(`display_name` IS NULL, `name`, `display_name`)")
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
     .map{ |id, c| [Player.find(id).name, c] }
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
    sql_str = %{
      SELECT `min`, COUNT(`min`) FROM (
        SELECT MIN(`rank`) AS `min` FROM `scores` GROUP BY `player_id`
      ) AS `t` GROUP BY `min`;
    }.gsub(/\s+/, ' ').strip
    res = sql(sql_str).rows.to_h
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
  has_many :scores
  has_many :player_aliases
  has_many :mappack_scores
  has_many :mappack_scores_tweaks
  alias_method :aliases, :player_aliases
  alias_method :tweaks,  :mappack_scores_tweaks

  # Only works for 1 type at a time
  def self.comparison_(type, tabs, p1, p2)
    type = ensure_type(type)
    request = Score.where(highscoreable_type: type)
    request = request.where(tab: tabs) if !tabs.empty?
    t = type.to_s.downcase.pluralize
    bench(:start) if BENCHMARK
    ids = request.where(player: [p1, p2])
                 .joins("INNER JOIN `#{t}` ON `#{t}`.`id` = `scores`.`highscoreable_id`")
                 .group(:highscoreable_id)
                 .having('COUNT(`highscoreable_id`) > 1')
                 .pluck('MIN(`highscoreable_id`)')
    scores1 = request.where(highscoreable_id: ids, player: p1)
                     .joins("INNER JOIN `#{t}` ON `#{t}`.`id` = `scores`.`highscoreable_id`")
                     .order(:highscoreable_id)
                     .pluck(:rank, :highscoreable_id, "`#{t}`.`name`", :score)
    scores2 = request.where(highscoreable_id: ids, player: p2)
                     .joins("INNER JOIN `#{t}` ON `#{t}`.`id` = `scores`.`highscoreable_id`")
                     .order(:highscoreable_id)
                     .pluck(:rank, :highscoreable_id, "`#{t}`.`name`", :score)
    scores = scores1.zip(scores2).group_by{ |s1, s2| s1[3] <=> s2[3] }
    s1 = request.where(player: p1)
                .where.not(highscoreable_id: ids)
                .joins("INNER JOIN `#{t}` ON `#{t}`.`id` = `scores`.`highscoreable_id`")
                .pluck(:rank, :highscoreable_id, "`#{t}`.`name`", :score)
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
                .joins("INNER JOIN `#{t}` ON `#{t}`.`id` = `scores`.`highscoreable_id`")
                .pluck(:rank, :highscoreable_id, "`#{t}`.`name`", :score)
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
    action_inc('http_login')
    res = forward(req)
    invalid = res.nil? || res == METANET_INVALID_RES
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
      steam_auth = req.query_string.split('&').map{ |s| s.split('=') }.to_h['steam_auth']
      SteamTicket.add_ascii(steam_auth) if !steam_auth.blank?
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

  # Send a POST request to N++'s server with this player
  def send_post(path, args: {}, parts: [], auth: true, silent: false)
    if !steam_id
      err("No Steam ID for #{name}") unless silent
      return nil
    end
    args = { user_id: metanet_id, steam_id: steam_id }.merge(args)
    tkt = ticket
    steam_auth = tkt && !tkt.expired? ? tkt.ascii : ''
    args.merge!({ steam_auth: steam_auth })
    res = post_form(path: path, args: args, parts: parts, silent: silent)
    if !res
      err("Failed to POST to #{path} via #{name} (bad HTTP).") unless silent
      return
    end
    if res == METANET_INVALID_RES
      err("Failed to POST to #{path} via #{name} (inactive Steam ID).")
      return if !auth || !authenticate
      return send_post(path, args: args, parts: parts, auth: false, silent: silent)
    end
    res
  end

  # Manually craft and send the login request for this player
  def login(steam_auth: nil)
    parts = [
      { name: 'user_id',    binary: false, value: metanet_id.to_s },
      { name: 'size',       binary: false, value: '16'            },
      { name: 'stats_size', binary: false, value: '0'             },
      { name: 'data',       binary: true,  value: "\x00" * 16     },
      { name: 'stats',      binary: true,  value: ''              }
    ]
    args = steam_auth ? { steam_auth: steam_auth } : {}
    send_post(METANET_POST_LOGIN, args: args, parts: parts)
  end

  # The player's Steam session authentication ticket sent to N++'s servers
  def ticket
    return if !steam_id
    SteamTicket.find_by(steam_id: steam_id, app_id: APP_ID)
  end

  # Get the player's Steam refresh token that can be used to login. It's issued
  # on command when we login with username and password and expires in ~200 days.
  def refresh_token
    return nil if !steam_id
    ENV["STEAM_TOKEN_#{steam_id}"]
  end

  # Authenticates the player by generating a Steam auth ticket and validating it
  # using Steamwork's API. This is then sent to N++'s server in the steam_auth
  # parameter of the query. See SteamTicket for more info.
  def authenticate
    return nil if !refresh_token
    if ticket
      ticket.refresh(token: refresh_token)
    else
      SteamTicket.generate(APP_ID, token: refresh_token)
    end
  end

  # Perform a request to N++'s server using this player's Steam ID
  # TODO: Might be a good idea to clean up get_data by calling this function,
  #       though obviously not perroring in that case.
  def request(type, log: true, discord: false, auth: false, **uri_args)
    # Ensure we know the player's Steam ID
    if !steam_id
      err("Player #{name}:#{metanet_id} has no Steam ID") if log
      perror("I don't know your Steam ID!") if discord
      return
    end

    # Perform HTTP request
    tkt = ticket
    steam_auth = tkt && !tkt.expired? ? tkt.ascii : ''
    res = Net::HTTP.get_response(npp_uri(type, steam_id, steam_auth: steam_auth, **uri_args))

    # Request failed
    if !res || !res.code.to_i.between?(200, 299)
      err("HTTP request for #{type} failed (#{!!res ? res.code : '?'})") if log
      perror("Failed to query Metanet score, try again later") if discord
      return
    end

    # Player is not authenticated in Steam
    if res.body == METANET_INVALID_RES
      err("Steam ID #{name}:#{steam_id} is inactive") if log
      perror("Your Steam account isn't active, please open N++") if discord
      return if !auth || !authenticate
      return request(type, log: log, discord: discord, auth: false, **uri_args)
    end

    res.body
  end

  # Downloads the scores for the specified highscoreable with this player's Steam ID
  def get_scores(h, qt: 0, log: true, discord: false, auth: false)
    return if !h.is_a?(Downloadable)
    id_key = (h.is_userlevel? ? 'level' : h.class.to_s.downcase) + '_id'
    res = request(:scores, qt: qt, id_key => h.id, log: log, discord: discord, auth: auth)
    return if !res
    JSON.parse(res)
  end

  # Fetches the player's score in the specified highscoreable
  def get_score(h, log: true, discord: false, auth: false)
    # Download scores
    json = get_scores(h, log: log, discord: discord, auth: auth)
    scores = h.correct_ties(h.clean_scores(json['scores']))

    # First, try to find personal score in global leaderboard.
    score, rank = scores.each_with_index.find{ |s, i| s['user_id'] == metanet_id }
    return { score: score['score'] / 1000.0, rank: rank, replay_id: score['replay_id'] } if score

    # Then, try to find it in the personal field
    score = json['userInfo']
    return { score: score['my_score'] / 1000.0, rank: score['my_rank'], replay_id: score['my_replay_id'] } if score

    # No personal score found
    err("Player #{name}:#{metanet_id} has no server score in #{h.name}") if log
    perror("#{format_name} has no #{h.name} score in the server") if discord
    nil
  end

  # Fetches the player's replay given the type and ID
  # TODO: I feel like some of this logic should be in the Demo class
  def get_replay(h, replay_id, log: true, discord: false)
    return if !h.is_a?(Downloadable)

    # Perform HTTP request
    type = TYPES[h.class.to_s.remove('Mappack')] || TYPES['Level']
    qt = type[:qt] rescue 0
    res = request(:replay, qt: qt, replay_id: replay_id, log: log, discord: discord)
    return if !res

    # Replay doesn't exist anymore
    if res.empty?
      err("#{type[:name]} replay #{replay_id} does not exist anymore") if log
      perror("The requested replay doesn't exist in the server anymore") if discord
      return
    end

    # Integrity checks (see format documentation in Demo)
    rt, rid, hid, uid = res[0, 16].unpack('l<4')
    if rt != type[:rt] || rid != replay_id || uid != metanet_id
      err("Received replay header doesn't match expected values") if log
      perror("Received corrupt replay data from the server") if discord
      return
    end

    # Parse demo data
    Demo.parse(res[16..], type[:name])
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

  # Find the current PB of the player in a mappack highscoreable in a given board
  def find_pb(h, board, frac: false)
    return if !h.is_mappack?
    scores = h.scores.where(player: self)
    case board
    when 'hs'
      score = !frac ? '`score_hs` DESC' : '`score_hs` - `fraction` DESC'
      scores.order(score, :date).first
    when 'sr'
      score = !frac ? '`score_sr` ASC' : '`score_sr` + `fraction` ASC'
      scores.order(score, :date).first
    when 'gm'
      scores.order(:gold, :date).first
    when 'gp'
      scores.order(gold: :desc, date: :asc).first
    end
  end

  # Update the rank field of the PB in a given mappack highscoreable, used
  # mainly when a player's score changes (is improved, patched or removed)
  def update_rank(h, board, frac: false)
    return if !h.is_mappack? || !['hs', 'sr'].include?(board)
    rankf = 'rank_' + board
    trankf = 'tied_' + rankf
    scores = h.scores.where(player: self)
    scores.update_all(rankf => nil, trankf => nil)
    pb = find_pb(h, board, frac: frac)
    pb.update(rankf => -1, trankf => -1) if pb
    h.update_ranks(board, frac: frac)
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
        list = list.where(gold: 0)
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
    scores_by_type_and_tabs(type, tabs).where("#{ties ? "`tied_rank`" : "`rank`"} < #{n}")
  end

  # Fetch player's scores (or, alternatively, missing scores) filtering by many
  # parameters, like type, tabs, rank...
  #
  # NOTE:
  #   If we're asking for missing 'cool' or 'star' scores, we actually take the
  #   scores the player HAS which are missing the cool/star badge.
  #   Otherwise, missing includes all the scores the player DOESN'T have.
  def range_ns(
      a,               # Bottom rank (nil = start = 0)
      b,               # Lower rank (nil = end)
      type,            # Type
      tabs,            # Tab list
      ties,            # Include ties when filtering by rank (use tied rank field)
      tied    = false, # Only include tied scores when filtering by rank
      cool    = false, # Scores must be cool
      star    = false, # Scores must be star (ex-0ths)
      missing = false, # Fetch missing scores with the desired properties
      mappack = nil,   # Mappack to use (nil = Metanet)
      board   = 'hs',  # Leaderboard type
      dev     = false, # Score must be better than the DEV score
      join:     false  # Join the result set with the highscoreables table
    )
    return missing(type, tabs, a, b, ties, tied, mappack, board, dev) if missing && !cool && !star

    # Return highscoreable names rather than scores
    high = !mappack.nil? && board == 'gm'

    # Filter scores by type and tabs
    ret = scores_by_type_and_tabs(type, tabs, nil, mappack, board)
    types = "FIELD(`highscoreable_type`, 'Level', 'Episode', 'Story', 'MappackLevel', 'MappackEpisode', 'MappackStory')"
    return ret.order(types, '`highscoreable_id`') if high

    # Optionally join scores with highscoreable tables
    if join || dev
      c = mappack ? 'Mappack'  : ''
      t = mappack ? 'mappack_' : ''
      join = <<~STR.gsub(/\s+/, ' ').strip
        LEFT JOIN `#{t}levels`   ON (`#{t}scores`.`highscoreable_type` = '#{c}Level'   AND `#{t}levels`.`id`   = `#{t}scores`.`highscoreable_id`)
        LEFT JOIN `#{t}episodes` ON (`#{t}scores`.`highscoreable_type` = '#{c}Episode' AND `#{t}episodes`.`id` = `#{t}scores`.`highscoreable_id`)
        LEFT JOIN `#{t}stories`  ON (`#{t}scores`.`highscoreable_type` = '#{c}Story'   AND `#{t}stories`.`id`  = `#{t}scores`.`highscoreable_id`)
      STR
      ret = ret.joins(join)
    end

    # Filter scores by rank
    if mappack.nil? || ['hs', 'sr'].include?(board)
      rankf = mappack.nil? ? 'rank' : "rank_#{board}"
      trankf = "tied_#{rankf}"
      if tied
        ret = ret.where(!a.blank? ? "`#{trankf}` >= #{a}" : nil)
                 .where(!b.blank? ? "`#{trankf}` < #{b}"  : nil)
                 .where(!b.blank? ? "`#{rankf}` >= #{b}"  : nil)
      else
        rank_type = ties ? trankf : rankf
        ret = ret.where(!a.blank? ? "`#{rank_type}` >= #{a}" : nil)
                 .where(!b.blank? ? "`#{rank_type}` < #{b}"  : nil)
      end
    end

    # Filter scores by dev time
    if dev && !mappack.nil? && ['hs', 'sr'].include?(board)
      dev_score = <<~STR.gsub(/\s+/, ' ').strip
        CASE
          WHEN `mappack_scores`.`highscoreable_type` = 'MappackLevel'   THEN `mappack_levels`.`dev_#{board}`
          WHEN `mappack_scores`.`highscoreable_type` = 'MappackEpisode' THEN `mappack_episodes`.`dev_#{board}`
          WHEN `mappack_scores`.`highscoreable_type` = 'MappackStory'   THEN `mappack_stories`.`dev_#{board}`
          ELSE ''
        END
      STR
      ret = ret.where("`score_#{board}` #{board == 'hs' ? '>' : '<'} (#{dev_score})#{board == 'hs' ? ' * 60.0' : ''}")
    end

    # Filter scores by cool and star, if not in a mappack
    if mappack.nil?
      ret = ret.where("#{missing ? 'NOT ' : ''}(`cool` = 1 AND `star` = 1)") if cool && star
      ret = ret.where(cool: !missing) if cool && !star
      ret = ret.where(star: !missing) if star && !cool
    end

    # Order results and return
    ret.order("`#{rankf}`", types, '`highscoreable_id`')
  end

  def cools(type, tabs, r1 = 0, r2 = 20, ties = false, missing = false)
    range_ns(r1, r2, type, tabs, ties).where(cool: !missing)
  end

  def stars(type, tabs, r1 = 0, r2 = 20, ties = false, missing = false)
    range_ns(r1, r2, type, tabs, ties).where(star: !missing)
  end

  def score_counts(tabs, ties, mappack = nil, board = 'hs')
    bench(:start) if BENCHMARK
    rankf = "`#{ties ? 'tied_' : ''}rank#{mappack ? '_' + board : ''}`"
    counts = {
      levels:   scores_by_type_and_tabs(Level,   tabs, nil, mappack, board).group(rankf).order(rankf).count(:id),
      episodes: scores_by_type_and_tabs(Episode, tabs, nil, mappack, board).group(rankf).order(rankf).count(:id),
      stories:  scores_by_type_and_tabs(Story,   tabs, nil, mappack, board).group(rankf).order(rankf).count(:id)
    }
    bench(:step) if BENCHMARK
    counts
  end

  def missing(type, tabs, a, b, ties, tied = false, mappack = nil, board = 'hs', dev = false)
    type = normalize_type(type, mappack: !mappack.nil?)
    bench(:start) if BENCHMARK
    scores = type.map{ |t|
      ids = range_ns(a, b, t, tabs, ties, tied, false, false, false, mappack, board, dev).pluck(:highscoreable_id)
      t = t.where(mappack: mappack) if !mappack.nil?
      t = t.where(tab: tabs) if !tabs.empty?
      t = t.where.not("dev_#{board}" => nil) if mappack && dev
      t.where.not(id: ids).order(:id).pluck(:name)
    }.flatten
    bench(:step) if BENCHMARK
    scores
  end

  # Return highscoreables with the biggest/smallest differences between the player's
  # score and the 0th.
  def score_gaps(type, tabs, worst = true, full = false, mappack = nil, board = 'hs', frac = false)
    # Prepare params
    type = ensure_type(normalize_type(type))
    type = type.mappack if mappack
    tname = type.table_name
    sfield = !mappack ? '`scores`.`score`' : board == 'hs' ? '`score_hs` / 60.0' : '`score_sr`'
    sfield += board == 'hs' ? ' - `fraction` / 60.0' : ' + `fraction`' if frac
    rfield = mappack ? "rank_#{board}" : 'rank'
    klass = mappack ? MappackScore.where(mappack: mappack).where.not(rfield.to_sym => nil) : Score
    tname2 = klass.table_name
    klass = klass.where(tab: tabs) unless tabs.empty?
    diff = "ABS(MAX(#{sfield}) - MIN(#{sfield}))"

    # Calculate gaps
    bench(:start) if BENCHMARK
    list = klass.joins(!mappack && frac ? "INNER JOIN `archives` ON `archives`.`replay_id` = `scores`.`replay_id`" : '')
                .where(!mappack && frac ? { archives: { highscoreable_type: type } } : {} )
                .joins("INNER JOIN `#{tname}` ON `#{tname}`.`id` = `#{tname2}`.`highscoreable_id`")
                .where(highscoreable_type: type)
                .where("`#{rfield}` = 0 OR `#{tname2}`.`player_id` = #{self.id}")
                .group(:highscoreable_id)
                .having('`diff` > 0')
                .order("`diff` #{worst ? 'DESC' : 'ASC'}", :highscoreable_id)
                .limit(full ? nil : NUM_ENTRIES)
                .pluck(:name, "#{diff} AS `diff`")
    bench(:step) if BENCHMARK
    list
  end

  # Return highscoreables with most/least missed pieces of gold.
  def gold_gaps(type, tabs, worst = true, full = false, mappack = nil, agd = true)
    # Prepare params
    type = ensure_type(normalize_type(type)).mappack
    tname = type.table_name
    klass = MappackScore.where(mappack: mappack, player: self)
    klass = klass.where(tab: tabs) unless tabs.empty?
    diff = agd ? "`#{tname}`.`gold` - MAX(`mappack_scores`.`gold`)" : 'MIN(`mappack_scores`.`gold`)'

    # Calculate gaps
    bench(:start) if BENCHMARK
    list = klass.joins("INNER JOIN `#{tname}` ON `#{tname}`.`id` = `highscoreable_id`")
                .where(highscoreable_type: type)
                .group(:highscoreable_id)
                .having('`diff` > 0')
                .order("`diff` #{worst ? 'DESC' : 'ASC'}")
                .limit(full ? nil : NUM_ENTRIES)
                .pluck(:name, "#{diff} AS `diff`")
    bench(:step) if BENCHMARK
    list
  end

  def points(type, tabs)
    bench(:start) if BENCHMARK
    points = scores_by_type_and_tabs(type, tabs).sum('20 - `rank`')
    bench(:step) if BENCHMARK
    points
  end

  def average_points(type, tabs)
    bench(:start) if BENCHMARK
    scores = scores_by_type_and_tabs(type, tabs).average('20 - `rank`')
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
    ids = req.where("`rank` = 1 AND `tied_rank` = #{plural ? 0 : 1}").pluck(:highscoreable_id)
    scores_by_type_and_tabs(type, tabs, :name).where(rank: 0, highscoreable_id: ids)
  end

  def singular(type, tabs, plural = false)
    bench(:start) if BENCHMARK
    type = type.nil? ? DEFAULT_TYPES : [type.to_s]
    ids = type.map{ |t| singular_(t, tabs, plural).collect(&:id) }.flatten
    ret = Score.where(id: ids)
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

  def table(rank, ties, a, b, cool = false, star = false, mappack = nil, board = 'hs', frac = false)
    rankf  = !mappack ? 'rank' : "rank_#{board}"
    trankf = "tied_#{rankf}"
    ttype = ties ? trankf : rankf
    klass = !mappack ? scores : mappack_scores.where(mappack: mappack).where.not(rankf => nil)
    [Level, Episode, Story].map do |type|
      if ![:maxed, :maxable].include?(rank)
        queryBasic = klass.where(highscoreable_type: mappack ? type.mappack : type)
                          .where(!cool.blank? && !mappack ? '`cool` = 1' : '')
                          .where(!star.blank? && !mappack ? '`star` = 1' : '')
        query = queryBasic.where(!a.blank? ? "`#{ttype}` >= #{a}" : '')
                          .where(!b.blank? ? "`#{ttype}` < #{b}" : '')
                          .group(:tab)
      end
      case rank
      when :rank
        query.count(:id).to_h
      when :tied_rank
        scores1 = queryBasic.where(!a.blank? ? "`#{trankf}` >= #{a}" : '')
                            .where(!b.blank? ? "`#{trankf}` < #{b}" : '')
                            .group(:tab)
                            .count(:id)
                            .to_h
        scores2 = queryBasic.where(!a.blank? ? "`#{rankf}` >= #{a}" : '')
                            .where(!b.blank? ? "`#{rankf}` < #{b}" : '')
                            .group(:tab)
                            .count(:id)
                            .to_h
        scores1.map{ |tab, count| [tab, count - scores2[tab].to_i] }.to_h
      when :points
        query.sum("20 - `#{ttype}`").to_h
      when :score
        sfield = !mappack ? '`scores`.`score`' : board == 'hs' ? '`score_hs` / 60.0' : '`score_sr`'
        sfield += board == 'hs' ? ' - `fraction` / 60.0' : ' + `fraction`' if frac
        query.joins(!mappack && frac ? "INNER JOIN `archives` ON `archives`.`replay_id` = `scores`.`replay_id`" : '')
             .where(!mappack && frac ? { archives: { highscoreable_type: type } } : {} )
             .sum(sfield).to_h
      when :avg_points
        query.average("20 - `#{ttype}`").to_h
      when :avg_rank
        query.average(ttype).to_h
      when :maxed
        Highscoreable.ties(type, [], nil, true, false, mappack, board)
                 .group_by{ |t| t[0].split("-")[mappack ? 1 : 0] }
                 .map{ |tab, scores| [formalize_tab(tab), scores.size] }
                 .to_h
      when :maxable
        Highscoreable.ties(type, [], nil, false, false, mappack, board)
                 .group_by{ |t| t[0].split("-")[mappack ? 1 : 0] }
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
  cattr_reader :status

  # Different types of interactions we log
  STATUS_ENTRIES = [
    'commands',      'main_commands', 'special_commands', 'messages',
    'edits',         'pings',         'dms',              'interactions',
    'logs',          'errors',        'warnings',         'exceptions',
    'http_requests', 'http_errors',   'http_forwards',    'http_scores',
    'http_replay',   'http_submit',   'http_login',       'http_levels'
  ]

  @@status = STATUS_ENTRIES.map{ |k| [k, 0] }.to_h

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
    type = type.mappack.where(mappack_id: 1) if ctp
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
    Time.parse(self.find_by(key: key).value) rescue prev_lotd_time(type, ctp: ctp)
  end

  # Save the date of the current lotd/eotw/cotm scores (to compute changes later)
  def self.set_saved_scores(type, ctp = false)
    key = "saved_#{ctp ? 'ctp_' : ''}#{type.to_s.downcase}_scores"
    self.find_or_create_by(key: key).update(value: Time.now.to_s)
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
    Player.where("UNIX_TIMESTAMP(`last_active`) >= #{Time.now.to_i - period}").update_all(active: true)
    Player.where("UNIX_TIMESTAMP(`last_active`) <  #{Time.now.to_i - period}").update_all(active: false)
  end

  def self.get_avatar
    self.find_by(key: 'avatar').value
  end

  def self.set_avatar(str)
    self.find_by(key: 'avatar').update(value: str)
  end

  def self.statuses
    where("`key` LIKE 'status\\_%'")
  end

  def self.status_init
    entries = statuses.pluck(:key).map{ |k| k.remove('status_') }
    create((STATUS_ENTRIES - entries).map{ |k| { key: 'status_' + k, value: '0' } })
    @@status = statuses.pluck(:key, :value).map{ |k, v| [k.remove('status_'), v.to_i] }.to_h
  end

  def self.status_persist
    @@status.each do |k, v|
      entry = find_by(key: 'status_' + k)
      entry ? entry.update(value: v.to_s) : create(key: 'status_' + k, value:  v.to_s)
    end
  end

  def self.status_get(key)
    @@status[key]
  end

  def self.status_set(key, value)
    @@status[key] = value
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
      v == 1 ? ANSI.good + "#{k}++" : (v == -1 ? ANSI.bad + "#{k}--" : "")
    }.join
  end

  def format(pad)
    ANSI.yellow + format_type + " " * [1, pad - count + 1].max + format_objs + ANSI.clear
  end
end

class Archive < ActiveRecord::Base
  # When archiving began
  EPOCH = Time.new(2020, 9, 3, 0, 0, 0, "+00:00")

  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  has_one :demo, foreign_key: :id, dependent: :destroy
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

  # Returns the leaderboards at a particular point in time
  def self.scores(highscoreable, date = nil, cheated: false, full: false, pluck: true, aliases: true, cools: false, stars: false, **kwargs)
    ids = Archive.where(highscoreable: highscoreable)
                 .where(!cheated ? '`cheated` = 0' : '')
                 .where(date ? "UNIX_TIMESTAMP(`date`) <= #{date.to_i}" : '')
                 .group(:metanet_id)
                 .maximum(:replay_id)
    board = Archive.where(highscoreable: highscoreable, replay_id: ids.values)
                   .joins(:player)
                   .order(score: :desc, replay_id: :asc)
                   .limit(full ? nil : 20)
    return board unless pluck

    # Optionally pluck only the relevant fields, this is what we tend to use
    names = aliases ? 'IF(`display_name` IS NOT NULL, `display_name`, `name`)' : '`name`'
    attr_names = %W[id score name metanet_id player_id fraction]
    attrs = %W[archives.id score #{names} metanet_id player_id fraction]
    board = board.pluck(*attrs).map{ |s| attr_names.zip(s).to_h }
    return board if !cools && !stars

    # We don't store cool and star flags, so compute them
    cool_count = highscoreable.find_coolness(scores: board, date: date) if cools
    board.each_with_index{ |s, i|
      s['cool'] = true if cools && i < cool_count
      # TODO: Add star here
    }
    board
  end

  # Return a list of all 0th holders in history on a specific highscoreable
  # until a certain date (nil = present)
  # Care must be taken when the 0th was improved multiple times in the same update
  def self.zeroths(highscoreable, date = nil)
    dates = highscoreable.changes
    return [] if dates.size == 0
    prev_date = dates[0]
    zeroth = scores(highscoreable, prev_date).first
    zeroths = [zeroth]
    date = Time.now.to_i if date.nil?

    dates[0..-2].each_with_index.reject{ |d, i| dates[i + 1] > date }.each{ |d, i|
      a = self.where(highscoreable: highscoreable, cheated: false)
              .where("UNIX_TIMESTAMP(`date`) > #{d} AND UNIX_TIMESTAMP(`date`) <= #{dates[i + 1]}")
              .order('`score` DESC')
              .first
      if a.score > zeroth[1]
        zeroth = [a.metanet_id, a.score]
        zeroths.push(zeroth)
      end
    }
    zeroths.map(&:first)
  end

  # Clean database:
  #   - Remove scores, archives and players by blacklisted players
  #   - Remove orphaned demos (without a corresponding archive)
  #   - Remove individually blacklisted archives
  #   - Remove duplicated archives
  # TODO: Remove duplicated players and adjust all the tables that might refer to the deleted player_id's
  def self.sanitize
    # Store results to print summary after sanitization
    ret = {}

    # Delete scores by ignored players
    query = Score.joins("INNER JOIN `players` ON `players`.`id` = `scores`.`player_id`")
                 .where("players.metanet_id" => HACKERS.keys + CHEATERS.keys)
    count = query.count.to_i
    ret['score_del'] = "Deleted #{count} illegitimate scores." unless count == 0
    query.delete_all

    # Delete archives (and their corresponding demos) by hackers
    query = Archive.where(metanet_id: HACKERS.keys)
    count = query.count.to_i
    ret['archive_del'] = "Deleted #{count} archives by hackers." unless count == 0
    query.each(&:destroy)

    # Flag archives by cheaters
    query = Archive.where(metanet_id: CHEATERS.keys, cheated: false)
    count = query.count.to_i
    ret['archive_del'] = "Flagged #{count} archives by cheaters." unless count == 0
    query.update_all(cheated: true)

    # Delete ignored players
    query = Player.where(metanet_id: HACKERS.keys)
    count = query.count.to_i
    ret['player_del'] = "Deleted #{count} hackers." unless count == 0
    query.delete_all

    # Delete individual incorrect archives
    count = 0
    ["Level", "Episode", "Story"].each{ |mode|
      query = Archive.where(highscoreable_type: mode, replay_id: PATCH_IND_DEL[mode.downcase.to_sym])
      count += query.count.to_i
      query.each(&:destroy)
    }
    ret['archive_ind_del'] = "Deleted #{count} incorrect archives." unless count == 0

    # Delete duplicate archives (can happen on accident)
    duplicates = Archive.group(
      :highscoreable_type,
      :highscoreable_id,
      :player_id,
      :score
    ).having('COUNT(`score`) > 1')
     .select(:highscoreable_type, :highscoreable_id, :player_id, :score, 'MIN(`date`)')
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
      same.each(&:destroy)
    }
    ret['duplicates'] = "Deleted #{count} duplicated archives." unless count == 0

    # Delete demos with missing archives
    query = Demo.joins("LEFT JOIN `archives` ON `archives`.`id` = `demos`.`id`")
                .where("`archives`.`id` IS NULL")
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

  # Calculate the interpolated fractional frame using Sim's tool
  def seed_fraction
    # Map or demo not available, cannot compute
    if !highscoreable || lost || !demo&.demo
      update(fraction: 1) if lost
      return :lost
    end

    frac = NSim.run(highscoreable.map.dump_level, [demo.demo]){ |nsim| nsim.frac }
    update(fraction: frac || 1, simulated: true)
    return frac ? :good : :bad
  rescue => e
    lex(e, "Fraction computation failed for archive #{id}")
  end

  # Returns the rank of the player at a particular point in time
  def find_rank(time)
    Archive.scores(highscoreable, time).index{ |s| s['metanet_id'] == metanet_id } || 20
  end

  def format_score
    "%.3f" % self.score.to_f / 60.0
  end
end

# Implemented by Demo and MappackDemo
module Demoish
  def decode(dump = false)
    Demo.decode(demo, dump)
  end

  def framecount
    decode(true).map(&:size).sum rescue -1
  end

  # The complexity of a run is the number of moving entities NSim supports times
  # the number of frames. This is used as a threshold to determine when a run is
  # too complex to be rendered fully in animations.
  def complexity
    run = is_a?(Demo) ? archive : score
    return -1 if !run || !demo
    object_counts = run.highscoreable.levels.map{ |l| l.map.complexity }
    frame_counts = decode(true).map(&:size)
    object_counts.zip(frame_counts).map{ |a, b| a * b }.sum
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
#     4B - Static data    (0xFFFFFFFF per ninja)                               |
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
  include Demoish
  belongs_to :archive, foreign_key: :id

  HEADER_SIZE = 26 # cllllllc
  Header = Struct.new(:type, :size, :version, :framecount, :id, :mode, :unknown, :mask)

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

  # Parse 26 byte header of a level demo
  def self.parse_header(replay, inflate: true)
    replay = Zlib::Inflate.inflate(replay) if inflate
    Header.new(*replay.unpack('Cl<6C'))
  end

  # Parse a demo, return array with inputs for each level as binary strings
  def self.parse(data, htype)
    # Parse header
    data = Zlib::Inflate.inflate(data)
    length_offset = { 'Level' => 1, 'Episode' =>  4, 'Story' =>   8 }[htype]
    offset        = { 'Level' => 0, 'Episode' => 24, 'Story' => 108 }[htype]
    header = Demo.parse_header(data[offset, HEADER_SIZE], inflate: false)
    ninja_count = header.mask.to_s(2).count('1')
    inputs_start = HEADER_SIZE + 4 * ninja_count

    # Extract raw inputs
    replays = []
    lengths = data.unpack('x%dl<%d' % [length_offset, TYPES[htype][:size]])
    lengths.each{ |length|
      replays << data[offset + inputs_start, length - inputs_start]
      offset += length
    }
    replays
  end

  def qt
    TYPES[archive.highscoreable_type][:qt] rescue -1
  end

  def replay_uri(steam_id)
    npp_uri(:replay, steam_id, replay_id: archive.replay_id, qt: qt)
  end

  def parse(replay)
    Demo.parse(replay, archive.highscoreable_type)
  end

  def get_demo
    uri = Proc.new { |steam_id| replay_uri(steam_id) }
    data = Proc.new { |data| data }
    err  = "error getting demo with id #{archive.replay_id} "\
           "for #{archive.highscoreable_type.downcase} "\
           "with id #{archive.highscoreable_id}"
    get_data(uri, data, err)
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

# The "raw" classes map to different tables whose purpose is to mirror Metanet's
# db in full as closely as possible. They are kept separate so the highscoring
# functionality is still performed on the much smaller tables.
# Their main purpose is archival and browsing, not really performing stats,
# but their structure has been kept similar to the highscoring ones in case we
# still want some basic stats.

class RawPlayer < ActiveRecord::Base
end

class RawScore < ActiveRecord::Base
end

class RawScore < ActiveRecord::Base
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
