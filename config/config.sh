# ===================== optional defaults =====================
# You do NOT need to edit this file: every setting can be given on the command
# line (./run_pipeline.sh -h). Values here are only defaults; command-line
# options override them. Relative paths are resolved from where you run the script.

# ---- inputs (usually given on the command line instead) ----
#SAMPLE="my_sample"
#SHORT_R1=""            # Illumina R1 (or single-end file)
#SHORT_R2=""            # Illumina R2 ("none" forces single-end)
#LONG_READS=""          # Nanopore / PacBio reads
#ASSEMBLY=""            # existing assembly to polish/validate

LONG_TYPE="ont-hq"      # ont-hq | ont-raw | pacbio-hifi | pacbio-clr
OUT_DIR="results"
#THREADS=8              # default: all CPU cores

# ---- short-read trimming (BBDuk) ----
TRIM_Q=20
MIN_LEN=100

# ---- long-read filtering (NanoFilt) ----
LONG_FILTER=1           # 0 = skip (recommended for PacBio HiFi)
LONG_MIN_Q=10
LONG_HEADCROP=20
LONG_TAILCROP=20
LONG_MIN_LEN=500        # 0 disables length filter
LONG_PLOT_MAXLEN=40000  # NanoPlot x-axis cutoff, 0 = none

# ---- assembly / polishing ----
GENOME_SIZE=""          # optional Flye hint, e.g. 5m
MEDAKA_MODEL=""         # optional, match your flowcell/basecaller

# ---- validation ----
BUSCO_LINEAGE="bacteria_odb10"   # or auto / auto-prok / auto-euk, or e.g. fungi_odb10

# ---- conda envs for tools kept separate ("" = use the active environment) ----
ENV_MEDAKA="bioinfo-medaka"
ENV_BUSCO="bioinfo-busco"

KEEP_INTERMEDIATE=0     # 1 keeps large SAM files
