# Criteria export engine

```bash
# from repository root
python3 -m engine seed
python3 -m engine export --dry-run --job-name DHL
python3 -m engine export --json --job-name DHL
python3 -m engine append-draft path.md
.venv/bin/pytest -q
```

Does not modify Apple Mail; only writes `.eml` files under each job’s `outputDir`. Never sends.
