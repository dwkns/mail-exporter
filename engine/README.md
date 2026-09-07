# Criteria export engine

```bash
# from repository root
python3 -m engine seed
python3 -m engine export --dry-run --job-name DHL
python3 -m engine export --job-name DHL
python3 -m unittest tests.test_criteria -v
```

Does not modify Apple Mail; only writes `.eml` files under each job’s `outputDir`.
