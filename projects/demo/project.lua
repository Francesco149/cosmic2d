-- the out-of-the-box demo: our platformer moveset across two rooms with
-- swapping music. Extract the engine, pick this, press play. It doubles
-- as the "new project" template and the packager's default target.
return {
  name = "cosmic demo",
  internal_w = 480,
  internal_h = 270,
  window_scale = 2,
  entry = "main.lua",
  -- Display metadata; player packaging requires name/version/description.
  author = "cosmic2d",
  version = "0.1",
  description = "A tiny two-room platformer showing the moveset, "
                .. "sound effects, and music that swaps between rooms.",
  -- Required player-bundle metadata. Paths are forward-slash relative to
  -- this project and are validated before an archive is published.
  icon = "icon.png",
  controls = "CONTROLS.md",
  credits = "CREDITS.md",
  licenses = { "LICENSE.md" },
}
