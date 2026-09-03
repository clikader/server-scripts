image := "clikader-tests"

_build:
    docker build -t {{image}} -f tests/Dockerfile tests

# Run the test suite quickly (no coverage)
test: _build
    docker run --rm -v .:/workspace/server-scripts -w /workspace/server-scripts {{image}} tests/docker-entrypoint.sh --no-coverage

# Run tests under kcov and enforce the 80% coverage threshold
coverage: _build
    docker run --rm -v .:/workspace/server-scripts -w /workspace/server-scripts {{image}} tests/docker-entrypoint.sh

# Drop into the test container shell (for debugging tests)
shell: _build
    docker run --rm -it -v .:/workspace/server-scripts -w /workspace/server-scripts {{image}} bash
