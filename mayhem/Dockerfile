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

# AIR-GAPPED CONTRACT (SPEC §6.5): upx vendors zlib/ucl/lzma-sdk/zstd/bzip2/doctest/valgrind as git
# submodules (vendor/*, all `shallow = true` in .gitmodules) that are NOT fetched by the CI
# checkout (docker/build-push-action's `context: .` carries only the committed gitlinks, not
# submodule CONTENTS). Fetch them here, as a Dockerfile BUILD LAYER (online, like any other apt/
# package-manager step) — NOT inside mayhem/build.sh — so the checked-out vendor/ sources are
# already on disk, baked into this image layer, before build.sh ever runs. build.sh itself then
# makes zero network calls and re-runs cleanly with --network none.
RUN git submodule update --init

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
