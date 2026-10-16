#!/bin/sh
# Single run:  run.sh <dir> <workload> [workload ...]
# Comparison:  run.sh compare <dir-A> <dir-B> [workload ...]
#   e.g.       run.sh compare /data/regional /data/normal
#              run.sh compare /data/zrs      /data/lrs
#   Both directories run one after another with identical jobs, followed by a
#   table with delta = (A - B) / B. So put the mirrored disk first (A).
#   Column names and result paths use the directory basenames (regional, normal, ...).
#   Without a workload list: disk-baseline postgresql-ssd mongodb-ssd meilisearch-ssd
#   Writes report.html (charts) next to compare.tsv.
# Report:      run.sh report <result-dir>
#   Rebuilds report.html from an existing compare.tsv and meta.txt.
#
# All parameters can be overridden via environment variables. Data files should be
# much larger than the page cache (on OpenShift: the pod's memory limit).
set -eu

: "${RESULT_DIR:=/results}"
: "${RUNTIME:=300}"
: "${BASE_RUNTIME:=60}"
: "${RAMP:=30}"
: "${BASE_SIZE:=16g}"
: "${PG_DATA_SIZE:=32g}"
: "${PG_WAL_SIZE:=8g}"
: "${MONGO_DATA_SIZE:=32g}"
: "${MONGO_JOURNAL_SIZE:=4g}"
: "${LOG_FILE_SIZE:=4g}"
: "${LOG_ARCHIVE_SIZE:=8g}"
: "${MEILI_DATA_SIZE:=32g}"
: "${MEILI_TMP_SIZE:=8g}"
: "${KEEP_FILES:=0}"
export RUNTIME BASE_RUNTIME RAMP BASE_SIZE PG_DATA_SIZE PG_WAL_SIZE MONGO_DATA_SIZE \
       MONGO_JOURNAL_SIZE LOG_FILE_SIZE LOG_ARCHIVE_SIZE MEILI_DATA_SIZE MEILI_TMP_SIZE

JOBS_DIR="$(cd "$(dirname "$0")" && pwd)/jobs"
REPORT_TEMPLATE="$(cd "$(dirname "$0")" && pwd)/report/template.html"
DEFAULT_WORKLOADS="disk-baseline postgresql-ssd mongodb-ssd meilisearch-ssd"

usage() {
  echo "usage: $0 <dir> <workload> [...]"
  echo "       $0 compare <dir-A> <dir-B> [workload ...]"
  echo "       $0 report <result-dir>"
  echo "workloads: $(ls "$JOBS_DIR" | sed 's/\.fio$//' | tr '\n' ' ')"
  exit 1
}

# Metrics per fio job; latencies in us, throughput in MiB/s
JQ_METRICS='
  def us(x): if x == null then null else (x / 100 | round) / 10 end;
  def pct(s; k): (s.lat_ns.percentile // s.clat_ns.percentile // {})[k];
  [.jobs[] | select(.jobname != "precondition") | {
    job: .jobname,
    r_iops: (.read.iops | round),  r_MiBs: (.read.bw / 1024 | round),
    r_p50_us: us(pct(.read; "50.000000")),  r_p99_us: us(pct(.read; "99.000000")),
    w_iops: (.write.iops | round), w_MiBs: (.write.bw / 1024 | round),
    w_p50_us: us(pct(.write; "50.000000")), w_p99_us: us(pct(.write; "99.000000")),
    fsync_p50_us: us(.sync.lat_ns.percentile["50.000000"]),
    fsync_p99_us: us(.sync.lat_ns.percentile["99.000000"])
  }]'

run_workload() {  # <dir> <workload> <json-out>
  [ -f "$JOBS_DIR/$2.fio" ] || { echo "unknown workload: $2"; exit 1; }
  TEST_DIR="$1/fio-$2"
  export TEST_DIR
  mkdir -p "$TEST_DIR" "$(dirname "$3")"
  # Show the runtime the job file actually uses (e.g. BASE_RUNTIME for disk-baseline)
  rt_var="$(sed -n 's/^runtime=\${\([A-Z_]*\)}$/\1/p' "$JOBS_DIR/$2.fio" | head -n 1)"
  eval "rt=\${${rt_var:-RUNTIME}}"
  phases="$(grep -c '^stonewall' "$JOBS_DIR/$2.fio")"
  echo "== $2 on $1 ($phases phases x (ramp=${RAMP}s + runtime=${rt}s) = ~$(( phases * (RAMP + rt) / 60 )) min + file layout) -> $3"
  fio --output-format=json --output="$3" "$JOBS_DIR/$2.fio"
  [ "$KEEP_FILES" = 1 ] || rm -rf "$TEST_DIR"
}

print_single() {  # <json>
  jq -r "$JQ_METRICS"' |
    (["job","r_iops","r_MiB/s","r_p99_us","w_iops","w_MiB/s","w_p99_us","fsync_p99_us"] | @tsv),
    (.[] | [.job, .r_iops, .r_MiBs, .r_p99_us, .w_iops, .w_MiBs, .w_p99_us, .fsync_p99_us]
         | map(if . == null or . == 0 then "-" else tostring end) | @tsv)' "$1" | column -t -s "$(printf '\t')"
}

compare_rows() {  # <workload> <json-A> <json-B>  -> TSV without header
  jq -rn --arg w "$1" --slurpfile a "$2" --slurpfile b "$3" '
    def m: '"$JQ_METRICS"';
    ($a[0] | m) as $A | ($b[0] | m | map({key: .job, value: .}) | from_entries) as $B |
    $A[] | . as $x | ($B[$x.job] // {}) as $y |
    ("r_iops","r_MiBs","w_iops","w_MiBs","r_p50_us","r_p99_us","w_p50_us","w_p99_us","fsync_p50_us","fsync_p99_us") as $k |
    ($x[$k] // 0) as $va | ($y[$k] // 0) as $vb |
    select($va > 0 or $vb > 0) |
    (if $vb > 0 then ($va - $vb) / $vb * 100 else null end) as $d |
    ($k | endswith("_us")) as $lat |
    [ $w, $x.job, $k, $va, $vb,
      (if $d == null then "-" else (($d | round | tostring) + "%") end),
      (if $d == null or ($d | fabs) < 5 then "~"
       elif ($lat and $d > 0) or ((($lat) | not) and $d < 0) then "A worse"
       else "A better" end) ] | @tsv'
}

make_report() {  # <result-dir>  -> <result-dir>/report.html
  # Data goes in via ENVIRON so awk does not interpret the backslash escapes of the JSON
  TSV_JSON="$(jq -Rs . "$1/compare.tsv")" META_JSON="$(jq -Rs . "$1/meta.txt")" awk '
    index($0, "/*@DATA@*/") { print "const TSV = " ENVIRON["TSV_JSON"] ";"; print "const META = " ENVIRON["META_JSON"] ";"; next }
    { print }' "$REPORT_TEMPLATE" > "$1/report.html"
}

[ $# -ge 2 ] || usage

case "$1" in
  compare)
    dir_a="$2"; dir_b="${3:-}"
    [ -n "$dir_b" ] || usage
    shift 3
    workloads="${*:-$DEFAULT_WORKLOADS}"
    label_a="$(basename "$dir_a")"; label_b="$(basename "$dir_b")"
    # Same basename (e.g. /mnt/x/data vs /mnt/y/data) would mix up the result dirs
    [ "$label_a" != "$label_b" ] || { label_a="A-$label_a"; label_b="B-$label_b"; }
    out="$RESULT_DIR/compare-$label_a-vs-$label_b-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out" "$dir_a" "$dir_b"
    {
      echo "A=$dir_a B=$dir_b workloads=$workloads"
      echo "fio=$(fio --version) kernel=$(uname -r) uid=$(id -u) gid=$(id -g)"
      df -h "$dir_a" "$dir_b" || true
      env | grep -E '^(RUNTIME|BASE_RUNTIME|RAMP|.*_SIZE)=' | sort
    } > "$out/meta.txt"
    cat "$out/meta.txt"

    tsv="$out/compare.tsv"
    printf 'workload\tjob\tmetric\t%s\t%s\tdelta\tverdict\n' "$label_a" "$label_b" > "$tsv"
    for w in $workloads; do
      run_workload "$dir_a" "$w" "$out/$label_a/$w.json"
      run_workload "$dir_b" "$w" "$out/$label_b/$w.json"
      compare_rows "$w" "$out/$label_a/$w.json" "$out/$label_b/$w.json" >> "$tsv"
    done

    echo
    echo "##### A=$label_a vs B=$label_b   (delta = (A-B)/B, latencies in us)"
    column -t -s "$(printf '\t')" "$tsv"
    make_report "$out"
    echo
    echo "Results: $out (open report.html in a browser)"
    ;;
  report)
    [ -f "$2/compare.tsv" ] || { echo "no compare.tsv in $2"; exit 1; }
    [ -f "$2/meta.txt" ] || : > "$2/meta.txt"
    make_report "$2"
    echo "Report: $2/report.html"
    ;;
  *)
    dir="$1"; shift
    out="$RESULT_DIR/$(basename "$dir")-$(date +%Y%m%d-%H%M%S)"
    for w in "$@"; do
      run_workload "$dir" "$w" "$out/$w.json"
      print_single "$out/$w.json"
    done
    ;;
esac
