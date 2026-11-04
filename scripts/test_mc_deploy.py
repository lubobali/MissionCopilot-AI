import pytest
from mc_deploy import check_image, migrations_applied, with_image

pytestmark = pytest.mark.unit

GOOD = "ghcr.io/lubobali/missioncopilot-backend@sha256:" + "a" * 64


def test_only_an_image_by_digest_is_deployed():
    assert check_image(GOOD, allow_local=False) == GOOD


@pytest.mark.parametrize(
    "bad",
    [
        "ghcr.io/lubobali/missioncopilot-backend:latest",
        "ghcr.io/lubobali/missioncopilot-backend:sha-abc",
        "ghcr.io/someone-else/missioncopilot-backend@sha256:" + "a" * 64,
        "ghcr.io/lubobali/missioncopilot-backend@sha256:" + "a" * 63,
        "missioncopilot-backend:check",
    ],
)
def test_a_tag_or_another_image_is_refused(bad):
    with pytest.raises(ValueError, match="by digest"):
        check_image(bad, allow_local=False)


def test_a_local_image_only_for_checks():
    assert check_image("missioncopilot-backend:check", allow_local=True)


def test_the_values_file_keeps_the_previous_image():
    before = "MC_ENV=staging\nMC_IMAGE=old@sha256:1\nMC_PORT=8121\n"

    after = with_image(before, "new@sha256:2")

    assert (
        after
        == "MC_ENV=staging\nMC_IMAGE=new@sha256:2\nMC_PORT=8121\nMC_IMAGE_PREVIOUS=old@sha256:1\n"
    )
    assert with_image(after, "newer@sha256:3").count("MC_IMAGE_PREVIOUS=") == 1
    assert "MC_IMAGE_PREVIOUS=new@sha256:2" in with_image(after, "newer@sha256:3")


@pytest.mark.parametrize(
    ("log", "applied"),
    [
        ("OK: directory: applied nothing, up to date\n"
         "OK: kandor-works: applied nothing, up to date", False),
        ("OK: directory: applied [3]\nOK: kandor-works: applied nothing, up to date", True),
        ("", True),  # no log at all: assume the worst
    ],
)  # fmt: skip
def test_a_rollback_knows_whether_migrations_ran(log, applied):
    assert migrations_applied(log) is applied
