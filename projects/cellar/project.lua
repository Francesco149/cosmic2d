-- the bundled top-down action mini-demo (A6): find the key, unlock the
-- vault, weigh the plate down, take the gem. See README.md for the tour.
return {
  name = "cellar",
  internal_w = 320,
  internal_h = 180,
  window_scale = 3,
  entry = "main.lua",
  -- Display metadata; player packaging requires name/version/description.
  author = "cosmic2d",
  version = "0.1",
  description = "A tiny top-down action demo: find the key in the cellar, "
                .. "unlock the vault, and take the gem.",
  -- Required player-bundle metadata. Paths are forward-slash relative to
  -- this project and are validated before an archive is published.
  icon = "icon.png",
  controls = "CONTROLS.md",
  credits = "CREDITS.md",
  licenses = { "LICENSE.md" },
}
