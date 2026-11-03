# 电脑工具入口

推荐入口：`bgm/bgm_library_gui.py`选择自有授权MP4或音频，生成48kHz单声道PCM曲库。该工具只生成电脑文件；不要将源素材直接当作FPGA可解码MP4。

曲库GUI调用的`bgm/make_touch.py`已改成相对本归档定位，随包包含所需的MIT许可hmi-builder源码及样式模块。它从当前六图触控JSON复制新工程，再替换BGM页，不覆盖现有HMI或下载触控屏。先安装requirements.txt中的Pillow和fonttools。中文字体使用Windows微软雅黑；新HMI仍需厂商工具编译并输出TFT。`make_touch_original.py`保留历史生成脚本原文，仅供溯源，不作为便携入口。

`prepare_rva_portable.py`为此次归档增加的独立RVA制备入口，使用同目录512字节格式头描述，不依赖旧商业媒体模板。示例：`python prepare_rva_portable.py --source own_clip.mp4 --output-dir NEW_FOLDER --ffmpeg D:/BBdown/ffmpeg.exe`。输出320×240 RGB565、每帧1714个24kHz样本，312扇区每帧，保留旧兼容标签。离线生成不等于上板验收。

`network/udp_subtitle_gui.py`发送中英文点阵字幕，默认本机192.168.240.2、目标192.168.240.1:5000，32字符上限、16×16字形、CNB1包头。

`video_original`保留原工程脚本以便溯源，可能依赖旧目录、旧模板和额外hmi_builder模块；它们不作为便携入口，也不应未经核对直接执行任何写卡函数。配套HMI可以直接用厂商编辑器打开，不依赖这些历史生成脚本。
