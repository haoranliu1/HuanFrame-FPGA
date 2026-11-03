"""Generate a paired, scrollable HMI project from the prepared playlist.

This is an asset generator: it only creates a NEW output folder. It neither
downloads a screen nor touches the TF card or the frozen workspace.
"""
from pathlib import Path
import argparse
import copy
import importlib.util
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
ARCHIVE = ROOT.parents[1]
TOOLS = ARCHIVE / 'third_party/hmi_builder/tools'
sys.path.insert(0, str(TOOLS))
from hmi_font import FontReader, encode_ttf

spec = importlib.util.spec_from_file_location('bgm_style', ROOT / 'touch_style.py')
style = importlib.util.module_from_spec(spec)
spec.loader.exec_module(style)
FONT = {'$ref': 'font:font_bgm'}


def send(code, variable):
    return [f'printh 55 01 {code:02X}', f'prints {variable}.val,1', 'printh FF FF FF']


def label(key, x, y, w, h, text, **kw):
    obj = style.text(key, x, y, w, h, text, **kw)
    obj['attributes']['font'] = FONT
    return obj


def button(key, x, y, w, h, text, lines):
    return style.button(key, x, y, w, h, text, lines, font=FONT)


def short_title(title, limit=25):
    # Screen font is 16 px: Chinese uses two half-width units.
    result, units = '', 0
    for char in title:
        cost = 1 if ord(char) < 128 else 2
        if units + cost > limit:
            return result + '…'
        result += char
        units += cost
    return result


def generate(manifest_path, output, installation_path=None):
    manifest_path, output = Path(manifest_path), Path(output).resolve()
    manifest = json.loads(manifest_path.read_text('utf8'))
    tracks = manifest['tracks']
    installation = None
    config_lines = []
    if installation_path:
        installation = json.loads(Path(installation_path).read_text('utf8'))
        if (installation.get('format') != 'BGM_INSTALL_V1'
                or installation.get('catalog_id') != manifest['catalog_id']
                or installation.get('library_bytes') != manifest['library_bytes']
                or installation.get('library_sha256') != manifest['library_sha256']
                or installation.get('contiguous_chain_verified') is not True
                or installation.get('physical_hash_passes') != 2
                or not 0 < installation.get('start_sector', 0) < 2**32
                or installation['start_sector']+(manifest['library_bytes']//512) >= 2**32):
            raise ValueError('安装记录与曲库不配套或尚未通过完整校验')
        for command, value in [(0x54, installation['start_sector']),
                               (0x58, manifest['library_bytes']),
                               (0x5c, int(manifest['catalog_id'], 16))]:
            for byte in range(4):
                config_lines.append(f'printh 55 01 {command+byte:02X} {(value>>(8*byte))&255:02X} FF FF FF')
        config_lines.append('printh 55 01 60 00 FF FF FF')
    if not 1 <= len(tracks) <= 16:
        raise ValueError('触控曲库支持1～16首')
    if [r['index'] for r in tracks] != list(range(len(tracks))):
        raise ValueError('曲目编号必须连续且从0开始')
    # Titles are embedded as HMI string literals. Reject syntax characters.
    if any(any(c in row['title'] for c in ['"', '\\', '\r', '\n']) for row in tracks):
        raise ValueError('请将曲名中的双引号、反斜杠或换行改为普通文字')
    if output.exists():
        raise FileExistsError('输出目录已存在，不覆盖已生成的触控工程：' + str(output))
    output.mkdir(parents=True)
    workspace = output / 'workspace'
    shutil.copytree(ARCHIVE / 'touch/editable', workspace)
    config = json.loads((workspace / 'project.json').read_text('utf8'))
    # The archived six-image workspace already has a BGM page; replace it
    # while preserving all other pages, six previews and stage controls.
    config['pages'] = [p for p in config['pages'] if p['key'] != 'bgm']
    config['fonts'] = [f for f in config['fonts'] if f['key'] != 'font_bgm']
    audio = json.loads((workspace / 'pages/audio.json').read_text('utf8'))
    param = json.loads((workspace / 'pages/param.json').read_text('utf8'))
    doc = style.page_root(audio['header'], None, None, [])
    doc['name'] = 'bgm'
    objects = doc['objects'] = [label('tTitle', 12, 2, 456, 28, '图片 BGM · 连续伴奏', center=0),
        label('tSelected', 12, 32, 294, 24, '01 ' + short_title(tracks[0]['title']), center=0, pco=style.ACCENT),
        label('tState', 318, 32, 150, 24, '请求：暂停', pco=style.MUTED)]
    for name, value in [('nTop', 0), ('nSelected', 0), ('nMode', 2), ('nPlay', 0),
                        ('nVolume', 20), ('nDrag', 0), ('nMoved', 0), ('nLastY', 0),
                        ('nY', 0), ('nRow', 0), ('nIndex', 0), ('nThreshold', 0)]:
        objects.append(style.variable(name, value))
    # Native GB2312 editor misreads UTF-8 Chinese inside event string literals.
    # Keep Unicode in static text attributes; events copy those attributes.
    hidden_texts = []
    for index, track in enumerate(tracks):
        key = f'tName{index}'
        objects.append(label(key,318+index*3,270,2,2,f'{index+1:02d} {short_title(track["title"])}',max_bytes=48))
        hidden_texts.append(key)
    for key, value in [('tPlaying','请求：播放'),('tPaused','请求：暂停')]:
        objects.append(label(key,366+len(hidden_texts)*3,270,2,2,value,max_bytes=20))
        hidden_texts.append(key)
    max_top = max(0, len(tracks) - 4)
    refresh = []
    for row in range(4):
        refresh += [f'bRow{row}.txt="-"', f'bRow{row}.bco={style.KEY}']
        for index, track in enumerate(tracks):
            if 0 <= index - row <= max_top:
                refresh += [f'if(nTop.val=={index-row})', '{', f'bRow{row}.txt=tName{index}.txt',
                            f'if(nSelected.val=={index})', '{', f'bRow{row}.bco={style.ACCENT_DOWN}', '}', '}']
        refresh += [f'ref bRow{row}']
    for index, track in enumerate(tracks):
        refresh += [f'if(nSelected.val=={index})', '{',
                    f'tSelected.txt=tName{index}.txt', '}']
    refresh += ['ref tSelected', 'if(nPlay.val==1)', '{', 'tState.txt=tPlaying.txt',
                '}else', '{', 'tState.txt=tPaused.txt', '}', 'ref tState']
    # bRefresh is a helper button hidden after load; click still runs its event.
    objects.append(button('bRefresh', 0, 0, 2, 2, '', refresh))
    down = ['nDrag.val=1', 'nMoved.val=0', 'nLastY.val=tch1',
            'nRow.val=tch1-62', 'nRow.val=nRow.val/34']
    # On real screens tch0/tch1 may already be 65535 on release. Use the
    # captured row and mark any movement using the held-touch timer.
    select = ['nDrag.val=0', 'if(nMoved.val==0)', '{',
              'nIndex.val=nTop.val+nRow.val',
              f'if(nIndex.val<{len(tracks)})', '{', 'nSelected.val=nIndex.val',
              *send(0x51, 'nSelected'), 'click bRefresh,0', '}', '}']
    for row in range(4):
        obj = button(f'bRow{row}', 12, 62+row*34, 294, 30, '-', select)
        obj['attributes']['xcen'] = 0
        obj['attributes']['txt_maxl'] = 96
        obj['events']['codesdown'] = down
        objects.append(obj)
    scroll = ['if(nDrag.val==1&&tch0>=12&&tch0<=305&&tch1>=62&&tch1<=193)', '{',
              'nY.val=tch1', 'nThreshold.val=nY.val+24', 'if(nLastY.val>=nThreshold.val)', '{', 'nMoved.val=1',
              f'if(nTop.val<{max_top})', '{', 'nTop.val=nTop.val+1', 'click bRefresh,0', '}',
              'nLastY.val=nY.val', '}', 'nThreshold.val=nLastY.val+24', 'if(nY.val>=nThreshold.val)', '{', 'nMoved.val=1',
              'if(nTop.val>0)', '{', 'nTop.val=nTop.val-1', 'click bRefresh,0', '}',
              'nLastY.val=nY.val', '}', '}']
    objects.append({'key': 'tmScroll', 'type': 'timer',
                    'attributes': {'objname': 'tmScroll', 'tim': 80, 'en': 1},
                    'events': {'codestimer': scroll}})
    objects += [button('bPlay',318,62,150,30,'播放 BGM',[
        'nMode.val=2','nPlay.val=1',*send(0x50,'nMode'),*send(0x52,'nPlay'),'click bRefresh,0']),
        button('bPause',318,102,150,30,'暂停',['nPlay.val=0',*send(0x52,'nPlay'),'click bRefresh,0']),
        button('bRestart',318,142,150,30,'从头播放',[
            'nMode.val=2','nPlay.val=1',*send(0x50,'nMode'),
            'printh 55 01 52 02 FF FF FF',*send(0x52,'nPlay'),'click bRefresh,0']),
        button('bMute',318,182,150,30,'关闭声音',['nMode.val=0',*send(0x50,'nMode')]),
        label('tHint',12,198,294,20,'上下滑动曲目 · 点击选择',pco=style.MUTED),
        label('tVolume',12,218,54,20,'音量',center=0)]
    slider = copy.deepcopy(next(o for o in audio['objects'] if o['key']=='hV'))
    slider['key'] = 'hVolume'
    slider['attributes'].update(objname='hVolume',x=70,y=216,w=236,h=20,endx=305,endy=235,
        minval=0,maxval=100,val=20,ch=16,bco=style.KEY,bco1=style.ACCENT,pco=style.ACCENT)
    volume_lines = ['nVolume.val=hVolume.val', *send(0x53,'nVolume')]
    slider['events'] = {'codesdown': [], 'codesup': volume_lines, 'codesslide': volume_lines}
    objects += [slider, button('bBack',12,242,140,28,'图像参数',['page ${page:param}']),
                button('bTest',166,242,140,28,'独立测试音',['page ${page:audio}']),
                label('tCount',318,218,150,20,f'曲库 {len(tracks)} 首' if installation else '待安装定位',pco=style.MUTED),
                label('tID',318,242,150,24,'ID '+manifest['catalog_id'],pco=style.MUTED)]
    doc['root']['events']['codesload'] = [*config_lines,'nDrag.val=0','nMoved.val=0',
        'hVolume.val=nVolume.val',*send(0x51,'nSelected'),*send(0x53,'nVolume'),
        *send(0x50,'nMode'),*send(0x52,'nPlay'),'click bRefresh,0','vis bRefresh,0',
        *[f'vis {key},0' for key in hidden_texts]]
    doc['root']['events']['codesup'] = ['nDrag.val=0']
    doc['root']['events']['codesunload'] = ['nDrag.val=0']
    # Existing test-tone controls remain a distinct source and volume.
    audio['root']['events']['codesload'].insert(0, 'printh 55 01 50 01 FF FF FF')
    next(o for o in audio['objects'] if o['key']=='bBack')['events']['codesup']=['page ${page:bgm}']
    for obj in param['objects']:
        for event, lines in obj.get('events', {}).items():
            obj['events'][event] = [line.replace('page ${page:audio}', 'page ${page:bgm}') for line in lines]
    config['pages'].append({'key':'bgm','content':{'mode':'json','path':'pages/bgm.json'}})
    config['fonts'].append({'key':'font_bgm','source':{'zi':'fonts/font_bgm.zi'}})
    labels = ''.join(o['attributes'].get('txt','') for o in objects)
    labels += ''.join(row['title'] for row in tracks) + '请求：暂停播放-…'
    chars = sorted(set(labels) | set(chr(i) for i in range(32,127)))
    font = encode_ttf('C:/Windows/Fonts/msyh.ttc',height=16,chars=chars,layout='bmp',bpp=3,name='Bgm16')
    (workspace/'fonts/font_bgm.zi').write_bytes(font)
    reader = FontReader(font)
    if any(reader.glyph(ord(c)) is None for c in chars):
        raise ValueError('曲名存在缺失字形')
    for key, data in [('bgm',doc),('audio',audio),('param',param)]:
        path = workspace/f'pages/{key}.json'
        if path.exists(): shutil.copy2(path,path.with_suffix('.json.before_bgm.bak'))
        path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n','utf8')
    shutil.copy2(workspace/'project.json',workspace/'project.json.before_bgm.bak')
    (workspace/'project.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n','utf8')
    for args in [('validate',str(workspace),'--config','project.json'),
                 ('pack',str(workspace),str(output/'图片BGM曲库.HMI'),'--config','project.json')]:
        result = subprocess.run([sys.executable,'-B',str(TOOLS/'hmi_project.py'),*args],
            capture_output=True,text=True,encoding='utf8',errors='replace')
        if result.returncode: raise RuntimeError(result.stdout+result.stderr)
    (output/'PAIRING.json').write_text(json.dumps({'catalog_id':manifest['catalog_id'],
        'track_count':len(tracks),'hardware_verified':False,'native_tft_compiled':False,
        'screen_catalog_is_paired_not_live_readback':True,
        'installation':installation,'ready_for_card':bool(installation) and not installation.get('synthetic_test_record',False)},indent=2)+'\n','utf8')
    return output/'图片BGM曲库.HMI'


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('manifest',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--installation',type=Path)
    args=parser.parse_args()
    print(generate(args.manifest,args.output,args.installation))
