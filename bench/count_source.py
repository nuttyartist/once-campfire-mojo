from pathlib import Path
import argparse,json,subprocess,tempfile,shutil
repo=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description="Count backend lines for the three sibling checkouts using the README convention.")
parser.add_argument('output',type=Path)
parser.add_argument('--workspace',type=Path,default=repo.parent)
parser.add_argument('--rust-helper',type=Path)
args=parser.parse_args();root=args.workspace.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
helper=args.rust_helper
if helper is None:
 subprocess.run(['cargo','build','--release','--locked','--manifest-path',str(repo/'bench/source-counter/Cargo.toml')],check=True)
 helper=repo/'bench/source-counter/target/release/campfire-source-counter'
# Whole generated files are excluded, matching the upstream README rule. Mixed
# hand-maintained files retain their inline data/route tables.
excluded_rust={
 'storage/src/tables.rs',
 'rails_compat/src/content_disposition/approximations.rs',
 'campfire/src/integrations/search/word_ranges.rs',
 'views/src/helpers/translations_table.rs',
}
excluded_c={'src/storage/marcel_tables.h','src/db/schema_sql.h'}
def cloc(paths,mojo=False):
 argv=['cloc','--json','--by-file','--skip-uniqueness']+(['--force-lang=Python,mojo'] if mojo else [])
 result=json.loads(subprocess.check_output(argv+list(map(str,paths)),text=True));return result.get('SUM',{}).get('code',0),result
def template_files(folder,syntax,extension,dest):
 files=[]
 for n,p in enumerate(sorted(folder.rglob('*'))):
  if not p.is_file():continue
  target=dest/f'{n}{extension}';target.write_text(subprocess.check_output(['ruby',root/'once-campfire-verification/bench/template_code.rb',syntax,p],text=True));files.append(target)
 return files
with tempfile.TemporaryDirectory() as td:
 temp=Path(td);rust=temp/'rust';rust.mkdir();rs=[]
 for p in sorted((root/'once-campfire-rust/crates').glob('*/src/**/*.rs')):
  rel=p.relative_to(root/'once-campfire-rust/crates')
  if rel.as_posix() in excluded_rust or 'tests' in rel.parts or 'test_support' in rel.parts or p.name in ['tests.rs','testing.rs','fixtures.rs','test_support.rs','golden.rs']:continue
  target=rust/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target);rs.append(target)
 subprocess.run([helper,*rs],check=True)
 rb,rd=cloc(rs);rt=temp/'rt';rt.mkdir();rtemp,rtd=cloc(template_files(root/'once-campfire-rust/crates/views/templates','askama','.rs',rt))
 cfiles=sorted((root/'once-campfire-c/src').rglob('*.c'))+sorted((root/'once-campfire-c/src').rglob('*.h'))
 # First-party native media adapters outside src are counted too.
 cfiles+=sorted((root/'once-campfire-c/native').glob('*.c'))+sorted((root/'once-campfire-c/native').glob('*.h'))
 cfiles=[p for p in cfiles if p.relative_to(root/'once-campfire-c').as_posix() not in excluded_c]
 cb,cd=cloc(cfiles)
 mb,md=cloc([p for p in sorted((repo/'src').glob('*.mojo')) if p.name!='templates.mojo'],True)
 mc,mcd=cloc(sorted((repo/'native').glob('*.c')));mt=temp/'mt';mt.mkdir();mtemp,mtd=cloc(template_files(repo/'templates','jinja','.py',mt))
 counts={'rust':{'backend':rb,'template':rtemp,'total':rb+rtemp},'c':{'backend':cb,'template':0,'total':cb},'mojo':{'mojo':mb,'c':mc,'template':mtemp,'total':mb+mc+mtemp}}
 report={'counts':counts,'cloc_version':subprocess.check_output(['cloc','--version'],text=True).strip(),'excluded_generated_files':{'rust':sorted(excluded_rust),'c':sorted(excluded_c),'mojo':['src/templates.mojo']},'method':'Same local cloc version with --by-file --skip-uniqueness; Mojo uses Python comment syntax. Rust inline cfg(test) and test-support items removed using syn 2.0.119; external test/helpers excluded. Upstream template_code.rb extracts executable template regions. Includes Mojo generic C adapters. Excludes whole generated files (listed explicitly), dependencies, frontend, tests, build/deployment tools and plain HTML. Inline data/route tables in mixed hand-maintained files are retained. Physical source lines, not a measure of feature parity or maintainability.','details':{'rust':rd,'rust_templates':rtd,'c':cd,'mojo':md,'mojo_c':mcd,'mojo_templates':mtd}}
 (out/'source-count.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(counts,indent=2))
