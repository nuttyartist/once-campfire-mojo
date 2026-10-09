from pathlib import Path
import subprocess,json,tempfile
repo=Path(__file__).resolve().parents[1]
import argparse
parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);out=parser.parse_args().output;out.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory() as td:
 tmp=Path(td)
 for template in sorted((repo/'templates').glob('*.html')):
  text=subprocess.check_output(['ruby','/workspace/once-campfire-verification/bench/template_code.rb','jinja',str(template)],text=True)
  (tmp/(template.stem+'.py')).write_text(text)
 def count(files):
  result=json.loads(subprocess.check_output(['cloc','--json','--force-lang=Python,mojo',*map(str,files)],text=True))
  return result.get('SUM',{}).get('code',0),result
 mojo,mojo_detail=count(p for p in sorted((repo/'src').glob('*.mojo')) if p.name!='templates.mojo')
 c,c_detail=count((repo/'native').glob('*.c'))
 templates,template_detail=count(tmp.glob('*.py'))
 value={'mojo':mojo,'c':c,'template':templates,'total':mojo+c+templates,'method':'cloc 2.04; Mojo as Python comments; upstream TemplateCode.extract jinja retains only executable template regions on original physical lines. Excludes generated src/templates.mojo, plain HTML, assets, dependencies, tests, tooling.','detail':{'mojo':mojo_detail,'c':c_detail,'template':template_detail}}
 (out/'source-count.json').write_text(json.dumps(value,indent=2)+'\n')
 print({k:v for k,v in value.items() if k!='detail'})
