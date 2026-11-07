#!/usr/bin/env python3
"""Small HDC accessibility helper for the local MiniChat emulator."""
import json, re, subprocess, sys
from pathlib import Path
HDC='/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'
DEVICE='127.0.0.1:5555'
def hdc(*args):
    return subprocess.check_output([HDC,'-t',DEVICE,*args],text=True)
def layout():
    hdc('shell','uitest','dumpLayout','-p','/data/local/tmp/minichat-probe.json','-b','com.anonymity.minichat')
    hdc('file','recv','/data/local/tmp/minichat-probe.json','/tmp/minichat-probe.json')
    tree=json.loads(Path('/tmp/minichat-probe.json').read_text())
    nodes=[]
    def walk(node):
        if isinstance(node,dict):
            if 'attributes' in node: nodes.append(node['attributes'])
            for v in node.values(): walk(v)
        elif isinstance(node,list):
            for v in node: walk(v)
    walk(tree)
    return nodes
def find(nodes,key):
    found=[n for n in nodes if n.get('id')==key or n.get('text')==key]
    if not found: raise SystemExit('Element not found: '+key)
    return found[0]
def center(node):
    a=list(map(int,re.findall(r'-?\d+',node['bounds'])))
    return str((a[0]+a[2])//2),str((a[1]+a[3])//2)
if __name__ == '__main__':
    cmd=sys.argv[1]
    if cmd=='dump':
        for n in layout():
            if n.get('id') or n.get('text'):
                print(json.dumps({k:('[redacted]' if n.get('id')=='apiKeyInput' and k=='text' else n.get(k)) for k in ['id','text','type','bounds','enabled']},ensure_ascii=False))
    elif cmd in ['tap','input']:
        x,y=center(find(layout(),sys.argv[2]))
        if cmd=='tap': print(hdc('shell','uitest','uiInput','click',x,y))
        else:
            hdc('shell','uitest','uiInput','click',x,y)
            hdc('shell','uitest','uiInput','keyEvent','2072','2017')
            print(hdc('shell','uitest','uiInput','text',sys.argv[3]) if sys.argv[3] else hdc('shell','uitest','uiInput','keyEvent','2055'))
    elif cmd=='back': print(hdc('shell','uitest','uiInput','keyEvent','Back'))
    elif cmd=='screen':
        hdc('shell','uitest','screenCap','-p','/data/local/tmp/minichat-screen.png')
        print(hdc('file','recv','/data/local/tmp/minichat-screen.png',sys.argv[2]))
    elif cmd=='restart':
        print(hdc('shell','aa','force-stop','com.anonymity.minichat'))
        print(hdc('shell','aa','start','-a','EntryAbility','-b','com.anonymity.minichat'))
