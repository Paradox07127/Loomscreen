/* Shared window chrome + sidebar injector for the LiveWallpaper UI mockups.
   Works on file:// (no fetch). Pages declare:
   <div class="titlebar" data-seg="Video,HTML,Shader,Scene|Scene"></div>
   <aside class="sidebar" data-active="mpg"></aside>  */
const ICONS = {
  display:'<rect x="2" y="3" width="16" height="11" rx="1.5"/><path d="M7 17h6M10 14v3"/>',
  bookmark:'<path d="M5 3h10v15l-5-3-5 3z"/>',
  sparkles:'<path d="M10 2l1.6 4.4L16 8l-4.4 1.6L10 14 8.4 9.6 4 8l4.4-1.6z"/>',
  cube:'<path d="M10 2l7 4v8l-7 4-7-4V6z"/><path d="M3 6l7 4 7-4M10 10v8"/>',
  wrench:'<path d="M13 3a4 4 0 00-5 5L3 13l1.5 1.5L9.5 9.5a4 4 0 005-5l-2.2 2.2-1.6-.4-.4-1.6z"/>',
  gear:'<circle cx="10" cy="10" r="3"/><path d="M10 2v2M10 16v2M2 10h2M16 10h2M4.2 4.2l1.4 1.4M14.4 14.4l1.4 1.4M15.8 4.2l-1.4 1.4M5.6 14.4l-1.4 1.4"/>',
  plus:'<path d="M10 4v12M4 10h12"/>',
  refresh:'<path d="M16 6a7 7 0 10.8 6"/><path d="M16 3v3h-3"/>',
  sidebar:'<rect x="2" y="3" width="16" height="14" rx="2"/><path d="M8 3v14"/>',
  bookmarkbar:'<path d="M6 3h8v14l-4-2.5L6 17z"/>',
  search:'<circle cx="9" cy="9" r="5"/><path d="M13 13l4 4"/>',
  star:'<path d="M10 2l2.4 5 5.6.6-4 4 1 5.4L10 14l-5 3 1-5.4-4-4 5.6-.6z" fill="currentColor" stroke="none"/>',
  chevron:'<path d="M7 5l5 5-5 5"/>',
  info:'<circle cx="10" cy="10" r="7.5"/><path d="M10 9v5M10 6.2v.2"/>',
  globe:'<circle cx="10" cy="10" r="7.5"/><path d="M2.5 10h15M10 2.5c2.5 2 2.5 13 0 15M10 2.5c-2.5 2-2.5 13 0 15"/>',
  power:'<path d="M10 3v7M5.5 6a6 6 0 109 0"/>',
  lock:'<rect x="5" y="9" width="10" height="7" rx="1.5"/><path d="M7 9V7a3 3 0 016 0v2"/>',
  bolt:'<path d="M11 2L4 11h5l-1 7 7-9h-5z" fill="currentColor" stroke="none"/>',
  battery:'<rect x="2" y="6" width="13" height="8" rx="1.5"/><path d="M17 9v2"/>',
  game:'<rect x="2" y="6" width="16" height="9" rx="3"/><path d="M6 9v3M4.5 10.5h3M13 10h.1M15 12h.1"/>',
  play:'<circle cx="10" cy="10" r="7.5"/><path d="M8 7l5 3-5 3z" fill="currentColor" stroke="none"/>',
  audio:'<path d="M4 8v4h3l4 3V5L7 8z"/><path d="M13 8a3 3 0 010 4"/>',
  cursor:'<path d="M5 3l11 5-4.5 1.5L9 14z"/>',
  sliders:'<path d="M4 6h8M14 6h2M4 14h2M8 14h8"/><circle cx="13" cy="6" r="1.6"/><circle cx="7" cy="14" r="1.6"/>',
  paint:'<rect x="3" y="3" width="14" height="11" rx="2"/><path d="M3 11l4-3 3 2 3-3 4 3"/>',
};
const svg = (n, s = 16) => `<svg viewBox="0 0 20 20" width="${s}" height="${s}" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${ICONS[n]||''}</svg>`;

function sidebar(active) {
  const item = (key, icon, label, dev) =>
    `<div class="side-item ${active === key ? 'active' : ''}"><span class="ic">${svg(icon, 15)}</span>${label}${dev ? '<span class="dev">DEV</span>' : ''}</div>`;
  return `
    <div class="side-section">
      <div class="side-head">Displays</div>
      ${item('mpg', 'display', 'MPG321CX OLED')}
      ${item('benq', 'display', 'BenQ RD280U')}
    </div>
    <div class="side-section">
      <div class="side-head">Library</div>
      ${item('bookmarks', 'bookmark', 'Bookmarks')}
      ${item('aerials', 'sparkles', 'Apple Aerials')}
      ${item('workshop', 'cube', 'Steam Workshop')}
      ${item('dev', 'wrench', 'Developer Tools', true)}
    </div>
    <div class="usage">
      <div class="seg2"><b>All</b><b class="active">App</b></div>
      <div class="gauges">
        <div class="gauge"><div class="ring" style="--gv:8%;--gc:var(--gauge-low)"><i>1%</i></div><span>CPU</span></div>
        <div class="gauge"><div class="ring" style="--gv:14%;--gc:var(--gauge-med)"><i>14%</i></div><span>GPU</span></div>
        <div class="gauge"><div class="ring" style="--gv:4%;--gc:var(--gauge-low)"><i>0%</i></div><span>RAM</span></div>
        <div class="gauge"><div class="ring" style="--gv:30%;--gc:var(--gauge-low)"><i>AC</i></div><span>PWR</span></div>
      </div>
      <div class="foot"><span>0/2 · Normal</span><span>271 MB</span></div>
    </div>`;
}

function titlebar(el) {
  const seg = el.dataset.seg;
  let center = '';
  if (seg) {
    const [opts, act] = seg.split('|');
    center = `<div class="seg">${opts.split(',').map(o => `<b class="${o === act ? 'active' : ''}">${o}</b>`).join('')}</div>`;
  }
  el.innerHTML =
    `<div class="traffic"><i class="r"></i><i class="y"></i><i class="g"></i></div>
     <div class="tb-icon">${svg('sidebar')}</div>
     <div class="tb-icon">${svg('gear')}</div>
     <div class="tb-icon">${svg('plus')}</div>
     <div class="tb-icon">${svg('refresh')}</div>
     <div class="tb-spacer"></div>${center}<div class="tb-spacer"></div>
     <div class="tb-icon">${svg('bookmarkbar')}</div>`;
}

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('.titlebar').forEach(titlebar);
  document.querySelectorAll('.sidebar').forEach(sb => sb.innerHTML = sidebar(sb.dataset.active));
  // expose icon helper for inline page use
  window.svg = svg;
  document.querySelectorAll('[data-ic]').forEach(n => n.innerHTML = svg(n.dataset.ic, +n.dataset.s || 16));
});
