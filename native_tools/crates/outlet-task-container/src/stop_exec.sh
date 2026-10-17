# Stop every process of the given runner execs, leaving the rest of the container alone.
# A process belongs to an exec when its environment carries OUTLET_EXEC_ID=<id>, when it
# runs in a session led by a member (each docker exec is a session leader and the runner's
# wrapper shell stays alive as that leader), or when it descends from a member. This also
# catches setsid/nohup/double-forked daemons and children started with a cleared
# environment. PID 1 and this helper are never signalled. Exit 0 once nothing remains.
self=$$
[ "$#" -gt 0 ] || exit 2
patterns=
for id in "$@"; do
  case $id in *[!0-9a-f]* | '') echo "invalid exec id" >&2; exit 2 ;; esac
  patterns="${patterns:+$patterns
}OUTLET_EXEC_ID=$id"
done
zgrep=0
printf 'x\0' | grep -qzx x 2>/dev/null && zgrep=1
tagged() {
  if [ "$zgrep" = 1 ]; then
    grep -lzxF -e "$patterns" /proc/[0-9]*/environ 2>/dev/null
  else
    for f in /proc/[0-9]*/environ; do
      tr '\0' '\n' <"$f" 2>/dev/null | grep -qxF -e "$patterns" && echo "$f"
    done
  fi
}
members() {
  tags=$(tagged | tr -cs '0-9' ' ')
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    s=$(cat "$d/stat" 2>/dev/null) || continue
    s=${s##*) }
    set -- $s
    case $1 in Z | X | x) continue ;; esac
    echo "$p $2 $4"
  done | awk -v tags="$tags" -v self="$self" '
    BEGIN { n = split(tags, t, " "); for (i = 1; i <= n; i++) mark[t[i]] = 1 }
    { pid[NR] = $1; ppid[$1] = $2; sid[$1] = $3 }
    END {
      do {
        changed = 0
        for (i = 1; i <= NR; i++) {
          p = pid[i]
          if (!(p in mark) && ((ppid[p] in mark) || (sid[p] in mark))) { mark[p] = 1; changed = 1 }
        }
      } while (changed)
      for (i = 1; i <= NR; i++) { p = pid[i]; if ((p in mark) && p != self && p != 1) print p }
    }'
}
pause() { sleep 0.2 2>/dev/null || sleep 1; }
pids=$(members)
if [ -z "$pids" ]; then
  # The exec may still be starting; look once more before reporting success.
  pause
  pids=$(members)
fi
[ -n "$pids" ] || exit 0
kill -s TERM $pids 2>/dev/null
i=0
while [ "$i" -lt 10 ]; do
  pause
  pids=$(members)
  [ -n "$pids" ] || exit 0
  i=$((i + 1))
done
i=0
while [ "$i" -lt 25 ]; do
  kill -s KILL $pids 2>/dev/null
  pause
  pids=$(members)
  [ -n "$pids" ] || exit 0
  i=$((i + 1))
done
echo "processes still running after SIGKILL: $pids" >&2
exit 1
