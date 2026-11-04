import re

import pytest
from render_nginx_site import TEMPLATES, render

pytestmark = pytest.mark.unit

PROD = {"env": "prod", "hostname": "mc.lubot.ai", "port": 8120}
STAGING = {"env": "staging", "hostname": "mc-staging.lubot.ai", "port": 8121}


def _site(**kwargs) -> str:
    return render(TEMPLATES["site"], **(PROD | kwargs))


def _locations(text: str) -> dict[str, str]:
    """Each location's body, by its header."""
    return dict(re.findall(r"\n\s*location ([^{]+)\{(.*?)\n\s*\}", text, flags=re.DOTALL))


def test_prod_listens_on_443_with_http2_on_both_address_families():
    site = _site()

    assert "listen 443 ssl http2;" in site and "listen [::]:443 ssl http2;" in site
    assert "listen 80;" in site and "listen [::]:80;" in site
    assert "default_server" not in site  # never take over unknown host names from other sites
    assert "server_name mc.lubot.ai;" in site


def test_the_api_gets_the_exact_path_and_the_real_client():
    site = _site()

    # Every proxy_pass without a URI part: with one, nginx would send a normalized path (decoded,
    # slashes merged) instead of the one the phone signed.
    passes = re.findall(r"proxy_pass [^;]+;", site)
    assert passes and set(passes) == {"proxy_pass http://127.0.0.1:8120;"}
    assert "proxy_set_header Host $host;" in site
    assert "proxy_set_header X-Forwarded-For $remote_addr;" in site  # overwrite, never append
    assert "$proxy_add_x_forwarded_for" not in site
    assert "proxy_http_version 1.1;" in site  # nginx 1.24 defaults to 1.0


def test_no_location_sets_its_own_proxy_headers():
    # nginx: a proxy_set_header inside a location drops every server-level one.
    assert [h for h, body in _locations(_site()).items() if "proxy_set_header" in body] == []


def test_tls_and_its_settings():
    site = _site()

    assert "ssl_protocols TLSv1.2 TLSv1.3;" in site
    assert "ssl_certificate /etc/letsencrypt/live/mc.lubot.ai/fullchain.pem;" in site
    assert "ssl_stapling" not in site  # Let's Encrypt ended OCSP in 2025
    assert "server_tokens off;" in site


def test_floods_get_429_with_retry_after_and_outages_a_503_json():
    site, locations = _site(), _locations(_site())

    assert "limit_req_zone $binary_remote_addr zone=mc_prod_addr:10m rate=20r/s;" in site
    assert "limit_req zone=mc_prod_addr burst=40 nodelay;" in site
    assert "limit_req_status 429;" in site
    assert "error_page 429 = @mc_too_many;" in site
    assert "error_page 502 503 504 = @mc_unavailable;" in site
    assert "add_header Retry-After 1 always;" in locations["@mc_too_many "]
    assert "return 429 " in locations["@mc_too_many "]
    assert "add_header Retry-After 5 always;" in locations["@mc_unavailable "]
    assert "return 503 " in locations["@mc_unavailable "]


def test_pack_files_keep_their_bytes_and_one_range():
    packs = _locations(_site())["~ ^/v1/missions/[^/]+/pack/files/ "]

    assert "gzip off;" in packs and "max_ranges 1;" in packs
    assert "proxy_read_timeout 300s;" in packs and "send_timeout 300s;" in packs


def test_its_own_logs_and_body_limit():
    site = _site()

    assert "access_log /var/log/nginx/missioncopilot-prod.access.log;" in site
    assert "error_log /var/log/nginx/missioncopilot-prod.error.log;" in site
    assert "client_max_body_size 1m;" in site


def test_staging_and_prod_differ_only_in_their_names_and_port():
    staging = render(TEMPLATES["site"], **STAGING)
    same = (
        staging.replace("mc-staging.lubot.ai", "mc.lubot.ai")
        .replace("8121", "8120")
        .replace("mc_staging_", "mc_prod_")
        .replace("missioncopilot-staging", "missioncopilot-prod")
        .replace("MissionCopilot staging:", "MissionCopilot prod:")
    )

    assert same == _site()


def test_the_certificate_bootstrap_serves_only_the_challenge_and_a_redirect():
    site = render(TEMPLATES["http-only"], **STAGING)

    assert "ssl" not in site
    assert "root /var/www/certbot;" in site
    assert "return 301 https://$host$request_uri;" in site
    assert "proxy_pass" not in site


def test_a_check_can_listen_on_test_ports_only():
    site = _site(
        env="check", listen_https=["127.0.0.1:18443 ssl http2"], listen_http=["127.0.0.1:18080"]
    )

    assert re.findall(r"listen ([^;]+);", site) == ["127.0.0.1:18080", "127.0.0.1:18443 ssl http2"]


@pytest.mark.parametrize(
    "bad",
    [
        {"hostname": "mc.lubot.ai; evil"},
        {"hostname": "MC.lubot.ai"},
        {"hostname": "localhost"},
        {"port": 80},
        {"port": 70000},
        {"env": "dev"},
    ],
)
def test_bad_values_are_refused(bad):
    with pytest.raises(ValueError):
        _site(**bad)


def test_a_placeholder_left_over_is_refused():
    with pytest.raises(ValueError, match="UNKNOWN"):
        render(TEMPLATES["site"] + "\n# {{UNKNOWN}}\n", **PROD)
