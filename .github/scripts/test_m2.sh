#!/usr/bin/env bash
# M-2 önteszt: 13 determinisztikus kapu-eset (ebből 6 regressziós: törlés, üres jegyzék) és 7 verdikt-eset. Nem használ hálózatot, API-kulcsot vagy titkot.
# Használat: bash .github/scripts/test_m2.sh   (a tároló gyökeréből)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/.github"
T="$(mktemp -d)"; cd "$T" || exit 2
FAILS=0

mk() { # név, PR-beállítás, [alap-beállítás]: a PR-ág merge-commitja jön létre (mint a GitHub merge-ref)
  rm -rf "$1"; mkdir "$1"; cd "$1" || exit 2
  git init -q -b main; git config user.email t@t; git config user.name t
  echo base > README.md; if [ -n "${3:-}" ]; then eval "$3" || { echo "ALAP BEÁLLÍTÁSI HIBA: $1"; FAILS=$((FAILS+1)); }; fi; git add .; git commit -qm base
  git checkout -qb pilot/x; eval "$2" || { echo "BEÁLLÍTÁSI HIBA: $1"; FAILS=$((FAILS+1)); }; git add -A; git commit -qm pr
  git checkout -q main; git merge -q --no-ff pilot/x -m merge; cd ..
}
M='(cd pilot-tesztek; sha256sum a.txt > SHA256SUMS)'
M2='(cd pilot-tesztek; sha256sum new.txt > SHA256SUMS)'
declare -A SETUP=(
 [good]="mkdir pilot-tesztek; echo hello > pilot-tesztek/a.txt; $M"
 [badhash]="mkdir pilot-tesztek; echo hello > pilot-tesztek/a.txt; echo \"\$(printf x | sha256sum | cut -c1-64)  a.txt\" > pilot-tesztek/SHA256SUMS"
 [nomanifest]="mkdir pilot-tesztek; echo hello > pilot-tesztek/a.txt"
 [workflow]="mkdir -p pilot-tesztek .github/workflows; echo hello > pilot-tesztek/a.txt; $M; echo x > .github/workflows/evil.yml"
 [outside]="mkdir pilot-tesztek; echo hello > pilot-tesztek/a.txt; $M; echo y > outside.txt"
 [traversal]="mkdir pilot-tesztek; echo hello > pilot-tesztek/a.txt; echo \"\$(sha256sum pilot-tesztek/a.txt | cut -c1-64)  ../README.md\" > pilot-tesztek/SHA256SUMS"
 [symlink]="mkdir pilot-tesztek; ln -s /etc/passwd pilot-tesztek/a.txt; echo \"0000000000000000000000000000000000000000000000000000000000000000  a.txt\" > pilot-tesztek/SHA256SUMS"
 [del_emptymanifest]="git rm -q pilot-tesztek/old.txt; mkdir -p pilot-tesztek; : > pilot-tesztek/SHA256SUMS"
 [emptymanifest_only]="mkdir -p pilot-tesztek; : > pilot-tesztek/SHA256SUMS"
 [delete_only]="git rm -q pilot-tesztek/old.txt"
 [del_plus_valid_add]="git rm -q pilot-tesztek/old.txt; mkdir -p pilot-tesztek; echo hello > pilot-tesztek/a.txt; $M"
 [manifest_only]="(cd pilot-tesztek; sha256sum old.txt > SHA256SUMS)"
 [rename_valid]="git mv pilot-tesztek/old.txt pilot-tesztek/new.txt; $M2"
)
declare -A WHY=([badhash]="SHA-256" [nomanifest]="SHA-256" [workflow]="tiltott" [outside]="engedélyezett mappában" [traversal]="tiltott útvonal" [symlink]="szimbolikus"
 [del_emptymanifest]="Nincs törölt fájl" [emptymanifest_only]="üres jegyzék" [delete_only]="Nincs törölt fájl"
 [del_plus_valid_add]="Nincs törölt fájl" [manifest_only]="tartalmi fájl" [rename_valid]="Nincs törölt fájl")
BASEOLD='mkdir pilot-tesztek; echo keep > pilot-tesztek/old.txt'
declare -A BASE=([del_emptymanifest]="$BASEOLD" [delete_only]="$BASEOLD" [del_plus_valid_add]="$BASEOLD" [manifest_only]="$BASEOLD" [rename_valid]="$BASEOLD")
declare -A WANT=([good]=true [badhash]=false [nomanifest]=false [workflow]=false [outside]=false [traversal]=false [symlink]=false [del_emptymanifest]=false [emptymanifest_only]=false [delete_only]=false [del_plus_valid_add]=false [manifest_only]=false [rename_valid]=false)

echo "== 7 eredeti + 6 regressziós determinisztikus kapu-teszt (8-13: törlés és üres jegyzék) =="
n=0
for c in good badhash nomanifest workflow outside traversal symlink del_emptymanifest emptymanifest_only delete_only del_plus_valid_add manifest_only rename_valid; do
  n=$((n+1)); mk "$c" "${SETUP[$c]}" "${BASE[$c]:-}"
  python3 "$S/scripts/m2.py" gate --pr-dir "$c" --policy "$S/codex/policy.json" --out "$c.json" >/dev/null
  got=$(python3 -c "import json;print(str(json.load(open('$c.json'))['passed']).lower())")
  why="${WHY[$c]:-}"; hit=""
  if [ -n "$why" ]; then
    if python3 -c "import json,sys;d=json.load(open('$c.json'));sys.exit(0 if any((not x['ok']) and sys.argv[1].lower() in (x['name']+' '+x['detail']).lower() for x in d['checks']) else 1)" "$why"; then hit=" és bukó ellenőrzés: '$why'"; else hit=" DE a várt bukó ellenőrzés ('$why') nem bukott"; got="rossz-ok"; fi
  fi
  if [ "$got" = "${WANT[$c]}" ] || { [ "${WANT[$c]}" = "false" ] && [ "$got" = "false" ]; }; then r=OK; else r=HIBA; FAILS=$((FAILS+1)); fi
  echo "$n. $c: várt passed=${WANT[$c]}, kapott passed=$got$hit -> $r"
done

echo "== 7 verdikt-teszt =="
cp good.json g_ok.json; cp badhash.json g_bad.json
echo '{"verdict":"PASS","summary_hu":"Rendben.","findings":[{"severity":"minor","file":"a.txt","issue_hu":"apró"}]}' > c_pass.json
echo '{"verdict":"PASS","summary_hu":"x","findings":[{"severity":"major","file":"a.txt","issue_hu":"nagy"}]}' > c_major.json
echo '{"verdict":"FAIL","summary_hu":"x","findings":[]}' > c_fail.json
echo 'nem json' > c_junk.json
v() { python3 "$S/scripts/m2.py" verdict --gate-result "$1" --codex-file "$2" --out-md out.md | tail -1 | sed 's/VERDIKT: //'; }
t() { got=$(v "$2" "$3"); if [ "$got" = "$4" ]; then r=OK; else r=HIBA; FAILS=$((FAILS+1)); fi; echo "$1: várt $4, kapott $got -> $r"; }
t "1. kapu OK + PASS (csak minor)" g_ok.json c_pass.json PASS
t "2. kapu OK + major észrevétel " g_ok.json c_major.json FAIL
t "3. kapu OK + Codex FAIL       " g_ok.json c_fail.json FAIL
t "4. kapu OK + érvénytelen válasz" g_ok.json c_junk.json FAIL
t "5. kapu OK + nincs Codex-fájl " g_ok.json missing.json FAIL
t "6. kapu FAIL + Codex PASS     " g_bad.json c_pass.json FAIL
t "7. nincs kapu-fájl            " nope.json c_pass.json FAIL

echo "== Összesen hibás eset: $FAILS =="
exit $((FAILS>0))
