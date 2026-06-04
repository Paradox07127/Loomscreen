#!/usr/bin/env python3
"""
Divergence Report Generator (Phase E)
Renders a per-scene WPE <-> Metal divergence report as a self-contained HTML file.
"""

import argparse
import json
import os
import sys

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WPE ↔ Metal Divergence Report</title>
  <style>
    :root {
      --bg-app: #0b0f19;
      --bg-card: #161e2e;
      --bg-card-header: #1f293d;
      --border-color: #243049;
      --text-primary: #f3f4f6;
      --text-secondary: #9ca3af;
      --text-muted: #6b7280;
      
      --color-green: #10b981;
      --color-green-bg: rgba(16, 185, 129, 0.1);
      --color-red: #ef4444;
      --color-red-bg: rgba(239, 68, 68, 0.1);
      --color-amber: #f59e0b;
      --color-amber-bg: rgba(245, 158, 11, 0.1);
      --color-purple: #8b5cf6;
      --color-purple-bg: rgba(139, 92, 246, 0.1);
      --color-blue: #3b82f6;
      --color-blue-bg: rgba(59, 130, 246, 0.1);
      --color-grey: #6b7280;
      --color-grey-bg: rgba(107, 114, 128, 0.1);
      
      --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    }

    body {
      background-color: var(--bg-app);
      color: var(--text-primary);
      font-family: var(--font-sans);
      margin: 0;
      padding: 24px;
      line-height: 1.5;
    }

    .container {
      max-width: 1400px;
      margin: 0 auto;
    }

    header {
      margin-bottom: 24px;
      border-bottom: 1px solid var(--border-color);
      padding-bottom: 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 16px;
    }

    .header-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 16px;
      margin-bottom: 24px;
    }

    .card {
      background-color: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      padding: 16px;
      box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
    }

    .card-title {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--text-secondary);
      margin-bottom: 8px;
      font-weight: 600;
    }

    .card-value {
      font-size: 24px;
      font-weight: 700;
      font-family: var(--font-mono);
    }

    .badge {
      display: inline-flex;
      align-items: center;
      padding: 4px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
    }

    .badge-green { background: var(--color-green-bg); color: var(--color-green); border: 1px solid rgba(16, 185, 129, 0.3); }
    .badge-red { background: var(--color-red-bg); color: var(--color-red); border: 1px solid rgba(239, 68, 68, 0.3); }
    .badge-amber { background: var(--color-amber-bg); color: var(--color-amber); border: 1px solid rgba(245, 158, 11, 0.3); }
    .badge-purple { background: var(--color-purple-bg); color: var(--color-purple); border: 1px solid rgba(139, 92, 246, 0.3); }
    .badge-blue { background: var(--color-blue-bg); color: var(--color-blue); border: 1px solid rgba(59, 130, 246, 0.3); }
    .badge-grey { background: var(--color-grey-bg); color: var(--text-secondary); border: 1px solid rgba(107, 114, 128, 0.3); }

    .timeline-container {
      margin-bottom: 24px;
    }

    .timeline-cells {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 12px;
    }

    .timeline-cell {
      flex: 1 1 65px;
      min-width: 65px;
      height: 52px;
      border-radius: 6px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      font-family: var(--font-mono);
      font-size: 11px;
      cursor: pointer;
      transition: all 0.2s ease;
      user-select: none;
      position: relative;
      border: 1px solid var(--border-color);
    }

    .timeline-cell:hover {
      transform: translateY(-2px);
      filter: brightness(1.2);
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
    }

    .timeline-cell .cell-label {
      font-size: 9px;
      color: var(--text-secondary);
      margin-bottom: 2px;
    }

    .timeline-cell .cell-val {
      font-weight: 700;
      font-size: 12px;
    }

    .timeline-matched {
      background-color: var(--color-green-bg);
      color: var(--color-green);
      border-color: rgba(16, 185, 129, 0.3);
    }

    .timeline-first-diverged {
      background-color: var(--color-red-bg);
      color: var(--color-red);
      border: 2px solid var(--color-red);
      box-shadow: 0 0 12px rgba(239, 68, 68, 0.4);
    }

    .timeline-suppressed {
      background-color: var(--color-grey-bg);
      color: var(--text-secondary);
      border-color: rgba(107, 114, 128, 0.3);
    }

    .timeline-particle {
      background-color: var(--color-purple-bg);
      color: var(--color-purple);
      border-color: rgba(139, 92, 246, 0.3);
    }

    .timeline-amber {
      background-color: var(--color-amber-bg);
      color: var(--color-amber);
      border-color: rgba(245, 158, 11, 0.3);
    }

    .timeline-default {
      background-color: var(--bg-card);
      color: var(--text-secondary);
    }

    .divergence-banner {
      background: linear-gradient(135deg, rgba(239, 68, 68, 0.15) 0%, rgba(239, 68, 68, 0.05) 100%);
      border: 1px solid var(--color-red);
      border-left: 6px solid var(--color-red);
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 24px;
    }

    .banner-title {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 18px;
      font-weight: 700;
      color: var(--color-red);
      margin-bottom: 12px;
    }

    .banner-code {
      background-color: rgba(0, 0, 0, 0.3);
      padding: 8px 12px;
      border-radius: 4px;
      font-family: var(--font-mono);
      font-size: 14px;
      border: 1px solid var(--border-color);
      margin: 8px 0;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .copy-btn {
      background: var(--bg-card-header);
      border: 1px solid var(--border-color);
      color: var(--text-primary);
      padding: 4px 8px;
      border-radius: 4px;
      font-size: 11px;
      cursor: pointer;
      transition: all 0.2s;
    }

    .copy-btn:hover {
      background: var(--border-color);
    }

    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 8px;
      font-size: 13px;
    }

    th {
      background-color: var(--bg-card-header);
      color: var(--text-secondary);
      text-align: left;
      padding: 10px 12px;
      font-weight: 600;
      border-bottom: 2px solid var(--border-color);
    }

    td {
      padding: 10px 12px;
      border-bottom: 1px solid var(--border-color);
      vertical-align: top;
    }

    tr:hover td {
      background-color: rgba(255, 255, 255, 0.02);
    }

    .monospace {
      font-family: var(--font-mono);
    }

    details {
      background: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 6px;
      padding: 12px;
      margin-bottom: 16px;
    }

    details summary {
      font-weight: 600;
      cursor: pointer;
      user-select: none;
      color: var(--text-secondary);
    }

    details summary:hover {
      color: var(--text-primary);
    }

    .details-content {
      margin-top: 12px;
    }

    .norm-banner {
      background: var(--color-blue-bg);
      border: 1px solid var(--color-blue);
      border-left: 4px solid var(--color-blue);
      border-radius: 6px;
      padding: 14px;
      margin-bottom: 24px;
      font-size: 13px;
      color: var(--text-primary);
    }

    .pass-section {
      margin-top: 32px;
      border-top: 1px solid var(--border-color);
      padding-top: 24px;
      transition: border-color 0.2s, box-shadow 0.2s;
    }

    .pass-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      background-color: var(--bg-card-header);
      padding: 12px 16px;
      border-radius: 6px 6px 0 0;
      border: 1px solid var(--border-color);
      border-bottom: none;
    }

    .pass-body {
      background-color: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 0 0 6px 6px;
      padding: 16px;
      margin-bottom: 24px;
    }

    .pass-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
      gap: 16px;
      margin-bottom: 16px;
    }

    .visual-diff-placeholder {
      border: 2px dashed var(--border-color);
      background-color: rgba(0, 0, 0, 0.15);
      border-radius: 6px;
      padding: 24px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      min-height: 120px;
    }

    .placeholder-icon {
      color: var(--text-muted);
      margin-bottom: 8px;
    }

    .placeholder-title {
      font-weight: 600;
      font-size: 14px;
      color: var(--text-secondary);
      margin-bottom: 4px;
    }

    .placeholder-text {
      font-size: 12px;
      color: var(--text-muted);
      max-width: 320px;
    }

    .hist-item {
      display: flex;
      align-items: center;
      margin-bottom: 8px;
      font-size: 12px;
    }

    .hist-label {
      width: 120px;
      font-family: var(--font-mono);
      color: var(--text-secondary);
    }

    .hist-bar-container {
      flex-grow: 1;
      background-color: rgba(255, 255, 255, 0.05);
      height: 8px;
      border-radius: 4px;
      overflow: hidden;
      margin: 0 12px;
    }

    .hist-bar {
      background-color: var(--color-blue);
      height: 100%;
      border-radius: 4px;
    }

    .hist-count {
      width: 24px;
      text-align: right;
      font-weight: 600;
      font-family: var(--font-mono);
    }

    .val-mismatch {
      color: var(--color-red) !important;
      background-color: rgba(239, 68, 68, 0.05);
    }

    .val-mismatch td {
      color: #fca5a5 !important;
    }

    .val-match {
      color: var(--color-green) !important;
      background-color: rgba(16, 185, 129, 0.02);
    }

    .val-volatile {
      color: var(--color-amber) !important;
      background-color: rgba(245, 158, 11, 0.02);
    }

    .transpose-badge {
      background: var(--color-amber-bg);
      color: var(--color-amber);
      border: 1px solid rgba(245, 158, 11, 0.3);
      font-size: 10px;
      padding: 1px 4px;
      border-radius: 3px;
      margin-left: 6px;
      display: inline-block;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div>
        <h1 style="margin: 0; font-size: 28px; font-weight: 800; background: linear-gradient(135deg, #ef4444 0%, #3b82f6 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent;">
          WPE ↔ Metal Divergence Pipeline
        </h1>
        <p style="margin: 4px 0 0 0; color: var(--text-secondary); font-size: 14px;">
          Phase E: Divergence & Comparison Report
        </p>
      </div>
      <div style="font-family: var(--font-mono); font-size: 12px; color: var(--text-muted); text-align: right;">
        Generated: <span id="generation-time"></span>
      </div>
    </header>

    <!-- Summary Cards Grid -->
    <div class="header-grid">
      <div class="card">
        <div class="card-title">Scene Identifier</div>
        <div class="card-value" id="val-scene-id">-</div>
      </div>
      <div class="card">
        <div class="card-title">Status</div>
        <div style="margin-top: 4px;" id="val-status">-</div>
      </div>
      <div class="card">
        <div class="card-title">Confidence Rating</div>
        <div class="card-value" id="val-confidence">-</div>
      </div>
      <div class="card" id="card-ssim">
        <div class="card-title">Final SSIM</div>
        <div class="card-value" id="val-ssim">N/A</div>
      </div>
    </div>

    <!-- Main Grid Layout -->
    <div style="display: grid; grid-template-columns: 1fr; gap: 24px; margin-bottom: 24px;">
      <div id="first-divergence-container"></div>
      <div id="normalization-notes-container"></div>
      <div id="timeline-container"></div>
      
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(450px, 1fr)); gap: 24px;">
        <div id="histogram-container"></div>
        <div id="findings-container"></div>
      </div>
    </div>

    <!-- Inspector Section -->
    <div style="margin-top: 40px;" id="inspector-root">
      <h2 style="margin: 0 0 16px 0; font-size: 20px; font-weight: 700;">Detailed Pass Inspector</h2>
      
      <div class="card" style="margin-bottom: 20px; background-color: var(--bg-card-header);">
        <div style="display: flex; flex-wrap: wrap; gap: 16px; align-items: center;">
          <div style="flex-grow: 1; min-width: 250px;">
            <label for="search-input" style="font-size: 11px; font-weight: 600; color: var(--text-secondary); display: block; margin-bottom: 6px; text-transform: uppercase;">Search passes (by shader or name)</label>
            <input type="text" id="search-input" placeholder="e.g. waterwaves, g_Texture2" style="width: 100%; background: var(--bg-app); border: 1px solid var(--border-color); color: var(--text-primary); padding: 8px 12px; border-radius: 4px; font-size: 13px; box-sizing: border-box;" oninput="filterPasses()">
          </div>
          <div style="display: flex; gap: 16px; margin-top: 18px;">
            <label style="display: flex; align-items: center; gap: 8px; font-size: 13px; cursor: pointer; user-select: none;">
              <input type="checkbox" id="mismatch-only" onchange="filterPasses()" style="cursor: pointer;">
              Mismatches Only
            </label>
            <label style="display: flex; align-items: center; gap: 8px; font-size: 13px; cursor: pointer; user-select: none;">
              <input type="checkbox" id="aligned-only" onchange="filterPasses()" style="cursor: pointer;">
              Aligned Passes Only
            </label>
          </div>
        </div>
      </div>

      <div id="inspector-container"></div>
    </div>
  </div>

  <script id="report-data" type="application/json">
{{JSON_DATA}}
  </script>

  <script>
    // Parse trace data safely
    const data = JSON.parse(document.getElementById('report-data').textContent);
    const summary = data.summary || {};
    const wpeTrace = data.wpeTrace || [];
    const macTrace = data.macTrace || [];

    // Map of passes by ordinal for fast O(1) lookup
    const wpePassByOrdinal = {};
    wpeTrace.forEach((p, idx) => {
      const ord = p.ordinal !== undefined ? p.ordinal : idx;
      wpePassByOrdinal[ord] = p;
    });

    const macPassByOrdinal = {};
    macTrace.forEach((p, idx) => {
      const ord = p.ordinal !== undefined ? p.ordinal : idx;
      macPassByOrdinal[ord] = p;
    });

    const volatileRegex = /g_Time|g_Frame|g_DeltaTime|time|frame/i;

    window.onload = function() {
      document.getElementById('generation-time').textContent = new Date().toLocaleString();
      renderReport();
    };

    function renderReport() {
      // Populate Header Grid
      document.getElementById('val-scene-id').textContent = summary.sceneId || 'N/A';
      
      const statusEl = document.getElementById('val-status');
      const status = summary.status || 'unknown';
      let statusBadgeClass = 'badge-grey';
      if (status === 'diverged') statusBadgeClass = 'badge-red';
      if (status === 'matched') statusBadgeClass = 'badge-green';
      statusEl.innerHTML = `<span class="badge ${statusBadgeClass}">${status}</span>`;

      const conf = summary.confidence !== undefined ? summary.confidence : null;
      document.getElementById('val-confidence').textContent = conf !== null ? (conf * 100).toFixed(1) + '%' : 'N/A';

      const ssim = summary.ssimFinal !== undefined ? summary.ssimFinal : null;
      const ssimValEl = document.getElementById('val-ssim');
      if (ssim !== null) {
        ssimValEl.textContent = ssim.toFixed(4);
      } else {
        ssimValEl.textContent = 'N/A';
        ssimValEl.style.color = 'var(--text-muted)';
      }

      // Render Content Blocks
      renderFirstDivergence();
      renderNormalizationNotes();
      renderTimeline();
      renderHistogram();
      renderFindings();
      renderInspector();
    }

    function renderFirstDivergence() {
      const container = document.getElementById('first-divergence-container');
      const fd = summary.firstDivergence;
      if (!fd) {
        container.innerHTML = '';
        return;
      }

      const site = fd.responsibleSite || 'unknown';
      const pinpoint = fd.pinpoint || {};
      const pinType = pinpoint.type || 'unknown';
      const name = pinpoint.name || 'unnamed';
      const varianceType = pinpoint.varianceType || 'unknown';

      let pinpointDetails = '';
      if (pinType === 'texture') {
        const w = pinpoint.wpe || {};
        const m = pinpoint.metal || {};
        pinpointDetails = `
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-top: 12px; background: rgba(0,0,0,0.25); padding: 12px; border-radius: 6px; border: 1px solid var(--border-color);">
            <div>
              <div style="font-size:11px; font-weight:600; color:var(--text-secondary); margin-bottom:4px; text-transform:uppercase; display:flex; align-items:center; gap:4px;">
                <span style="display:inline-block; width:6px; height:6px; border-radius:50%; background:#3b82f6;"></span> WPE Pinpoint
              </div>
              <div class="monospace" style="font-size:12px; line-height: 1.6;">
                Slot: ${w.slot !== undefined ? w.slot : 'N/A'}<br>
                Resource: <span style="color:var(--text-secondary);">${w.resource || 'N/A'}</span><br>
                Dimensions: ${w.width !== undefined ? `${w.width}x${w.height}` : 'N/A'}<br>
                Format: ${w.format || 'N/A'}<br>
                Fallback: ${w.fallback !== undefined ? w.fallback : 'N/A'}
              </div>
            </div>
            <div>
              <div style="font-size:11px; font-weight:600; color:var(--text-secondary); margin-bottom:4px; text-transform:uppercase; display:flex; align-items:center; gap:4px;">
                <span style="display:inline-block; width:6px; height:6px; border-radius:50%; background:#ef4444;"></span> Metal Pinpoint
              </div>
              <div class="monospace" style="font-size:12px; line-height: 1.6;">
                Slot: ${m.slot !== undefined ? m.slot : 'N/A'}<br>
                Resource: <span style="color:var(--text-secondary);">${m.resource || 'N/A'}</span><br>
                Dimensions: ${m.width !== undefined ? `${m.width}x${m.height}` : 'N/A'}<br>
                Format: ${m.format || 'N/A'}<br>
                Fallback: ${m.fallback !== undefined ? m.fallback : 'N/A'}
              </div>
            </div>
          </div>
        `;
      } else {
        pinpointDetails = `
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-top: 12px; background: rgba(0,0,0,0.25); padding: 12px; border-radius: 6px; border: 1px solid var(--border-color);">
            <div>
              <div style="font-size:11px; font-weight:600; color:var(--text-secondary); margin-bottom:4px; text-transform:uppercase;">WPE Value</div>
              <div class="monospace" style="font-size:12px;">
                ${formatValue(pinpoint.wpe)}
              </div>
            </div>
            <div>
              <div style="font-size:11px; font-weight:600; color:var(--text-secondary); margin-bottom:4px; text-transform:uppercase;">Metal Value</div>
              <div class="monospace" style="font-size:12px;">
                ${formatValue(pinpoint.metal)}
              </div>
            </div>
          </div>
        `;
      }

      container.innerHTML = `
        <div class="divergence-banner">
          <div class="banner-title">
            <svg viewBox="0 0 24 24" width="24" height="24" style="fill: var(--color-red);">
              <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/>
            </svg>
            <span>FIRST DIVERGENCE PINPOINTED</span>
          </div>
          <div style="font-size: 14px; margin-bottom: 12px;">
            A divergence of type <strong style="color:var(--color-amber);">${varianceType}</strong> was located in bucket <strong>${fd.bucket}</strong> (Pass ordinal: <strong>${fd.wpePassOrdinal}</strong>, Mac index: <strong>${fd.macPassIndex}</strong>, ID: <strong>${fd.passId || 'N/A'}</strong>, Shader: <strong>${fd.shaderName}</strong>).
          </div>
          <div style="margin-bottom: 8px;">
            <span style="font-size: 11px; color: var(--text-secondary); text-transform: uppercase; font-weight: 600; display: block; margin-bottom: 4px;">Responsible Site (Go Fix Here)</span>
            <div class="banner-code">
              <span style="font-weight:700; font-size:15px; color:#fca5a5;">${site}</span>
              <button class="copy-btn" onclick="copyToClipboard('${site.replace(/\\\\/g, '\\\\\\\\').replace(/'/g, "\\'")}', this)">Copy Path</button>
            </div>
          </div>
          <div>
            <span style="font-size: 11px; color: var(--text-secondary); text-transform: uppercase; font-weight: 600; display: block; margin-bottom: 4px;">Pinpoint Resource: ${name} (${pinType})</span>
            ${pinpointDetails}
          </div>
        </div>
      `;
    }

    function renderNormalizationNotes() {
      const container = document.getElementById('normalization-notes-container');
      const notes = summary.normalizationNotes || [];
      if (notes.length === 0) {
        container.innerHTML = '';
        return;
      }

      const listItems = notes.map(note => `<li>${note}</li>`).join('');
      container.innerHTML = `
        <div class="norm-banner">
          <div style="font-weight: 700; font-size: 14px; margin-bottom: 6px; display: flex; align-items: center; gap: 6px;">
            <svg viewBox="0 0 24 24" width="18" height="18" style="fill: var(--color-blue);">
              <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
            </svg>
            <span>Pipeline Reconciliation Notes</span>
          </div>
          <ul style="margin: 0; padding-left: 20px; line-height: 1.6;">
            ${listItems}
          </ul>
        </div>
      `;
    }

    function getTimelineData() {
      const alignment = summary.alignment || [];
      const passes = summary.passes || [];
      const maxLength = Math.max(alignment.length, passes.length);
      const result = [];
      
      for (let i = 0; i < maxLength; i++) {
        const align = alignment[i] || {};
        const p = passes[i] || {};
        result.push({
          index: i,
          wpe: align.wpe !== undefined ? align.wpe : (p.wpe !== undefined ? p.wpe : null),
          mac: align.mac !== undefined ? align.mac : (p.mac !== undefined ? p.mac : null),
          status: align.status || p.status || 'unknown',
          wpeTopology: align.wpeTopology || p.topology || 'unknown',
          cost: align.cost !== undefined ? align.cost : (p.cost !== undefined ? p.cost : null),
          bucket: align.bucket || p.bucket || null,
          reason: p.reason || '',
          ssim: p.ssim !== undefined ? p.ssim : null
        });
      }
      return result;
    }

    function getPassColorClass(cell, idx, list) {
      const fd = summary.firstDivergence;
      const isFirst = fd && cell.wpe === fd.wpePassOrdinal && cell.mac === fd.macPassIndex;
      
      if (isFirst) {
        return 'timeline-first-diverged';
      }
      if (cell.status === 'matched') {
        return 'timeline-matched';
      }
      
      const isParticle = (cell.status === 'deleted' || cell.bucket === 'puppet+particle') && 
                         (cell.wpeTopology === 'pointlist' || cell.wpeTopology === 'point');
      if (isParticle) {
        return 'timeline-particle';
      }
      
      if (cell.status === 'diverged' || cell.status === 'unverified') {
        return 'timeline-suppressed';
      }
      
      if (cell.status === 'deleted' || cell.status === 'skipped_on_mac' || cell.status === 'skipped' || cell.status === 'inserted') {
        return 'timeline-amber';
      }

      return 'timeline-default';
    }

    // Badge variant of getPassColorClass: maps an alignment entry's status to a
    // badge-* class, used by the per-pass inspector header.
    function getPassBadgeClass(entry) {
      const fd = summary.firstDivergence;
      const isFirst = fd && entry.wpe === fd.wpePassOrdinal && entry.mac === fd.macPassIndex;
      if (isFirst) return 'badge-red';
      if (entry.status === 'matched') return 'badge-green';
      const isParticle = (entry.status === 'deleted' || entry.bucket === 'puppet+particle') &&
                         (entry.wpeTopology === 'pointlist' || entry.wpeTopology === 'point');
      if (isParticle) return 'badge-purple';
      if (entry.status === 'diverged') return 'badge-red';
      if (entry.status === 'unverified') return 'badge-grey';
      if (entry.status === 'deleted' || entry.status === 'skipped_on_mac' || entry.status === 'skipped' || entry.status === 'inserted') return 'badge-amber';
      return 'badge-grey';
    }

    function renderTimeline() {
      const container = document.getElementById('timeline-container');
      const timelineData = getTimelineData();
      if (timelineData.length === 0) {
        container.innerHTML = '';
        return;
      }

      let cellsHtml = '';
      timelineData.forEach((cell, idx) => {
        const colorClass = getPassColorClass(cell, idx, timelineData);
        const wpeStr = cell.wpe !== null ? cell.wpe : '-';
        const macStr = cell.mac !== null ? cell.mac : '-';
        
        let shader = '';
        const wpeP = wpePassByOrdinal[cell.wpe];
        const macP = macPassByOrdinal[cell.mac];
        if (wpeP && wpeP.shaderName) shader = wpeP.shaderName;
        else if (macP && macP.shaderName) shader = macP.shaderName;

        const tooltip = `Pass Index: ${cell.index}\\nWPE Ordinal: ${wpeStr}\\nMac Ordinal: ${macStr}\\nStatus: ${cell.status}${shader ? '\\nShader: ' + shader : ''}${cell.cost ? '\\nCost: ' + cell.cost : ''}`;
        
        cellsHtml += `
          <div class="timeline-cell ${colorClass}" title="${tooltip}" onclick="scrollToPass(${cell.index})">
            <span class="cell-label">W${wpeStr} M${macStr}</span>
            <span class="cell-val">#${cell.index}</span>
          </div>
        `;
      });

      container.innerHTML = `
        <div class="timeline-container card">
          <div class="card-title">Pass Alignment Timeline (Click cell to jump)</div>
          <div class="timeline-cells">
            ${cellsHtml}
          </div>
        </div>
      `;
    }

    function renderHistogram() {
      const container = document.getElementById('histogram-container');
      const hist = summary.bucketHistogram || {};
      const entries = Object.entries(hist);
      
      if (entries.length === 0) {
        container.innerHTML = '<div class="card text-muted">No histogram metrics present.</div>';
        return;
      }

      const maxVal = Math.max(...entries.map(([_, v]) => v), 1);
      let html = `
        <div class="card" style="height: 100%; box-sizing: border-box;">
          <div class="card-title">Divergence Bucket Histogram</div>
          <div style="margin-top: 16px;">
      `;

      entries.forEach(([bucket, val]) => {
        const pct = (val / maxVal) * 100;
        let color = 'var(--color-blue)';
        if (bucket === 'transpiler') color = 'var(--color-purple)';
        if (bucket === 'FBO') color = 'var(--color-green)';
        if (bucket === 'puppet+particle') color = 'var(--color-amber)';
        
        html += `
          <div class="hist-item">
            <span class="hist-label" title="${bucket}">${bucket}</span>
            <div class="hist-bar-container">
              <div class="hist-bar" style="width: ${pct}%; background-color: ${color};"></div>
            </div>
            <span class="hist-count">${val}</span>
          </div>
        `;
      });

      html += '</div></div>';
      container.innerHTML = html;
    }

    function renderFindings() {
      const container = document.getElementById('findings-container');
      const findings = summary.findings || [];
      
      if (findings.length === 0) {
        container.innerHTML = '<div class="card text-muted">No finding list entries loaded.</div>';
        return;
      }

      const active = findings.filter(f => !f.suppressed);
      const suppressed = findings.filter(f => f.suppressed);

      const makeTable = (list, isSuppressed) => {
        let rows = '';
        list.forEach((f, idx) => {
          const pin = f.pinpoint || {};
          const name = pin.name || 'unnamed';
          const pinType = pin.type || 'unknown';
          const variance = pin.varianceType || 'unknown';
          const site = f.responsibleSite || 'unknown';
          const passText = `Pass ${f.wpePassOrdinal !== null ? f.wpePassOrdinal : 'N/A'} (Shader: ${f.shaderName || 'N/A'}, ID: ${f.passId || 'N/A'})`;
          
          rows += `
            <tr id="finding-row-${f.wpePassOrdinal !== null ? f.wpePassOrdinal : idx}" style="${isSuppressed ? 'color: var(--text-muted); opacity: 0.75;' : ''}">
              <td><span class="badge ${isSuppressed ? 'badge-grey' : 'badge-blue'}">${f.bucket}</span></td>
              <td style="font-weight: 500;">${passText}</td>
              <td class="monospace">${name} (${pinType})</td>
              <td class="monospace" style="color: ${isSuppressed ? 'var(--text-muted)' : 'var(--color-amber)'};">${variance}</td>
              <td class="monospace" style="font-size: 11px; max-width: 180px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title="${site}">${site}</td>
            </tr>
          `;
        });

        return `
          <div style="overflow-x: auto;">
            <table>
              <thead>
                <tr>
                  <th style="width: 100px;">Bucket</th>
                  <th>Pass Info</th>
                  <th>Pinpoint Target</th>
                  <th>Variance</th>
                  <th>Responsible Site</th>
                </tr>
              </thead>
              <tbody>
                ${rows}
              </tbody>
            </table>
          </div>
        `;
      };

      let html = '<div class="card" style="height: 100%; box-sizing: border-box;">';
      html += '<div class="card-title">Findings Summary</div>';
      
      if (active.length > 0) {
        html += makeTable(active, false);
      } else {
        html += '<div style="padding: 12px; color: var(--text-secondary); font-style: italic; font-size: 13px;">No active unsuppressed findings.</div>';
      }

      if (suppressed.length > 0) {
        html += `
          <details style="margin-top: 16px;">
            <summary>Cascade (${suppressed.length} Suppressed Downstream Findings)</summary>
            <div class="details-content">
              ${makeTable(suppressed, true)}
            </div>
          </details>
        `;
      }

      html += '</div>';
      container.innerHTML = html;
    }

    function renderInspector() {
      const container = document.getElementById('inspector-container');
      const timelineData = getTimelineData();
      
      if (timelineData.length === 0) {
        container.innerHTML = '<div class="card text-muted">No timeline data mapping available.</div>';
        return;
      }

      // Check if both trace lists are missing
      if (wpeTrace.length === 0 && macTrace.length === 0) {
        container.innerHTML = `
          <div class="card" style="text-align: center; padding: 48px; border: 2px dashed var(--border-color);">
            <svg style="color: var(--text-muted); margin-bottom: 12px;" viewBox="0 0 24 24" width="48" height="48">
              <path fill="currentColor" d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
            </svg>
            <h3 style="margin-top: 0; color: var(--text-secondary);">GPU Trace Files Not Loaded</h3>
            <p style="color: var(--text-muted); max-width: 500px; margin: 0 auto 16px; font-size: 13px;">
              To inspect detailed constant buffer values, uniforms, textures, render targets, and pinpoint differences side-by-side, launch the CLI tool with trace inputs:
            </p>
            <code style="display: inline-block; background: rgba(0,0,0,0.3); padding: 8px 16px; border-radius: 4px; font-family: var(--font-mono); color: var(--color-amber); font-size: 12px; border: 1px solid var(--border-color);">
              python3 report_html.py --diff diff.json --windows wpe_trace.json --mac mac_trace.json --out report.html
            </code>
          </div>
        `;
        return;
      }

      let html = '';
      timelineData.forEach(entry => {
        html += renderPassSection(entry);
      });
      container.innerHTML = html;
    }

    function renderPassSection(entry) {
      const wpePass = wpePassByOrdinal[entry.wpe];
      const macPass = macPassByOrdinal[entry.mac];
      
      let shaderName = 'N/A';
      if (wpePass && wpePass.shaderName) shaderName = wpePass.shaderName;
      else if (macPass && macPass.shaderName) shaderName = macPass.shaderName;
      
      const badgeClass = getPassBadgeClass(entry);

      let detailsHtml = '';
      if (!wpePass && !macPass) {
        detailsHtml = `
          <div style="text-align: center; padding: 16px; color: var(--text-muted); font-style: italic;">
            Trace metadata for ordinals (WPE: ${entry.wpe !== null ? entry.wpe : 'N/A'}, Mac: ${entry.mac !== null ? entry.mac : 'N/A'}) was not found.
          </div>
        `;
      } else {
        const topologyRT = renderTopologyRT(entry, wpePass, macPass);
        const texturesTable = renderTexturesTable(wpePass, macPass);
        const uniformsTable = renderUniformsTable(wpePass, macPass);

        detailsHtml = `
          <div class="pass-grid">
            ${topologyRT}
            <div class="card" style="padding: 12px; background: rgba(255,255,255,0.01); display: flex; align-items: center; justify-content: center;">
              <div class="visual-diff-placeholder" style="width: 100%;">
                <svg class="placeholder-icon" viewBox="0 0 24 24" width="20" height="20" style="fill: var(--text-muted);">
                  <path d="M19 5v14H5V5h14m0-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-4.86 8.86l-3 3.87L9 13.14 6 17h12l-3.86-5.14z"/>
                </svg>
                <div class="placeholder-title">Visual Diff (SSIM) Unavailable</div>
                <div class="placeholder-text" style="font-size: 10px;">The conversion pipeline has no WPE Render Target readback for visual comparisons.</div>
              </div>
            </div>
          </div>
          ${texturesTable}
          ${uniformsTable}
        `;
      }

      return `
        <div class="pass-section" id="pass-${entry.index}" data-wpe-idx="${entry.wpe}" data-mac-idx="${entry.mac}" data-shader="${shaderName}" data-status="${entry.status}">
          <div class="pass-header">
            <div style="display: flex; align-items: center; gap: 8px;">
              <span class="badge ${badgeClass}">${entry.status}</span>
              <strong style="font-size: 15px;">Pass ${entry.index}: ${shaderName}</strong>
            </div>
            <div style="font-family: var(--font-mono); font-size: 11px; color: var(--text-secondary); display: flex; align-items: center; gap: 12px;">
              <span>WPE Ord: ${entry.wpe !== null ? entry.wpe : 'N/A'} ↔ Mac Ord: ${entry.mac !== null ? entry.mac : 'N/A'}</span>
              ${entry.cost ? `<span style="background: rgba(255,255,255,0.05); padding: 2px 6px; border-radius: 4px;">Alignment Cost: ${entry.cost}</span>` : ''}
            </div>
          </div>
          <div class="pass-body">
            ${detailsHtml}
          </div>
        </div>
      `;
    }

    function renderTopologyRT(entry, wpePass, macPass) {
      const wpeTopo = (wpePass && wpePass.draw && wpePass.draw.topology) || entry.wpeTopology || 'N/A';
      const macTopo = (macPass && macPass.draw && macPass.draw.topology) || 'N/A';
      
      const getRTList = (pass) => {
        if (!pass || !pass.targets || !pass.targets.color) return '<span class="text-muted">None</span>';
        return pass.targets.color.map(c => `<code class="monospace" style="font-size:11px;">${c.resource || 'unknown'}</code>`).join(', ');
      };
      
      return `
        <div class="card" style="padding: 12px; background: rgba(255,255,255,0.01);">
          <div class="card-title">Topology & Render Targets</div>
          <div style="font-size: 13px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 8px;">
            <div>
              <div style="font-weight:600; font-size:10px; color:var(--text-secondary); margin-bottom:4px; text-transform:uppercase;">WPE (Windows)</div>
              <div>Topology: <code class="monospace">${wpeTopo}</code></div>
              <div style="margin-top: 4px;">Color RT: ${getRTList(wpePass)}</div>
            </div>
            <div>
              <div style="font-weight:600; font-size:10px; color:var(--text-secondary); margin-bottom:4px; text-transform:uppercase;">Metal (Mac)</div>
              <div>Topology: <code class="monospace">${macTopo}</code></div>
              <div style="margin-top: 4px;">Color RT: ${getRTList(macPass)}</div>
            </div>
          </div>
        </div>
      `;
    }

    function getMergedTextures(wpePass, macPass) {
      const textures = {};
      
      if (wpePass && wpePass.textures) {
        wpePass.textures.forEach(t => {
          const key = t.slot !== undefined ? `slot-${t.slot}` : `name-${t.name}`;
          textures[key] = { wpe: t, mac: null };
        });
      }
      
      if (macPass && macPass.textures) {
        macPass.textures.forEach(t => {
          const key = t.slot !== undefined ? `slot-${t.slot}` : `name-${t.name}`;
          if (textures[key]) {
            textures[key].mac = t;
          } else {
            textures[key] = { wpe: null, mac: t };
          }
        });
      }
      
      return Object.values(textures).sort((a, b) => {
        const slotA = (a.wpe || a.mac).slot !== undefined ? (a.wpe || a.mac).slot : 999;
        const slotB = (b.wpe || b.mac).slot !== undefined ? (b.wpe || b.mac).slot : 999;
        return slotA - slotB;
      });
    }

    function renderTexturesTable(wpePass, macPass) {
      const textures = getMergedTextures(wpePass, macPass);
      if (textures.length === 0) return '';
      
      let rows = '';
      textures.forEach(t => {
        const w = t.wpe;
        const m = t.mac;
        
        const slot = (w || m).slot !== undefined ? (w || m).slot : '-';
        const name = (w && w.name) || (m && m.name) || `<span class="text-muted">unnamed</span>`;
        
        let wpeInfo = '<span class="text-muted">N/A</span>';
        let macInfo = '<span class="text-muted">N/A</span>';
        let status = '';
        let rowClass = '';
        
        if (w && m) {
          const wpeDims = w.width !== undefined ? `${w.width}x${w.height}` : 'unknown';
          const macDims = m.width !== undefined ? `${m.width}x${m.height}` : 'unknown';
          const dimsMatch = w.width === m.width && w.height === m.height;
          const formatMatch = w.format === m.format;
          
          const dimsClass = dimsMatch ? '' : 'val-mismatch';
          const formatClass = formatMatch ? '' : 'val-mismatch';
          
          wpeInfo = `
            <div class="monospace" style="font-size:11px; line-height:1.4;">
              Dim: <span class="${dimsClass}">${wpeDims}</span><br>
              Fmt: <span class="${formatClass}">${w.format || 'unknown'}</span><br>
              Res: <span class="text-muted" style="font-size:10px;">${w.resource || 'none'}</span>
            </div>
          `;
          macInfo = `
            <div class="monospace" style="font-size:11px; line-height:1.4;">
              Dim: <span class="${dimsClass}">${macDims}</span><br>
              Fmt: <span class="${formatClass}">${m.format || 'unknown'}</span><br>
              Res: <span class="text-muted" style="font-size:10px;">${m.resource || 'none'}</span>
              ${m.fallback ? '<br><span class="badge badge-amber" style="font-size:9px; padding:1px 3px; border:none; margin-top:2px;">Fallback</span>' : ''}
            </div>
          `;
          
          if (!dimsMatch || !formatMatch) {
            status = '<span class="badge badge-red">Mismatch</span>';
            rowClass = 'val-mismatch';
          } else {
            status = '<span class="badge badge-green">Match</span>';
          }
        } else if (w) {
          wpeInfo = `
            <div class="monospace" style="font-size:11px; line-height:1.4;">
              Dim: ${w.width !== undefined ? w.width + 'x' + w.height : 'unknown'}<br>
              Fmt: ${w.format || 'unknown'}<br>
              Res: ${w.resource || 'none'}
            </div>
          `;
          status = '<span class="badge badge-amber">WPE Only</span>';
        } else if (m) {
          macInfo = `
            <div class="monospace" style="font-size:11px; line-height:1.4;">
              Dim: ${m.width !== undefined ? m.width + 'x' + m.height : 'unknown'}<br>
              Fmt: ${m.format || 'unknown'}<br>
              Res: ${m.resource || 'none'}
            </div>
          `;
          status = '<span class="badge badge-amber">Metal Only</span>';
        }
        
        rows += `
          <tr class="${rowClass}">
            <td class="monospace">${slot}</td>
            <td style="font-weight: 500;">${name}</td>
            <td>${wpeInfo}</td>
            <td>${macInfo}</td>
            <td>${status}</td>
          </tr>
        `;
      });
      
      return `
        <div style="margin-top: 16px;">
          <div class="card-title">Textures</div>
          <div style="overflow-x: auto;">
            <table>
              <thead>
                <tr>
                  <th style="width: 60px;">Slot</th>
                  <th>Texture Name</th>
                  <th>WPE (Windows)</th>
                  <th>Metal (Mac)</th>
                  <th style="width: 100px;">Status</th>
                </tr>
              </thead>
              <tbody>
                ${rows}
              </tbody>
            </table>
          </div>
        </div>
      `;
    }

    function extractVariables(pass) {
      const vars = {};
      if (pass && pass.constantBuffers) {
        pass.constantBuffers.forEach(cb => {
          if (cb.variables) {
            cb.variables.forEach(v => {
              vars[v.name] = {
                name: v.name,
                value: v.value,
                matrix4x4: v.matrix4x4,
                matrixMajor: cb.matrixMajor || v.matrixMajor || 'row',
                stage: cb.stage || v.stage || 'unknown',
                usedByShader: v.usedByShader
              };
            });
          }
        });
      }
      return vars;
    }

    function compareMatrices(a, b) {
      if (!Array.isArray(a) || !Array.isArray(b)) return null;
      if (a.length !== b.length) return null;
      
      const len = a.length;
      let matchesDirect = true;
      let matchesTranspose = false;
      
      // Direct comparison
      for (let i = 0; i < len; i++) {
        if (Math.abs(a[i] - b[i]) > 1e-4) {
          matchesDirect = false;
          break;
        }
      }
      
      // Transpose comparison for 4x4 or 3x3
      if (len === 16) {
        matchesTranspose = true;
        for (let r = 0; r < 4; r++) {
          for (let c = 0; c < 4; c++) {
            if (Math.abs(a[r * 4 + c] - b[c * 4 + r]) > 1e-4) {
              matchesTranspose = false;
              break;
            }
          }
          if (!matchesTranspose) break;
        }
      } else if (len === 9) {
        matchesTranspose = true;
        for (let r = 0; r < 3; r++) {
          for (let c = 0; c < 3; c++) {
            if (Math.abs(a[r * 3 + c] - b[c * 3 + r]) > 1e-4) {
              matchesTranspose = false;
              break;
            }
          }
          if (!matchesTranspose) break;
        }
      }
      
      return { direct: matchesDirect, transpose: matchesTranspose };
    }

    function formatValue(val) {
      if (val === null || val === undefined) return '<span class="text-muted">N/A</span>';
      if (typeof val === 'boolean') return val ? 'true' : 'false';
      if (typeof val === 'number') {
        return Number.isInteger(val) ? val.toString() : val.toFixed(5);
      }
      if (Array.isArray(val)) {
        if (val.length === 16 || val.length === 9) {
          const size = val.length === 16 ? 4 : 3;
          let html = `<div class="matrix-grid" style="display: grid; grid-template-columns: repeat(${size}, minmax(40px, 1fr)); gap: 4px; font-family: var(--font-mono); background: rgba(0,0,0,0.2); padding: 4px; border-radius: 4px; font-size: 11px; max-width: 220px;">`;
          for (let i = 0; i < val.length; i++) {
            const num = typeof val[i] === 'number' ? val[i].toFixed(3) : String(val[i]);
            html += `<span title="${val[i]}">${num}</span>`;
          }
          html += '</div>';
          return html;
        }
        return `[${val.map(v => typeof v === 'number' ? v.toFixed(3) : String(v)).join(', ')}]`;
      }
      if (typeof val === 'object') {
        return JSON.stringify(val);
      }
      return String(val);
    }

    function renderUniformsTable(wpePass, macPass) {
      const wpeVars = extractVariables(wpePass);
      const macVars = extractVariables(macPass);
      const allVarNames = Array.from(new Set([...Object.keys(wpeVars), ...Object.keys(macVars)])).sort();
      
      if (allVarNames.length === 0) return '';
      
      let rows = '';
      allVarNames.forEach(varName => {
        const w = wpeVars[varName];
        const m = macVars[varName];
        
        const wVal = w ? w.value : null;
        const mVal = m ? m.value : null;
        
        let diffStr = '-';
        let cellClass = '';
        let badge = '';
        
        const isVolatile = volatileRegex.test(varName);
        
        if (w && m && wVal !== null && mVal !== null) {
          const wArr = Array.isArray(wVal);
          const mArr = Array.isArray(mVal);
          
          if (wArr && mArr) {
            if (wVal.length === mVal.length) {
              let maxDelta = 0;
              for (let i = 0; i < wVal.length; i++) {
                if (typeof wVal[i] === 'number' && typeof mVal[i] === 'number') {
                  maxDelta = Math.max(maxDelta, Math.abs(wVal[i] - mVal[i]));
                }
              }
              
              const matrixComp = compareMatrices(wVal, mVal);
              let isTranspose = false;
              
              if (matrixComp) {
                if (matrixComp.direct) {
                  maxDelta = 0;
                } else if (matrixComp.transpose) {
                  isTranspose = true;
                  maxDelta = 0;
                }
              }
              
              diffStr = maxDelta.toExponential(3);
              
              if (isTranspose) {
                badge = '<span class="transpose-badge" title="Values match when transposed (row-major vs column-major layout)">Transpose Detected</span>';
                cellClass = 'val-match';
              } else if (maxDelta > 1e-4) {
                if (isVolatile) {
                  cellClass = 'val-volatile';
                  badge = '<span class="badge badge-amber" style="font-size:9px; padding:1px 3px; margin-left:6px; border:none;">Volatile</span>';
                } else {
                  cellClass = 'val-mismatch';
                }
              } else {
                cellClass = 'val-match';
              }
            } else {
              diffStr = 'Layout Mismatch';
              cellClass = 'val-mismatch';
            }
          } else if (!wArr && !mArr) {
            if (typeof wVal === 'number' && typeof mVal === 'number') {
              const delta = Math.abs(wVal - mVal);
              diffStr = delta.toExponential(3);
              if (delta > 1e-4) {
                if (isVolatile) {
                  cellClass = 'val-volatile';
                  badge = '<span class="badge badge-amber" style="font-size:9px; padding:1px 3px; margin-left:6px; border:none;">Volatile</span>';
                } else {
                  cellClass = 'val-mismatch';
                }
              } else {
                cellClass = 'val-match';
              }
            } else {
              const match = wVal === mVal;
              diffStr = match ? '0.000e+0' : 'N/A';
              if (!match) {
                if (isVolatile) {
                  cellClass = 'val-volatile';
                  badge = '<span class="badge badge-amber" style="font-size:9px; padding:1px 3px; margin-left:6px; border:none;">Volatile</span>';
                } else {
                  cellClass = 'val-mismatch';
                }
              } else {
                cellClass = 'val-match';
              }
            }
          } else {
            diffStr = 'Type Mismatch';
            cellClass = 'val-mismatch';
          }
        } else {
          cellClass = 'val-volatile';
          diffStr = 'Missing Side';
        }
        
        const wFormatted = formatValue(wVal);
        const mFormatted = formatValue(mVal);
        const stage = (w || m).stage;
        
        rows += `
          <tr class="${cellClass}">
            <td class="monospace" style="font-weight:600;">${varName}${badge}</td>
            <td class="monospace" style="font-size:11px; text-transform:uppercase; color:var(--text-muted);">${stage}</td>
            <td>${wFormatted}</td>
            <td>${mFormatted}</td>
            <td class="monospace" style="font-size:11px; text-align:right;">${diffStr}</td>
          </tr>
        `;
      });
      
      return `
        <div style="margin-top: 16px;">
          <div class="card-title">Uniforms & Constants</div>
          <div style="overflow-x: auto;">
            <table>
              <thead>
                <tr>
                  <th>Variable Name</th>
                  <th style="width: 80px;">Stage</th>
                  <th>WPE (Windows)</th>
                  <th>Metal (Mac)</th>
                  <th style="width: 100px; text-align:right;">Δ (Delta)</th>
                </tr>
              </thead>
              <tbody>
                ${rows}
              </tbody>
            </table>
          </div>
        </div>
      `;
    }

    function getTimelineCellByIndex(idx) {
      return getTimelineData()[idx];
    }

    function scrollToPass(idx) {
      const el = document.getElementById('pass-' + idx);
      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        el.style.borderColor = 'var(--color-blue)';
        el.style.boxShadow = '0 0 16px rgba(59, 130, 246, 0.4)';
        setTimeout(() => {
          el.style.borderColor = '';
          el.style.boxShadow = '';
        }, 1500);
      } else {
        const cell = getTimelineCellByIndex(idx);
        const searchVal = cell && cell.wpe !== null ? cell.wpe : idx;
        const findingRow = document.getElementById('finding-row-' + searchVal);
        if (findingRow) {
          findingRow.scrollIntoView({ behavior: 'smooth', block: 'center' });
          findingRow.style.backgroundColor = 'rgba(239, 68, 68, 0.2)';
          setTimeout(() => {
            findingRow.style.backgroundColor = '';
          }, 1500);
        } else {
          alert("Detailed inspection for Pass #" + idx + " is not available because traces were not loaded.");
        }
      }
    }

    function filterPasses() {
      const query = document.getElementById('search-input').value.toLowerCase();
      const mismatchOnly = document.getElementById('mismatch-only').checked;
      const alignedOnly = document.getElementById('aligned-only').checked;
      
      const sections = document.querySelectorAll('.pass-section');
      
      sections.forEach(sec => {
        const wpeIdx = sec.getAttribute('data-wpe-idx');
        const macIdx = sec.getAttribute('data-mac-idx');
        const shader = (sec.getAttribute('data-shader') || '').toLowerCase();
        const isAligned = sec.getAttribute('data-status') === 'aligned' || (wpeIdx !== 'null' && macIdx !== 'null');
        
        const hasMismatch = sec.querySelectorAll('.val-mismatch').length > 0;
        let matchesQuery = !query || shader.includes(query);
        
        if (!matchesQuery && query) {
          const texts = sec.querySelectorAll('td');
          for (let td of texts) {
            if (td.textContent.toLowerCase().includes(query)) {
              matchesQuery = true;
              break;
            }
          }
        }
        
        let visible = matchesQuery;
        if (mismatchOnly && !hasMismatch) visible = false;
        if (alignedOnly && !isAligned) visible = false;
        
        sec.style.display = visible ? 'block' : 'none';
      });
    }

    function copyToClipboard(text, btn) {
      navigator.clipboard.writeText(text).then(() => {
        const original = btn.textContent;
        btn.textContent = "Copied!";
        btn.style.backgroundColor = "var(--color-green)";
        btn.style.borderColor = "var(--color-green)";
        setTimeout(() => {
          btn.textContent = original;
          btn.style.backgroundColor = "";
          btn.style.borderColor = "";
        }, 1500);
      }).catch(err => {
        console.error("Failed to copy path: ", err);
      });
    }
  </script>
</body>
</html>"""


def main():
    parser = argparse.ArgumentParser(description="Generate per-scene WPE-Metal divergence report.")
    parser.add_argument("--diff", required=True, help="Path to divergence-summary.json")
    parser.add_argument("--windows", help="Path to windows/trace.json (optional)")
    parser.add_argument("--mac", help="Path to mac/trace.json (optional)")
    parser.add_argument("--out", required=True, help="Path to write the output HTML report")
    
    args = parser.parse_args()
    
    # Load Summary Diff
    try:
        with open(args.diff, 'r') as f:
            summary = json.load(f)
    except Exception as e:
        sys.stderr.write(f"Error: Failed to load diff summary '{args.diff}': {e}\n")
        sys.exit(1)
        
    # Load WPE Trace
    wpe_trace = None
    if args.windows:
        try:
            with open(args.windows, 'r') as f:
                wpe_trace = json.load(f)
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to load Windows trace '{args.windows}': {e}\n")
            
    # Load Mac Trace
    mac_trace = None
    if args.mac:
        try:
            with open(args.mac, 'r') as f:
                mac_trace = json.load(f)
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to load Mac trace '{args.mac}': {e}\n")

    # The JS renders directly from raw trace passes (reads pass.constantBuffers /
    # pass.textures), so embed the passes lists as-is. The diff JSON already did
    # the uniform-by-name reconciliation; the report just displays both sides.
    if isinstance(wpe_trace, dict) and "passes" in wpe_trace:
        wpe_trace = wpe_trace["passes"]
    if isinstance(mac_trace, dict) and "passes" in mac_trace:
        mac_trace = mac_trace["passes"]

    report_data = {
        "summary": summary,
        "wpeTrace": wpe_trace,
        "macTrace": mac_trace,
    }
    
    # Build & Inject
    json_data = json.dumps(report_data, indent=2)
    html_content = HTML_TEMPLATE.replace("{{JSON_DATA}}", json_data)
    
    # Ensure parent output directory exists
    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir and not os.path.exists(out_dir):
        try:
            os.makedirs(out_dir, exist_ok=True)
        except Exception as e:
            sys.stderr.write(f"Error: Failed to create output directory '{out_dir}': {e}\n")
            sys.exit(1)
            
    # Write self-contained HTML
    try:
        with open(args.out, 'w', encoding='utf-8') as f:
            f.write(html_content)
        print(f"Success: WPE-Metal divergence report written to '{args.out}'")
    except Exception as e:
        sys.stderr.write(f"Error: Failed to write report file '{args.out}': {e}\n")
        sys.exit(1)


if __name__ == '__main__':
    main()
