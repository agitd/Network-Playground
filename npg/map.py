"""Interactive network map: the gateway sits in the centre, devices ring around it.

Mouse wheel = zoom, drag background = pan, drag a node = move it (the caller
saves the position), click a node = select it, double-click background = fit all.
"""

import math

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QBrush, QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QGraphicsEllipseItem, QGraphicsItem, QGraphicsLineItem, QGraphicsScene,
    QGraphicsSimpleTextItem, QGraphicsView,
)

from .theme import colors

HUB_RADIUS = 26
NODE_RADIUS = 15
RING_BASE = 190
RING_STEP = 130
SCENE_RECT = QRectF(-800, -600, 1600, 1200)


def _node_colors(c, online):
    """(fill, outline) for a node; online=None is the placeholder (gateway not found yet)."""
    if online is None:
        return c["node_unknown_fill"], c["text_dim"]
    if online:
        return c["node_online_fill"], c["online"]
    return c["node_offline_fill"], c["offline"]


def default_position(index):
    """Slot `index` on concentric rings around the centre: 10 nodes, then 16, 22, ..."""
    ring, cap = 0, 10
    while index >= cap:
        index -= cap
        ring += 1
        cap += 6
    angle = -math.pi / 2 + 2 * math.pi * index / cap + ring * 0.35
    radius = RING_BASE + ring * RING_STEP
    return radius * math.cos(angle), radius * math.sin(angle)


def _font():
    font = QFont()
    font.setFamilies(["JetBrains Mono", "DejaVu Sans Mono", "Ubuntu Mono"])
    font.setStyleHint(QFont.Monospace)
    font.setPointSize(8)
    return font


class Node(QGraphicsEllipseItem):
    def __init__(self, view, dev_id, radius, online, label, movable, c):
        super().__init__(-radius, -radius, 2 * radius, 2 * radius)
        self.view_ref = view
        self.dev_id = dev_id
        self.edge = None
        self._press_pos = QPointF()

        fill, outline = _node_colors(c, online)
        self.base_pen = QPen(QColor(outline), 2)
        self.setBrush(QBrush(QColor(fill)))
        self.setPen(self.base_pen)
        self.setZValue(3 if not movable else 2)
        if dev_id is not None:
            self.setCursor(Qt.PointingHandCursor)
        if movable:
            self.setFlag(QGraphicsItem.ItemIsMovable, True)
            self.setFlag(QGraphicsItem.ItemSendsGeometryChanges, True)

        text = QGraphicsSimpleTextItem(label, self)
        text.setFont(_font())
        text.setBrush(QBrush(QColor(c["text"] if online else c["text_dim"])))
        rect = text.boundingRect()
        text.setPos(-rect.width() / 2, radius + 4)

    def itemChange(self, change, value):
        if change == QGraphicsItem.ItemPositionHasChanged and self.edge is not None:
            self.edge.setLine(0, 0, self.pos().x(), self.pos().y())  # hub is at the origin
        return super().itemChange(change, value)

    def mousePressEvent(self, event):
        self._press_pos = QPointF(self.pos())
        super().mousePressEvent(event)
        if self.dev_id is not None:
            self.view_ref.deviceSelected.emit(self.dev_id)

    def mouseReleaseEvent(self, event):
        super().mouseReleaseEvent(event)
        if self.dev_id is not None and self.pos() != self._press_pos:
            self.view_ref.deviceMoved.emit(self.dev_id, self.pos().x(), self.pos().y())


class NetworkMap(QGraphicsView):
    deviceSelected = Signal(int)
    deviceMoved = Signal(int, float, float)

    def __init__(self):
        super().__init__()
        self._scene = QGraphicsScene(self)
        self._scene.setSceneRect(SCENE_RECT)
        self.setScene(self._scene)
        self.c = colors("dark")
        self.setBackgroundBrush(QBrush(QColor(self.c["panel"])))
        self.setRenderHint(QPainter.Antialiasing)
        self.setDragMode(QGraphicsView.ScrollHandDrag)
        self.setViewportUpdateMode(QGraphicsView.FullViewportUpdate)
        self.setTransformationAnchor(QGraphicsView.AnchorUnderMouse)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._nodes = {}
        self._selected = None
        self._fitted = False

    def set_theme(self, name):
        """Switch palette. Call set_data() afterwards to repaint the nodes."""
        self.c = colors(name)
        self.setBackgroundBrush(QBrush(QColor(self.c["panel"])))

    # ---- data -> items ----
    @staticmethod
    def _label(d, is_hub, is_self):
        lines = []
        if is_hub:
            lines.append("GATEWAY")
        lines.append(d["ip"] or "?")
        host = d["name"] or d["hostname"]  # a custom name wins over the network hostname
        if host:
            lines.append(host if len(host) <= 22 else host[:21] + "…")
        if is_self:
            lines.append("[this PC]")
        return "\n".join(lines)

    def set_data(self, devices, gateway_ip, self_mac, positions, selected_id):
        self._scene.clear()
        self._nodes = {}
        self._selected = selected_id

        hub_dev = None
        if gateway_ip:
            hub_dev = next((d for d in devices if d["ip"] == gateway_ip), None)

        if hub_dev is not None:
            is_self = bool(self_mac) and hub_dev["mac"] == self_mac
            hub = Node(self, hub_dev["id"], HUB_RADIUS, bool(hub_dev["online"]),
                       self._label(hub_dev, True, is_self), movable=False, c=self.c)
            self._nodes[hub_dev["id"]] = hub
        else:
            hub = Node(self, None, HUB_RADIUS, None, "GATEWAY\n(not found yet)", movable=False, c=self.c)
        self._scene.addItem(hub)  # centre of the map = (0, 0)

        others = sorted((d for d in devices if d is not hub_dev), key=lambda d: d["id"])
        for index, d in enumerate(others):
            x, y = positions.get(d["id"]) or default_position(index)
            online = bool(d["online"])
            is_self = bool(self_mac) and d["mac"] == self_mac

            edge = QGraphicsLineItem(0, 0, x, y)
            edge.setPen(QPen(QColor(self.c["edge_online"] if online else self.c["edge_offline"]), 1,
                             Qt.SolidLine if online else Qt.DashLine))
            edge.setZValue(1)
            self._scene.addItem(edge)

            node = Node(self, d["id"], NODE_RADIUS, online, self._label(d, False, is_self), movable=True, c=self.c)
            node.setPos(x, y)
            node.edge = edge
            self._scene.addItem(node)
            self._nodes[d["id"]] = node

        self._apply_selection()
        if self.isVisible() and not self._fitted:
            self.fit()
            self._fitted = True

    # ---- selection ----
    def set_selected(self, dev_id):
        self._selected = dev_id
        self._apply_selection()

    def _apply_selection(self):
        for dev_id, node in self._nodes.items():
            if dev_id == self._selected:
                node.setPen(QPen(QColor(self.c["select"]), 3))
            else:
                node.setPen(node.base_pen)

    # ---- view behaviour ----
    def fit(self):
        rect = self._scene.itemsBoundingRect().adjusted(-50, -40, 50, 40)
        self.fitInView(rect, Qt.KeepAspectRatio)
        if self.transform().m11() > 1.5:  # don't blow up a nearly empty map
            self.resetTransform()
            self.scale(1.5, 1.5)
            self.centerOn(0, 0)

    def showEvent(self, event):
        super().showEvent(event)
        if not self._fitted:
            self.fit()
            self._fitted = True

    def wheelEvent(self, event):
        factor = 1.15 if event.angleDelta().y() > 0 else 1 / 1.15
        if 0.25 <= self.transform().m11() * factor <= 3.0:
            self.scale(factor, factor)

    def mouseDoubleClickEvent(self, event):
        if self.itemAt(event.position().toPoint()) is None:
            self.fit()
        else:
            super().mouseDoubleClickEvent(event)
