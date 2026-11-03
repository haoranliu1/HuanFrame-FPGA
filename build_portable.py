"""Offline build helper. Never programs a cable or removable media.

Usage: python build_portable.py image_A --td-home C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116
The helper creates a NEW independent build directory and writes a Tcl script.
Pass --run to invoke td_commands; default only prepares a reviewable script.
"""
from pathlib import Path
import argparse,re,shutil,subprocess,os

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('profile',choices=['image_A','video_B'])
    ap.add_argument('--td-home',required=True,type=Path)
    ap.add_argument('--workdir',type=Path)
    ap.add_argument('--run',action='store_true')
    a=ap.parse_args();root=Path(__file__).resolve().parent
    flow=a.td_home/'doc/scripts/DefaultFlow.tcl'
    if not flow.is_file():ap.error('TD installation does not contain doc/scripts/DefaultFlow.tcl')
    dest=(a.workdir or root/('_build_'+a.profile)).resolve()
    if dest.exists():ap.error('workdir must not exist; preserve the previous build')
    shutil.copytree(root/a.profile,dest)
    # Keep original archived project bytes; repair XML only in this new tree.
    for p in dest.rglob('*.prj'):
        text=p.read_text(encoding='utf-8-sig')
        fixed=re.sub(r'&(?!amp;|lt;|gt;|quot;|apos;|#\d+;|#x[0-9a-fA-F]+;)', '&amp;',text)
        if text!=fixed:p.write_text(fixed,encoding='utf-8')
    syn=dest/'td_project/lab_ex5_i2s_v1.0_Runs/syn_1';phy=syn.parent/'phy_1'
    tcl=[f'cd {{{syn.as_posix()}}}','source settings.cfg',f'source {{{flow.as_posix()}}}',f'cd {{{phy.as_posix()}}}','source settings.cfg','set phyWildParams {place seed 9}',f'source {{{flow.as_posix()}}}','fix_hold','fix_hold','report_area -io_info -file portable_phy.area','update_timing -mode final','report_timing_status -file portable_phy.ts','report_timing_summary -file portable_timing.rpt','commit_param -step bitgen','bitgen -bit portable.bit','exit 0']
    if a.profile=='image_A':
        shutil.copy2(root/'image_A/original_flow/bgm_cdc.tcl',dest/'bgm_cdc_generated.sdc')
        # Use explicit constraints and original manual place/route flow for A.
        tcl=[f'cd {{{syn.as_posix()}}}','source settings.cfg','set synWildParams {gate pack_effort high}',f'source {{{flow.as_posix()}}}',f'cd {{{phy.as_posix()}}}','import_device eagle_s20.db -package EG4S20BG256','open_project lab_ex5_i2s_v1.0.prj -noanalyze','import_db ../syn_1/lab_ex5_i2s_v1.0_gate.db','read_adc ../../../user_source/constraints_source/pin.adc',f'read_sdc {{{(dest/"bgm_cdc_generated.sdc").as_posix()}}}','set_param place hfn_opt_effort low','set_param place seed 9','commit_param -step place','place','commit_param -step route','route',*tcl[-9:]]
    script=dest/'build_offline.tcl';script.write_text('\n'.join(tcl)+'\n',encoding='utf-8')
    print('Prepared:',script)
    if a.run:
        exe=next(iter(a.td_home.rglob('td_commands.exe')),None)
        if exe is None:ap.error('td_commands.exe not found')
        raise SystemExit(subprocess.call([str(exe),str(script)]))
if __name__=='__main__':main()
