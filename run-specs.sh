#!/bin/zsh
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" || exit 1
mkdir -p logs

for n in 02 03 04 05 06 07; do
  echo "=== starting spec-$n at $(date) ==="
  claude -p --model opus \
    --allowedTools "Read,Edit,Write,Bash(git status *),Bash(git diff *),Bash(git add *),Bash(git commit *),Bash(swift build *),Bash(swift test *),Bash(xcodebuild *)" \
    --max-budget-usd 40 \
    --output-format json \
    "Look in '/Users/carlostarrats/Documents/Projects/Muse/Muse App/docs/new-build' and read muse-photo-foundation.md and DECISIONS.md. Then find the file in '/Users/carlostarrats/Documents/Projects/Muse/Muse App/docs/superpowers/plans' whose name starts with '2026-07-30-spec-$n' and read it. Implement that plan — write the actual code, create/modify the files it specifies, and confirm it builds and passes existing tests, including what prior specs already built. The foundation doc and DECISIONS.md are both authoritative — where either answers something, don't ask me; DECISIONS.md wins on conflict. Read actual source files from prior specs when you need detail beyond what DECISIONS.md captures. If you hit something the plan didn't anticipate, make the reasonable call and keep going. When done, extract a DECISIONS.md update based on what was actually built, including anything that diverged. Flat facts, only what's binding on future specs. Merge into DECISIONS.md — don't duplicate, only add what's new or changed. Then commit." \
    > "logs/build-$n.json" 2>&1

  if [ $? -ne 0 ]; then
    echo "spec-$n build failed, stopping" >&2
    exit 1
  fi
  echo "=== finished spec-$n at $(date) ==="
done
echo "=== all specs complete ==="
