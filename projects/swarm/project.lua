-- the bundled one-screen arcade mini-demo (A6): a twin-stick arena
-- shooter with waves, juice, and a persisted high score. See README.md.
return {
  name = "swarm",
  internal_w = 320,
  internal_h = 180,
  window_scale = 3,
  entry = "main.lua",
  save_id = "swarm",
  -- Display metadata; player packaging requires name/version/description.
  author = "cosmic2d",
  version = "0.1",
  description = "A one-screen twin-stick arena shooter: kite the swarm, "
                .. "shoot eight ways, chase the persisted high score.",
  -- Required player-bundle metadata. Paths are forward-slash relative to
  -- this project and are validated before an archive is published.
  icon = "icon.png",
  controls = "CONTROLS.md",
  credits = "CREDITS.md",
  licenses = { "LICENSE.md" },
}
