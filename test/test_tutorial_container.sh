#!/bin/sh

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

image=${TUTORIAL_IMAGE:-yeokcham-tutorial:tutorial-container-test}
build_timeout=${TUTORIAL_CONTAINER_BUILD_TIMEOUT:-900}
source_status=$(git status --porcelain)

fail() {
  printf '%s\n' "tutorial container test: $*" >&2
  exit 1
}

for tool in docker git sed timeout; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

if [ -z "${TUTORIAL_IMAGE+x}" ]; then
  timeout "$build_timeout" docker build \
    --file containers/tutorial/Containerfile --tag "$image" .
fi

docker image inspect "$image" >/dev/null

docker run --rm "$image" /bin/sh -ec '
  test "$(id -u)" = 10001
  test -f /workspace/yeokcham/note.txt
  test "$(cat /workspace/yeokcham/note.txt)" = "first note"
  test -d /workspace/recovered
  escape=$(printf "\\033[")
  plain=$(yeokcham --version)
  case "$plain" in *"$escape"*) exit 1 ;; esac
  printf "%s\\n" "$plain" | grep -F "yeokcham V1 source build" >/dev/null
  forced=$(yeokcham --color always --version)
  case "$forced" in *"$escape"*) ;; *) exit 1 ;; esac
  completion=$(yeokcham completion bash --color always)
  case "$completion" in *"$escape"*) exit 1 ;; esac
  initial=$(yeokcham init --root /workspace/yeokcham --username alice \
    --draft first-task --title "first task" | sed -n "s/^saved //p" | sed -n "1p")
  test "${#initial}" = 64
  printf "%s\\n" "second note" >>/workspace/yeokcham/note.txt
  saved=$(yeokcham save --root /workspace/yeokcham | sed -n "s/^saved //p" | sed -n "1p")
  test "${#saved}" = 64
  printf "%s\\n" "unsaved line" >>/workspace/yeokcham/note.txt
  yeokcham restore --root /workspace/yeokcham --checkpoint "$saved" \
    --destination /workspace/recovered
  expected=$(printf "%s\\n%s" "first note" "second note")
  test "$(cat /workspace/recovered/note.txt)" = "$expected"
  test "$(tail -n 1 /workspace/yeokcham/note.txt)" = "unsaved line"
  yeokcham verify --root /workspace/yeokcham >/dev/null
  json=$(yeokcham verify --root /workspace/yeokcham --format json --color always)
  case "$json" in *"$escape"*) exit 1 ;; esac
'

[ "$(git status --porcelain)" = "$source_status" ] \
  || fail "tutorial container test changed repository source files"

printf '%s\n' 'tutorial container integration passed'
