# Concepts and Glossary

**Workflow logic:** raw reads → QC → trim/filter → assemble → polish → validate. Bad input gives a bad genome, so QC comes first.

**Illumina:** short (100–300 bp), very accurate, paired-end (R1 forward, R2 reverse). **Nanopore:** long (1 kb–100 kb+), noisier; spans repeats. Combining both is *hybrid assembly*.

**FASTQ** (4 lines per read): `@id`, sequence, `+`, quality string. `N` = unknown base. **Phred:** Q10 ≈ 90%, Q20 ≈ 99%, Q30 ≈ 99.9% base accuracy.

**Adapters:** synthetic sequences added during library prep; must be trimmed. Illumina quality typically declines toward read ends.

**SAM/BAM:** SAM is text alignment output; BAM is compressed, sorted, indexed form.

| Term | Meaning |
|---|---|
| Read | DNA fragment from the sequencer |
| Contig | continuous assembled sequence |
| N50 | length L such that contigs ≥ L hold half the assembly |
| Polishing | correcting residual assembly errors (Medaka: long reads; Polypolish: short reads) |
| BUSCO | completeness check against expected single-copy genes (Complete / Fragmented / Missing) |
| Reference | known genome used for comparison |

**Reproducibility:** keep configs, versions and logs. Record versions with `conda env export -n bioinfo > envs/bioinfo.lock.yml`.
