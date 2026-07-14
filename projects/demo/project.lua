-- the out-of-the-box demo: our platformer moveset across two rooms with
-- swapping music. Extract the engine, pick this, press play. It doubles
-- as the "new project" template and the packager's default target.
return {
  name = "cosmic demo",
  internal_w = 480,
  internal_h = 270,
  window_scale = 2,
  entry = "main.lua",
  -- optional metadata (audit G3): the picker + packager surface these
  author = "cosmic2d",
  version = "0.1",
  description = "A tiny two-room platformer showing the moveset, "
                .. "sound effects, and music that swaps between rooms.",
}
