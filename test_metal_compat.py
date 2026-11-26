#!/usr/bin/env python3
import json, os, re, subprocess, tempfile
from concurrent.futures import ThreadPoolExecutor

# Extract exact AM_METAL_COMPAT_BEGIN .. AM_METAL_COMPAT_END from AlightMotionMods.mm
mm = open('AlightMotionMods.mm', encoding='utf-8').read()
m = re.search(r'// AM_METAL_COMPAT_BEGIN(.*?)// AM_METAL_COMPAT_END', mm, re.S)
assert m, 'Markers not found'
compat_src = m.group(1)

runner_mm = r'''
#import <Foundation/Foundation.h>
''' + compat_src + r'''
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) return 1;
        NSString *inPath = [NSString stringWithUTF8String:argv[1]];
        NSString *outPath = [NSString stringWithUTF8String:argv[2]];
        NSString *src = [NSString stringWithContentsOfFile:inPath encoding:NSUTF8StringEncoding error:nil];
        NSString *res = AMTranspileGLSLWrapperToMSL(src);
        [res writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return 0;
}
'''

with open('/tmp/am_transpile_test.mm', 'w') as f:
    f.write(runner_mm)
subprocess.check_call(['clang++', '-std=c++17', '-fobjc-arc', '-framework', 'Foundation',
                       '/tmp/am_transpile_test.mm', '-o', '/tmp/am_transpile_test'])

data = json.load(open('gm_metal_test_cases.json', encoding='utf-8'))
tpl = data['tpl']
cases = data['cases']

def build_raw_msl(c):
    # Reconstruct exact Template 1 MSL as AlightEffectShader.swift generates it!
    param_fields = '\n'.join(f'    {ty} {pid};' for ty, pid in c['params'])
    if not param_fields:
        param_fields = '    float _dummy;'
    img_fields = '\n'.join(f'    AC_ImageInfo {tid};' for tid in c['textures'])
    tex_args = ''.join(f',\n        texture2d<half> tex{i} [[ texture({i}) ]]' for i in range(len(c['textures'])))
    tex_assigns = '\n'.join(f'    wrapper.ac__img.{tid}.texture = tex{i};' for i, tid in enumerate(c['textures']))
    param_defs = '\n'.join(f'    #define {pid} (ac__p.{pid})' for _, pid in c['params'])
    img_defs = '\n'.join(f'    #define {tid} (ac__img.{tid})' for tid in c['textures'])
    param_undefs = '\n'.join(f'    #undef {pid}' for _, pid in c['params'])
    img_undefs = '\n'.join(f'    #undef {tid}' for tid in c['textures'])

    glsl = c['glsl']
    glsl = re.sub(r'\.st([^a-zA-Z0-9_])', r'.xy\1', glsl)
    glsl = re.sub(r'\.s([^a-zA-Z0-9_])', r'.x\1', glsl)
    glsl = re.sub(r'\.t([^a-zA-Z0-9_])', r'.y\1', glsl)

    src = (
        tpl['head'] + param_fields +
        tpl['img_params'] + img_fields +
        tpl['typedefs'] + tpl['vert_body'] +
        tpl['wrapper_head'] + tpl['tex2dcv'] +
        tpl['wrapper_mid'] +
        '    AC_ShaderParams ac__p;\n    AC_ImageParams ac__img;\n' +
        tpl['defines'] + '\n' +
        param_defs + '\n' + img_defs + '\n' +
        glsl + '\n' +
        param_undefs + '\n' + img_undefs + '\n' +
        tpl['undefs'] +
        tpl['frag_head'] + tex_args +
        tpl['frag_mid'] +
        '    wrapper.ac__p = *uniforms;\n' +
        tex_assigns + '\n' +
        tpl['frag_tail']
    )
    return src

def test_one(idx_c):
    idx, c = idx_c
    raw = build_raw_msl(c)
    raw_p = f'/tmp/gm_raw_{idx}.metal'
    tr_p = f'/tmp/gm_tr_{idx}.metal'
    with open(raw_p, 'w') as f: f.write(raw)

    r1 = subprocess.run(['xcrun', '--sdk', 'iphoneos', 'metal', '-x', 'metal', '-c', raw_p, '-o', '/dev/null'],
                        capture_output=True, text=True)
    if r1.returncode == 0:
        return (c['name'], 'RAW_OK', '')

    subprocess.check_call(['/tmp/am_transpile_test', raw_p, tr_p])
    r2 = subprocess.run(['xcrun', '--sdk', 'iphoneos', 'metal', '-x', 'metal', '-c', tr_p, '-o', '/dev/null'],
                        capture_output=True, text=True)
    if r2.returncode == 0:
        return (c['name'], 'TRANSPILED_OK', '')

    errs = [l for l in r2.stderr.splitlines() if 'error:' in l][:3]
    return (c['name'], 'FAIL', ' | '.join(errs))

with ThreadPoolExecutor(max_workers=4) as ex:
    results = list(ex.map(test_one, enumerate(cases)))

raw_ok = [r for r in results if r[1] == 'RAW_OK']
tr_ok = [r for r in results if r[1] == 'TRANSPILED_OK']
fails = [r for r in results if r[1] == 'FAIL']
print(f'=== APPLE METAL COMPILER RESULTS ({len(results)} Gold Motion Shaders) ===')
print(f'  RAW_OK:        {len(raw_ok)}')
print(f'  TRANSPILED_OK: {len(tr_ok)}')
print(f'  TOTAL_PASS:    {len(raw_ok)+len(tr_ok)}/{len(results)}')
print(f'  FAIL:          {len(fails)}')
for name, _, err in fails[:40]:
    print(f'  [FAIL] {name}: {err}')
