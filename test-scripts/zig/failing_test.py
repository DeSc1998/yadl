import os
import pytest
from pathlib import Path

from helper import parse_yadl, run_failing_test, to_dir

configurations = []
TEST_DIR = os.path.abspath("test/failing")
for posix_path in Path(TEST_DIR).rglob("*.yadl"):
    full_path = os.path.join(os.path.dirname(TEST_DIR), posix_path)
    configurations.append((parse_yadl(str(full_path)), TEST_DIR))
file_names = map(lambda t: to_dir(t[0], t[1]), configurations)


@pytest.mark.parametrize("config", configurations, ids=file_names)
def test_config(config):
    run_failing_test(config[0])


def pytest_collection_modifyitems(items):
    for item in items:
        if item.get_marker('timeout') is None:
            item.add_marker(pytest.mark.timeout(10))
