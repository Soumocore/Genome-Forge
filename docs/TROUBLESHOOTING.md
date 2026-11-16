# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CondaToSNonInteractiveError` | Anaconda channels need ToS acceptance | Use the provided envs (they use conda-forge/bioconda with `nodefaults`), or `conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main` (and `/pkgs/r`) |
| `mamba: command not found` | Not installed | Install Miniforge, or `conda install -n base -c conda-forge mamba` |
| Solver hangs ("Using Flat Repodata") | Huge dependency graph / channel mix | Use `scripts/setup_envs.sh`; keep `channel_priority strict`; install in small batches |
| `command not found: fastqc` | Wrong/inactive environment | `conda activate bioinfo`; check typos (`fatsqc`) |
| File is 0 bytes | Failed download / dead URL | `ls -lh`, delete it, re-download |
| `gzip: unexpected end of file` | Truncated download | `gzip -t file.gz`; re-download with `wget -c` |
| `No such file` for `sample_r1.fq.gz` | Linux is case-sensitive | Match `R1` exactly; use `ls` |
| Pipeline says tool missing | Env not active | `conda activate bioinfo` |
| Medaka/BUSCO not found | Separate envs not created | `bash scripts/setup_envs.sh`, or set `ENV_MEDAKA=""` and install into the active env |
| BUSCO fails on existing output | Previous run folder | `./run_pipeline.sh -s busco -f` |
| Step skipped unexpectedly | Output already exists | Add `-f` |
| `Missing or empty file` | Wrong path (relative paths start from where you run the command) or failed download | `ls -lh` the path; use absolute paths |
| R2 not found automatically | File names don't follow `_R1/_R2` or `_1/_2` | Pass `--r2` explicitly |
| Sample sheet columns misread | Spaces instead of tabs, or empty cells | Separate by tabs; write `-` for empty cells |

Debug checklist: `pwd` → `ls -lh` → `conda env list` → `tool --version` → `gzip -t file.gz`. Per-tool logs are in `results/<SAMPLE>/logs/`.
