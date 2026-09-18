# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for upx (C++, CMake). Builds ON TOP of the org base image, which
# provides debian + clang/llvm + libFuzzer/afl++ runtimes + identities + the build-contract ENV.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t upx-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an empty
# value breaks clang, both here and for any in-image rebuild.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default. Declared
# WITHOUT a default so an unset arg lets the base ENV flow through, and --build-arg overrides it.
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instruments the TEST build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset.
ARG MAYHEM_JOBS=

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# AIR-GAPPED CONTRACT (SPEC §6.5): at this commit upx vendors only the LZMA SDK as a git
# submodule (src/lzma-sdk) that is NOT fetched by the CI checkout (docker/build-push-action's
# `context: .` carries only the committed gitlink, not submodule CONTENTS). Fetch it here, as a
# Dockerfile BUILD LAYER (online, like any other apt/package-manager step) — NOT inside
# mayhem/build.sh — so the checked-out src/lzma-sdk sources are already on disk, baked into this
# image layer, before build.sh ever runs. build.sh itself then makes zero network calls and
# re-runs cleanly with --network none.
RUN git submodule update --init

# UPX at this commit (pre-CMake, Jan 2020) hardcodes WITH_UCL=1 (src/conf.h) and links the
# standalone UCL compression library, which is neither vendored in-tree here (vendoring came
# later — see vendor/ucl on the mayhem branch) nor a Debian package (Debian's libucl-dev is an
# unrelated "Universal Configuration Library"). Fetch the same historical UCL sources the later
# CMake build vendors, as another online Dockerfile build layer; mayhem/build.sh compiles them
# into a static lib with no network access.
RUN git clone --depth 1 --branch upx-vendor https://github.com/upx/upx-vendor-ucl.git /home/mayhem/vendor-ucl

RUN bash mayhem/build.sh

# Run the project's functional tests at build time (mayhem/test.sh is present for upx — its own
# upstream CTest self-pack/self-unpack suite). A failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
