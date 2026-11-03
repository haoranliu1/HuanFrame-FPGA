#!/usr/bin/env python3
"""Windows GUI for sending Chinese bitmap subtitles to the HX4S20 FPGA."""

from __future__ import annotations

import argparse
import ipaddress
import socket
import subprocess
import threading
import time
import tkinter as tk
from datetime import datetime
from tkinter import messagebox, ttk

from PIL import Image, ImageDraw, ImageFont


DEFAULT_SOURCE_IP = "192.168.240.2"
DEFAULT_TARGET_IP = "192.168.240.1"
DEFAULT_TARGET_PORT = 5000
MAX_CHARACTERS = 32
BITMAP_SIZE = 16
BITMAP_MAGIC = b"CNB1"
FONT_PATH = r"C:\Windows\Fonts\msyhbd.ttc"
COLOR_OPTIONS = {
    "白色": 0,
    "黄色": 1,
    "青色": 2,
    "绿色": 3,
    "橙色": 4,
    "粉色": 5,
    "红色": 6,
}
PRESETS = (
    "欢迎使用安路科技",
    "图片播放系统运行正常",
    "网络字幕测试成功",
    "现场演示进行中",
)


def validate_ipv4(value: str) -> str:
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError as exc:
        raise ValueError(f"IPv4 地址无效：{value}") from exc
    if address.version != 4:
        raise ValueError(f"不是 IPv4 地址：{value}")
    return str(address)


def validate_message(text: str) -> str:
    if not text:
        raise ValueError("请输入要发送的中英文字幕。")
    if not 1 <= len(text) <= MAX_CHARACTERS:
        raise ValueError(f"字幕长度必须为 1～{MAX_CHARACTERS} 个字符。")
    if any(ord(character) < 32 for character in text):
        raise ValueError("字幕只能使用单行文字，不能包含换行或控制字符。")
    return text


def render_character(character: str, font: ImageFont.FreeTypeFont) -> bytes:
    image = Image.new("L", (BITMAP_SIZE, BITMAP_SIZE), 0)
    draw = ImageDraw.Draw(image)
    box = draw.textbbox((0, 0), character, font=font)
    width = box[2] - box[0]
    height = box[3] - box[1]
    x = (BITMAP_SIZE - width) // 2 - box[0]
    y = (BITMAP_SIZE - height) // 2 - box[1]
    draw.text((x, y), character, font=font, fill=255)

    rows = bytearray()
    for row_index in range(BITMAP_SIZE):
        row_bits = 0
        for column_index in range(BITMAP_SIZE):
            if image.getpixel((column_index, row_index)) >= 80:
                row_bits |= 1 << (BITMAP_SIZE - 1 - column_index)
        rows.extend(row_bits.to_bytes(2, "big"))
    return bytes(rows)


def build_bitmap_payload(text: str, color_index: int) -> bytes:
    text = validate_message(text)
    if not 0 <= color_index <= 6:
        raise ValueError("字幕颜色编号必须在 0～6 之间。")
    font = ImageFont.truetype(FONT_PATH, 15)
    payload = bytearray(BITMAP_MAGIC)
    payload.extend((len(text), color_index, 0, 0))
    for character in text:
        payload.extend(render_character(character, font))
    return bytes(payload)


def send_udp(
    text: str,
    *,
    color_index: int,
    source_ip: str,
    target_ip: str,
    target_port: int,
) -> tuple[int, tuple[str, int]]:
    payload = build_bitmap_payload(text, color_index)
    source_ip = validate_ipv4(source_ip)
    target_ip = validate_ipv4(target_ip)
    if not 1 <= target_port <= 65535:
        raise ValueError("UDP 端口必须在 1～65535 之间。")

    last_error: OSError | None = None
    for attempt in range(3):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.bind((source_ip, 0))
                sent = sock.sendto(payload, (target_ip, target_port))
                return sent, sock.getsockname()
        except OSError as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(0.2)
    assert last_error is not None
    raise OSError(
        f"无法从 {source_ip} 发送 UDP 数据。请检查‘以太网 2’的 IPv4 设置和网线连接。"
    ) from last_error


def ping_fpga(source_ip: str, target_ip: str) -> tuple[bool, str]:
    source_ip = validate_ipv4(source_ip)
    target_ip = validate_ipv4(target_ip)
    command = [
        "ping.exe",
        "-S",
        source_ip,
        "-n",
        "1",
        "-w",
        "1000",
        target_ip,
    ]
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="mbcs",
        errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )
    return completed.returncode == 0, completed.stdout


class SubtitleSenderApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("FPGA 网络字幕发送器（中英文点阵版）")
        self.root.geometry("860x650")
        self.root.minsize(760, 560)
        self.root.configure(bg="#eef3f8")

        self.source_ip = tk.StringVar(value=DEFAULT_SOURCE_IP)
        self.target_ip = tk.StringVar(value=DEFAULT_TARGET_IP)
        self.target_port = tk.StringVar(value=str(DEFAULT_TARGET_PORT))
        self.message = tk.StringVar(value="欢迎使用安路科技 FPGA")
        self.counter = tk.StringVar(value=f"{len(self.message.get())} / 32")
        self.color_name = tk.StringVar(value="青色")
        self.connection_text = tk.StringVar(value="尚未检测")
        self.status_text = tk.StringVar(value="准备就绪")
        self.last_message = ""
        self._checking = False

        self._configure_styles()
        self._build_ui()
        self.message.trace_add("write", self._on_message_changed)
        self.root.bind("<Return>", self._send_from_event)
        self.root.after(300, self.check_connection)

    def _configure_styles(self) -> None:
        style = ttk.Style(self.root)
        if "clam" in style.theme_names():
            style.theme_use("clam")
        style.configure("TFrame", background="#eef3f8")
        style.configure("Card.TFrame", background="#ffffff")
        style.configure(
            "TLabel",
            background="#eef3f8",
            foreground="#223047",
            font=("Microsoft YaHei UI", 10),
        )
        style.configure(
            "Card.TLabel",
            background="#ffffff",
            foreground="#223047",
            font=("Microsoft YaHei UI", 10),
        )
        style.configure(
            "Hint.Card.TLabel",
            background="#ffffff",
            foreground="#66758c",
            font=("Microsoft YaHei UI", 9),
        )
        style.configure(
            "Accent.TButton",
            background="#1769e0",
            foreground="#ffffff",
            font=("Microsoft YaHei UI", 10, "bold"),
            padding=(18, 10),
        )
        style.map(
            "Accent.TButton",
            background=[("active", "#0f57bd"), ("disabled", "#9eb8dc")],
        )
        style.configure(
            "Secondary.TButton",
            background="#e8eef7",
            foreground="#23405f",
            font=("Microsoft YaHei UI", 9),
            padding=(12, 8),
        )
        style.map("Secondary.TButton", background=[("active", "#d8e4f2")])
        style.configure(
            "Treeview",
            rowheight=28,
            font=("Microsoft YaHei UI", 9),
            background="#ffffff",
            fieldbackground="#ffffff",
        )
        style.configure(
            "Treeview.Heading",
            font=("Microsoft YaHei UI", 9, "bold"),
            background="#dfe8f3",
            foreground="#223047",
        )

    def _build_ui(self) -> None:
        header = tk.Frame(self.root, bg="#123b70", height=92)
        header.pack(fill="x")
        header.pack_propagate(False)
        tk.Label(
            header,
            text="FPGA 网络字幕发送器",
            bg="#123b70",
            fg="#ffffff",
            font=("Microsoft YaHei UI", 20, "bold"),
        ).pack(anchor="w", padx=28, pady=(17, 0))
        tk.Label(
            header,
            text="HX4S20 · UDP 中英文点阵字幕 · 单行最多 32 个字符",
            bg="#123b70",
            fg="#cfe2ff",
            font=("Microsoft YaHei UI", 9),
        ).pack(anchor="w", padx=30, pady=(3, 0))

        body = ttk.Frame(self.root, padding=(22, 18))
        body.pack(fill="both", expand=True)

        connection = ttk.Frame(body, style="Card.TFrame", padding=16)
        connection.pack(fill="x", pady=(0, 12))
        connection.columnconfigure(1, weight=1)
        connection.columnconfigure(3, weight=1)
        ttk.Label(connection, text="本机 IP", style="Card.TLabel").grid(
            row=0, column=0, sticky="w", padx=(0, 8)
        )
        ttk.Entry(connection, textvariable=self.source_ip, width=18).grid(
            row=0, column=1, sticky="ew", padx=(0, 18)
        )
        ttk.Label(connection, text="FPGA IP", style="Card.TLabel").grid(
            row=0, column=2, sticky="w", padx=(0, 8)
        )
        ttk.Entry(connection, textvariable=self.target_ip, width=18).grid(
            row=0, column=3, sticky="ew", padx=(0, 18)
        )
        ttk.Label(connection, text="端口", style="Card.TLabel").grid(
            row=0, column=4, sticky="w", padx=(0, 8)
        )
        ttk.Entry(connection, textvariable=self.target_port, width=7).grid(
            row=0, column=5, sticky="w", padx=(0, 12)
        )
        ttk.Button(
            connection,
            text="检测连接",
            style="Secondary.TButton",
            command=self.check_connection,
        ).grid(row=0, column=6, sticky="e")

        status_row = ttk.Frame(connection, style="Card.TFrame")
        status_row.grid(row=1, column=0, columnspan=7, sticky="ew", pady=(12, 0))
        self.connection_badge = tk.Label(
            status_row,
            textvariable=self.connection_text,
            bg="#e9edf2",
            fg="#526274",
            padx=12,
            pady=5,
            font=("Microsoft YaHei UI", 9, "bold"),
        )
        self.connection_badge.pack(side="left")
        ttk.Label(
            status_row,
            text="发送成功表示电脑已发出 UDP；最终以 HDMI 字幕变化为准。",
            style="Hint.Card.TLabel",
        ).pack(side="left", padx=12)

        composer = ttk.Frame(body, style="Card.TFrame", padding=16)
        composer.pack(fill="x", pady=(0, 12))
        composer.columnconfigure(0, weight=1)
        title_row = ttk.Frame(composer, style="Card.TFrame")
        title_row.grid(row=0, column=0, sticky="ew")
        ttk.Label(
            title_row,
            text="中英文字幕",
            style="Card.TLabel",
            font=("Microsoft YaHei UI", 11, "bold"),
        ).pack(side="left")
        self.counter_label = tk.Label(
            title_row,
            textvariable=self.counter,
            bg="#ffffff",
            fg="#617189",
            font=("Microsoft YaHei UI", 9),
        )
        self.counter_label.pack(side="right")

        self.message_entry = ttk.Entry(
            composer,
            textvariable=self.message,
            font=("Microsoft YaHei UI", 15),
        )
        self.message_entry.grid(row=1, column=0, sticky="ew", pady=(10, 12), ipady=8)
        self.message_entry.focus_set()

        action_row = ttk.Frame(composer, style="Card.TFrame")
        action_row.grid(row=2, column=0, sticky="ew")
        self.send_button = ttk.Button(
            action_row,
            text="发送到 FPGA",
            style="Accent.TButton",
            command=self.send_message,
        )
        self.send_button.pack(side="left")
        ttk.Button(
            action_row,
            text="清空",
            style="Secondary.TButton",
            command=self.clear_message,
        ).pack(side="left", padx=(10, 0))
        ttk.Button(
            action_row,
            text="重发上一条",
            style="Secondary.TButton",
            command=self.resend_last,
        ).pack(side="left", padx=(10, 0))
        ttk.Label(
            action_row,
            text="回车可直接发送",
            style="Hint.Card.TLabel",
        ).pack(side="right")
        ttk.Combobox(
            action_row,
            textvariable=self.color_name,
            values=tuple(COLOR_OPTIONS),
            state="readonly",
            width=7,
        ).pack(side="right", padx=(6, 12))
        ttk.Label(
            action_row,
            text="字幕颜色",
            style="Hint.Card.TLabel",
        ).pack(side="right")

        preset_row = ttk.Frame(composer, style="Card.TFrame")
        preset_row.grid(row=3, column=0, sticky="ew", pady=(14, 0))
        ttk.Label(preset_row, text="快捷文本：", style="Hint.Card.TLabel").pack(
            side="left"
        )
        for preset in PRESETS:
            ttk.Button(
                preset_row,
                text=preset,
                style="Secondary.TButton",
                command=lambda value=preset: self.message.set(value),
            ).pack(side="left", padx=(6, 0))

        history_card = ttk.Frame(body, style="Card.TFrame", padding=16)
        history_card.pack(fill="both", expand=True)
        ttk.Label(
            history_card,
            text="发送历史",
            style="Card.TLabel",
            font=("Microsoft YaHei UI", 11, "bold"),
        ).pack(anchor="w", pady=(0, 8))
        table_frame = ttk.Frame(history_card, style="Card.TFrame")
        table_frame.pack(fill="both", expand=True)
        self.history = ttk.Treeview(
            table_frame,
            columns=("time", "target", "status", "text"),
            show="headings",
            height=7,
        )
        self.history.heading("time", text="时间")
        self.history.heading("target", text="目标")
        self.history.heading("status", text="状态")
        self.history.heading("text", text="字幕内容")
        self.history.column("time", width=88, anchor="center", stretch=False)
        self.history.column("target", width=155, anchor="center", stretch=False)
        self.history.column("status", width=78, anchor="center", stretch=False)
        self.history.column("text", width=360, anchor="w")
        scrollbar = ttk.Scrollbar(
            table_frame, orient="vertical", command=self.history.yview
        )
        self.history.configure(yscrollcommand=scrollbar.set)
        self.history.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        status_bar = tk.Label(
            self.root,
            textvariable=self.status_text,
            anchor="w",
            bg="#dfe8f3",
            fg="#34465d",
            padx=18,
            pady=7,
            font=("Microsoft YaHei UI", 9),
        )
        status_bar.pack(fill="x", side="bottom")

    def _on_message_changed(self, *_args: object) -> None:
        text = self.message.get()
        count = len(text)
        valid = (
            bool(text)
            and count <= MAX_CHARACTERS
            and not any(ord(character) < 32 for character in text)
        )
        self.counter.set(f"{count} / {MAX_CHARACTERS}")
        self.counter_label.configure(fg="#178246" if valid else "#c23b3b")
        if valid:
            self.send_button.state(["!disabled"])
        else:
            self.send_button.state(["disabled"])

    def _send_from_event(self, _event: tk.Event) -> str:
        if not self.send_button.instate(["disabled"]):
            self.send_message()
        return "break"

    def _connection_values(self) -> tuple[str, str, int]:
        source = validate_ipv4(self.source_ip.get())
        target = validate_ipv4(self.target_ip.get())
        try:
            port = int(self.target_port.get())
        except ValueError as exc:
            raise ValueError("UDP 端口必须是数字。") from exc
        if not 1 <= port <= 65535:
            raise ValueError("UDP 端口必须在 1～65535 之间。")
        return source, target, port

    def send_message(self) -> None:
        text = self.message.get()
        try:
            source, target, port = self._connection_values()
            sent, local = send_udp(
                text,
                color_index=COLOR_OPTIONS[self.color_name.get()],
                source_ip=source,
                target_ip=target,
                target_port=port,
            )
        except (ValueError, OSError) as exc:
            self._add_history("失败", text)
            self.status_text.set(str(exc))
            messagebox.showerror("发送失败", str(exc), parent=self.root)
            return

        self.last_message = text
        self._add_history("已发送", text)
        self.status_text.set(
            f"已发送 {len(text)} 个字符、{sent} 字节点阵："
            f"{local[0]}:{local[1]} → {target}:{port}；请观察 HDMI 字幕。"
        )

    def _add_history(self, status: str, text: str) -> None:
        target = f"{self.target_ip.get()}:{self.target_port.get()}"
        self.history.insert(
            "",
            0,
            values=(datetime.now().strftime("%H:%M:%S"), target, status, text),
        )
        children = self.history.get_children()
        for item in children[100:]:
            self.history.delete(item)

    def clear_message(self) -> None:
        self.message.set("")
        self.message_entry.focus_set()

    def resend_last(self) -> None:
        if not self.last_message:
            messagebox.showinfo("没有历史", "尚无可重发的成功字幕。", parent=self.root)
            return
        self.message.set(self.last_message)
        self.send_message()

    def set_connection_state(self, state: str, detail: str) -> None:
        colors = {
            "online": ("FPGA 在线", "#dff4e7", "#13713a"),
            "offline": ("FPGA 未响应", "#fde5e3", "#a7342d"),
            "checking": ("正在检测…", "#fff2cf", "#805c00"),
        }
        text, background, foreground = colors[state]
        self.connection_text.set(text)
        self.connection_badge.configure(bg=background, fg=foreground)
        self.status_text.set(detail)

    def check_connection(self) -> None:
        if self._checking:
            return
        try:
            source, target, _port = self._connection_values()
        except ValueError as exc:
            messagebox.showerror("地址错误", str(exc), parent=self.root)
            return
        self._checking = True
        self.set_connection_state("checking", f"正在检测 {target}…")

        def worker() -> None:
            try:
                online, _output = ping_fpga(source, target)
                error = ""
            except (ValueError, OSError) as exc:
                online = False
                error = str(exc)
            self.root.after(0, lambda: self._finish_connection_check(online, error))

        threading.Thread(target=worker, daemon=True).start()

    def _finish_connection_check(self, online: bool, error: str) -> None:
        self._checking = False
        if online:
            self.set_connection_state(
                "online", f"连接正常：{self.target_ip.get()} 响应小于 1 秒。"
            )
        else:
            detail = error or (
                f"{self.target_ip.get()} 未响应。请检查候选位流、网线和本机 IP。"
            )
            self.set_connection_state("offline", detail)


def run_self_check() -> int:
    assert validate_message("安路科技 FPGA") == "安路科技 FPGA"
    assert len(build_bitmap_payload("中", 2)) == 40
    assert len(build_bitmap_payload("中" * 32, 6)) == 1032
    try:
        validate_message("A" * 33)
    except ValueError:
        pass
    else:
        raise AssertionError("A 33-character subtitle should be rejected")
    try:
        validate_message("第一行\n第二行")
    except ValueError:
        pass
    else:
        raise AssertionError("Multiline subtitles should be rejected")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((DEFAULT_SOURCE_IP, 0))
    print("检查通过：Tkinter、中文点阵、32 字符边界和本机 UDP 源地址均正常。")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--check", action="store_true", help="run non-GUI checks")
    args = parser.parse_args()
    if args.check:
        return run_self_check()

    try:
        import ctypes

        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass

    root = tk.Tk()
    SubtitleSenderApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
