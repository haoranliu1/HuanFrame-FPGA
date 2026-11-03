"""Check fonts first; extend a copied HMI workspace with video/boot controls."""
import copy
import importlib.util
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
sys.path.insert(0, str(REPO / 'tools/hmi-builder-src/hmi-builder-main/tools'))
from hmi_font import FontReader, encode_ttf


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def save(path, value):
    if path.exists():
        backup = path.with_name(path.name + '.before_av_controls.bak')
        if backup.exists():
            raise FileExistsError(backup)
        shutil.copy2(path, backup)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def check_texts(pages, fonts):
    problems = []
    used = set()
    for page in pages:
        for obj in page.get('objects', []):
            attrs = obj['attributes']
            ref = attrs.get('font', {}).get('$ref', '') if isinstance(attrs.get('font'), dict) else ''
            if ref.startswith('font:'):
                font = fonts[ref[5:]]
                for char in attrs.get('txt', ''):
                    if ord(char) >= 32:
                        used.add(char)
                        if font.glyph(ord(char)) is None:
                            problems.append(f"{page['name']}.{obj['key']}:{char}")
    return problems, used


def main():
    workspace = ROOT / 'touch/workspace'
    config_path = workspace / 'project.json'
    config = read(config_path)
    fonts = {f['key']: FontReader((workspace / f['source']['zi']).read_bytes()) for f in config['fonts']}
    old_pages = [read(workspace / p['content']['path']) for p in config['pages']]
    missing, used = check_texts(old_pages, fonts)
    if missing:
        raise ValueError(f'Existing font coverage failed before editing: {missing}')
    # Dynamic event text and printable ASCII are needed even if no static label uses them.
    required = set(chr(i) for i in range(32, 127))
    for page in old_pages:
        for quoted in re.findall(r'"([^"\n]*)"', json.dumps(page, ensure_ascii=False)):
            required.update(c for c in quoted if ord(c) >= 0x4e00 and ord(c) <= 0x9fff)
    labels = '视频控制版本切换图片网络版进入返回取消确认暂停继续单帧音量静音设定已发送请求请观察大屏等待完成后再调节指令'
    required.update(labels)
    absent = ''.join(sorted(c for c in required if fonts['font_0'].glyph(ord(c)) is None))
    # Original editor fonts use qumo=10, unsupported by strict re-encoding.
    # Preserve both originals byte-for-byte and append a dedicated new font.
    new_font_path = workspace / 'fonts/font_video.zi'
    if new_font_path.exists():
        raise FileExistsError(new_font_path)
    new_font_path.write_bytes(encode_ttf('C:/Windows/Fonts/msyh.ttc', height=16,
                             chars=''.join(sorted(required)), name='Video20', layout='bmp', bpp=3))
    config['fonts'].append({'key': 'font_video', 'source': {'zi': 'fonts/font_video.zi'}})

    helper_path = REPO / 'variants/frozen_dynamic_subtitle_touch_20261018/touch/generate_dynamic_subtitle_hmi.py'
    spec = importlib.util.spec_from_file_location('existing_touch_style', helper_path)
    style = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(style)
    style.FONT.clear()
    style.FONT.update({'$ref': 'font:font_video'})
    button, text = style.button, style.text
    mode = read(workspace / 'pages/mode.json')
    header = mode['header']
    mode['objects'].append(button('bVersion', 226, 3, 96, 36, '版本切换', ['page ${page:version}'], bco=style.ACCENT))

    version = style.page_root(header, None, None, [])
    version['name'] = 'version'
    version['objects'] = [
        text('tTitle', 12, 4, 456, 32, '版本切换'),
        text('tTip', 12, 40, 456, 28, '确认后等待大屏切换', pco=style.MUTED),
        button('bPhoto', 16, 80, 216, 64, '图片网络版', [
            'printh 55 01 30 00 FF FF FF', 'tSta.txt="已发送请求"', 'ref tSta']),
        button('bVideo', 248, 80, 216, 64, '进入视频版', [
            'printh 55 01 30 01 FF FF FF', 'page ${page:video}'], bco=style.ACCENT),
        text('tSta', 16, 156, 448, 32, '请观察大屏', pco=style.MUTED),
        button('bBack', 0, 224, 158, 48, '返回', ['page ${page:mode}']),
        button('bControls', 240, 224, 240, 48, '视频控制', ['page ${page:video}']),
    ]
    video = style.page_root(header, None, None, [
        'hVol.val=nVol.val', 'covx nVol.val,tVal.txt,0,0'])
    video['name'] = 'video'
    send_volume = ['nVol.val=hVol.val', 'covx nVol.val,tVal.txt,0,0', 'ref tVal',
                   'printh 55 01 12', 'prints nVol.val,1', 'printh FF FF FF']
    audio = read(workspace / 'pages/audio.json')
    slider = copy.deepcopy(next(o for o in audio['objects'] if o['key'] == 'hV'))
    slider['key'] = 'hVol'
    slider['attributes'].update({'objname': 'hVol', 'x': 94, 'y': 142, 'w': 292, 'h': 30, 'val': 50, 'ch': 30})
    # Handle both a tap and a drag, including exact 0 and 100 endpoints.
    slider['events'] = {'codesdown': [], 'codesup': send_volume, 'codesslide': send_volume}
    minus = ['if(nVol.val>0)', '{', 'nVol.val=nVol.val-1', '}', 'hVol.val=nVol.val',
             'covx nVol.val,tVal.txt,0,0', 'ref tVal', 'ref hVol',
             'printh 55 01 12', 'prints nVol.val,1', 'printh FF FF FF']
    plus = [s.replace('>0', '<100').replace('-1', '+1') for s in minus]
    video['objects'] = [
        style.variable('nVol', 50),
        text('tTitle', 8, 4, 464, 30, '视频控制'),
        text('tSta', 8, 36, 464, 24, '指令已发送后请观察大屏', pco=style.MUTED),
        button('bPause', 16, 68, 140, 48, '暂停', ['printh 55 01 02 00 FF FF FF']),
        button('bPlay', 170, 68, 140, 48, '继续', ['printh 55 01 02 01 FF FF FF'], bco=style.ACCENT),
        button('bStep', 324, 68, 140, 48, '单帧', ['printh 55 01 01 01 FF FF FF']),
        text('tVol', 16, 118, 220, 24, '音量设定', center=0),
        text('tVal', 392, 118, 72, 24, '50', center=2),
        button('bMinus', 16, 140, 64, 40, '-', minus), slider,
        button('bPlus', 400, 140, 64, 40, '+', plus),
        button('bMute', 16, 186, 140, 32, '静音', [
            'nVol.val=0', 'hVol.val=0', 'tVal.txt="0"', 'ref hVol', 'ref tVal',
            'printh 55 01 12 00 FF FF FF']),
        text('tHint', 170, 186, 294, 32, '等待切换完成后再调节', pco=style.MUTED, max_bytes=80),
        button('bBack', 0, 224, 158, 48, '版本切换', ['page ${page:version}']),
        button('bReturn', 240, 224, 240, 48, '返回图片网络版', [
            'printh 55 01 30 00 FF FF FF', 'page ${page:mode}']),
    ]
    # Keep old page IDs unchanged by appending both new pages.
    for key, page in [('version', version), ('video', video)]:
        config['pages'].append({'key': key, 'content': {'mode': 'json', 'path': f'pages/{key}.json'}})
        save(workspace / f'pages/{key}.json', page)
    save(workspace / 'pages/mode.json', mode)
    save(config_path, config)
    final_fonts = {f['key']: FontReader((workspace / f['source']['zi']).read_bytes()) for f in config['fonts']}
    all_pages = [read(workspace / p['content']['path']) for p in config['pages']]
    missing, _ = check_texts(all_pages, final_fonts)
    if missing:
        raise ValueError(f'Final coverage failed: {missing}')
    for c in required:
        if final_fonts['font_video'].glyph(ord(c)) is None:
            raise ValueError(f'Dynamic/ASCII font coverage failed: {c}')
    report = {'pre_edit_existing_static_glyphs_pass': True,
              'original_fonts_preserved': True, 'new_font_required_characters_missing_from_old_font': absent,
              'post_edit_missing_glyphs': missing,
              'all_printable_ascii_checked': True, 'pages': len(all_pages),
              'uart': {'pause': '55 01 02 00 FF FF FF', 'resume': '55 01 02 01 FF FF FF',
                       'network_image': '55 01 30 00 FF FF FF', 'video_image': '55 01 30 01 FF FF FF',
                       'volume': '55 01 12 VALUE FF FF FF'},
              'status_is_command_only_not_readback': True,
              'panel_downloaded': False}
    save(ROOT / 'touch/FONT_AND_PROTOCOL_CHECK.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
