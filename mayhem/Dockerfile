# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# If mayhem/build.sh needs EXTRA apt packages, install them as root before the build
# (re-pin to SOURCE_DATE_EPOCH first for reproducibility — repro-sources-list.sh ships
# in the base):
#   USER root
#   RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
#       apt-get update && apt-get install -yq --no-install-recommends <pkgs> \
#    && rm -rf /var/lib/apt/lists/*
#   USER mayhem

# Anything the upstream build would download, or a library apt lacks or ships at the wrong version, is
# built once from pinned source into a static prefix under /opt/toolchains/deps/<name>-<version>/
# (root-owned, world-readable, no .so); build.sh just points at it, e.g. via PKG_CONFIG_PATH
# (SPEC §6.2 item 19). The source stays in $d/src and the build runs out of tree with -gdwarf-3, so
# backtraces show /opt/toolchains/deps/... paths and the harness binary stays DWARF <= 3. Example:
#   USER root
#   ARG JANSSON_VER=2.14.1
#   ARG JANSSON_SHA256=<sha256 of the tarball>
#   RUN d=/opt/toolchains/deps/jansson-${JANSSON_VER} && mkdir -p "$d/src" /tmp/dep-build \
#    && curl -fsSL -o /tmp/dep.tgz \
#         https://github.com/akheron/jansson/releases/download/v${JANSSON_VER}/jansson-${JANSSON_VER}.tar.gz \
#    && echo "${JANSSON_SHA256}  /tmp/dep.tgz" | sha256sum -c - \
#    && tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src" && cd /tmp/dep-build \
#    && "$d/src/configure" --prefix="$d" --disable-shared --enable-static CFLAGS="-O2 -g -gdwarf-3" \
#    && make -j"$(nproc)" install \
#    && cd / && rm -rf /tmp/dep-build /tmp/dep.tgz && chmod -R a+rX "$d"
#   USER mayhem

# Libraries upstream's PlatformIO build fetches (platformio.ini [deps_common] + [env:native]),
# fetched once from pinned sources (sha256) into /opt/toolchains/deps/<name>-<version>/src
# (SPEC §6.2 item 19); mayhem/build.sh compiles them from there, offline.
USER root
RUN set -eux; \
    fetch() { name="$1"; url="$2"; sum="$3"; d="/opt/toolchains/deps/$name"; \
      mkdir -p "$d/src"; curl -fsSL -o /tmp/dep.tgz "$url"; \
      echo "$sum  /tmp/dep.tgz" | sha256sum -c -; \
      tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src"; rm -f /tmp/dep.tgz; }; \
    fetch ArduinoJson-7.4.2 https://github.com/bblanchon/ArduinoJson/archive/refs/tags/v7.4.2.tar.gz 681f703dd237f5b7f1dc1d7009a9cf246e88676b349572e73eae9154e8994a55; \
    fetch PNGdec-1.1.6 https://github.com/bitbank2/PNGdec/archive/refs/tags/1.1.6.tar.gz 8b1d407536fee17488415215517e4438fdda83948518d8ddeb5e9db1efffc299; \
    fetch JPEGDEC-1.8.4 https://github.com/bitbank2/JPEGDEC/archive/refs/tags/1.8.4.tar.gz bca29ec7026530a50c60b3a2b7e389ba9e631f9a50e01b9558735b284365307a; \
    fetch bb_epaper-bfd1b4dc https://github.com/bitbank2/bb_epaper/archive/bfd1b4dc69afc534aa08c33ca7ae5ce1afa1c771.tar.gz 5723842a9946c15565157a865dd33b9ee60a6e45e3f257a63ac1f0282ac6afd5; \
    fetch ArduinoFake-0.4.0 https://github.com/FabioBatSilva/ArduinoFake/archive/refs/tags/0.4.0.tar.gz d8dbc246ca67f6ebfaf02537e382d372b6a11b3b03b8e2c2b8f05af59491441e; \
    fetch Unity-2.6.0 https://github.com/ThrowTheSwitch/Unity/archive/refs/tags/v2.6.0.tar.gz aa4c9fb1ae5fc5242f914c65f3557e817e40cb37f04a31e5ff76d1ab89dbf674; \
    chmod -R a+rX,go-w /opt/toolchains/deps

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
