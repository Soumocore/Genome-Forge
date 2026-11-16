#!/usr/bin/env bash
# Download a small public Illumina paired-end E. coli test set (SRR2584868)
# into data/raw/. Good for testing QC + trimming only.
# NOTE: no matching Nanopore data is downloaded - supply your own for assembly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../data/raw"

BASE="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR258/008/SRR2584868"
for i in 1 2; do
  out="sample_R${i}.fq.gz"
  wget -c "${BASE}/SRR2584868_${i}.fastq.gz" -O "$out"
  gzip -t "$out" && echo "OK: $out is a valid gzip file"
done
ls -lh
