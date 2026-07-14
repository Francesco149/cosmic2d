# builds ../bin/cosmic (run `make` from pal/, inside `nix develop`).
# Cross-compile for Windows by overriding CC/CXX + PKG_CONFIG + EXE + LDFLAGS
# from the env/flake (see flake.nix `cosmic-windows`); Linux build unchanged.
CC ?= cc
CXX ?= c++
PKG_CONFIG ?= pkg-config
EXE ?=
BIN := ../bin/cosmic$(EXE)
BUILD := build

CFLAGS := -O2 -g -std=c11 -Wall -Wextra -Wno-unused-parameter \
          -Ivendor -Ivendor/lua/src $(shell $(PKG_CONFIG) --cflags sdl3)
LDLIBS := $(shell $(PKG_CONFIG) --libs sdl3) -lm

# C++ is allowed for vendored libs + their host TUs only (D049): imgui and
# pal/src/*.cpp. C ABI at every boundary; the PAL core stays C11.
IMGUI_DEFS := -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_DISABLE_DEMO_WINDOWS
CXXFLAGS := -O2 -g -std=c++17 -Wall -Wextra -Wno-unused-parameter \
            -Ivendor -Ivendor/lua/src -Ivendor/imgui -Ivendor/imgui/backends \
            -Ivendor/imgui/misc/cpp $(IMGUI_DEFS) \
            $(shell $(PKG_CONFIG) --cflags sdl3)

# deterministic string-hash seed (D003): lstate.c's seeding block is
# guarded by '#if !defined(luai_makeseed)', so this define replaces it
LUA_CFLAGS := -O2 -std=c11 -Ivendor/lua/src '-Dluai_makeseed(L)=0x70657474u'

PAL_SRC := $(wildcard src/*.c)
PAL_CXX := $(wildcard src/*.cpp)
LUA_SRC := $(filter-out vendor/lua/src/lua.c vendor/lua/src/luac.c,\
             $(wildcard vendor/lua/src/*.c))
IMGUI_SRC := vendor/imgui/imgui.cpp vendor/imgui/imgui_draw.cpp \
             vendor/imgui/imgui_tables.cpp vendor/imgui/imgui_widgets.cpp \
             vendor/imgui/misc/cpp/imgui_stdlib.cpp \
             vendor/imgui/backends/imgui_impl_sdl3.cpp \
             vendor/imgui/backends/imgui_impl_sdlgpu3.cpp
PAL_OBJ := $(PAL_SRC:src/%.c=$(BUILD)/%.o) $(PAL_CXX:src/%.cpp=$(BUILD)/%_cxx.o)
LUA_OBJ := $(LUA_SRC:vendor/lua/src/%.c=$(BUILD)/lua_%.o)
IMGUI_OBJ := $(addprefix $(BUILD)/ig_,$(notdir $(IMGUI_SRC:.cpp=.o)))

SHADERS := shaders/quad.vert.spv shaders/quad.frag.spv shaders/blit.vert.spv \
           shaders/blit.frag.spv

all: $(BIN) $(SHADERS)

# link with the C++ driver so libstdc++ resolves portably (mingw:
# -static-libstdc++ in LDFLAGS keeps the exe self-contained)
$(BIN): $(PAL_OBJ) $(LUA_OBJ) $(IMGUI_OBJ)
	@mkdir -p $(dir $@)
	$(CXX) -o $@ $^ $(LDFLAGS) $(LDLIBS)

$(BUILD)/%.o: src/%.c src/pal.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/%_cxx.o: src/%.cpp src/pal.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/lua_%.o: vendor/lua/src/%.c | $(BUILD)
	$(CC) $(LUA_CFLAGS) -c -o $@ $<

$(BUILD)/ig_%.o: vendor/imgui/%.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -c -o $@ $<
$(BUILD)/ig_%.o: vendor/imgui/backends/%.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -c -o $@ $<
$(BUILD)/ig_%.o: vendor/imgui/misc/cpp/%.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

%.spv: %
	glslang -V $< -o $@

clean:
	rm -rf $(BUILD) $(BIN)

.PHONY: all clean
