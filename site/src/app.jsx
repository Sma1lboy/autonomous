/* global React, ReactDOM */
const { useState, useEffect, useRef, useMemo, useCallback } = React;

function useInterval(cb, ms, enabled = true) {
  const ref = useRef(cb);
  useEffect(() => { ref.current = cb; }, [cb]);
  useEffect(() => {
    if (!enabled) return;
    const id = setInterval(() => ref.current(), ms);
    return () => clearInterval(id);
  }, [ms, enabled]);
}

function useTypewriter(lines, { charDelay = 14, lineDelay = 300, enabled = true, loop = false } = {}) {
  const [emitted, setEmitted] = useState([]);
  const [partial, setPartial] = useState("");
  const [done, setDone] = useState(false);
  const iRef = useRef(0), jRef = useRef(0), timerRef = useRef(null);
  useEffect(() => {
    if (!enabled) return;
    iRef.current = 0; jRef.current = 0;
    setEmitted([]); setPartial(""); setDone(false);
    function tick() {
      const i = iRef.current;
      if (i >= lines.length) {
        setDone(true);
        if (loop) {
          timerRef.current = setTimeout(() => {
            iRef.current = 0; jRef.current = 0;
            setEmitted([]); setPartial(""); setDone(false); tick();
          }, 2500);
        }
        return;
      }
      const line = lines[i], j = jRef.current;
      if (j < line.text.length) {
        jRef.current = j + 1;
        setPartial(line.text.slice(0, j + 1));
        timerRef.current = setTimeout(tick, charDelay + Math.random() * charDelay);
      } else {
        setEmitted((e) => [...e, line]);
        setPartial("");
        iRef.current = i + 1; jRef.current = 0;
        timerRef.current = setTimeout(tick, lineDelay);
      }
    }
    timerRef.current = setTimeout(tick, 400);
    return () => clearTimeout(timerRef.current);
  }, [enabled, lines, charDelay, lineDelay, loop]);
  return { emitted, partial, currentCls: lines[emitted.length]?.cls, done };
}

function Eyebrow({ children }) {
  return <div className="hero__eyebrow"><span className="bar" /><span>{children}</span></div>;
}

function SectionLabel({ tag, children }) {
  return <div className="section__label"><span className="tag">{tag}</span><span>{children}</span></div>;
}

function Install({ cmd }) {
  const [copied, setCopied] = useState(false);
  const onCopy = useCallback(() => {
    navigator.clipboard?.writeText(cmd).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1400); }).catch(() => {});
  }, [cmd]);
  return (
    <div className="install-block">
      <div className="install-block__head">
        <div className="install-block__title">
          <span className="install-block__step">Step 1</span>
          <span>Install on your machine</span>
        </div>
        <span className="install-block__meta">~30 seconds</span>
      </div>
      <div className="install-block__req">
        Requirements: <strong>Claude Code</strong>, <strong>Git</strong>, <strong>Python 3.9+</strong> · optional: tmux, jq
      </div>
      <div className="install-block__sub">Open Claude Code and paste this. Claude does the rest.</div>
      <div className="install-block__prompt">
        <pre className="install-block__cmd">{cmd}</pre>
        <button className="install-block__copy" onClick={onCopy}>{copied ? "copied" : "copy"}</button>
      </div>
      <div className="install-block__foot">
        Then ask the user if they also want to add <code>/autonomous-skill</code> to the current project so teammates get it.
      </div>
    </div>
  );
}

function LiveTerminal({ enabled = true }) {
  const script = useMemo(() => [
    { text: "~/repo/saas-project $ /autonomous-skill 5 ship billing v2", cls: "t-cmd" },
    { text: "", cls: "t-dim" },
    { text: "[conductor] reading OWNER.md · project context loaded", cls: "t-tag-conductor" },
    { text: "[conductor] mission: ship billing v2", cls: "t-tag-conductor" },
    { text: "[conductor] branch: auto/session-20260421-011704", cls: "t-muted" },
    { text: "[conductor] phase: directed · budget: 5 sprints", cls: "t-muted" },
    { text: "", cls: "t-dim" },
    { text: "───── sprint 01 ─ stripe webhook hardening ─────", cls: "t-dim" },
    { text: "[sprint] dispatching worker · fresh session · 14m budget", cls: "t-tag-sprint" },
    { text: "[worker] reading src/billing/webhooks.ts", cls: "t-tag-worker" },
    { text: "[worker] question → 'retry on 5xx only, or any non-2xx?' → rec: 5xx only", cls: "t-tag-worker" },
    { text: "[sprint] answered · continuing", cls: "t-tag-sprint" },
    { text: "[worker] wrote tests/webhook-retry.spec.ts  (+87 −0)", cls: "t-tag-worker" },
    { text: "[worker] all tests green · 124 pass, 0 fail", cls: "t-accent" },
    { text: "[sprint] ✓ merged · 3 commits · $0.74", cls: "t-accent" },
    { text: "", cls: "t-dim" },
    { text: "───── sprint 02 ─ subscription proration ─────", cls: "t-dim" },
    { text: "[worker] wrote src/billing/proration.ts  (+142 −38)", cls: "t-tag-worker" },
    { text: "[sprint] ✓ merged · 2 commits · $0.91", cls: "t-accent" },
    { text: "", cls: "t-dim" },
    { text: "───── sprint 03 ─ invoice pdf generator ─────", cls: "t-dim" },
    { text: "[worker] strike 1: pdfkit font embedding broken in ci", cls: "t-warn" },
    { text: "[worker] ✓ resolved · tests green", cls: "t-accent" },
    { text: "[sprint] ✓ merged · 4 commits · $1.18", cls: "t-accent" },
    { text: "", cls: "t-dim" },
    { text: "[conductor] directed phase complete · transitioning to exploration", cls: "t-tag-conductor" },
    { text: "[conductor] scanning 8 dimensions…  weakest: test_coverage (0.42)", cls: "t-tag-conductor" },
    { text: "", cls: "t-dim" },
    { text: "[conductor] session closing · 5/5 sprints · 11 commits · $4.20", cls: "t-accent" }
  ], []);
  const { emitted, partial, currentCls, done } = useTypewriter(script, { charDelay: 8, lineDelay: 280, enabled, loop: true });
  const bodyRef = useRef(null);
  useEffect(() => { const el = bodyRef.current; if (el) el.scrollTop = el.scrollHeight; }, [emitted.length, partial]);
  return (
    <div className="term">
      <div className="term__chrome">
        <span className="term__dot" /><span className="term__dot" /><span className="term__dot" />
        <span className="term__title">claude code · /autonomous-skill · auto/session-20260421-011704</span>
      </div>
      <div className="term__body" ref={bodyRef}>
        {emitted.map((l, i) => <span key={i} className={`term__line ${l.cls}`}>{l.text || "\u00A0"}</span>)}
        {!done && <span className={`term__line ${currentCls || ""}`}>{partial}<span className="cursor" /></span>}
      </div>
    </div>
  );
}

function StaticTerminal({ title, lines }) {
  return (
    <div className="term">
      <div className="term__chrome">
        <span className="term__dot" /><span className="term__dot" /><span className="term__dot" />
        <span className="term__title">{title}</span>
      </div>
      <div className="term__body">
        {lines.map((l, i) => <span key={i} className={`term__line ${l.cls || ""}`}>{l.text || "\u00A0"}</span>)}
      </div>
    </div>
  );
}

function ArchDiagram() {
  const [active, setActive] = useState(0);
  useInterval(() => setActive((a) => (a + 1) % 3), 1800);
  const nodes = [
    { title: "Conductor", chip: "user's session", desc: "Plans sprint directions, dispatches sprint masters, evaluates results, manages phase transitions between directed work and exploration." },
    { title: "Sprint Master", chip: "claude -p", desc: "Sense → Direct → Respond → Summarize loop. Dispatches a worker, answers its questions via comms.json, writes a sprint summary." },
    { title: "Worker", chip: "full tools", desc: "Does the actual work. Reads code, edits files, runs tests, makes commits. Each sprint gets a fresh, isolated context." }
  ];
  return (
    <div className="arch">
      <div className="arch__stack">
        {nodes.map((n, i) => (
          <React.Fragment key={n.title}>
            <div className="arch__node" data-active={active === i} onMouseEnter={() => setActive(i)}>
              <div className="arch__head">
                <div className="arch__title">{n.title}</div>
                <div className="arch__chip">{n.chip}</div>
              </div>
              <div className="arch__desc">{n.desc}</div>
            </div>
            {i < nodes.length - 1 && <div className="arch__wire" />}
          </React.Fragment>
        ))}
      </div>
    </div>
  );
}

function MetricStrip() {
  const items = [
    { n: "38", sub: "/47", label: "TODOs shipped by 8am" },
    { n: "$4.20", sub: "", label: "avg session cost" },
    { n: "329", sub: "", label: "tests · all bash" },
    { n: "3", sub: "layers", label: "conductor · master · worker" }
  ];
  return (
    <div className="strip">
      {items.map((i) => (
        <div className="strip__cell" key={i.label}>
          <div className="strip__num">{i.n}{i.sub && <sub>{i.sub}</sub>}</div>
          <div className="strip__label">{i.label}</div>
        </div>
      ))}
    </div>
  );
}

function HowItWorks() {
  const steps = [
    { h: "Persona", p: <>Reads your <code>git log</code> and project docs to understand your coding style. Writes <code>OWNER.md</code>.</> },
    { h: "Discovery", p: "The conductor confirms the mission. If you passed a direction in args, it acknowledges and moves on." },
    { h: "Session", p: <>Creates <code>auto/session-TIMESTAMP</code> and initializes conductor state. Main branch is never touched.</> },
    { h: "Loop", p: "Plan → dispatch → monitor → evaluate → repeat. Sprint masters run in isolated sessions, each gets a fresh context." },
    { h: "Phase transition", p: "When the directed mission is done, it shifts to exploration — auditing the project across 8 dimensions and fixing the weakest." },
    { h: "Merge or discard", p: "Successful sprints merge back to the session branch. Failed sprints are discarded cleanly." },
    { h: "Review", p: <>You wake up. You run <code>git log main..auto/session-*</code>. You merge what you like.</> }
  ];
  return (
    <ol className="steps">
      {steps.map((s, i) => (
        <li className="step" key={i}>
          <div className="step__idx" />
          <div className="step__body"><h3>{s.h}</h3><p>{s.p}</p></div>
        </li>
      ))}
    </ol>
  );
}

function Dimensions() {
  const dims = [
    { id: "test_coverage", desc: "Untested code paths, missing edge cases, coverage gaps.", score: 0.42 },
    { id: "error_handling", desc: "Unhandled failures, swallowed errors, silent catches.", score: 0.71 },
    { id: "security", desc: "Hardcoded secrets, injection holes, input validation.", score: 0.88 },
    { id: "code_quality", desc: "Dead code, duplication, overly complex functions.", score: 0.65 },
    { id: "documentation", desc: "README accuracy, missing docstrings, stale references.", score: 0.58 },
    { id: "architecture", desc: "Module boundaries, dependency directions, separation of concerns.", score: 0.80 },
    { id: "performance", desc: "N+1 queries, blocking I/O, missing caching layers.", score: 0.74 },
    { id: "dx", desc: "CLI help text, error messages, setup instructions.", score: 0.66 }
  ];
  return (
    <div className="dims">
      {dims.map((d) => (
        <div className="dim" key={d.id}>
          <div className="dim__head"><span className="dim__id">{d.id}</span><span className="dim__score">{d.score.toFixed(2)}</span></div>
          <div className="dim__desc">{d.desc}</div>
          <div className="dim__bar"><span style={{ width: `${d.score * 100}%` }} /></div>
        </div>
      ))}
    </div>
  );
}

function Skills() {
  return (
    <div className="skills">
      <div className="skill">
        <div className="skill__cmd">/autonomous-skill</div>
        <p className="skill__tagline">Full multi-sprint orchestration.</p>
        <p className="skill__desc">Conductor → sprint master → worker. Plans sprints, transitions between directed work and autonomous exploration, manages branches, evaluates between sprints.</p>
        <div className="skill__specs">
          <span>default 10 sprints · configurable</span>
          <span>directed + exploration phases</span>
          <span>tmux, blocking, or headless dispatch</span>
          <span>cross-session backlog pickup</span>
        </div>
      </div>
      <div className="skill">
        <div className="skill__cmd">/quickdo</div>
        <p className="skill__tagline">One direction, one sprint, done.</p>
        <p className="skill__desc">Skips the conductor. Runs a single sprint master directly via blocking claude -p. No tmux, no multi-sprint state, no monitor polling.</p>
        <div className="skill__specs">
          <span>blocking mode only</span>
          <span>best for: a page, a feature, a test suite</span>
          <span>auto/quickdo-* branch</span>
          <span>fast feedback loop</span>
        </div>
      </div>
    </div>
  );
}

function Safety() {
  const guards = [
    { k: "Branch isolation", v: "All work happens on auto/session-* or auto/quickdo-* branches. Main is never touched." },
    { k: "Per-sprint branches", v: "Each sprint gets its own branch. Merged on success, discarded on failure — no half-states left behind." },
    { k: "Timeout", v: "Each Claude invocation is capped at 15 minutes by default. Configurable via CC_TIMEOUT." },
    { k: "Cost budget", v: "Set MAX_COST_USD to stop the session when spend exceeds a threshold." },
    { k: "Worker safety hook", v: "Opt-in PreToolUse hook blocks rm -rf /, fork bombs, force-pushes, DROP TABLE, and interpreter-wrapped variants." },
    { k: "3-strike rule", v: "If the same approach fails three times, the sprint stops and reports. No infinite retry loops." },
    { k: "Atomic state", v: "Conductor state uses tmp+mv writes and a PID lock. Safe under concurrent reads." },
    { k: "Graceful shutdown", v: "SIGINT plus a sentinel file for clean exit across all three layers." }
  ];
  return (
    <div className="safety">
      {guards.map((g) => (
        <div className="safety__row" key={g.k}>
          <div className="safety__guard">{g.k}</div>
          <div className="safety__how">{g.v}</div>
        </div>
      ))}
    </div>
  );
}

function CommsBlock() {
  const worker = [
    { text: "# worker writes to .autonomous/comms.json", cls: "t-dim" },
    { text: "{", cls: "t-muted" },
    { text: '  "status": "waiting",', cls: "t-muted" },
    { text: '  "questions": [', cls: "t-muted" },
    { text: '    { "question": "retry on 5xx only, or any non-2xx?",', cls: "t-accent" },
    { text: '      "options": ["5xx only", "all non-2xx"] }', cls: "t-accent" },
    { text: '  ],', cls: "t-muted" },
    { text: '  "rec": "5xx only"', cls: "t-muted" },
    { text: "}", cls: "t-muted" },
    { text: "", cls: "t-dim" },
    { text: "# sprint master decides, writes back", cls: "t-dim" },
    { text: '{ "status": "answered", "answers": ["5xx only"] }', cls: "t-accent" }
  ];
  return <StaticTerminal title=".autonomous/comms.json · worker ↔ sprint master" lines={worker} />;
}

function Quote() {
  return (
    <blockquote className="quote">
      You close your laptop at midnight with 47 TODOs. You open it at 8am and 38 are done, tested, committed, on a clean branch.
      <span className="quote__attrib">— the pitch, in one sentence</span>
    </blockquote>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <div className="page footer__grid">
        <div>
          <div className="footer__links">
            <a href="https://github.com/Sma1lboy/autonomous" target="_blank" rel="noreferrer">github</a>
            <a href="https://github.com/Sma1lboy/autonomous/blob/main/README.md" target="_blank" rel="noreferrer">readme</a>
            <a href="https://github.com/Sma1lboy/autonomous/releases" target="_blank" rel="noreferrer">releases</a>
            <a href="https://github.com/Sma1lboy/autonomous/issues" target="_blank" rel="noreferrer">issues</a>
          </div>
          <div className="footer__meta">autonomous v0.7.0 · MIT · requires claude code, git, python 3.9+</div>
        </div>
        <div style={{ fontSize: 11, color: "var(--fg-dim)", textAlign: "right" }}>built for people who ship in their sleep.</div>
      </div>
    </footer>
  );
}

const ACCENTS = [
  { id: "green",  color: "oklch(0.78 0.17 142)" },
  { id: "orange", color: "oklch(0.74 0.17 55)" },
  { id: "indigo", color: "oklch(0.72 0.17 275)" },
  { id: "amber",  color: "oklch(0.82 0.17 90)"  },
  { id: "white",  color: "#ededec" }
];

function Tweaks({ state, setState }) {
  return (
    <div className="tweaks">
      <h4 className="tweaks__h">Tweaks</h4>
      <div className="tweaks__row">
        <label>Accent</label>
        <div className="swatches">
          {ACCENTS.map((a) => (
            <button key={a.id} className="swatch" style={{ background: a.color }} data-sel={state.accent === a.id} onClick={() => setState({ accent: a.id })} aria-label={a.id} />
          ))}
        </div>
      </div>
      <div className="tweaks__row">
        <label>Density</label>
        <div className="pills">
          {["comfortable", "compact"].map((d) => (
            <button key={d} className="pill" data-sel={state.density === d} onClick={() => setState({ density: d })}>{d}</button>
          ))}
        </div>
      </div>
      <div className="tweaks__row" style={{ marginBottom: 0 }}>
        <label className="tweaks__check">
          <input type="checkbox" checked={!!state.showLiveLog} onChange={(e) => setState({ showLiveLog: e.target.checked })} />
          animate live terminal
        </label>
      </div>
    </div>
  );
}

function useTweaks() {
  const [state, _setState] = useState(() => ({ ...(window.TWEAK_DEFAULTS || {}) }));
  const [active, setActive] = useState(false);
  const setState = useCallback((patch) => {
    _setState((prev) => {
      const next = { ...prev, ...patch };
      try { window.parent.postMessage({ type: "__edit_mode_set_keys", edits: patch }, "*"); } catch (e) {}
      return next;
    });
  }, []);
  useEffect(() => {
    function onMsg(e) {
      const d = e.data || {};
      if (d.type === "__activate_edit_mode") setActive(true);
      if (d.type === "__deactivate_edit_mode") setActive(false);
    }
    window.addEventListener("message", onMsg);
    try { window.parent.postMessage({ type: "__edit_mode_available" }, "*"); } catch (e) {}
    return () => window.removeEventListener("message", onMsg);
  }, []);
  useEffect(() => {
    const root = document.documentElement;
    root.setAttribute("data-accent", state.accent || "green");
    root.setAttribute("data-density", state.density || "comfortable");
  }, [state.accent, state.density]);
  return { state, setState, active };
}

function TopBar() {
  return (
    <header className="topbar">
      <div className="topbar__inner">
        <div className="topbar__brand"><span className="dot" /><span>autonomous</span></div>
        <nav className="topbar__nav">
          <a href="#how">how it works</a>
          <a href="#architecture">architecture</a>
          <a href="#explore">exploration</a>
          <a href="#skills">skills</a>
          <a href="#safety">safety</a>
        </nav>
        <div className="topbar__right">
          <span className="topbar__badge">v0.7.0</span>
          <a className="btn-link" href="https://github.com/Sma1lboy/autonomous" target="_blank" rel="noreferrer">github ↗</a>
        </div>
      </div>
    </header>
  );
}

function Hero({ showLiveLog }) {
  const install = 'Install autonomous: run git clone --single-branch --depth 1 https://github.com/Sma1lboy/autonomous.git ~/.claude/skills/autonomous-skill && cd ~/.claude/skills/autonomous-skill && ./setup, then add an "autonomous" section to CLAUDE.md that lists the available skills: /autonomous-skill, /quickdo — and notes that /autonomous-skill runs a three-layer conductor → sprint master → worker loop on an isolated auto/session-* branch, while /quickdo runs a single sprint on auto/quickdo-*. Then ask the user if they also want to add autonomous to the current project so teammates get it.';
  return (
    <section className="hero">
      <div className="page">
        <Eyebrow>a self-driving project agent for claude code</Eyebrow>
        <h1 className="hero__h1">You sleep.<br/><em>It ships.</em></h1>
        <p className="hero__lede">
          Drop <strong>autonomous</strong> into any git repo, run <strong>/autonomous-skill</strong>, and close your laptop.
          A three-layer agent — conductor, sprint master, worker — finds tasks, writes code,
          runs your tests, and commits the results on an isolated branch. You review in the morning.
        </p>
        <div className="hero__cta-row"><a className="btn-link" href="#how">how it works →</a><a className="btn-link" href="https://github.com/Sma1lboy/autonomous" target="_blank" rel="noreferrer">view on github ↗</a></div>
        <div style={{ marginTop: 32 }}><Install cmd={install} /></div>
        <div style={{ marginTop: 40 }}><LiveTerminal enabled={showLiveLog} /></div>
        <MetricStrip />
      </div>
    </section>
  );
}

function App() {
  const { state, setState, active } = useTweaks();
  return (
    <>
      <TopBar />
      <Hero showLiveLog={!!state.showLiveLog} />
      <section className="section" id="how"><div className="page">
        <SectionLabel tag="01">how it works</SectionLabel>
        <h2 className="section__h">Plan. Dispatch.<br/><em>Evaluate. Repeat.</em></h2>
        <p className="section__sub">Seven steps run on repeat until the mission is done, the budget is spent, or the project feels solid. You stay out of the loop.</p>
        <HowItWorks />
      </div></section>
      <section className="section" id="architecture"><div className="page">
        <SectionLabel tag="02">architecture</SectionLabel>
        <h2 className="section__h">Three layers.<br/><em>Full context isolation.</em></h2>
        <p className="section__sub">Each layer runs in its own Claude session. No bleed between sprints. Clean separation, clean context.</p>
        <ArchDiagram />
        <div style={{ marginTop: 32 }}><CommsBlock /></div>
      </div></section>
      <section className="section" id="explore"><div className="page">
        <SectionLabel tag="03">exploration</SectionLabel>
        <h2 className="section__h">When direction runs out,<br/><em>it keeps going.</em></h2>
        <p className="section__sub">Once the directed mission is complete, the conductor scans eight project dimensions, scores each via Python heuristics, and generates sprints against the weakest.</p>
        <Dimensions />
      </div></section>
      <section className="section" id="skills"><div className="page">
        <SectionLabel tag="04">skills</SectionLabel>
        <h2 className="section__h">Two commands.<br/><em>One philosophy.</em></h2>
        <p className="section__sub">A full orchestration for the night shift, and a fast single-sprint mode for when you want one thing done, right now.</p>
        <Skills />
      </div></section>
      <section className="section" id="safety"><div className="page">
        <SectionLabel tag="05">safety</SectionLabel>
        <h2 className="section__h">Autonomous,<br/><em>not unsupervised.</em></h2>
        <p className="section__sub">Branch isolation, per-sprint branches, timeouts, cost caps, a 3-strike rule, and an opt-in PreToolUse hook that blocks the classics. You wake up to commits, not craters.</p>
        <Safety />
      </div></section>
      <section className="section"><div className="page"><Quote /></div></section>
      <Footer />
      {active && <Tweaks state={state} setState={setState} />}
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
