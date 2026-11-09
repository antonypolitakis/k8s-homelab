#!/bin/sh
# Rebuild the site whenever git-sync publishes a new commit.
# /git/current -> /git/.worktrees/<commit-hash>   (swapped atomically by git-sync)
# /site/<hash>  = a built site;  /site/live -> the one nginx serves
last=""
while true; do
  src=$(readlink -f /git/root/current 2>/dev/null || true)
  rev=${src##*/}
  if [ -n "$rev" ] && [ -f "$src/mkdocs.yml" ] && [ "$rev" != "$last" ]; then
    last=$rev
    echo "building $rev"
    if mkdocs build --strict -f "$src/mkdocs.yml" -d "/site/$rev"; then
      ln -sfn "$rev" /site/live
      for d in /site/*; do
        n=${d##*/}
        [ "$n" = live ] || [ "$n" = "$rev" ] || rm -rf "$d"
      done
      echo "serving $rev"
    else
      rm -rf "/site/$rev"
      echo "build of $rev FAILED - still serving the previous version"
    fi
  fi
  sleep 10
done
