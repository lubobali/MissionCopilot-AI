from pathlib import Path

import check_theme_colors
import pytest
from check_theme_colors import find_raw_colors

pytestmark = pytest.mark.unit


def _swift(tmp_path: Path, name: str, body: str) -> Path:
    path = tmp_path / "ios" / "MissionCopilot" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    return path


@pytest.mark.parametrize(
    "line",
    [
        "Text(a).foregroundStyle(.secondary)",
        "Text(a).foregroundStyle(check.passed ? .green : .red)",
        "Color(.systemBackground).ignoresSafeArea()",
        "Rectangle().fill(Color.blue)",
        "Text(a).foregroundColor(.orange)",
        "Button(a) {}.tint(.purple)",
        "Color(red: 0.1, green: 0.2, blue: 0.3)",
        "UIColor(white: 0.5, alpha: 1)",
        "Color(uiColor: .label)",
        "let c = #colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)",
        "view.background(.gray)",
    ],
)
def test_a_raw_color_in_a_screen_is_reported(tmp_path, line):
    path = _swift(tmp_path, "App/Screen.swift", f"let x = 1\n{line}\n")

    assert find_raw_colors([path]) == [(path, 2, line)]


@pytest.mark.parametrize(
    "line",
    [
        "Text(a).foregroundStyle(Color(.secondaryText))",
        "Color(.background).ignoresSafeArea()",
        "Text(a).font(.headline)",
        'Image(systemName: "lock.fill")',
        "// .foregroundStyle(.red) was wrong",
        "let isRed = state == .red",
        "Text(a).foregroundStyle(Color(.text)).opacity(style.primary ? 1 : 0.5)",
    ],
)
def test_theme_roles_and_other_code_pass(tmp_path, line):
    path = _swift(tmp_path, "App/Screen.swift", f"{line}\n")

    assert find_raw_colors([path]) == []


def test_the_theme_folder_itself_may_hold_raw_colors(tmp_path):
    line = "UIColor(red: 1, green: 0, blue: 0, alpha: 1)\n"
    path = _swift(tmp_path, "Platform/Theme/Palette.swift", line)

    assert find_raw_colors([path]) == []


def test_only_app_swift_files_are_checked(tmp_path):
    test_file = tmp_path / "ios" / "MissionCopilotTests" / "T.swift"
    test_file.parent.mkdir(parents=True)
    test_file.write_text("Color(red: 1, green: 0, blue: 0)\n")
    notes = _swift(tmp_path, "notes.md", "Text(a).foregroundStyle(.red)\n")

    assert find_raw_colors([test_file, notes]) == []


def test_main_fails_and_names_the_line(tmp_path, monkeypatch, capsys):
    path = _swift(tmp_path, "App/Screen.swift", "Text(a).foregroundStyle(.red)\n")
    monkeypatch.setattr(check_theme_colors, "tracked_files", lambda: [path])

    assert check_theme_colors.main() == 1
    assert f"{path}:1" in capsys.readouterr().out


def test_main_passes_on_a_clean_tree(tmp_path, monkeypatch, capsys):
    path = _swift(tmp_path, "App/Screen.swift", "Text(a).foregroundStyle(Color(.text))\n")
    monkeypatch.setattr(check_theme_colors, "tracked_files", lambda: [path])

    assert check_theme_colors.main() == 0
    assert "OK" in capsys.readouterr().out
