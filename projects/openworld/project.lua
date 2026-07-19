return {
  name = "openworld",
  internal_w = 320,
  internal_h = 240,
  window_scale = 3,
  entry = "main.lua",
  -- player-menu knobs, declared as DATA (D133): the engine builds the F1
  -- menu row and persists the choice; main.lua reads it in draw (live
  -- render policy — never in step)
  options = {
    { id = "retro_filter", label = "retro filter",
      kind = "toggle", default = true },
  },
}
