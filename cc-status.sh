#!/usr/bin/env bash
# cc 系统状态采集器：常驻预算 / 记忆 / git / 引擎 / MCP / session 实时快照。
# 用法: cc-status.sh          人类可读
#       cc-status.sh --json   供悬浮窗 GUI 消费（定时 poll 它）
# 2026-06-14 建（架构监视器数据层）。只做本地快速探测,不卡网络。
set -uo pipefail
# Xcode 已装但 license 未同意时,/usr/bin/{git,python3} shim 报错失败 → JSON 产不出 → 面板冻结。
# 有 CommandLineTools 就强制走它绕开 Xcode license 门(健壮兜底;license 同意后也无副作用)。
[ -d /Library/Developer/CommandLineTools ] && export DEVELOPER_DIR=/Library/Developer/CommandLineTools
# 脱敏:PKM 根目录可配(默认 ~/mycc),memory 目录名由 CC 路径转义规则推导(/ → -)
C="$HOME/.claude"; PKM="${CC_MONITOR_PKM_DIR:-$HOME/mycc}"
MEM="$C/projects/$(echo "$PKM" | sed 's#/#-#g')/memory"

rules_kb=$(( ($(cat "$C"/rules/*.md 2>/dev/null | wc -c)) / 1024 ))
mem_kb=$(( ($(wc -c < "$MEM/MEMORY.md" 2>/dev/null || echo 0)) / 1024 ))
events_kb=$(( ($(wc -c < "$PKM/0-System/RECENT_EVENTS.md" 2>/dev/null || echo 0)) / 1024 ))
cards=$(ls "$MEM"/*.md 2>/dev/null | wc -l | tr -d ' ')
# 记忆向量健康(rebuild-index 写的 vector-health.json;让向量陈旧/失败可见,根治 76 天静默死亡)
vec_health=$(python3 -c "
import json,datetime
try:
    d=json.load(open('$PKM/0-System/vector-health.json'))
    lr=datetime.datetime.fromisoformat(d['last_run'].replace('Z','+00:00'))
    days=(datetime.datetime.now(datetime.timezone.utc)-lr).days
    print(f\"{round(d['coverage']*100)}|{d['vectored']}|{d['total']}|{'1' if d['ollama_ready'] else '0'}|{days}\")
except: print('-1|0|0|0|-1')
" 2>/dev/null || echo '-1|0|0|0|-1')
IFS='|' read -r vec_cov vec_vectored vec_total vec_ready vec_days <<< "$vec_health"
git_dirty=$(git -C "$C" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
git_last=$(git -C "$C" log -1 --format='%h' 2>/dev/null)   # 仅 hash,ASCII 安全(中文 commit 信息字节截断会产生非法 UTF-8 → JSON 失效)
git_tag=$(git -C "$C" describe --tags --abbrev=0 2>/dev/null || echo "-")
e_omp=$([ -x "$HOME/.bun/bin/omp" ] && echo 1 || echo 0)
e_grok=$([ -e "$HOME/.grok/bin/grok" ] && echo 1 || echo 0)
e_codex=$([ -e "$HOME/.codex/config.toml" ] && echo 1 || echo 0)
e_gemini=$([ -d "$HOME/.gemini" ] && echo 1 || echo 0)
e_gw=$([ -e "$HOME/.gateway.env" ] && echo 1 || echo 0)
# ── 引擎配置的模型(配置态;严格只取 model 字段,token/key 绝不入 JSON) ──
eng_codex_m=$(grep -E '^[[:space:]]*model[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' "')
eng_codex_e=$(grep -E '^[[:space:]]*model_reasoning_effort' "$HOME/.codex/config.toml" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' "')
eng_codex="${eng_codex_m:-未配置}"; [ -n "$eng_codex_e" ] && eng_codex="${eng_codex}·${eng_codex_e}"
eng_grok=$(python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.grok/models_cache.json')));it=d if isinstance(d,list) else d.get('models',d.get('data',[]));print((it[0].get('id') if isinstance(it[0],dict) else it[0]) if it else 'grok-build')" 2>/dev/null || echo grok-build)
eng_gemini="gemini"   # 无配置默认,routing 策略值(engine-ops),非配置态
eng_omp="omp·聚合"            # 多 provider 聚合,主力满血档
gw_n=$(grep -cE '^CODEX_API_GATEWAY[0-9]*_BASE_URL=' "$HOME/.gateway.env" 2>/dev/null || echo 0)
eng_gateway="codex网关×${gw_n}"
mcp=$(python3 -c "import json;print(len(json.load(open('$PKM/.mcp.json')).get('mcpServers',{})))" 2>/dev/null || echo 0)
sessions=$(pgrep -fl "claude" 2>/dev/null | grep -vc "cc-status" || echo 0)
hook=$([ -x "$C/.git/hooks/pre-commit" ] && echo 1 || echo 0)
ts=$(date "+%H:%M:%S")

# ── skills 自进化采集(纯读现成 evolution-log + task-log,关键词匹配反推 friction heat,不改 cc 核心) ──
EVO="$PKM/0-System/evolution-log.md"; TLOG="$PKM/0-System/task-log.md"
skill_total=$(( $(ls -d "$PKM/.claude/skills"/*/ 2>/dev/null | wc -l) + $(ls -d "$C/skills"/*/ 2>/dev/null | wc -l) ))
# friction TOP3:拿真实 skill 名 + 常见工具名当关键词 grep 最近 250 行 friction 描述(自由文本,只求 heat 量级非精确)
fkw=$(ls -d "$PKM/.claude/skills"/*/ "$C/skills"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' '|' | sed 's/|$//')
fkw="${fkw}|lark-cli|codex|tell-me|gemini|omp|grok|ssh|rsync|docker|nginx|image2|hindsight|proxy|xray|frpc"
friction_top=$(tail -250 "$TLOG" 2>/dev/null | awk -F'|' 'NF>3{print $(NF-1)}' | grep -oiE "$fkw" 2>/dev/null | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s:%s\n",$2,$1}')
# evolution:最新活跃项 + 待晋升(🔴🟡 未毕业) + 停滞天数(文件 mtime 距今)
evo_line=$(grep -E "^\| E[0-9]" "$EVO" 2>/dev/null | tail -1)
evo_id=$(echo "$evo_line" | awk -F'|' '{print $2}' | tr -d ' ')
evo_color=$(echo "$evo_line" | grep -oE "🔴|🟡|⚪" | head -1)
evo_problem=$(echo "$evo_line" | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//')
evo_total=$(grep -cE "^\| E[0-9]" "$EVO" 2>/dev/null || echo 0)
evo_pending=$(grep -E "^\| E[0-9]" "$EVO" 2>/dev/null | grep -E "🔴|🟡" | grep -vcE "已验证有效|已毕业|毕业 ✅" 2>/dev/null || echo 0)
evo_mtime=$(stat -f %m "$EVO" 2>/dev/null || echo 0)
evo_stale_days=$(( ($(date +%s) - evo_mtime) / 86400 ))
# git 未提交文件列表(展开看具体内容,只读) + 全部活跃进化项(展开列表)
git_files=$(git -C "$C" status --short 2>/dev/null | head -20)
evo_items=$(grep -E "^\| E[0-9]" "$EVO" 2>/dev/null)
# friction 详情:TOP skill 各最近 2 条具体摩擦记录(展开看) + ack 读取(已确认项,独立状态文件不碰原始数据)
friction_detail=$(for sk in $(echo "$friction_top" | cut -d: -f1); do
  tail -250 "$TLOG" 2>/dev/null | awk -F'|' 'NF>3{print $(NF-1)}' | grep -i "$sk" | grep -vE '^ *— *$' | tail -2 | awk -v s="$sk" '{gsub(/^ +| +$/,"");print s"\t"$0}'
done)
ACK="$C/.skills-monitor-acks.json"
acked_evo=$(python3 -c "import json;print(','.join(json.load(open('$ACK')).get('evo',[])))" 2>/dev/null || echo "")
acked_fric=$(python3 -c "import json;print(','.join(json.load(open('$ACK')).get('friction',[])))" 2>/dev/null || echo "")

flag(){ [ "$1" -gt "$2" ] && echo "warn" || echo "ok"; }

if [ "${1:-}" = "--json" ]; then
  export rules_kb mem_kb events_kb cards git_dirty git_last git_tag e_omp e_grok e_codex e_gemini e_gw mcp sessions hook ts
  export eng_omp eng_grok eng_codex eng_gemini eng_gateway
  export vec_cov vec_vectored vec_total vec_ready vec_days
  export skill_total friction_top evo_id evo_color evo_problem evo_total evo_pending evo_stale_days git_files evo_items friction_detail acked_evo acked_fric
  python3 -c '
import os,json
g=lambda k:os.environ.get(k,"")
def gi(k):
    try: return int(g(k))
    except: return 0
ft=[]
for ln in g("friction_top").splitlines():
    if ":" in ln:
        nm,ct=ln.rsplit(":",1)
        try: ft.append({"name":nm,"count":int(ct)})
        except: pass
gfiles=[]
for ln in g("git_files").splitlines():
    ln=ln.rstrip()
    if len(ln)>=4:
        gfiles.append({"st":ln[:2].strip(),"path":ln[3:]})
eitems=[]
for ln in g("evo_items").splitlines():
    p=[x.strip() for x in ln.split("|")]
    if len(p)>=7 and p[1].startswith("E"):
        col=""
        for c in ["🔴","🟡","⚪"]:
            if c in p[5]: col=c; break
        eitems.append({"id":p[1],"problem":p[2][:70],"color":col,"status":p[6][:36]})
fdetail={}
for ln in g("friction_detail").splitlines():
    if "\t" in ln:
        sk,rec=ln.split("\t",1)
        fdetail.setdefault(sk,[]).append(rec[:80])
print(json.dumps({
 "ts":g("ts"),
 "budget":{"rules_kb":gi("rules_kb"),"memory_kb":gi("mem_kb"),"events_kb":gi("events_kb"),
           "rules_trip":12,"memory_trip":12,"events_trip":60},
 "memory_cards":gi("cards"),
 "vector_health":{"coverage":gi("vec_cov"),"vectored":gi("vec_vectored"),"total":gi("vec_total"),"ollama_ready":g("vec_ready")=="1","days":gi("vec_days")},
 "git":{"dirty":gi("git_dirty"),"last":g("git_last"),"tag":g("git_tag"),"files":gfiles},
 "engines":{"omp":{"on":g("e_omp")=="1","model":g("eng_omp")},"grok":{"on":g("e_grok")=="1","model":g("eng_grok")},"codex":{"on":g("e_codex")=="1","model":g("eng_codex")},"gemini":{"on":g("e_gemini")=="1","model":g("eng_gemini")},"gateway":{"on":g("e_gw")=="1","model":g("eng_gateway")}},
 "mcp":gi("mcp"),"sessions":gi("sessions"),"secret_hook":g("hook")=="1",
 "skills":{"total":gi("skill_total"),"friction_top":ft,
           "evo_latest":{"id":g("evo_id"),"color":g("evo_color"),"problem":g("evo_problem")},
           "evo_total":gi("evo_total"),"evo_pending":gi("evo_pending"),"evo_stale_days":gi("evo_stale_days"),
           "evo_items":eitems,"friction_detail":fdetail,
           "acked_evo":[x for x in g("acked_evo").split(",") if x],
           "acked_friction":[x for x in g("acked_fric").split(",") if x]}
},ensure_ascii=False))'
else
  echo "🧠 cc 系统状态 · $ts"
  echo "  常驻预算  rules ${rules_kb}KB/$( [ $rules_kb -gt 12 ]&&echo ⚠️||echo ✅ )12  MEMORY ${mem_kb}KB/$( [ $mem_kb -gt 12 ]&&echo ⚠️||echo ✅ )12  events ${events_kb}KB/$( [ $events_kb -gt 60 ]&&echo ⚠️||echo ✅ )60"
  echo "  记忆      ${cards} 卡片(canonical) · secret 闸 $( [ $hook = 1 ]&&echo active✅||echo off⚠️ )"
  echo "  git       ~/.claude $( [ $git_dirty = 0 ]&&echo 干净✅||echo "${git_dirty}未提交⚠️" ) · tag ${git_tag} · ${git_last}"
  echo "  引擎团队  omp$( [ $e_omp = 1 ]&&echo ✅||echo ❌ ) grok$( [ $e_grok = 1 ]&&echo ✅||echo ❌ ) codex$( [ $e_codex = 1 ]&&echo ✅||echo ❌ ) gemini$( [ $e_gemini = 1 ]&&echo ✅||echo ❌ ) gateway$( [ $e_gw = 1 ]&&echo ✅||echo ❌ )"
  echo "  MCP ${mcp} 个 · 运行中 cc session ${sessions} 个"
fi
