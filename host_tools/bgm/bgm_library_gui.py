"""Click-to-start local library preparation, with explicit source/order/title controls."""
from pathlib import Path
from datetime import datetime
import queue
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import bgm_media


class LibraryWindow:
    def __init__(self, root):
        self.root = root
        root.title('幻帧视界 · 图片BGM曲库')
        root.geometry('840x640')
        root.minsize(760, 600)
        self.entries = []
        self.events = queue.Queue()
        self.busy = False
        try:
            default_ffmpeg = str(bgm_media.locate_ffmpeg())
        except FileNotFoundError:
            default_ffmpeg = ''
        self.ffmpeg = tk.StringVar(value=default_ffmpeg)
        self.output = tk.StringVar(value=str(Path(__file__).resolve().parent / 'media' /
                                             datetime.now().strftime('library_%Y%m%d_%H%M%S')))
        self.title = tk.StringVar()
        panel = ttk.Frame(root, padding=20)
        panel.pack(fill='both', expand=True)
        ttk.Label(panel, text='图片背景音乐', font=('Microsoft YaHei UI', 20, 'bold')).pack(anchor='w')
        ttk.Label(panel, text='从MP4或音频提取音乐；换图与缩放不重启曲目。首版支持16首。').pack(anchor='w', pady=(5, 16))
        listing = ttk.Frame(panel)
        listing.pack(fill='both', expand=True)
        self.listbox = tk.Listbox(listing, font=('Microsoft YaHei UI', 11),
                                  selectmode='browse', activestyle='none', exportselection=False)
        scrollbar = ttk.Scrollbar(listing, orient='vertical', command=self.listbox.yview)
        self.listbox.configure(yscrollcommand=scrollbar.set)
        self.listbox.pack(side='left', fill='both', expand=True)
        scrollbar.pack(side='right', fill='y')
        self.listbox.bind('<<ListboxSelect>>', self.select)
        toolbar = ttk.Frame(panel)
        toolbar.pack(fill='x', pady=8)
        self.buttons = []
        for label, callback in [('添加MP4／音频', self.add), ('移除', self.remove),
                                ('上移', lambda: self.move(-1)), ('下移', lambda: self.move(1))]:
            button = ttk.Button(toolbar, text=label, command=callback)
            button.pack(side='left', padx=(0, 8))
            self.buttons.append(button)
        titles = ttk.Frame(panel)
        titles.pack(fill='x', pady=4)
        ttk.Label(titles, text='选中曲名').pack(side='left')
        ttk.Entry(titles, textvariable=self.title).pack(side='left', fill='x', expand=True, padx=10)
        self.buttons.append(ttk.Button(titles, text='保存曲名', command=self.rename))
        self.buttons[-1].pack(side='left')
        for label, variable, chooser in [('FFmpeg', self.ffmpeg, self.choose_ffmpeg),
                                         ('输出目录', self.output, self.choose_output)]:
            row = ttk.Frame(panel)
            row.pack(fill='x', pady=4)
            ttk.Label(row, text=label, width=9).pack(side='left')
            ttk.Entry(row, textvariable=variable).pack(side='left', fill='x', expand=True)
            button = ttk.Button(row, text='选择', command=chooser)
            button.pack(side='right', padx=(8, 0))
            self.buttons.append(button)
        self.status = tk.StringVar(value='只在电脑生成曲库，不会自动覆盖TF卡。')
        ttk.Label(panel, textvariable=self.status, wraplength=750).pack(anchor='w', pady=10)
        ttk.Label(panel, text='先生成曲库；安全写卡并核验连续存储后，再导入安装记录生成最终触控工程。').pack(anchor='w')
        self.pair_button = ttk.Button(panel, text='导入已核验安装记录 · 生成触控工程', command=self.pair)
        self.pair_button.pack(anchor='e', pady=6)
        self.buttons.append(self.pair_button)
        self.build_button = ttk.Button(panel, text='提取音轨并生成曲库与预览工程', command=self.start)
        self.build_button.pack(anchor='e')
        root.after(150, self.poll)

    def refresh(self, selected=None):
        self.listbox.delete(0, 'end')
        for i, entry in enumerate(self.entries):
            self.listbox.insert('end', f'{i + 1:02d}  {entry["title"]}')
        if selected is not None and self.entries:
            self.listbox.selection_set(selected)
            self.listbox.see(selected)
            self.select()

    def index(self):
        selected = self.listbox.curselection()
        return selected[0] if selected else None

    def select(self, event=None):
        index = self.index()
        if index is not None:
            self.title.set(self.entries[index]['title'])

    def add(self):
        if self.busy:
            return
        paths = filedialog.askopenfilenames(title='选择包含音轨的MP4或音频', filetypes=[
            ('音视频文件', '*.mp4 *.mkv *.mov *.m4a *.mp3 *.wav *.flac *.aac *.ogg'), ('全部文件', '*.*')])
        if len(self.entries) + len(paths) > 16:
            messagebox.showerror('曲目过多', '首版最多支持16首，请分成不同曲库。')
            return
        self.entries.extend({'source': p, 'title': Path(p).stem} for p in paths)
        self.refresh(len(self.entries) - 1 if self.entries else None)

    def remove(self):
        index = self.index()
        if index is not None and not self.busy:
            self.entries.pop(index)
            self.refresh(min(index, len(self.entries) - 1) if self.entries else None)

    def move(self, direction):
        index = self.index()
        if index is not None and not self.busy and 0 <= index + direction < len(self.entries):
            self.entries[index], self.entries[index + direction] = self.entries[index + direction], self.entries[index]
            self.refresh(index + direction)

    def rename(self):
        index = self.index()
        if index is not None and not self.busy:
            title = self.title.get().strip()
            if not 1 <= len(title) <= 48 or any(ord(c)<32 or c in '"\\' for c in title):
                messagebox.showerror('曲名格式', '曲名需为1～48个字符，不含英文双引号、反斜杠或换行。')
                return
            self.entries[index]['title'] = title
            self.refresh(index)

    def choose_ffmpeg(self):
        path = filedialog.askopenfilename(title='选择ffmpeg.exe', filetypes=[('FFmpeg', 'ffmpeg.exe')])
        if path:
            self.ffmpeg.set(path)

    def choose_output(self):
        path = filedialog.askdirectory(title='选择电脑输出父目录')
        if path:
            self.output.set(str(Path(path) / datetime.now().strftime('bgm_%Y%m%d_%H%M%S')))

    def start(self):
        if self.busy:
            return
        if not self.entries:
            messagebox.showinfo('添加音轨', '先添加至少一个MP4或音频文件。')
            return
        self.busy = True
        for button in self.buttons + [self.build_button]:
            button.state(['disabled'])
        entries = [dict(entry) for entry in self.entries]
        output, ffmpeg = self.output.get(), self.ffmpeg.get()

        def work():
            try:
                manifest = bgm_media.prepare(entries, output, ffmpeg, self.events.put)
                self.events.put('生成配套触控曲目列表…')
                from make_touch import generate
                generate(Path(output) / 'PLAYLIST.json', Path(output) / 'touch')
                self.events.put(('done', manifest['library']))
            except Exception as exc:
                self.events.put(('error', str(exc)))
        threading.Thread(target=work, daemon=True).start()

    def pair(self):
        if self.busy:
            return
        manifest = filedialog.askopenfilename(title='选择对应PLAYLIST.json', filetypes=[('曲库清单','*.json')])
        if not manifest:
            return
        installation = filedialog.askopenfilename(title='选择只读核验生成的安装记录', filetypes=[('安装记录','*.json')])
        if not installation:
            return
        parent = filedialog.askdirectory(title='选择电脑触控工程输出父目录')
        if not parent:
            return
        output = Path(parent)/datetime.now().strftime('touch_paired_%Y%m%d_%H%M%S')
        self.busy = True
        for button in self.buttons+[self.build_button]:
            button.state(['disabled'])
        def work():
            try:
                from make_touch import generate
                hmi = generate(manifest, output, installation)
                self.events.put(('paired', str(hmi)))
            except Exception as exc:
                self.events.put(('error', str(exc)))
        threading.Thread(target=work, daemon=True).start()

    def poll(self):
        while not self.events.empty():
            event = self.events.get_nowait()
            if isinstance(event, tuple):
                self.busy = False
                for button in self.buttons + [self.build_button]:
                    button.state(['!disabled'])
                if event[0] == 'done':
                    self.status.set('曲库已生成，触控预览未定位，不能直接播放；TF尚未写入。'+event[1])
                elif event[0] == 'paired':
                    self.status.set('配对HMI已生成，仍需厂商编译和下载：'+event[1])
                else:
                    self.status.set('生成未完成，已保留输出供检查。')
                    messagebox.showerror('生成失败', event[1])
            else:
                self.status.set(event)
        self.root.after(150, self.poll)


if __name__ == '__main__':
    app = tk.Tk()
    LibraryWindow(app)
    app.mainloop()
