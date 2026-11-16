# Contributing to Genome-Forge

Thanks for helping! The most useful contributions right now:

1. **Real-data test reports.** Run the pipeline on your data and tell us what happened (works / breaks), including organism, read types and tool versions.
2. **Bug reports.** Open an issue with the exact command, the error, and the relevant file from `results/<sample>/logs/`.
3. **Pull requests.** Small, focused changes are easiest to review.

## Before you open a pull request

- Keep the code in Bash and check it with ShellCheck: `shellcheck -x run_pipeline.sh scripts/*.sh`
- Test at least: paired-end, single-end, and a sample-sheet run (the stand-in-tool approach in the issue template works for logic changes).
- Update the README if you add or change options.

## Ideas welcome

- Snakemake / Nextflow versions of the workflow
- Containers (Docker/Apptainer)
- More long-read polishing options and read-type presets
- Extra QC reports (e.g. MultiQC, QUAST)
