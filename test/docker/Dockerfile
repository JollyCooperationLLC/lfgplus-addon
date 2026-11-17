# Real Lua 5.1 (the version WoW runs) with busted, for running the addon's specs anywhere Docker runs.
# Built and used by ../../busted.sh, which mounts the addon at /addon.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends lua5.1 liblua5.1-0-dev luarocks build-essential ca-certificates unzip git \
 && rm -rf /var/lib/apt/lists/*

# Pinned rock versions so every machine runs the same test stack. luabitop is WoW's `bit` library.
RUN luarocks --lua-version=5.1 install busted 2.2.0-1 \
 && luarocks --lua-version=5.1 install dkjson 2.8-1 \
 && luarocks --lua-version=5.1 install luabitop 1.0.2-3

# luacov counts lines for coverage.sh. Its own layer, so adding it reused the one above.
RUN luarocks --lua-version=5.1 install luacov 0.15.0-1

WORKDIR /addon
CMD ["busted"]
