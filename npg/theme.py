"""Colour palettes and the Qt stylesheet.

    colors(name)      -> palette dict (treat as read-only)
    stylesheet(name)  -> QSS string for QApplication.setStyleSheet()

`name` is "dark" or "light"; anything else falls back to dark.
"""

DARK = {
    "bg": "#0a0a0b",
    "panel": "#111113",
    "panel_alt": "#16161a",
    "border": "#26262b",
    "text": "#c8c8cc",
    "text_dim": "#6e6e76",
    "accent": "#a8121a",
    "accent_bright": "#e0222d",
    "online": "#3fa66b",
    "offline": "#a8121a",
    "warn": "#d9a441",
    "select": "#ffffff",          # outline of the selected map node
    "node_online_fill": "#12301f",
    "node_offline_fill": "#2a0a0d",
    "node_unknown_fill": "#18181b",
    "edge_online": "#245c3c",
    "edge_offline": "#4a1216",
}

LIGHT = {
    "bg": "#f6f6f7",
    "panel": "#ffffff",
    "panel_alt": "#eeeef0",
    "border": "#d3d3d8",
    "text": "#1a1a1c",
    "text_dim": "#6a6a72",
    "accent": "#a8121a",
    "accent_bright": "#c4161f",
    "online": "#2f7d4f",
    "offline": "#a8121a",
    "warn": "#9a6a10",
    "select": "#1a1a1c",
    "node_online_fill": "#d5eadc",
    "node_offline_fill": "#f4d6d8",
    "node_unknown_fill": "#e3e3e7",
    "edge_online": "#8cc0a0",
    "edge_offline": "#dba3a7",
}

PALETTES = {"dark": DARK, "light": LIGHT}
THEME_NAMES = tuple(PALETTES)


def colors(name):
    return PALETTES.get(name, DARK)


def stylesheet(name):
    c = colors(name)
    return f"""
* {{
    font-family: "JetBrains Mono", "DejaVu Sans Mono", "Ubuntu Mono", monospace;
    font-size: 12px;
    color: {c["text"]};
}}
QMainWindow, QDialog, QWidget {{ background-color: {c["bg"]}; }}

QLabel#title {{
    color: {c["accent_bright"]};
    font-size: 15px;
    font-weight: bold;
    letter-spacing: 3px;
    padding: 4px 2px;
}}
QLabel#sectionHeader {{
    color: {c["text_dim"]};
    font-size: 10px;
    letter-spacing: 2px;
    padding: 6px 2px 2px 2px;
}}
QLabel#statusBar {{ color: {c["text_dim"]}; padding: 2px 4px; }}

QFrame#panel {{
    background-color: {c["panel"]};
    border: 1px solid {c["border"]};
}}

QGraphicsView {{ border: 1px solid {c["border"]}; }}

QTableWidget {{
    background-color: {c["panel"]};
    alternate-background-color: {c["panel_alt"]};
    border: 1px solid {c["border"]};
    gridline-color: {c["border"]};
    selection-background-color: {c["accent"]};
    selection-color: #ffffff;
    outline: 0;
}}
QTableWidget::item {{ padding: 3px 6px; border: none; }}
QHeaderView::section {{
    background-color: {c["bg"]};
    color: {c["text_dim"]};
    border: none;
    border-bottom: 1px solid {c["accent"]};
    padding: 4px 6px;
    font-size: 10px;
    letter-spacing: 2px;
}}

QPushButton {{
    background-color: {c["panel"]};
    border: 1px solid {c["border"]};
    padding: 5px 14px;
    letter-spacing: 1px;
}}
QPushButton:hover {{ border-color: {c["accent_bright"]}; }}
QPushButton:pressed {{ background-color: {c["accent"]}; color: #ffffff; }}
QPushButton:checked {{ border-color: {c["accent"]}; }}
QPushButton:disabled {{ color: {c["text_dim"]}; }}

QCheckBox, QRadioButton {{ spacing: 8px; padding: 2px 0; background: transparent; }}
QCheckBox:disabled, QRadioButton:disabled {{ color: {c["text_dim"]}; }}
QCheckBox::indicator, QRadioButton::indicator {{
    width: 13px;
    height: 13px;
    border: 1px solid {c["border"]};
    background-color: {c["panel"]};
}}
QRadioButton::indicator {{ border-radius: 7px; }}
QCheckBox::indicator:checked, QRadioButton::indicator:checked {{
    background-color: {c["accent"]};
    border-color: {c["accent_bright"]};
}}
QCheckBox::indicator:disabled, QRadioButton::indicator:disabled {{ border-color: {c["panel_alt"]}; }}

QTimeEdit {{
    background-color: {c["panel"]};
    border: 1px solid {c["border"]};
    padding: 3px 6px;
    selection-background-color: {c["accent"]};
    selection-color: #ffffff;
}}
QTimeEdit:disabled {{ color: {c["text_dim"]}; }}

QMenu {{ background-color: {c["panel"]}; border: 1px solid {c["border"]}; padding: 3px; }}
QMenu::item {{ padding: 5px 24px; background: transparent; }}
QMenu::item:selected {{ background-color: {c["accent"]}; color: #ffffff; }}
QMenu::separator {{ height: 1px; background: {c["border"]}; margin: 3px 6px; }}

QToolTip {{
    background-color: {c["panel"]};
    color: {c["text"]};
    border: 1px solid {c["border"]};
    padding: 3px;
}}

QSplitter::handle {{ background-color: {c["border"]}; }}
QSplitter::handle:hover {{ background-color: {c["accent"]}; }}

QScrollBar:vertical {{ background: {c["bg"]}; width: 9px; margin: 0; }}
QScrollBar::handle:vertical {{ background: {c["border"]}; min-height: 24px; }}
QScrollBar::handle:vertical:hover {{ background: {c["accent"]}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QScrollBar:horizontal {{ background: {c["bg"]}; height: 9px; }}
QScrollBar::handle:horizontal {{ background: {c["border"]}; min-width: 24px; }}
QScrollBar::handle:horizontal:hover {{ background: {c["accent"]}; }}
"""
