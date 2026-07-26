from pathlib import Path


def load_tests(loader, tests, pattern):
    contract_dir = Path(__file__).parent
    return loader.discover(
        start_dir=str(contract_dir),
        pattern="test*.py",
        top_level_dir=str(contract_dir.parents[1]),
    )
