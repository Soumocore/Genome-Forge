#!/usr/bin/env bash
# =============================================================================
# Flexible genome assembly pipeline - works with whatever reads you have:
#   Illumina paired-end / single-end, Nanopore, PacBio, or an existing assembly.
#   QC -> trim/filter -> assemble -> polish -> BUSCO -> summary
#
#   ./run_pipeline.sh --r1 a_R1.fq.gz --r2 a_R2.fq.gz --long ont.fastq.gz
#   ./run_pipeline.sh --samplesheet samples.tsv
#   ./run_pipeline.sh -h
# Relative paths are resolved from the directory you run the command in.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_PWD="$PWD"
CONFIG="$ROOT/config/config.sh"
STEPS="all"; SKIP=""; FORCE=0
declare -A CLI=()
ALL_STEPS="check qc_raw trim qc_trim long_qc long_filter assemble medaka polish busco summary"

usage() {
  cat <<USAGE
Usage: ./run_pipeline.sh [input options] [other options]

Inputs (give any combination that makes sense):
  --r1 FILE            short reads (Illumina) - R1, or the only file if single-end
  --r2 FILE            short reads R2. Auto-detected from R1 name (_R1/_R2, _1/_2);
                       use '--r2 none' to force single-end
  --long FILE          long reads (Nanopore / PacBio); alias: --nano
  --long-type TYPE     ont-hq (default) | ont-raw | pacbio-hifi | pacbio-clr
  --assembly FILE      existing assembly: skips assembly, only polishes/validates
  --samplesheet FILE   TSV for many samples: sample<TAB>short_r1<TAB>short_r2<TAB>long<TAB>assembly
                       (use '-' for empty cells; see examples/samplesheet.tsv)

General:
  --sample NAME        output name (default: derived from the first input file)
  -o, --out DIR        output directory (default: results)
  -t, --threads N      CPU threads (default: all cores)
  --lineage NAME       BUSCO lineage, e.g. bacteria_odb10 (default), or auto / auto-prok / auto-euk
  --genome-size SIZE   optional Flye hint, e.g. 5m
  --medaka-model NAME  optional Medaka model for your ONT chemistry
  --no-filter          do not filter long reads (e.g. PacBio HiFi)
  -s, --steps LIST     run only these steps (default: all): ${ALL_STEPS// /,}
  --skip LIST          skip these steps, e.g. --skip busco
  -f, --force          re-run even if outputs exist
  -c, --config FILE    config file with defaults (command-line options win)
  -h, --help           show this help

Assembly route chosen automatically:
  long reads present -> Flye (+ Medaka for ONT) (+ Polypolish if short reads too)
  only short reads   -> SPAdes
  --assembly given   -> polish / validate that assembly
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)      CONFIG="${2:?missing value for $1}"; shift 2 ;;
    -s|--steps)       STEPS="${2:?missing value for $1}"; shift 2 ;;
    --skip)           SKIP="${2:?missing value for $1}"; shift 2 ;;
    -f|--force)       FORCE=1; shift ;;
    --sample)         CLI[SAMPLE]="${2:?missing value for $1}"; shift 2 ;;
    --r1)             CLI[SHORT_R1]="${2:?missing value for $1}"; shift 2 ;;
    --r2)             CLI[SHORT_R2]="${2:?missing value for $1}"; shift 2 ;;
    --long|--nano)    CLI[LONG_READS]="${2:?missing value for $1}"; shift 2 ;;
    --long-type)      CLI[LONG_TYPE]="${2:?missing value for $1}"; shift 2 ;;
    --assembly)       CLI[ASSEMBLY]="${2:?missing value for $1}"; shift 2 ;;
    --samplesheet)    CLI[SAMPLESHEET]="${2:?missing value for $1}"; shift 2 ;;
    -o|--out)         CLI[OUT_DIR]="${2:?missing value for $1}"; shift 2 ;;
    -t|--threads)     CLI[THREADS]="${2:?missing value for $1}"; shift 2 ;;
    --lineage)        CLI[BUSCO_LINEAGE]="${2:?missing value for $1}"; shift 2 ;;
    --genome-size)    CLI[GENOME_SIZE]="${2:?missing value for $1}"; shift 2 ;;
    --medaka-model)   CLI[MEDAKA_MODEL]="${2:?missing value for $1}"; shift 2 ;;
    --no-filter)      CLI[LONG_FILTER]=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ---- defaults < config file < command line ----------------------------------
SAMPLE=""; SHORT_R1=""; SHORT_R2=""; LONG_READS=""; ASSEMBLY=""; SAMPLESHEET=""
LONG_TYPE="ont-hq"; OUT_DIR="results"; THREADS="$(nproc 2>/dev/null || echo 4)"
TRIM_Q=20; MIN_LEN=100
LONG_FILTER=1; LONG_MIN_Q=10; LONG_HEADCROP=20; LONG_TAILCROP=20; LONG_MIN_LEN=500
LONG_PLOT_MAXLEN=40000
GENOME_SIZE=""; MEDAKA_MODEL=""; BUSCO_LINEAGE="bacteria_odb10"
ENV_MEDAKA=""; ENV_BUSCO=""; KEEP_INTERMEDIATE=0

if [[ -f "$CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
elif [[ "$CONFIG" != "$ROOT/config/config.sh" ]]; then
  echo "Config not found: $CONFIG" >&2; exit 1
fi
# backwards compatibility with old config variable names
LONG_READS="${LONG_READS:-${NANO_READS:-}}"
for k in "${!CLI[@]}"; do printf -v "$k" '%s' "${CLI[$k]}"; done

# ---- helpers ----------------------------------------------------------------
abs() { [[ -z "$1" ]] && return 0; case "$1" in /*) echo "$1" ;; *) echo "$CALLER_PWD/$1" ;; esac; }
log() { local m; m="[$(date '+%F %T')] $*"; echo "$m"
        if [[ -n "${LOG_DIR:-}" && -d "$LOG_DIR" ]]; then echo "$m" >> "$LOG_DIR/pipeline.log"; fi; return 0; }
die() { log "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Did you run 'conda activate bioinfo'?"; }

should_run() {
  [[ ",$SKIP," == *",$1,"* ]] && return 1
  [[ "$STEPS" == "all" || ",$STEPS," == *",$1,"* ]]
}
skip_if() { if [[ "$FORCE" != 1 && -e "$1" ]]; then log "  skip (already exists): $1"; return 0; fi; return 1; }

run_logged() { local n="$1"; shift; "$@" 2>&1 | tee -a "$LOG_DIR/$n.log"; }
in_env() { local e="$1"; shift
  if [[ -n "$e" ]]; then conda run --no-capture-output -n "$e" "$@"; else "$@"; fi; }

check_reads() {   # exists, non-empty, valid gzip if .gz, looks like FASTQ/FASTA
  local f="$1" c
  [[ -s "$f" ]] || die "Missing or empty file: $f"
  if [[ "$f" == *.gz ]]; then gzip -t "$f" 2>/dev/null || die "Corrupt gzip (re-download it): $f"; fi
  c="$(zcat -f "$f" 2>/dev/null | head -c1 || true)"
  [[ "$c" == "@" || "$c" == ">" ]] || log "  WARNING: $f does not look like FASTQ/FASTA"
}

fq_base() { local b; b="$(basename "$1")"; b="${b%.gz}"; echo "${b%.*}"; }   # FastQC naming
derive_name() { local b; b="$(basename "$1")"; b="${b%.gz}"; b="${b%.*}"; b="${b%%_R1*}"; b="${b%%_1}"
                echo "${b//[^A-Za-z0-9._-]/_}"; }
guess_r2() {
  local r1="$1" c
  for c in "${r1/_R1/_R2}" "${r1/_1./_2.}" "${r1/.R1./.R2.}" "${r1/_1_/_2_}"; do
    if [[ "$c" != "$r1" && -f "$c" ]]; then echo "$c"; return 0; fi
  done
  return 0
}
fasta_stats() {
  awk '/^>/{if(l)print l; l=0; next}{l+=length($0)}END{if(l)print l}' "$1" | sort -rn |
  awk '{a[NR]=$1;t+=$1}END{if(NR==0){print "no sequences";exit}
       c=0;for(i=1;i<=NR;i++){c+=a[i];if(c>=t/2){n=a[i];break}}
       printf "contigs=%d total_bp=%d longest_bp=%d N50=%d\n",NR,t,a[1],n}'
}
flye_flag() {
  case "$LONG_TYPE" in
    ont-hq) echo "--nano-hq" ;;   ont-raw) echo "--nano-raw" ;;
    pacbio-hifi) echo "--pacbio-hifi" ;;  pacbio-clr) echo "--pacbio-raw" ;;
    *) die "Unknown --long-type '$LONG_TYPE' (use ont-hq, ont-raw, pacbio-hifi, pacbio-clr)" ;;
  esac
}

# ---- per-sample setup -------------------------------------------------------
setup_sample() {
  SR1="$(abs "$SHORT_R1")"; SR2="$(abs "$SHORT_R2")"; LR="$(abs "$LONG_READS")"; ASM_IN="$(abs "$ASSEMBLY")"
  [[ "$SHORT_R2" == "none" ]] && SR2=""
  [[ -z "$SR1" && -n "$SR2" ]] && { echo "ERROR: --r2 given without --r1" >&2; exit 1; }

  if [[ -z "$SAMPLE" ]]; then
    SAMPLE="$(derive_name "${SR1:-${LR:-${ASM_IN:-sample}}}")"
  fi
  [[ "$SAMPLE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: sample name must use only letters, digits, . _ - : '$SAMPLE'" >&2; exit 1; }

  OUT="$(abs "$OUT_DIR")/$SAMPLE"; LOG_DIR="$OUT/logs"; mkdir -p "$LOG_DIR"

  if [[ -n "$SR1" && -z "$SR2" && "$SHORT_R2" != "none" ]]; then
    local g; g="$(guess_r2 "$SR1")"
    if [[ -n "$g" ]]; then SR2="$g"; log "Auto-detected R2: $SR2"; fi
  fi
  HAS_SHORT=0; PAIRED=0; HAS_LONG=0
  [[ -n "$SR1" ]] && HAS_SHORT=1
  [[ -n "$SR1" && -n "$SR2" ]] && PAIRED=1
  [[ -n "$LR" ]] && HAS_LONG=1
  IS_ONT=0; [[ "$LONG_TYPE" == ont-* ]] && IS_ONT=1

  TRIM1="$OUT/trimmed/trim_R1.fq.gz"; TRIM2="$OUT/trimmed/trim_R2.fq.gz"
  LONG_FILT="$OUT/long_filtered/filtered_long.fq.gz"
  if (( LONG_FILTER )); then LR_USE="$LONG_FILT"; else LR_USE="$LR"; fi
  FLYE_FA="$OUT/assembly/flye/assembly.fasta"
  SPADES_FA="$OUT/assembly/spades/contigs.fasta"
  MEDAKA_FA="$OUT/assembly/medaka/consensus.fasta"
  POLISHED_FA="$OUT/assembly/polish/final_polished.fasta"

  # trimmed short reads are what downstream tools use (if trimming ran)
  if (( HAS_SHORT )); then S1_USE="$TRIM1"; S2_USE="$TRIM2"; fi
}

draft_assembly() {
  if [[ -n "$ASM_IN" ]]; then echo "$ASM_IN"; return 0; fi
  if (( HAS_LONG )); then [[ -s "$FLYE_FA" ]] && { echo "$FLYE_FA"; return 0; }
  else [[ -s "$SPADES_FA" ]] && { echo "$SPADES_FA"; return 0; }; fi
  return 1
}
best_assembly() {
  if [[ -s "$POLISHED_FA" ]]; then echo "$POLISHED_FA"; return 0; fi
  if [[ -s "$MEDAKA_FA" ]]; then echo "$MEDAKA_FA"; return 0; fi
  draft_assembly
}

# ---- steps ------------------------------------------------------------------
validate_inputs() {   # always runs: fail early on bad/missing input files
  (( HAS_SHORT || HAS_LONG )) || [[ -n "$ASM_IN" ]] || die "No inputs. Give --r1/--r2, --long and/or --assembly (see -h)."
  if (( HAS_SHORT )); then check_reads "$SR1"; (( PAIRED )) && check_reads "$SR2"; fi
  if (( HAS_LONG )); then check_reads "$LR"; flye_flag >/dev/null; fi
  if [[ -n "$ASM_IN" && ! -s "$ASM_IN" ]]; then die "Assembly not found: $ASM_IN"; fi
  return 0
}

step_check() {
  log "STEP check: tools   [short=$HAS_SHORT paired=$PAIRED long=$HAS_LONG ($LONG_TYPE) assembly=$([[ -n $ASM_IN ]] && echo yes || echo no)]"
  if (( HAS_SHORT )); then need fastqc; need bbduk.sh; fi
  if (( HAS_LONG )); then need NanoPlot; (( LONG_FILTER )) && need NanoFilt; fi
  if [[ -z "$ASM_IN" ]]; then
    if (( HAS_LONG )); then need flye
    elif (( HAS_SHORT )); then need spades.py; fi
  fi
  if (( HAS_SHORT )) && { (( HAS_LONG )) || [[ -n "$ASM_IN" ]]; }; then need bwa; need samtools; need polypolish; fi
  log "  OK"
}

step_qc_raw() {
  (( HAS_SHORT )) || { log "STEP qc_raw: skipped (no short reads)"; return 0; }
  log "STEP qc_raw: FastQC on raw short reads"
  mkdir -p "$OUT/qc_raw"
  local last="$SR1"; (( PAIRED )) && last="$SR2"
  skip_if "$OUT/qc_raw/$(fq_base "$last")_fastqc.html" && return 0
  local files=("$SR1"); (( PAIRED )) && files+=("$SR2")
  run_logged fastqc_raw fastqc -t "$THREADS" -o "$OUT/qc_raw" "${files[@]}"
}

step_trim() {
  (( HAS_SHORT )) || { log "STEP trim: skipped (no short reads)"; return 0; }
  log "STEP trim: BBDuk adapter + quality trimming ($([[ $PAIRED == 1 ]] && echo paired-end || echo single-end))"
  mkdir -p "$OUT/trimmed"
  skip_if "$([[ $PAIRED == 1 ]] && echo "$TRIM2" || echo "$TRIM1")" && return 0
  local common=(ref=adapters ktrim=r k=23 mink=11 hdist=1 qtrim=rl trimq="$TRIM_Q" minlen="$MIN_LEN"
                threads="$THREADS" stats="$OUT/trimmed/bbduk_stats.txt")
  if (( PAIRED )); then
    run_logged bbduk bbduk.sh in1="$SR1" in2="$SR2" out1="$TRIM1.tmp.fq.gz" out2="$TRIM2.tmp.fq.gz" \
      tbo tpe "${common[@]}"
    mv "$TRIM1.tmp.fq.gz" "$TRIM1"; mv "$TRIM2.tmp.fq.gz" "$TRIM2"
  else
    run_logged bbduk bbduk.sh in="$SR1" out="$TRIM1.tmp.fq.gz" "${common[@]}"
    mv "$TRIM1.tmp.fq.gz" "$TRIM1"
  fi
}

step_qc_trim() {
  (( HAS_SHORT )) || { log "STEP qc_trim: skipped (no short reads)"; return 0; }
  log "STEP qc_trim: FastQC on trimmed reads"
  mkdir -p "$OUT/qc_trim"
  local files=("$TRIM1"); (( PAIRED )) && files+=("$TRIM2")
  skip_if "$OUT/qc_trim/$(fq_base "${files[-1]}")_fastqc.html" && return 0
  run_logged fastqc_trim fastqc -t "$THREADS" -o "$OUT/qc_trim" "${files[@]}"
}

nanoplot_args() { local a=(-t "$THREADS"); (( LONG_PLOT_MAXLEN > 0 )) && a+=(--maxlength "$LONG_PLOT_MAXLEN"); echo "${a[@]}"; }

step_long_qc() {
  (( HAS_LONG )) || { log "STEP long_qc: skipped (no long reads)"; return 0; }
  log "STEP long_qc: NanoPlot on raw long reads"
  skip_if "$OUT/long_qc/raw/NanoStats.txt" && return 0
  # shellcheck disable=SC2046
  run_logged nanoplot_raw NanoPlot --fastq "$LR" $(nanoplot_args) -o "$OUT/long_qc/raw"
}

step_long_filter() {
  (( HAS_LONG )) || { log "STEP long_filter: skipped (no long reads)"; return 0; }
  if (( ! LONG_FILTER )); then log "STEP long_filter: skipped (--no-filter)"; return 0; fi
  log "STEP long_filter: NanoFilt (q>=$LONG_MIN_Q, crop $LONG_HEADCROP/$LONG_TAILCROP, min length $LONG_MIN_LEN)"
  mkdir -p "$OUT/long_filtered"
  if ! skip_if "$LONG_FILT"; then
    local lenargs=(); (( LONG_MIN_LEN > 0 )) && lenargs=(-l "$LONG_MIN_LEN")
    zcat -f "$LR" |
      NanoFilt -q "$LONG_MIN_Q" "${lenargs[@]}" --headcrop "$LONG_HEADCROP" --tailcrop "$LONG_TAILCROP" |
      gzip > "$LONG_FILT.tmp"
    mv "$LONG_FILT.tmp" "$LONG_FILT"
  fi
  check_reads "$LONG_FILT"
  skip_if "$OUT/long_qc/filtered/NanoStats.txt" && return 0
  # shellcheck disable=SC2046
  run_logged nanoplot_filtered NanoPlot --fastq "$LONG_FILT" $(nanoplot_args) -o "$OUT/long_qc/filtered"
}

step_assemble() {
  if [[ -n "$ASM_IN" ]]; then log "STEP assemble: skipped (using provided assembly $ASM_IN)"; return 0; fi
  if (( HAS_LONG )); then
    log "STEP assemble: Flye ($(flye_flag))"
    skip_if "$FLYE_FA" && return 0
    [[ -s "$LR_USE" ]] || die "Long reads not found: $LR_USE (run the long_filter step first, or use --no-filter)"
    local extra=(); [[ -n "$GENOME_SIZE" ]] && extra=(--genome-size "$GENOME_SIZE")
    run_logged flye flye "$(flye_flag)" "$LR_USE" --out-dir "$OUT/assembly/flye" --threads "$THREADS" "${extra[@]}"
    [[ -s "$FLYE_FA" ]] || die "Flye produced no assembly.fasta - see $LOG_DIR/flye.log"
  elif (( HAS_SHORT )); then
    log "STEP assemble: SPAdes (short reads only)"
    skip_if "$SPADES_FA" && return 0
    [[ -s "$TRIM1" ]] || die "Trimmed reads not found - run the trim step first"
    local in=(-s "$TRIM1"); (( PAIRED )) && in=(-1 "$TRIM1" -2 "$TRIM2")
    run_logged spades spades.py --isolate "${in[@]}" -o "$OUT/assembly/spades" -t "$THREADS"
    [[ -s "$SPADES_FA" ]] || die "SPAdes produced no contigs.fasta - see $LOG_DIR/spades.log"
  else
    log "STEP assemble: skipped (no reads)"
  fi
}

step_medaka() {
  if (( ! HAS_LONG )); then log "STEP medaka: skipped (no long reads)"; return 0; fi
  if (( ! IS_ONT )); then log "STEP medaka: skipped (Medaka is for Nanopore; long-type=$LONG_TYPE)"; return 0; fi
  log "STEP medaka: long-read polishing"
  skip_if "$MEDAKA_FA" && return 0
  local draft; draft="$(draft_assembly)" || die "No draft assembly - run the assemble step first"
  [[ -s "$LR_USE" ]] || die "Long reads not found: $LR_USE"
  local extra=(); [[ -n "$MEDAKA_MODEL" ]] && extra=(-m "$MEDAKA_MODEL")
  run_logged medaka in_env "$ENV_MEDAKA" medaka_consensus -i "$LR_USE" -d "$draft" \
    -o "$OUT/assembly/medaka" -t "$THREADS" "${extra[@]}"
  [[ -s "$MEDAKA_FA" ]] || die "Medaka produced no consensus.fasta - see $LOG_DIR/medaka.log"
}

step_polish() {
  if (( ! HAS_SHORT )); then log "STEP polish: skipped (no short reads)"; return 0; fi
  if (( ! HAS_LONG )) && [[ -z "$ASM_IN" ]]; then
    log "STEP polish: skipped (short-read SPAdes assembly needs no short-read polishing)"; return 0; fi
  log "STEP polish: BWA mapping + Polypolish short-read polishing"
  local d="$OUT/assembly/polish"; mkdir -p "$d"
  local draft="$MEDAKA_FA"; [[ -s "$draft" ]] || draft="$(draft_assembly)" || die "No draft assembly found"
  skip_if "$POLISHED_FA" && return 0
  [[ -s "$S1_USE" ]] || die "Trimmed short reads not found - run the trim step first"
  cp "$draft" "$d/draft.fasta"
  run_logged bwa_index bwa index "$d/draft.fasta"

  # Polypolish needs ALL alignments per read (-a); mates are aligned separately
  run_logged bwa_r1 bash -c "bwa mem -t '$THREADS' -a '$d/draft.fasta' '$S1_USE' > '$d/aln_1.sam'"
  if (( PAIRED )); then
    run_logged bwa_r2 bash -c "bwa mem -t '$THREADS' -a '$d/draft.fasta' '$S2_USE' > '$d/aln_2.sam'"
    run_logged polypolish_filter polypolish filter --in1 "$d/aln_1.sam" --in2 "$d/aln_2.sam" \
      --out1 "$d/filt_1.sam" --out2 "$d/filt_2.sam"
    polypolish polish "$d/draft.fasta" "$d/filt_1.sam" "$d/filt_2.sam" \
      > "$POLISHED_FA.tmp" 2> >(tee -a "$LOG_DIR/polypolish.log" >&2)
  else
    polypolish polish "$d/draft.fasta" "$d/aln_1.sam" \
      > "$POLISHED_FA.tmp" 2> >(tee -a "$LOG_DIR/polypolish.log" >&2)
  fi
  mv "$POLISHED_FA.tmp" "$POLISHED_FA"

  log "  mapping stats against polished assembly"
  bwa index "$POLISHED_FA" >/dev/null 2>&1
  local rd=("$S1_USE"); (( PAIRED )) && rd+=("$S2_USE")
  bwa mem -t "$THREADS" "$POLISHED_FA" "${rd[@]}" 2>/dev/null |
    samtools sort -@ "$THREADS" -o "$d/check.sorted.bam" -
  samtools index "$d/check.sorted.bam"
  samtools flagstat "$d/check.sorted.bam" | tee "$d/flagstat.txt"
  (( KEEP_INTERMEDIATE )) || rm -f "$d"/aln_*.sam "$d"/filt_*.sam
}

step_busco() {
  local fa; fa="$(best_assembly)" || { log "STEP busco: skipped (no assembly yet)"; return 0; }
  log "STEP busco: $BUSCO_LINEAGE on $(basename "$fa")"
  skip_if "$OUT/busco/.done" && return 0
  local larg force=()
  case "$BUSCO_LINEAGE" in
    auto) larg=(--auto-lineage) ;; auto-prok) larg=(--auto-lineage-prok) ;;
    auto-euk) larg=(--auto-lineage-euk) ;; *) larg=(-l "$BUSCO_LINEAGE") ;;
  esac
  (( FORCE )) && force=(-f)
  mkdir -p "$OUT/busco"
  run_logged busco in_env "$ENV_BUSCO" busco -i "$fa" -o busco_out --out_path "$OUT/busco" \
    -m genome "${larg[@]}" -c "$THREADS" "${force[@]}"
  touch "$OUT/busco/.done"
}

step_summary() {
  log "STEP summary"
  {
    echo "Sample: $SAMPLE   ($(date '+%F %T'))"
    local f
    for f in "$SPADES_FA" "$FLYE_FA" "$MEDAKA_FA" "$POLISHED_FA" "$ASM_IN"; do
      if [[ -n "$f" && -s "$f" ]]; then echo "$(basename "$(dirname "$f")")/$(basename "$f"): $(fasta_stats "$f")"; fi
    done
    if [[ -s "$OUT/assembly/polish/flagstat.txt" ]]; then
      echo "--- flagstat ---"; head -n 7 "$OUT/assembly/polish/flagstat.txt"; fi
    local b; b="$(ls "$OUT"/busco/busco_out/short_summary*.txt 2>/dev/null | head -n1 || true)"
    if [[ -n "$b" ]]; then echo "--- BUSCO ---"; grep -E "C:|Complete|Fragmented|Missing" "$b" || true; fi
  } | tee "$OUT/summary.txt"
  local fa
  if fa="$(best_assembly)"; then
    mkdir -p "$OUT/final"; cp "$fa" "$OUT/final/final_assembly.fasta"
    log "Final assembly: $OUT/final/final_assembly.fasta"
  fi
}

run_sample() {
  setup_sample
  log "Pipeline start | sample=$SAMPLE threads=$THREADS steps=$STEPS skip=${SKIP:-none}"
  validate_inputs
  local s
  for s in $ALL_STEPS; do
    if should_run "$s"; then "step_$s"; fi
  done
  log "Finished sample '$SAMPLE'. Results: $OUT"
}

# ---- main -------------------------------------------------------------------
if [[ -n "$SAMPLESHEET" ]]; then
  sheet="$(abs "$SAMPLESHEET")"; [[ -f "$sheet" ]] || { echo "Samplesheet not found: $sheet" >&2; exit 1; }
  dash() { if [[ "${1:-}" == "-" ]]; then echo ""; else echo "${1:-}"; fi; }
  failed=(); n=0
  while IFS=$'\t' read -r s r1 r2 lr asm || [[ -n "${s:-}" ]]; do
    s="${s%$'\r'}"; [[ -z "$s" || "$s" == \#* || "$s" == "sample" ]] && continue
    asm="${asm%$'\r'}"; lr="${lr%$'\r'}"; r2="${r2%$'\r'}"; r1="${r1%$'\r'}"
    n=$((n+1))
    set +e
    (
      set -euo pipefail
      SAMPLE="$s"; SHORT_R1="$(dash "$r1")"; SHORT_R2="$(dash "$r2")"
      LONG_READS="$(dash "$lr")"; ASSEMBLY="$(dash "$asm")"
      run_sample
    ) < /dev/null
    rc=$?
    set -e
    (( rc == 0 )) || failed+=("$s")
  done < "$sheet"
  echo "Processed $n sample(s); failed: ${#failed[@]}${failed[*]:+ (${failed[*]})}"
  (( ${#failed[@]} == 0 ))
else
  ( run_sample )
fi
