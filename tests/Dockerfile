# Test environment for the CLiKader server-scripts Bash codebase.
#
# Debian 13 (the primary supported target OS) with:
#   - bash 5.x (scripts require bash 4+; macOS bash 3.2 is too old)
#   - bats-core   (test framework)
#   - kcov        (line coverage for shell scripts)
#   - jq          (parse kcov's coverage.json for the 80% gate)
#   - script      (util-linux; gives the suite a pty so /dev/tty reads work)
#   - setpriv     (util-linux; lets tests exercise non-root branches)
#
# System-mutating / network tools (apt-get, systemctl, nft, sysctl, curl, ...)
# are deliberately NOT installed here: the test harness provides fake
# executables on PATH so the scripts can be exercised without touching the box.

FROM debian:13

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bats \
        kcov \
        jq \
        util-linux \
        coreutils \
        findutils \
        grep \
        gawk \
        sed \
        perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
