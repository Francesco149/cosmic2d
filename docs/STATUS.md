# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-10
**Milestone**: M0 — boot (in progress)

## Done

- SEED.md digested into docs/ (PLAN, ARCHITECTURE, DECISIONS, PROCESS) and
  deleted, per instruction. All foundational decisions logged (D001–D011).
- Environment verified: WSLg display live; Vulkan devices = dzn (RTX 5060,
  hardware) + lavapipe (software, golden target); nixpkgs has sdl3 3.4.8,
  lua5_4 5.4.7, glslang, spleen; llm-feed up at :8777.

## In flight

- flake.nix + vendored Lua/stb, then the M0 PAL binary (see PLAN.md M0 exit
  criteria).

## Next step

1. flake devshell; vendor lua 5.4.7 (seed patch, D003) + stb headers; commit.
2. pal/src M0: SDL3 + SDL_GPU quad batcher + Lua boot + headless + screenshot
   + named buffers + watch/error-state reload; Makefile; shaders committed.
3. engine/boot.lua + projects/sandbox animated-quads demo; hot reload proof;
   screenshot → llm-feed; STATUS update; suggest /clear.

## Open questions for the human

- none blocking.
