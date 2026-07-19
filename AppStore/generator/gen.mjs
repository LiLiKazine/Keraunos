import { writeFileSync } from 'node:fs';

// ---------------------------------------------------------------------------
// Shared CSS variables (from the Keraunos design system) — defined on .poster
// so the reused screen markup resolves them without a .canvas-root ancestor.
// ---------------------------------------------------------------------------
const VARS = `
  --bg: oklch(0.17 0.006 260); --s1: oklch(0.215 0.008 260); --s2: oklch(0.262 0.008 260);
  --hair: oklch(0.32 0.008 260); --tx1: oklch(0.96 0.004 260); --tx2: oklch(0.72 0.008 260); --tx3: oklch(0.58 0.01 260);
  --accent: oklch(0.68 0.13 248); --accent-soft: oklch(0.68 0.13 248 / 0.16); --on-accent: oklch(0.99 0 0);
  --success: oklch(0.72 0.14 155); --error: oklch(0.64 0.17 25);
  --shadow: 0 1px 2px oklch(0 0 0 / 0.4), 0 6px 20px oklch(0 0 0 / 0.3);
`;

const POSTER_CSS = `
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: #0a0c11; }
  .poster {
    position: relative; overflow: hidden;
    font-family: -apple-system, system-ui, "SF Pro Display", sans-serif;
    ${VARS}
    color: var(--tx1);
    background:
      radial-gradient(125% 80% at 50% -8%, oklch(0.37 0.11 248 / 0.55), transparent 52%),
      radial-gradient(58% 30% at 50% 60%, oklch(0.55 0.14 248 / 0.16), transparent 70%),
      radial-gradient(110% 75% at 50% 118%, oklch(0.30 0.09 288 / 0.32), transparent 60%),
      linear-gradient(180deg, oklch(0.165 0.006 260), oklch(0.115 0.006 260));
  }
  .p-caption { position: absolute; left: 0; right: 0; top: 0; display: flex; flex-direction: column; align-items: center; text-align: center; }
  .p-caption h1 { margin: 0; font-weight: 700; letter-spacing: -0.03em; line-height: 1.03; }
  .p-caption p { margin: 0; color: var(--tx2); font-weight: 500; letter-spacing: -0.01em; }
  .p-caption .accent { color: var(--accent); }
  .p-stage { position: absolute; left: 50%; transform-origin: top center; }
  .p-stage .device { position: relative !important; left: auto !important; top: auto !important; margin: 0 !important; }
`;

// ---------------------------------------------------------------------------
// Per-family CSS, copied verbatim from the design-system pages.
// ---------------------------------------------------------------------------
const HOME_CSS = `
  .num { font-variant-numeric: tabular-nums; }
  .device { background: var(--bg); color: var(--tx1); overflow: hidden; box-shadow: 0 50px 130px oklch(0 0 0 / 0.55); border: 1px solid var(--hair); }
  .iphone { width: 393px; height: 852px; border-radius: 46px; }
  .ipad { width: 1180px; height: 820px; border-radius: 26px; }
  .col { display: flex; flex-direction: column; }
  .statusbar { height: 52px; display: flex; align-items: center; justify-content: space-between; padding: 0 30px 0 34px; font-size: 15px; font-weight: 600; flex: none; }
  .statusbar .glyphs { display: flex; align-items: center; gap: 6px; }
  .statusbar .glyphs svg { width: 17px; height: 17px; }
  .phone-body { flex: 1; display: flex; flex-direction: column; padding: 4px 20px 0; gap: 22px; overflow: hidden; }
  .phone-head { display: flex; align-items: center; justify-content: space-between; }
  .phone-title { display: flex; align-items: center; gap: 10px; font-size: 32px; font-weight: 700; letter-spacing: -0.02em; }
  .phone-title svg { width: 28px; height: 28px; }
  .bolt { fill: var(--accent); }
  .icon-btn { width: 38px; height: 38px; border-radius: 50%; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; color: var(--tx2); }
  .icon-btn svg { width: 20px; height: 20px; }
  .hero { background: var(--s1); border: 1px solid var(--hair); border-radius: 16px; padding: 18px; display: flex; flex-direction: column; gap: 14px; box-shadow: var(--shadow); }
  .hero-label { font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--tx3); font-weight: 600; }
  .input { display: flex; align-items: center; gap: 8px; background: var(--s2); border: 1px solid var(--hair); border-radius: 12px; padding: 5px 5px 5px 16px; min-width: 180px; }
  .input .field { flex: 1; min-width: 0; color: var(--tx3); font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .paste-btn { background: var(--accent-soft); color: var(--accent); font-size: 13px; font-weight: 600; padding: 10px 15px; border-radius: 10px; display: inline-flex; align-items: center; gap: 6px; flex: none; }
  .paste-btn svg { width: 14px; height: 14px; }
  .btn-primary { background: var(--accent); color: var(--on-accent); font-size: 16px; font-weight: 600; padding: 15px; border-radius: 12px; border: none; display: flex; align-items: center; justify-content: center; gap: 9px; box-shadow: var(--shadow); cursor: pointer; }
  .btn-primary svg { width: 18px; height: 18px; }
  .sec-label { display: flex; align-items: center; justify-content: space-between; font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--tx3); font-weight: 600; }
  .card { background: var(--s1); border: 1px solid var(--hair); border-radius: 16px; padding: 16px; display: flex; flex-direction: column; gap: 13px; box-shadow: var(--shadow); }
  .card-top { display: flex; align-items: center; gap: 12px; }
  .thumb { width: 50px; height: 50px; border-radius: 10px; flex: none; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; }
  .thumb svg { width: 19px; height: 19px; color: var(--tx3); }
  .card-meta { flex: 1; display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .card-title { font-size: 15px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .card-sub { font-size: 12px; color: var(--tx3); }
  .size-badge { font-size: 12.5px; color: var(--tx2); flex: none; }
  .track { height: 7px; border-radius: 4px; background: var(--s2); overflow: hidden; }
  .fill { height: 100%; border-radius: 4px; background: var(--accent); }
  .card-foot { display: flex; align-items: center; justify-content: space-between; }
  .rate { font-size: 12.5px; color: var(--accent); font-weight: 600; }
  .mini-cancel { font-size: 13px; color: var(--tx3); }
  .list { display: flex; flex-direction: column; }
  .row { display: flex; align-items: center; gap: 13px; padding: 12px 0; border-top: 1px solid var(--hair); }
  .row:first-child { border-top: none; }
  .row-thumb { width: 62px; height: 39px; border-radius: 10px; flex: none; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; }
  .row-thumb svg { width: 16px; height: 16px; color: var(--accent); }
  .row-meta { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .row-title { font-size: 15px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row-sub { font-size: 11.5px; color: var(--tx3); }
  .row-play { color: var(--accent); flex: none; display: flex; }
  .row-play svg { width: 24px; height: 24px; }
  .tabbar { flex: none; height: 86px; border-top: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.92); display: flex; padding: 10px 0 22px; }
  .tab { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 5px; font-size: 10.5px; font-weight: 500; color: var(--tx3); }
  .tab svg { width: 25px; height: 25px; }
  .tab.active { color: var(--accent); }
  .home-ind { position: absolute; bottom: 8px; left: 50%; transform: translateX(-50%); width: 134px; height: 5px; border-radius: 3px; background: var(--tx1); opacity: 0.5; }
  .ipad-layout { display: flex; height: 100%; }
  .sidebar { width: 280px; flex: none; border-right: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.6); padding: 26px 16px; display: flex; flex-direction: column; gap: 6px; }
  .side-brand { display: flex; align-items: center; gap: 12px; padding: 6px 12px 22px; }
  .side-tile { width: 40px; height: 40px; border-radius: 11px; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; box-shadow: var(--shadow); }
  .side-tile svg { width: 26px; height: 26px; }
  .side-word { font-size: 20px; font-weight: 700; letter-spacing: -0.02em; }
  .nav { display: flex; align-items: center; gap: 13px; padding: 12px 14px; border-radius: 10px; color: var(--tx2); font-size: 15px; font-weight: 500; }
  .nav svg { width: 20px; height: 20px; }
  .nav.active { background: var(--accent-soft); color: var(--accent); }
  .side-foot { margin-top: auto; }
  .ipad-content { flex: 1; min-width: 0; padding: 40px 48px; display: flex; flex-direction: column; gap: 30px; overflow: hidden; }
  .content-head { display: flex; align-items: flex-end; justify-content: space-between; }
  .content-title { font-size: 34px; font-weight: 700; letter-spacing: -0.02em; }
  .ipad-hero { max-width: 720px; }
  .ipad-hero .hero-inner { display: flex; gap: 12px; align-items: center; }
  .ipad-hero .btn-primary { flex: none; padding: 15px 26px; }
  .dl-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
  .dl-card { background: var(--s1); border: 1px solid var(--hair); border-radius: 16px; overflow: hidden; display: flex; flex-direction: column; box-shadow: var(--shadow); }
  .cover { aspect-ratio: 16 / 9; background: var(--s2); display: flex; align-items: center; justify-content: center; position: relative; }
  .cover .play { width: 34px; height: 34px; color: var(--accent); opacity: 0.9; }
  .cover .cover-track { position: absolute; left: 0; right: 0; bottom: 0; height: 5px; background: oklch(0 0 0 / 0.4); }
  .cover .cover-fill { height: 100%; background: var(--accent); }
  .dl-body { padding: 13px 15px; display: flex; flex-direction: column; gap: 5px; }
  .dl-title { font-size: 14.5px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .dl-sub { font-size: 11.5px; color: var(--tx3); }
`;

const LIB_CSS = `
  .num { font-variant-numeric: tabular-nums; }
  .device { background: var(--bg); color: var(--tx1); overflow: hidden; box-shadow: 0 50px 130px oklch(0 0 0 / 0.55); border: 1px solid var(--hair); }
  .iphone { width: 393px; height: 852px; border-radius: 46px; }
  .ipad { width: 1180px; height: 820px; border-radius: 26px; }
  .bolt { fill: var(--accent); }
  .col { display: flex; flex-direction: column; }
  .statusbar { height: 52px; display: flex; align-items: center; justify-content: space-between; padding: 0 30px 0 34px; font-size: 15px; font-weight: 600; flex: none; }
  .statusbar .glyphs { display: flex; align-items: center; gap: 6px; }
  .statusbar .glyphs svg { width: 17px; height: 17px; }
  .phone-body { flex: 1; display: flex; flex-direction: column; padding: 4px 18px 0; gap: 16px; overflow: hidden; }
  .lg-head { display: flex; align-items: center; justify-content: space-between; }
  .lg-title { font-size: 32px; font-weight: 700; letter-spacing: -0.02em; }
  .icon-btn { width: 38px; height: 38px; border-radius: 50%; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; color: var(--tx2); flex: none; }
  .icon-btn svg { width: 20px; height: 20px; }
  .search { display: flex; align-items: center; gap: 8px; background: var(--s2); border: 1px solid var(--hair); border-radius: 12px; padding: 10px 14px; color: var(--tx3); font-size: 15px; }
  .search svg { width: 17px; height: 17px; }
  .seg { display: flex; background: var(--s2); border-radius: 10px; padding: 3px; gap: 3px; }
  .seg-item { flex: 1; text-align: center; padding: 7px; border-radius: 8px; font-size: 13px; font-weight: 600; color: var(--tx3); }
  .seg-item.on { background: oklch(0.36 0.008 260); color: var(--tx1); }
  .list { display: flex; flex-direction: column; }
  .row { display: flex; align-items: center; gap: 13px; padding: 12px 0; border-top: 1px solid var(--hair); }
  .row:first-child { border-top: none; }
  .row-thumb { width: 76px; height: 47px; border-radius: 10px; flex: none; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; position: relative; overflow: hidden; }
  .row-thumb svg { width: 17px; height: 17px; color: var(--accent); }
  .dur { position: absolute; right: 4px; bottom: 4px; font-size: 9.5px; font-weight: 600; color: #fff; background: oklch(0 0 0 / 0.6); padding: 1px 4px; border-radius: 4px; }
  .row-meta { flex: 1; display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .row-title { font-size: 15px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row-sub { font-size: 11.5px; color: var(--tx3); }
  .row-more { color: var(--tx3); flex: none; display: flex; }
  .row-more svg { width: 22px; height: 22px; }
  .tabbar { flex: none; height: 86px; border-top: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.92); display: flex; padding: 10px 0 22px; }
  .tab { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 5px; font-size: 10.5px; font-weight: 500; color: var(--tx3); }
  .tab svg { width: 25px; height: 25px; }
  .tab.active { color: var(--accent); }
  .home-ind { position: absolute; bottom: 8px; left: 50%; transform: translateX(-50%); width: 134px; height: 5px; border-radius: 3px; background: var(--tx1); opacity: 0.5; }
  .ctx-scrim { position: absolute; inset: 0; background: oklch(0 0 0 / 0.5); }
  .ctx-wrap { position: absolute; left: 18px; top: 210px; display: flex; flex-direction: column; gap: 10px; width: 300px; }
  .ctx-preview { background: var(--s1); border: 1px solid var(--hair); border-radius: 12px; padding: 10px; display: flex; align-items: center; gap: 12px; box-shadow: 0 24px 60px oklch(0 0 0 / 0.6); }
  .ctx-preview .row-thumb { width: 64px; height: 40px; }
  .ctx-preview .p-title { font-size: 14px; font-weight: 600; }
  .ctx-preview .p-sub { font-size: 11px; color: var(--tx3); }
  .ctx-menu { width: 232px; background: oklch(0.30 0.008 260); border: 1px solid var(--hair); border-radius: 16px; overflow: hidden; box-shadow: 0 24px 60px oklch(0 0 0 / 0.6); }
  .ctx-item { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 13px 16px; font-size: 16px; border-top: 1px solid var(--hair); }
  .ctx-item:first-child { border-top: none; }
  .ctx-item svg { width: 20px; height: 20px; color: var(--tx2); }
  .ctx-item.danger { color: var(--error); }
  .ctx-item.danger svg { color: var(--error); }
  .ipad-layout { display: flex; height: 100%; }
  .sidebar { width: 260px; flex: none; border-right: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.6); padding: 26px 16px; display: flex; flex-direction: column; gap: 6px; }
  .side-brand { display: flex; align-items: center; gap: 12px; padding: 6px 12px 22px; }
  .side-tile { width: 40px; height: 40px; border-radius: 11px; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; box-shadow: var(--shadow); }
  .side-tile svg { width: 26px; height: 26px; }
  .side-word { font-size: 20px; font-weight: 700; letter-spacing: -0.02em; }
  .nav { display: flex; align-items: center; gap: 13px; padding: 12px 14px; border-radius: 10px; color: var(--tx2); font-size: 15px; font-weight: 500; }
  .nav svg { width: 20px; height: 20px; }
  .nav.active { background: var(--accent-soft); color: var(--accent); }
  .side-foot { margin-top: auto; }
  .lib-main { flex: 1; min-width: 0; padding: 28px 26px; display: flex; flex-direction: column; gap: 20px; overflow: hidden; }
  .lib-head { display: flex; align-items: center; gap: 14px; }
  .toggle { width: 34px; height: 34px; border-radius: 12px; border: 1px solid var(--hair); background: var(--s1); display: flex; align-items: center; justify-content: center; color: var(--tx2); flex: none; }
  .toggle svg { width: 18px; height: 18px; }
  .lib-title { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; }
  .lib-search { margin-left: auto; width: 240px; }
  .dl-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; align-content: start; overflow: hidden; }
  .dl-card { background: var(--s1); border: 1px solid var(--hair); border-radius: 16px; overflow: hidden; display: flex; flex-direction: column; box-shadow: var(--shadow); }
  .dl-card.sel { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent), var(--shadow); }
  .cover { aspect-ratio: 16 / 9; background: var(--s2); display: flex; align-items: center; justify-content: center; position: relative; }
  .cover .play { width: 32px; height: 32px; color: var(--accent); opacity: 0.9; }
  .cover .dur { right: 6px; bottom: 6px; }
  .dl-body { padding: 12px 14px; display: flex; flex-direction: column; gap: 5px; }
  .dl-title { font-size: 14px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .dl-sub { font-size: 11px; color: var(--tx3); }
  .detail-pane { width: 366px; flex: none; border-left: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.4); padding: 24px; display: flex; flex-direction: column; gap: 16px; }
  .player { aspect-ratio: 16 / 9; border-radius: 16px; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; }
  .player svg { width: 54px; height: 54px; color: var(--accent); }
  .detail-title { font-size: 19px; font-weight: 700; letter-spacing: -0.01em; line-height: 1.25; }
  .detail-src { font-size: 12.5px; color: var(--tx3); margin-top: -8px; }
  .meta-chips { display: flex; gap: 8px; flex-wrap: wrap; }
  .mchip { font-size: 12px; color: var(--tx2); background: var(--s2); border: 1px solid var(--hair); padding: 5px 10px; border-radius: 8px; }
  .detail-actions { display: flex; flex-direction: column; gap: 10px; margin-top: auto; }
  .play-btn { display: flex; align-items: center; justify-content: center; gap: 9px; padding: 14px; border-radius: 12px; font-size: 16px; font-weight: 600; background: var(--accent); color: var(--on-accent); box-shadow: var(--shadow); }
  .play-btn svg { width: 18px; height: 18px; }
  .action-row { display: flex; gap: 10px; }
  .icon-action { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 12px; border-radius: 12px; background: var(--s2); border: 1px solid var(--hair); font-size: 11px; font-weight: 500; color: var(--tx2); }
  .icon-action svg { width: 20px; height: 20px; }
  .icon-action.danger { color: var(--error); }
`;

const QP_CSS = `
  .num { font-variant-numeric: tabular-nums; }
  .device { background: var(--bg); color: var(--tx1); overflow: hidden; box-shadow: 0 50px 130px oklch(0 0 0 / 0.55); border: 1px solid var(--hair); }
  .iphone { width: 393px; height: 852px; border-radius: 46px; }
  .ipad { width: 1180px; height: 820px; border-radius: 26px; }
  .bolt { fill: var(--accent); }
  .backdrop-home { position: absolute; inset: 0; padding: 60px 22px; display: flex; flex-direction: column; gap: 18px; filter: saturate(0.9); }
  .bh-title { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; opacity: 0.8; }
  .bh-block { background: var(--s1); border: 1px solid var(--hair); border-radius: 16px; height: 92px; opacity: 0.5; }
  .scrim { position: absolute; inset: 0; background: oklch(0 0 0 / 0.55); }
  .sheet { position: absolute; left: 0; right: 0; bottom: 0; background: var(--s1); border-top: 1px solid var(--hair); border-radius: 24px 24px 0 0; padding: 8px 14px 32px; display: flex; flex-direction: column; }
  .grabber { width: 38px; height: 5px; border-radius: 3px; background: var(--hair); margin: 6px auto 10px; }
  .sheet-title { font-size: 20px; font-weight: 700; text-align: center; }
  .sheet-sub { font-size: 13px; color: var(--tx3); text-align: center; margin: 2px 0 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding: 0 20px; }
  .opt { display: flex; align-items: center; gap: 14px; padding: 13px 12px; border-radius: 12px; }
  .opt.sel { background: var(--accent-soft); }
  .opt-main { flex: 1; display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .opt-res { font-size: 16px; font-weight: 600; display: flex; align-items: center; gap: 8px; }
  .opt-sub { font-size: 12px; color: var(--tx3); }
  .opt-size { font-size: 13px; color: var(--tx2); flex: none; }
  .check { color: var(--accent); flex: none; display: flex; }
  .check svg { width: 22px; height: 22px; }
  .tag { font-size: 9.5px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; color: var(--accent); background: var(--accent-soft); padding: 2px 7px; border-radius: 6px; }
  .badge4k { font-size: 10px; font-weight: 700; color: var(--bg); background: var(--tx2); padding: 2px 6px; border-radius: 5px; }
  .divider { height: 1px; background: var(--hair); margin: 2px 12px; }
  .sheet-cancel { margin-top: 12px; text-align: center; padding: 15px; font-size: 16px; font-weight: 600; color: var(--accent); background: var(--s2); border-radius: 13px; }
  .dialog { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); width: 460px; background: var(--s1); border: 1px solid var(--hair); border-radius: 20px; padding: 24px 20px 20px; display: flex; flex-direction: column; box-shadow: 0 40px 120px oklch(0 0 0 / 0.6); }
  .dialog .sheet-title { font-size: 21px; }
  .dialog-actions { display: flex; gap: 12px; margin-top: 16px; }
  .btn { flex: 1; text-align: center; padding: 13px; border-radius: 12px; font-size: 15px; font-weight: 600; }
  .btn-secondary { background: var(--s2); color: var(--tx1); border: 1px solid var(--hair); }
  .btn-primary { background: var(--accent); color: var(--on-accent); box-shadow: var(--shadow); }
`;

const ACCT_CSS = `
  .device { background: var(--bg); color: var(--tx1); overflow: hidden; box-shadow: 0 50px 130px oklch(0 0 0 / 0.55); border: 1px solid var(--hair); }
  .iphone { width: 393px; height: 852px; border-radius: 46px; }
  .ipad { width: 1180px; height: 820px; border-radius: 26px; }
  .bolt { fill: var(--accent); }
  .col { display: flex; flex-direction: column; }
  .statusbar { height: 52px; display: flex; align-items: center; justify-content: space-between; padding: 0 30px 0 34px; font-size: 15px; font-weight: 600; flex: none; }
  .statusbar .glyphs { display: flex; align-items: center; gap: 6px; }
  .statusbar .glyphs svg { width: 17px; height: 17px; }
  .phone-body { flex: 1; display: flex; flex-direction: column; padding: 4px 18px 0; gap: 18px; overflow: hidden; }
  .lg-head { display: flex; align-items: center; justify-content: space-between; }
  .lg-title { font-size: 32px; font-weight: 700; letter-spacing: -0.02em; }
  .icon-btn { width: 38px; height: 38px; border-radius: 50%; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; color: var(--tx2); flex: none; }
  .icon-btn svg { width: 20px; height: 20px; }
  .hint { font-size: 13px; color: var(--tx3); line-height: 1.45; }
  .sec-label { font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--tx3); font-weight: 600; margin-bottom: -6px; }
  .add { display: flex; gap: 10px; align-items: center; }
  .site-input { flex: 1; min-width: 0; display: flex; align-items: center; background: var(--s2); border: 1px solid var(--hair); border-radius: 12px; padding: 12px 14px; color: var(--tx3); font-size: 15px; }
  .add-btn { flex: none; background: var(--accent); color: var(--on-accent); font-size: 15px; font-weight: 600; padding: 12px 18px; border-radius: 12px; box-shadow: var(--shadow); }
  .card-list { background: var(--s1); border: 1px solid var(--hair); border-radius: 16px; overflow: hidden; box-shadow: var(--shadow); }
  .acct-row { display: flex; align-items: center; gap: 13px; padding: 13px 15px; border-top: 1px solid var(--hair); }
  .acct-row:first-child { border-top: none; }
  .monogram { width: 36px; height: 36px; border-radius: 10px; flex: none; background: var(--accent-soft); color: var(--accent); display: flex; align-items: center; justify-content: center; font-size: 16px; font-weight: 700; }
  .acct-host { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .acct-name { font-size: 15px; font-weight: 500; }
  .acct-state { font-size: 11.5px; color: var(--tx3); }
  .signout { font-size: 14px; font-weight: 600; color: var(--accent); flex: none; }
  .danger-btn { text-align: center; padding: 14px; border-radius: 12px; background: var(--s1); border: 1px solid var(--hair); color: var(--error); font-size: 15px; font-weight: 600; }
  .tabbar { flex: none; height: 86px; border-top: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.92); display: flex; padding: 10px 0 22px; margin-top: auto; }
  .tab { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 5px; font-size: 10.5px; font-weight: 500; color: var(--tx3); }
  .tab svg { width: 25px; height: 25px; }
  .tab.active { color: var(--accent); }
  .home-ind { position: absolute; bottom: 8px; left: 50%; transform: translateX(-50%); width: 134px; height: 5px; border-radius: 3px; background: var(--tx1); opacity: 0.5; }
  .ipad-layout { display: flex; height: 100%; }
  .sidebar { width: 260px; flex: none; border-right: 1px solid var(--hair); background: oklch(0.19 0.007 260 / 0.6); padding: 26px 16px; display: flex; flex-direction: column; gap: 6px; }
  .side-brand { display: flex; align-items: center; gap: 12px; padding: 6px 12px 22px; }
  .side-tile { width: 40px; height: 40px; border-radius: 11px; background: var(--s2); border: 1px solid var(--hair); display: flex; align-items: center; justify-content: center; box-shadow: var(--shadow); }
  .side-tile svg { width: 26px; height: 26px; }
  .side-word { font-size: 20px; font-weight: 700; letter-spacing: -0.02em; }
  .nav { display: flex; align-items: center; gap: 13px; padding: 12px 14px; border-radius: 10px; color: var(--tx2); font-size: 15px; font-weight: 500; }
  .nav svg { width: 20px; height: 20px; }
  .nav.active { background: var(--accent-soft); color: var(--accent); }
  .side-foot { margin-top: auto; }
  .acct-main { flex: 1; min-width: 0; padding: 28px 40px; display: flex; flex-direction: column; gap: 22px; overflow: hidden; }
  .acct-head { display: flex; align-items: center; gap: 14px; }
  .toggle { width: 34px; height: 34px; border-radius: 12px; border: 1px solid var(--hair); background: var(--s1); display: flex; align-items: center; justify-content: center; color: var(--tx2); flex: none; }
  .toggle svg { width: 18px; height: 18px; }
  .acct-title { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; }
  .acct-col { max-width: 640px; display: flex; flex-direction: column; gap: 22px; }
`;

// ---------------------------------------------------------------------------
// Reusable SVG snippets
// ---------------------------------------------------------------------------
const S = {
  glyphs: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M2 15h3v5H2zM7 11h3v9H7zM12 7h3v13h-3zM17 3h3v17h-3z"/></svg><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="2" y="7" width="18" height="10" rx="3"/><rect x="4" y="9" width="12" height="6" rx="1" fill="currentColor" stroke="none"/></svg>`,
  bolt: `<svg viewBox="0 0 100 100"><polygon class="bolt" points="60,4 24,56 47,56 40,96 82,40 55,40"/></svg>`,
  gear: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 00-.1-1l2-1.5-2-3.5-2.4 1a7 7 0 00-1.7-1L16.5 3h-4l-.3 2.5a7 7 0 00-1.7 1l-2.4-1-2 3.5 2 1.5a7 7 0 000 2l-2 1.5 2 3.5 2.4-1a7 7 0 001.7 1l.3 2.5h4l.3-2.5a7 7 0 001.7-1l2.4 1 2-3.5-2-1.5a7 7 0 00.1-1z"/></svg>`,
  dl: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 4v12m0 0l-4-4m4 4l4-4M5 20h14" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  dlTab: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 4v12m0 0l-4-4m4 4l4-4M5 20h14" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  paste: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="8" y="3" width="8" height="4" rx="1"/><path d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h12a2 2 0 002-2V7a2 2 0 00-2-2h-2"/></svg>`,
  play: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>`,
  playOutline: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><polygon points="6 4 20 12 6 20 6 4"/></svg>`,
  libTab: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>`,
  acctTab: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="4"/><path d="M4 20c0-4 4-6 8-6s8 2 8 6"/></svg>`,
  more: `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>`,
  search: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4-4" stroke-linecap="round"/></svg>`,
  share: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M12 16V4m0 0L8 8m4-4l4 4" stroke-linecap="round" stroke-linejoin="round"/><path d="M5 15v3a2 2 0 002 2h10a2 2 0 002-2v-3" stroke-linecap="round"/></svg>`,
  save: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><rect x="4" y="4" width="16" height="16" rx="3"/><path d="M12 8v8m0 0l-3-3m3 3l3-3" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  trash: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-8 0v12a2 2 0 002 2h4a2 2 0 002-2V7" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  check: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M5 13l4 4L19 7" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  menu: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 6h16M4 12h16M4 18h16" stroke-linecap="round"/></svg>`,
};

const iphoneStatus = `<div class="statusbar"><span class="num">9:41</span><span class="glyphs">${S.glyphs}</span></div>`;
const ipadBrand = `<div class="side-brand"><div class="side-tile">${S.bolt}</div><div class="side-word">Keraunos</div></div>`;
const ipadNav = (active) => `
  <div class="nav${active==='dl'?' active':''}">${S.dlTab}Download</div>
  <div class="nav${active==='lib'?' active':''}">${S.libTab}Library</div>
  <div class="nav${active==='acct'?' active':''}">${S.acctTab}Accounts</div>
  <div class="side-foot"><div class="nav">${S.gear}Settings</div></div>`;
const phoneTabs = (active) => `<div class="tabbar">
  <div class="tab${active==='dl'?' active':''}">${S.dlTab}Download</div>
  <div class="tab${active==='lib'?' active':''}">${S.libTab}Library</div>
  <div class="tab${active==='acct'?' active':''}">${S.acctTab}Accounts</div>
</div>`;

// ---------------------------------------------------------------------------
// Screen markup (genericized content)
// ---------------------------------------------------------------------------
const HOME_IPHONE = `
<div class="device iphone col">
  ${iphoneStatus}
  <div class="phone-body">
    <div class="phone-head">
      <div class="phone-title">${S.bolt}Keraunos</div>
      <div class="icon-btn">${S.gear}</div>
    </div>
    <div class="hero">
      <div class="hero-label">Paste a video link</div>
      <div class="input"><span class="field">https://example.com/watch?v=…</span><span class="paste-btn">${S.paste}Paste</span></div>
      <button class="btn-primary">${S.dl}Download</button>
    </div>
    <div class="col" style="gap:12px">
      <div class="sec-label"><span>Downloading</span></div>
      <div class="card">
        <div class="card-top">
          <div class="thumb">${S.playOutline}</div>
          <div class="card-meta"><div class="card-title">Aurora timelapse — 4K HDR</div><div class="card-sub">example.com · 1080p</div></div>
          <div class="size-badge num">48.2 MB</div>
        </div>
        <div class="track"><div class="fill" style="width:62%"></div></div>
        <div class="card-foot"><span class="rate num">62% · 3.1 MB/s</span><span class="mini-cancel">Cancel</span></div>
      </div>
    </div>
    <div class="col" style="gap:2px">
      <div class="sec-label" style="margin-bottom:8px"><span>Recent</span><span style="color:var(--accent)">See all</span></div>
      <div class="list">
        <div class="row"><div class="row-thumb">${S.play}</div><div class="row-meta"><div class="row-title">Live set — Warehouse Mix</div><div class="row-sub num">720p · 58:20 · 612 MB</div></div><span class="row-play">${S.play}</span></div>
        <div class="row"><div class="row-thumb">${S.play}</div><div class="row-meta"><div class="row-title">Coding tips — 100 seconds</div><div class="row-sub num">1080p · 1:41 · 22 MB</div></div><span class="row-play">${S.play}</span></div>
      </div>
    </div>
  </div>
  ${phoneTabs('dl')}
  <div class="home-ind"></div>
</div>`;

const QUALITY_IPHONE = `
<div class="device iphone">
  <div class="backdrop-home">
    <div class="bh-title">Download</div>
    <div class="bh-block" style="height:120px"></div>
    <div class="bh-block"></div>
  </div>
  <div class="scrim"></div>
  <div class="sheet">
    <div class="grabber"></div>
    <div class="sheet-title">Choose quality</div>
    <div class="sheet-sub">Aurora timelapse — 4K HDR</div>
    <div class="opt"><div class="opt-main"><div class="opt-res">2160p <span class="badge4k">4K</span></div><div class="opt-sub">MP4 · HEVC</div></div><span class="opt-size num">210 MB</span></div>
    <div class="opt sel"><div class="opt-main"><div class="opt-res">1080p <span class="tag">Recommended</span></div><div class="opt-sub">MP4 · H.264</div></div><span class="opt-size num">48 MB</span><span class="check">${S.check}</span></div>
    <div class="opt"><div class="opt-main"><div class="opt-res">720p</div><div class="opt-sub">MP4 · H.264</div></div><span class="opt-size num">26 MB</span></div>
    <div class="opt"><div class="opt-main"><div class="opt-res">480p</div><div class="opt-sub">MP4 · H.264</div></div><span class="opt-size num">12 MB</span></div>
    <div class="divider"></div>
    <div class="opt"><div class="opt-main"><div class="opt-res">Audio only</div><div class="opt-sub">M4A · AAC</div></div><span class="opt-size num">4 MB</span></div>
    <div class="sheet-cancel">Cancel</div>
  </div>
</div>`;

const libRow = (title, sub, dur) => `<div class="row"><div class="row-thumb">${S.play}<span class="dur num">${dur}</span></div><div class="row-meta"><div class="row-title">${title}</div><div class="row-sub num">${sub}</div></div><span class="row-more">${S.more}</span></div>`;

const LIBRARY_IPHONE = `
<div class="device iphone col">
  ${iphoneStatus}
  <div class="phone-body">
    <div class="lg-head"><div class="lg-title">Library</div><div class="icon-btn">${S.gear}</div></div>
    <div class="search">${S.search}Search downloads</div>
    <div class="seg"><div class="seg-item on">All</div><div class="seg-item">Video</div><div class="seg-item">Audio</div></div>
    <div class="list">
      ${libRow('Aurora timelapse — 4K HDR', '1080p · 48 MB', '4:12')}
      ${libRow('Live set — Warehouse Mix', '720p · 612 MB', '58:20')}
      ${libRow('Coding tips — 100 seconds', '1080p · 22 MB', '1:41')}
    </div>
  </div>
  ${phoneTabs('lib')}
  <div class="home-ind"></div>
</div>`;

const SHARE_IPHONE = `
<div class="device iphone col">
  ${iphoneStatus}
  <div class="phone-body">
    <div class="lg-head"><div class="lg-title">Library</div><div class="icon-btn">${S.gear}</div></div>
    <div class="search">${S.search}Search downloads</div>
    <div class="seg"><div class="seg-item on">All</div><div class="seg-item">Video</div><div class="seg-item">Audio</div></div>
    <div class="list">
      ${libRow('Aurora timelapse — 4K HDR', '1080p · 48 MB', '4:12')}
      ${libRow('Live set — Warehouse Mix', '720p · 612 MB', '58:20')}
      ${libRow('Coding tips — 100 seconds', '1080p · 22 MB', '1:41')}
    </div>
  </div>
  ${phoneTabs('lib')}
  <div class="home-ind"></div>
  <div class="ctx-scrim"></div>
  <div class="ctx-wrap">
    <div class="ctx-preview"><div class="row-thumb">${S.play}</div><div><div class="p-title">Aurora timelapse — 4K HDR</div><div class="p-sub num">1080p · 4:12 · 48 MB</div></div></div>
    <div class="ctx-menu">
      <div class="ctx-item">Play${S.play}</div>
      <div class="ctx-item">Share…${S.share}</div>
      <div class="ctx-item">Save to Photos${S.save}</div>
      <div class="ctx-item danger">Delete${S.trash}</div>
    </div>
  </div>
</div>`;

const ACCOUNTS_IPHONE = `
<div class="device iphone col">
  ${iphoneStatus}
  <div class="phone-body">
    <div class="lg-head"><div class="lg-title">Accounts</div><div class="icon-btn">${S.gear}</div></div>
    <div class="hint">Sign in to a site to download private, members-only, or age-restricted videos. Keraunos only stores the site's login cookies on this device.</div>
    <div class="sec-label">Add a site</div>
    <div class="add"><div class="site-input">site, e.g. example.com</div><div class="add-btn">Sign in</div></div>
    <div class="sec-label">Signed in</div>
    <div class="card-list">
      <div class="acct-row"><div class="monogram">E</div><div class="acct-host"><div class="acct-name">example.com</div><div class="acct-state">Signed in</div></div><div class="signout">Sign out</div></div>
      <div class="acct-row"><div class="monogram">C</div><div class="acct-host"><div class="acct-name">clips.example</div><div class="acct-state">Signed in</div></div><div class="signout">Sign out</div></div>
      <div class="acct-row"><div class="monogram">S</div><div class="acct-host"><div class="acct-name">stream.example</div><div class="acct-state">Signed in</div></div><div class="signout">Sign out</div></div>
    </div>
    <div class="danger-btn">Sign out of everything</div>
  </div>
  ${phoneTabs('acct')}
  <div class="home-ind"></div>
</div>`;

const dlCard = (title, sub, dur, sel) => `<div class="dl-card${sel?' sel':''}"><div class="cover">${S.play.replace('class="', 'class="play ') || S.play}<span class="dur num">${dur}</span></div><div class="dl-body"><div class="dl-title">${title}</div><div class="dl-sub num">${sub}</div></div></div>`;

const HOME_IPAD = `
<div class="device ipad">
  <div class="ipad-layout">
    <div class="sidebar">${ipadBrand}${ipadNav('dl')}</div>
    <div class="ipad-content">
      <div class="content-head"><div class="content-title">Download</div></div>
      <div class="hero ipad-hero">
        <div class="hero-label">Paste a video link</div>
        <div class="hero-inner">
          <div class="input" style="flex:1"><span class="field">https://example.com/watch?v=…</span><span class="paste-btn">${S.paste}Paste</span></div>
          <button class="btn-primary">${S.dl}Download</button>
        </div>
      </div>
      <div class="col" style="gap:16px">
        <div class="sec-label"><span>Library</span><span style="color:var(--accent)">See all</span></div>
        <div class="dl-grid">
          <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg><div class="cover-track"><div class="cover-fill" style="width:62%"></div></div></div><div class="dl-body"><div class="dl-title">Aurora timelapse — 4K HDR</div><div class="dl-sub num">Downloading · 62% · 3.1 MB/s</div></div></div>
          <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></div><div class="dl-body"><div class="dl-title">Live set — Warehouse Mix</div><div class="dl-sub num">720p · 58:20 · 612 MB</div></div></div>
          <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></div><div class="dl-body"><div class="dl-title">Coding tips — 100 seconds</div><div class="dl-sub num">1080p · 1:41 · 22 MB</div></div></div>
          <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></div><div class="dl-body"><div class="dl-title">Nebula documentary</div><div class="dl-sub num">1080p · 42:08 · 1.2 GB</div></div></div>
          <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></div><div class="dl-body"><div class="dl-title">Interview — full cut</div><div class="dl-sub num">480p · 24:11 · 190 MB</div></div></div>
          <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></div><div class="dl-body"><div class="dl-title">Lofi mix — audio only</div><div class="dl-sub num">Audio · 1:02:00 · 58 MB</div></div></div>
        </div>
      </div>
    </div>
  </div>
</div>`;

const LIBRARY_IPAD = `
<div class="device ipad">
  <div class="ipad-layout">
    <div class="sidebar">${ipadBrand}${ipadNav('lib')}</div>
    <div class="lib-main">
      <div class="lib-head">
        <div class="toggle">${S.menu}</div>
        <div class="lib-title">Library</div>
        <div class="search lib-search">${S.search}Search</div>
      </div>
      <div class="dl-grid">
        <div class="dl-card sel"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg><span class="dur num">58:20</span></div><div class="dl-body"><div class="dl-title">Live set — Warehouse Mix</div><div class="dl-sub num">720p · 612 MB</div></div></div>
        <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg><span class="dur num">4:12</span></div><div class="dl-body"><div class="dl-title">Aurora timelapse — 4K HDR</div><div class="dl-sub num">1080p · 48 MB</div></div></div>
        <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg><span class="dur num">1:41</span></div><div class="dl-body"><div class="dl-title">Coding tips — 100 seconds</div><div class="dl-sub num">1080p · 22 MB</div></div></div>
        <div class="dl-card"><div class="cover"><svg class="play" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg><span class="dur num">42:08</span></div><div class="dl-body"><div class="dl-title">Nebula documentary</div><div class="dl-sub num">1080p · 1.2 GB</div></div></div>
      </div>
    </div>
    <div class="detail-pane">
      <div class="player">${S.play}</div>
      <div class="detail-title">Live set — Warehouse Mix</div>
      <div class="detail-src num">example.com · saved Jul 12</div>
      <div class="meta-chips"><span class="mchip num">720p</span><span class="mchip num">58:20</span><span class="mchip num">612 MB</span><span class="mchip">MP4</span></div>
      <div class="detail-actions">
        <div class="play-btn">${S.play}Play</div>
        <div class="action-row">
          <div class="icon-action">${S.share}Share</div>
          <div class="icon-action">${S.save}Save</div>
          <div class="icon-action danger">${S.trash}Delete</div>
        </div>
      </div>
    </div>
  </div>
</div>`;

const QUALITY_IPAD = `
<div class="device ipad">
  <div class="backdrop-home" style="padding:40px 48px">
    <div class="bh-title">Download</div>
    <div class="bh-block" style="height:96px;max-width:720px"></div>
    <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:18px;opacity:0.5"><div class="bh-block" style="height:150px"></div><div class="bh-block" style="height:150px"></div><div class="bh-block" style="height:150px"></div></div>
  </div>
  <div class="scrim"></div>
  <div class="dialog">
    <div class="sheet-title">Choose quality</div>
    <div class="sheet-sub">Aurora timelapse — 4K HDR</div>
    <div class="opt"><div class="opt-main"><div class="opt-res">2160p <span class="badge4k">4K</span></div><div class="opt-sub">MP4 · HEVC</div></div><span class="opt-size num">210 MB</span></div>
    <div class="opt sel"><div class="opt-main"><div class="opt-res">1080p <span class="tag">Recommended</span></div><div class="opt-sub">MP4 · H.264</div></div><span class="opt-size num">48 MB</span><span class="check">${S.check}</span></div>
    <div class="opt"><div class="opt-main"><div class="opt-res">720p</div><div class="opt-sub">MP4 · H.264</div></div><span class="opt-size num">26 MB</span></div>
    <div class="opt"><div class="opt-main"><div class="opt-res">480p</div><div class="opt-sub">MP4 · H.264</div></div><span class="opt-size num">12 MB</span></div>
    <div class="divider"></div>
    <div class="opt"><div class="opt-main"><div class="opt-res">Audio only</div><div class="opt-sub">M4A · AAC</div></div><span class="opt-size num">4 MB</span></div>
    <div class="dialog-actions"><div class="btn btn-secondary">Cancel</div><div class="btn btn-primary">Download 1080p</div></div>
  </div>
</div>`;

// ---------------------------------------------------------------------------
// Screen registry
// ---------------------------------------------------------------------------
const IPHONE = [1320, 2868];      // 6.9"  (also emitted at 6.5")
const IPHONE65 = [1242, 2688];
const IPAD = [2752, 2064];        // 13" landscape

const screens = [
  { key: 'home',      dev: 'iphone', css: HOME_CSS, inner: HOME_IPHONE,     h1: 'Paste a link.<br>Get the video.',      sub: 'Fast, native downloads — no browser, no clutter.' },
  { key: 'quality',   dev: 'iphone', css: QP_CSS,   inner: QUALITY_IPHONE,  h1: 'Your quality,<br>your call.',           sub: 'From audio-only to <span class="accent">4K HDR</span>.' },
  { key: 'library',   dev: 'iphone', css: LIB_CSS,  inner: LIBRARY_IPHONE,  h1: 'Every download<br>in one place.',       sub: 'Search, sort, and play offline.' },
  { key: 'share',     dev: 'iphone', css: LIB_CSS,  inner: SHARE_IPHONE,    h1: 'Play, share, or<br>save to Photos.',     sub: 'Your library, your rules.' },
  { key: 'accounts',  dev: 'iphone', css: ACCT_CSS, inner: ACCOUNTS_IPHONE, h1: 'Sign in to reach<br>your own content.',  sub: 'Cookies stay on your device.' },
  { key: 'home',      dev: 'ipad',   css: HOME_CSS, inner: HOME_IPAD,       h1: 'Paste a link. Get the video.',          sub: 'Fast, native downloads on iPad.' },
  { key: 'library',   dev: 'ipad',   css: LIB_CSS,  inner: LIBRARY_IPAD,    h1: 'Your whole library, one tap away.',     sub: 'Play, share, or save to Photos.' },
  { key: 'quality',   dev: 'ipad',   css: QP_CSS,   inner: QUALITY_IPAD,    h1: 'Your quality, your call.',              sub: 'From audio-only to 4K HDR.' },
];

function layout(screen, W, H) {
  const dev = screen.dev;
  const dw = dev === 'iphone' ? 393 : 1180;
  const dh = dev === 'iphone' ? 852 : 820;
  const twoLine = /<br>/.test(screen.h1);
  const h1 = Math.round(dev === 'iphone' ? W * 0.075 : W * 0.040);
  const sub = Math.round(h1 * 0.42);
  const gap = Math.round(h1 * 0.34);
  const capTop = Math.round(H * (dev === 'iphone' ? 0.065 : 0.085));
  const lineF = twoLine ? 2.05 : 1.15;
  const capBottom = capTop + Math.round(h1 * lineF) + gap + sub + Math.round(H * 0.02);
  const region = H - capBottom;
  let scale, bias;
  if (dev === 'iphone') {
    scale = Math.min((W * 0.74) / dw, (region * 0.94) / dh);
    bias = 0.18;
  } else {
    scale = Math.min((W * 0.70) / dw, (region * 0.94) / dh);
    bias = 0.32;
  }
  const top = Math.round(capBottom + (region - dh * scale) * bias);
  return { scale, h1, sub, gap, capTop, top };
}

function pageLayout(screen, W, H) { return layout(screen, W, H); }

function page(screen, W, H) {
  const L = layout(screen, W, H);
  return `<!doctype html><html><head><meta charset="utf-8">
<style>
${POSTER_CSS}
${screen.css}
</style></head><body>
<div class="poster" style="width:${W}px;height:${H}px">
  <div class="p-caption" style="padding:${L.capTop}px 8% 0;gap:${L.gap}px">
    <h1 style="font-size:${L.h1}px">${screen.h1}</h1>
    <p style="font-size:${L.sub}px">${screen.sub}</p>
  </div>
  <div class="p-stage" style="top:${L.top}px;transform:translateX(-50%) scale(${L.scale.toFixed(4)})">
    ${screen.inner}
  </div>
</div>
</body></html>`;
}

const outDir = new URL('./out/', import.meta.url);
const manifest = [];
for (const sc of screens) {
  const sizes = sc.dev === 'iphone' ? [['6.9', ...IPHONE], ['6.5', ...IPHONE65]] : [['13', ...IPAD]];
  for (const [label, W, H] of sizes) {
    const name = `${String(manifest.length + 1).padStart(2, '0')}_${sc.key}_${sc.dev}${label.replace('.', '')}__${W}x${H}.html`;
    writeFileSync(new URL(name, outDir), page(sc, W, H));
    manifest.push(name);
  }
}
console.log(manifest.join('\n'));
console.log(`\n${manifest.length} poster HTML files written.`);
