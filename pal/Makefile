# builds ../bin/cosmic (run `make` from pal/, inside `nix develop`)
CC ?= cc
BIN := ../bin/cosmic
BUILD := build

CFLAGS := -O2 -g -std=c11 -Wall -Wextra -Wno-unused-parameter \
          -Ivendor -Ivendor/lua/src $(shell pkg-config --cflags sdl3)
LDLIBS := $(shell pkg-config --libs sdl3) -lm

# deterministic string-hash seed (D003): lstate.c's seeding block is
# guarded by '#if !defined(luai_makeseed)', so this define replaces it
LUA_CFLAGS := -O2 -std=c11 -Ivendor/lua/src '-Dluai_makeseed(L)=0x70657474u'

PAL_SRC := $(wildcard src/*.c)
LUA_SRC := $(filter-out vendor/lua/src/lua.c vendor/lua/src/luac.c,\
             $(wildcard vendor/lua/src/*.c))
PAL_OBJ := $(PAL_SRC:src/%.c=$(BUILD)/%.o)
LUA_OBJ := $(LUA_SRC:vendor/lua/src/%.c=$(BUILD)/lua_%.o)

SHADERS := shaders/quad.vert.spv shaders/quad.frag.spv shaders/blit.vert.spv

all: $(BIN) $(SHADERS)

$(BIN): $(PAL_OBJ) $(LUA_OBJ)
	@mkdir -p $(dir $@)
	$(CC) -o $@ $^ $(LDLIBS)

$(BUILD)/%.o: src/%.c src/pal.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/lua_%.o: vendor/lua/src/%.c | $(BUILD)
	$(CC) $(LUA_CFLAGS) -c -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

%.spv: %
	glslang -V $< -o $@

clean:
	rm -rf $(BUILD) $(BIN)

.PHONY: all clean
