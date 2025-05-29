# NSim's fraction returns how much of the last frame is remaining.
# Instead, we want to store how much has elapsed (its simpler to deal with
# for multiple reasons), so we change the current contents of the table.
#   The elapsed frame is in [0, 1), it cannot be 1, as that would mean collision
# hasn't taken place on this frame. Therefore, we can use 1 as a default for when:
# - The fractional frame has not been computed yet (used to be NULL).
# - Its computation has failed (used to be -1).
# The result is that those people's frac score will lose 1 frame, instead of having
# to deal with NULL's all over the place, and we can still distinguish them.
#   The only consequence is that we can no longer distinguish between a fractional
# score missing because it hasn't been computed yet or because its computation failed,
# but this is hardly ever relevant.
class ChangeFractionDefault < ActiveRecord::Migration[5.1]
  def change
    [Archive, MappackScore].each do |klass|
      # Change current valid values from "remaining time" to "elapsed time"
      klass.where('`fraction` >= 0 AND `fraction` <= 1').update_all('`fraction` = 1 - `fraction`')

      # Change missing values from NULL to 1
      klass.where(fraction: nil).update_all(fraction: 1)

      # Change incorrectly computed values from -1 to 1
      klass.where(fraction: -1).update_all(fraction: 1)
    end

    # Change column defaults
    change_column_default :archives,       :fraction, from: nil, to: 1
    change_column_default :mappack_scores, :fraction, from: nil, to: 1
  end
end
